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

/// The document model: a tree of [TextBlock]s.
///
/// Immutable. Operations return a new [Document].
///
/// [blocks] is the top-level list (the tree roots).
/// [allBlocks] is a depth-first flattening, computed lazily — edit operations
/// chain intermediate documents whose flattening and id map may never be read.
class Document {
  Document(this.blocks);

  factory Document.empty(String defaultBlockType) => Document([
    TextBlock(
      id: generateBlockId(),
      blockType: defaultBlockType,
      segments: const [],
    ),
  ]);

  /// Top-level blocks (tree roots). May have children.
  final List<TextBlock> blocks;

  /// Depth-first flattening of the entire tree.
  /// Lazy — computed on first read, O(1) after.
  late final List<TextBlock> allBlocks = _flatten(blocks);

  /// Block id → index into [allBlocks]. Lazy — the IME hot path, selection
  /// normalization, and every op's resolve-at-apply hit this per keystroke,
  /// but intermediate documents inside an op chain never read it.
  late final Map<String, int> idToFlatIndex = {
    for (var i = 0; i < allBlocks.length; i++) allBlocks[i].id: i,
  };

  static List<TextBlock> _flatten(List<TextBlock> roots) {
    final result = <TextBlock>[];
    void walk(List<TextBlock> nodes) {
      for (final node in nodes) {
        result.add(node);
        walk(node.children);
      }
    }

    walk(roots);
    return List.unmodifiable(result);
  }

  /// Index of a block in [allBlocks], or -1 if the id is not in the document.
  int indexOfBlock(String blockId) => idToFlatIndex[blockId] ?? -1;

  /// The block with [blockId], or null if not in the document.
  TextBlock? blockById(String blockId) {
    final index = idToFlatIndex[blockId];
    return index == null ? null : allBlocks[index];
  }

