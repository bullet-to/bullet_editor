import 'dart:math';

import 'block.dart';

/// Controls which segment is returned when an offset falls on a boundary
/// between two adjacent segments.
enum SegmentBoundary {
  /// Return the segment starting at this offset (what you'd type into).
  forward,

  /// Return the segment ending at this offset (the one the cursor is "on").
  backward,
}

/// Result of mapping a global TextField offset to a block + local offset.
class BlockPosition {
  const BlockPosition(this.blockIndex, this.localOffset);

  /// Index into [Document.allBlocks] (the flat, depth-first list).
  final int blockIndex;
  final int localOffset;

  @override
  String toString() =>
      'BlockPosition(block: $blockIndex, offset: $localOffset)';
}

/// The document model: a tree of [TextBlock]s.
///
/// Immutable. Operations return a new [Document].
///
/// [B] is the block type key — typically an enum like [BlockType].
///
/// [blocks] is the top-level list (the tree roots).
/// [allBlocks] is a depth-first flattening — what the TextField sees.
/// All offset mapping uses [allBlocks].
class Document<B> {
  Document(this.blocks) : _allBlocks = _flatten(blocks);

  factory Document.empty(B defaultBlockType) => Document(
        [TextBlock(id: generateBlockId(), blockType: defaultBlockType, segments: const [])],
      );

  /// Top-level blocks (tree roots). May have children.
  final List<TextBlock<B>> blocks;

  /// Cached depth-first flattening of the entire tree.
  final List<TextBlock<B>> _allBlocks;

  /// Depth-first flattening of the entire tree.
  /// This is the linear sequence the TextField renders.
  /// Cached — O(1) after first construction.
  List<TextBlock<B>> get allBlocks => _allBlocks;

  static List<TextBlock<B>> _flatten<B>(List<TextBlock<B>> roots) {
    final result = <TextBlock<B>>[];
    void walk(List<TextBlock<B>> nodes) {
      for (final node in nodes) {
        result.add(node);
        walk(node.children);
      }
    }
    walk(roots);
    return List.unmodifiable(result);
  }

  /// Plain text as it appears in the TextField. Blocks separated by '\n'.
  String get plainText => allBlocks.map((b) => b.plainText).join('\n');

  int get textLength => plainText.length;

  /// Map a global TextField offset to (flatIndex, localOffset).
  ///
  /// Clamps to valid range: negative offsets map to (0, 0),
  /// offsets beyond the document map to the end of the last block.
  BlockPosition blockAt(int globalOffset) {
    final flat = _allBlocks;
    if (flat.isEmpty) return const BlockPosition(0, 0);
    if (globalOffset <= 0) return const BlockPosition(0, 0);

    var remaining = globalOffset;
    for (var i = 0; i < flat.length; i++) {
      final blockLen = flat[i].length;
      if (remaining <= blockLen) {
        return BlockPosition(i, remaining);
      }
      remaining -= blockLen + 1;
    }
    return BlockPosition(flat.length - 1, flat.last.length);
  }

  /// Reverse mapping: flat index + local offset -> global TextField offset.
  ///
  /// Clamps [flatIndex] to `[0, allBlocks.length - 1]`.
  int globalOffset(int flatIndex, int localOffset) {
    final flat = _allBlocks;
    if (flat.isEmpty) return 0;
    final clampedIndex = flatIndex.clamp(0, flat.length - 1);
    var offset = 0;
    for (var i = 0; i < clampedIndex; i++) {
      offset += flat[i].length + 1;
    }
    return offset + localOffset;
  }

  /// Return the [StyledSegment] at a global offset within the document.
  ///
  /// At segment boundaries the [boundary] parameter controls which segment
  /// is returned:
  /// - [SegmentBoundary.forward] — the segment starting at this offset
  ///   (what you'd type into). Default; used for `_activeStyles`.
  /// - [SegmentBoundary.backward] — the segment ending at this offset
  ///   (the one the cursor is "on"). Used for link detection at link end.
  ///
  /// Returns null if the block has no segments.
  StyledSegment? segmentAt(int globalOffset, {
    SegmentBoundary boundary = SegmentBoundary.forward,
  }) {
    final pos = blockAt(globalOffset);
    final block = allBlocks[pos.blockIndex];
    var offset = 0;
    for (var i = 0; i < block.segments.length; i++) {
      final seg = block.segments[i];
      final segEnd = offset + seg.text.length;

      // Strictly inside — unambiguous.
      if (pos.localOffset > offset && pos.localOffset < segEnd) return seg;

      // At a boundary between two segments (offset == segEnd).
      if (pos.localOffset == segEnd && seg.text.isNotEmpty) {
        if (boundary == SegmentBoundary.backward) return seg;
        // Forward: prefer next segment if available.
        if (i + 1 < block.segments.length) {
          offset = segEnd;
          continue;
        }
        // No next segment — return this one.
        return seg;
      }

      // At segment start.
      if (pos.localOffset == offset && seg.text.isNotEmpty) {
        if (boundary == SegmentBoundary.forward || offset == 0) return seg;
      }

      offset = segEnd;
    }
    return null;
  }

  /// Get the inline styles at a global offset.
  ///
  /// Uses backward boundary so that the cursor at the end of a bold word
  /// reports bold (matching standard editor behavior: typing continues
  /// the style you just left).
  Set<Object> stylesAt(int globalOffset) {
    final seg = segmentAt(globalOffset, boundary: SegmentBoundary.backward);
    return seg != null ? Set.of(seg.styles) : {};
  }

  /// Extract blocks/segments within a global offset range [start, end).
  ///
  /// Returns a list of [TextBlock]s with tree structure preserved.
  /// Block types and nesting are maintained. For partial blocks, only
  /// the selected segment slice is included. Used for copy/encode.
  List<TextBlock<B>> extractRange(int start, int end) {
    if (start >= end || start < 0) return [];
    final flat = _allBlocks;
    if (flat.isEmpty) return [];
    final startPos = blockAt(start);
    final endPos = blockAt(end);

    // Build flat list of (depth, block) pairs.
    final items = <(int, TextBlock<B>)>[];
    for (var i = startPos.blockIndex; i <= endPos.blockIndex; i++) {
      final block = flat[i];
      final localStart = i == startPos.blockIndex ? startPos.localOffset : 0;
      final localEnd =
          i == endPos.blockIndex ? endPos.localOffset : block.length;

      final sliced = _sliceSegments(block.segments, localStart, localEnd);
      final extracted = TextBlock<B>(
        id: generateBlockId(),
        blockType: block.blockType,
        segments: sliced,
        metadata: block.metadata,
      );
      items.add((depthOf(i), extracted));
    }

    // Rebuild tree from (depth, block) pairs.
    return buildTreeFromPairs(items, items.isEmpty ? 0 : items.first.$1);
  }

  // -- Tree mutation helpers --
  // All return a new Document with the tree immutably updated.

  /// Replace a block found by flat index.
  Document<B> replaceBlockByFlatIndex(int flatIndex, TextBlock<B> newBlock) {
    final targetId = allBlocks[flatIndex].id;
    return Document(_replaceInTree(blocks, targetId, newBlock));
  }

  /// Remove a block found by flat index.
  Document<B> removeBlockByFlatIndex(int flatIndex) {
    final targetId = allBlocks[flatIndex].id;
    return Document(_removeFromTree(blocks, targetId));
  }

  /// Insert a block as a sibling after the block at flat index.
  Document<B> insertAfterFlatIndex(int flatIndex, TextBlock<B> newBlock) {
    final targetId = allBlocks[flatIndex].id;
    return Document(_insertAfterInTree(blocks, targetId, newBlock));
  }

  /// Add [child] as the last child of the block at [flatIndex].
  Document<B> addChild(int flatIndex, TextBlock<B> child) {
    final flat = allBlocks;
    final parent = flat[flatIndex];
    final updatedParent = parent.copyWith(
      children: [...parent.children, child],
    );
    return replaceBlockByFlatIndex(flatIndex, updatedParent);
  }

  /// Find the depth (nesting level) of a block by its flat index.
  /// Root-level blocks have depth 0.
  int depthOf(int flatIndex) {
    final targetId = allBlocks[flatIndex].id;
    return _depthInTree(blocks, targetId, 0) ?? 0;
  }

  /// Find the parent of a block by flat index. Returns null if root-level.
  TextBlock<B>? parentOf(int flatIndex) {
    final targetId = allBlocks[flatIndex].id;
    return _findParent(blocks, targetId, null);
  }

  /// Find the index of a block in its parent's children list (or in root blocks).
  /// Returns -1 if not found.
  int siblingIndex(int flatIndex) {
    final targetId = allBlocks[flatIndex].id;
    final parent = parentOf(flatIndex);
    final siblings = parent?.children ?? blocks;
    return siblings.indexWhere((b) => b.id == targetId);
  }

  /// Previous sibling of the block at flat index, or null if first.
  TextBlock<B>? previousSibling(int flatIndex) {
    final idx = siblingIndex(flatIndex);
    if (idx <= 0) return null;
    final parent = parentOf(flatIndex);
    final siblings = parent?.children ?? blocks;
    return siblings[idx - 1];
  }

  // Legacy convenience methods (used by operations via flat index).

  Document<B> replaceBlock(int flatIndex, TextBlock<B> newBlock) =>
      replaceBlockByFlatIndex(flatIndex, newBlock);

  Document<B> removeBlock(int flatIndex) =>
      removeBlockByFlatIndex(flatIndex);

  /// Remove a block but promote its children to become siblings at the
  /// same level. Used by DeleteRange to avoid silently discarding subtrees.
  Document<B> removeBlockPromoteChildren(int flatIndex) {
    final targetId = allBlocks[flatIndex].id;
    return Document(_removePromoteChildren(blocks, targetId));
  }