  /// Return the [StyledSegment] at a local offset within the block at
  /// [flatIndex].
  ///
  /// At segment boundaries the [boundary] parameter controls which segment
  /// is returned:
  /// - [SegmentBoundary.forward] — the segment starting at this offset
  ///   (what you'd type into). Default; used for active-style queries.
  /// - [SegmentBoundary.backward] — the segment ending at this offset
  ///   (the one the cursor is "on"). Used for link detection at link end.
  ///
  /// Returns null if the block has no segments.
  StyledSegment? segmentAt(
    int flatIndex,
    int localOffset, {
    SegmentBoundary boundary = SegmentBoundary.forward,
  }) {
    final block = allBlocks[flatIndex];
    var offset = 0;
    for (var i = 0; i < block.segments.length; i++) {
      final seg = block.segments[i];
      final segEnd = offset + seg.text.length;

      // Strictly inside — unambiguous.
      if (localOffset > offset && localOffset < segEnd) return seg;

      // At a boundary between two segments (offset == segEnd).
      if (localOffset == segEnd && seg.text.isNotEmpty) {
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
      if (localOffset == offset && seg.text.isNotEmpty) {
        if (boundary == SegmentBoundary.forward || offset == 0) return seg;
      }

      offset = segEnd;
    }
    return null;
  }

  /// Get the inline styles at a local offset within the block at [flatIndex].
  ///
  /// Uses backward boundary so that the cursor at the end of a bold word
  /// reports bold (matching standard editor behavior: typing continues
  /// the style you just left).
  Set<Object> stylesAt(int flatIndex, int localOffset) {
    final seg = segmentAt(
      flatIndex,
      localOffset,
      boundary: SegmentBoundary.backward,
    );
    return seg != null ? Set.of(seg.styles) : {};
  }

  /// Extract blocks/segments within the range from (startIndex, startOffset)
  /// to (endIndex, endOffset) — flat indices + local offsets, start ≤ end.
  ///
  /// Returns a list of [TextBlock]s with tree structure preserved.
  /// Block types and nesting are maintained. For partial blocks, only
  /// the selected segment slice is included. Used for copy/encode.
  List<TextBlock> extractRange(
    int startIndex,
    int startOffset,
    int endIndex,
    int endOffset,
  ) {
    final flat = allBlocks;
    if (flat.isEmpty || startIndex < 0 || endIndex >= flat.length) return [];
    if (startIndex > endIndex) return [];
    if (startIndex == endIndex && startOffset >= endOffset) return [];

    // Build flat list of (depth, block) pairs.
    final items = <(int, TextBlock)>[];
    for (var i = startIndex; i <= endIndex; i++) {
      final block = flat[i];
      final localStart = i == startIndex ? startOffset : 0;
      final localEnd = i == endIndex ? endOffset : block.length;

      final sliced = _sliceSegments(block.segments, localStart, localEnd);
      final extracted = TextBlock(
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
  Document replaceBlockByFlatIndex(int flatIndex, TextBlock newBlock) {
    final targetId = allBlocks[flatIndex].id;
    return Document(_replaceInTree(blocks, targetId, newBlock));
  }

  /// Remove a block found by flat index.
  Document removeBlockByFlatIndex(int flatIndex) {
    final targetId = allBlocks[flatIndex].id;
    return Document(_removeFromTree(blocks, targetId));
  }

  /// Insert a block as a sibling after the block at flat index.
  Document insertAfterFlatIndex(int flatIndex, TextBlock newBlock) {
    final targetId = allBlocks[flatIndex].id;
    return Document(_insertAfterInTree(blocks, targetId, newBlock));
  }

  /// Insert a block as a sibling before the block at flat index.
  Document insertBeforeFlatIndex(int flatIndex, TextBlock newBlock) {
    final targetId = allBlocks[flatIndex].id;
    return Document(_insertBeforeInTree(blocks, targetId, newBlock));
  }

  /// Add [child] as the last child of the block at [flatIndex].
  Document addChild(int flatIndex, TextBlock child) {
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
  TextBlock? parentOf(int flatIndex) {
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
  TextBlock? previousSibling(int flatIndex) {
    final idx = siblingIndex(flatIndex);
    if (idx <= 0) return null;
    final parent = parentOf(flatIndex);
    final siblings = parent?.children ?? blocks;
    return siblings[idx - 1];
  }

  /// Replace a block found by flat index.
  Document replaceBlock(int flatIndex, TextBlock newBlock) =>
      replaceBlockByFlatIndex(flatIndex, newBlock);

  /// Remove a block found by flat index.
  Document removeBlock(int flatIndex) => removeBlockByFlatIndex(flatIndex);

  /// Remove a block but promote its children to become siblings at the
  /// same level. Used by DeleteRange to avoid silently discarding subtrees.
  Document removeBlockPromoteChildren(int flatIndex) {
    final targetId = allBlocks[flatIndex].id;
    return Document(_removePromoteChildren(blocks, targetId));
  }

  @override
  String toString() =>
      'Document(${blocks.length} roots, ${allBlocks.length} total)';
}

// -- Tree manipulation internals --
//
// All tree mutations use a single recursive visitor pattern.
// Each operation provides a callback that receives the target node
// and returns a list of replacement nodes (empty = remove, >1 = insert after).

/// Walk [nodes] recursively looking for the block with [targetId].
/// When found, call [onFound] which returns the replacement node list.
/// Returns (newNodes, found) — `found` prevents unnecessary copies.
(List<TextBlock>, bool) _visitTree(
  List<TextBlock> nodes,
  String targetId,
  List<TextBlock> Function(TextBlock node) onFound,
) {
  var changed = false;
  final result = <TextBlock>[];
  for (final node in nodes) {
    if (node.id == targetId) {
      result.addAll(onFound(node));
      changed = true;
    } else {
      final (newChildren, childChanged) = _visitTree(
        node.children,
        targetId,
        onFound,
      );
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

List<TextBlock> _replaceInTree(
  List<TextBlock> nodes,
  String targetId,
  TextBlock replacement,
) {
  return _visitTree(nodes, targetId, (_) => [replacement]).$1;
}

List<TextBlock> _removeFromTree(List<TextBlock> nodes, String targetId) {
  return _visitTree(nodes, targetId, (_) => <TextBlock>[]).$1;
}

List<TextBlock> _removePromoteChildren(List<TextBlock> nodes, String targetId) {
  return _visitTree(nodes, targetId, (node) => node.children).$1;
}

List<TextBlock> _insertAfterInTree(
  List<TextBlock> nodes,
  String targetId,
  TextBlock newBlock,
) {
  return _visitTree(nodes, targetId, (node) => [node, newBlock]).$1;
}

List<TextBlock> _insertBeforeInTree(
  List<TextBlock> nodes,
  String targetId,
  TextBlock newBlock,
) {
  return _visitTree(nodes, targetId, (node) => [newBlock, node]).$1;
}

int? _depthInTree(List<TextBlock> nodes, String targetId, int currentDepth) {
  for (final node in nodes) {
    if (node.id == targetId) return currentDepth;
    final found = _depthInTree(node.children, targetId, currentDepth + 1);
    if (found != null) return found;
  }
  return null;
}

TextBlock? _findParent(
  List<TextBlock> nodes,
  String targetId,
  TextBlock? parent,
) {
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
List<TextBlock> buildTreeFromPairs(List<(int, TextBlock)> items, int minDepth) {
  final result = <TextBlock>[];
  var i = 0;
  while (i < items.length) {
    final (depth, block) = items[i];
    if (depth < minDepth) break;
    i++;
    final childItems = <(int, TextBlock)>[];
    while (i < items.length && items[i].$1 > depth) {
      childItems.add(items[i]);
      i++;
    }
    final children = childItems.isEmpty
        ? const <TextBlock>[]
        : buildTreeFromPairs(childItems, depth + 1);
    result.add(children.isEmpty ? block : block.copyWith(children: children));
  }
  return result;
}

/// Generate a globally unique block ID (UUID v4).
///
/// Ids must never collide across documents, paste operations, persistence
/// round-trips, or replicas (the collaboration-readiness constraint, D14).
final _random = Random.secure();
String generateBlockId() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx
  final hex = [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')];
  return '${hex.sublist(0, 4).join()}-${hex.sublist(4, 6).join()}-'
      '${hex.sublist(6, 8).join()}-${hex.sublist(8, 10).join()}-'
      '${hex.sublist(10).join()}';
}

/// Slice segments to extract the range [start, end) within a block.
List<StyledSegment> _sliceSegments(
  List<StyledSegment> segments,
  int start,
  int end,
) {
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

    result.add(
      StyledSegment(
        seg.text.substring(overlapStart, overlapEnd),
        seg.styles,
        seg.attributes,
      ),
    );
  }
  return result;
}