  int indexOfBlock(String blockId) =>
      allBlocks.indexWhere((b) => b.id == blockId);

  @override
  String toString() => 'Document(${blocks.length} roots, ${allBlocks.length} total)';
}

// -- Tree manipulation internals --
//
// All tree mutations use a single recursive visitor pattern.
// Each operation provides a callback that receives the target node
// and returns a list of replacement nodes (empty = remove, >1 = insert after).

/// Walk [nodes] recursively looking for the block with [targetId].
/// When found, call [onFound] which returns the replacement node list.
/// Returns (newNodes, found) — `found` prevents unnecessary copies.
(List<TextBlock<B>>, bool) _visitTree<B>(
  List<TextBlock<B>> nodes,
  String targetId,
  List<TextBlock<B>> Function(TextBlock<B> node) onFound,
) {
  var changed = false;
  final result = <TextBlock<B>>[];
  for (final node in nodes) {
    if (node.id == targetId) {
      result.addAll(onFound(node));
      changed = true;
    } else {
      final (newChildren, childChanged) =
          _visitTree(node.children, targetId, onFound);
      if (childChanged) {
        result.add(node.copyWith(children: newChildren));
        changed = true;
      } else {
        result.add(node);
      }
    }
  }
  return (changed ? result : nodes, changed);
}

List<TextBlock<B>> _replaceInTree<B>(
    List<TextBlock<B>> nodes, String targetId, TextBlock<B> replacement) {
  return _visitTree(nodes, targetId, (_) => [replacement]).$1;
}

List<TextBlock<B>> _removeFromTree<B>(List<TextBlock<B>> nodes, String targetId) {
  return _visitTree(nodes, targetId, (_) => <TextBlock<B>>[]).$1;
}

List<TextBlock<B>> _removePromoteChildren<B>(
    List<TextBlock<B>> nodes, String targetId) {
  return _visitTree(nodes, targetId, (node) => node.children).$1;
}

List<TextBlock<B>> _insertAfterInTree<B>(
    List<TextBlock<B>> nodes, String targetId, TextBlock<B> newBlock) {
  return _visitTree(nodes, targetId, (node) => [node, newBlock]).$1;
}

int? _depthInTree<B>(List<TextBlock<B>> nodes, String targetId, int currentDepth) {
  for (final node in nodes) {
    if (node.id == targetId) return currentDepth;
    final found = _depthInTree(node.children, targetId, currentDepth + 1);
    if (found != null) return found;
  }
  return null;
}

TextBlock<B>? _findParent<B>(
    List<TextBlock<B>> nodes, String targetId, TextBlock<B>? parent) {
  for (final node in nodes) {
    if (node.id == targetId) return parent;
    final found = _findParent(node.children, targetId, node);
    if (found != null) return found;
  }
  return null;
}

/// Build a tree from (depth, block) pairs.
///
/// Shared by [Document.extractRange] and [MarkdownCodec].
List<TextBlock<B>> buildTreeFromPairs<B>(
    List<(int, TextBlock<B>)> items, int minDepth) {
  final result = <TextBlock<B>>[];
  var i = 0;
  while (i < items.length) {
    final (depth, block) = items[i];
    if (depth < minDepth) break;
    i++;
    final childItems = <(int, TextBlock<B>)>[];
    while (i < items.length && items[i].$1 > depth) {
      childItems.add(items[i]);
      i++;
    }
    final children = childItems.isEmpty
        ? const <TextBlock<Never>>[]
        : buildTreeFromPairs(childItems, depth + 1);
    result
        .add(children.isEmpty ? block : block.copyWith(children: children));
  }
  return result;
}

/// Generate a unique block ID.
///
/// Uses random hex to avoid collisions across documents, paste operations,
/// and persistence round-trips.
final _random = Random();
String generateBlockId() {
  final timestamp = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
  final rand = _random.nextInt(0xFFFF).toRadixString(16).padLeft(4, '0');
  return 'blk_${timestamp}_$rand';
}

/// Slice segments to extract the range [start, end) within a block.
List<StyledSegment> _sliceSegments(
    List<StyledSegment> segments, int start, int end) {
  final result = <StyledSegment>[];
  var pos = 0;
  for (final seg in segments) {
    final segStart = pos;
    final segEnd = pos + seg.text.length;
    pos = segEnd;

    // Skip segments entirely outside the range.
    if (segEnd <= start || segStart >= end) continue;

    // Compute the overlap.
    final overlapStart = (start - segStart).clamp(0, seg.text.length);
    final overlapEnd = (end - segStart).clamp(0, seg.text.length);
    if (overlapEnd <= overlapStart) continue;

    result.add(StyledSegment(
      seg.text.substring(overlapStart, overlapEnd),
      seg.styles,
      seg.attributes,
    ));
  }
  return result;
}
