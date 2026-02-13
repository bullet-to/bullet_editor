import 'dart:math';

import 'block.dart';
import 'inline_style.dart';

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
/// [blocks] is the top-level list (the tree roots).
/// [allBlocks] is a depth-first flattening — what the TextField sees.
/// All offset mapping uses [allBlocks].
class Document {
  const Document(this.blocks);

  factory Document.empty() =>
      Document([TextBlock(id: generateBlockId(), segments: const [])]);

  /// Top-level blocks (tree roots). May have children.
  final List<TextBlock> blocks;

  /// Depth-first flattening of the entire tree.
  /// This is the linear sequence the TextField renders.
  List<TextBlock> get allBlocks {
    final result = <TextBlock>[];
    void walk(List<TextBlock> nodes) {
      for (final node in nodes) {
        result.add(node);
        walk(node.children);
      }
    }
    walk(blocks);
    return result;
  }

  /// Plain text as it appears in the TextField. Blocks separated by '\n'.
  String get plainText => allBlocks.map((b) => b.plainText).join('\n');

  int get textLength => plainText.length;

  /// Map a global TextField offset to (flatIndex, localOffset).
  BlockPosition blockAt(int globalOffset) {
    final flat = allBlocks;
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
  int globalOffset(int flatIndex, int localOffset) {
    final flat = allBlocks;
    var offset = 0;
    for (var i = 0; i < flatIndex; i++) {
      offset += flat[i].length + 1;
    }
    return offset + localOffset;
  }

  /// Get the inline styles at a global TextField offset.
  Set<InlineStyle> stylesAt(int globalOffset) {
    final flat = allBlocks;
    final pos = blockAt(globalOffset);
    final block = flat[pos.blockIndex];

    var offset = 0;
    for (final seg in block.segments) {
      final segEnd = offset + seg.text.length;
      if (pos.localOffset <= segEnd && (pos.localOffset > offset || offset == 0)) {
        return Set.of(seg.styles);
      }
      offset = segEnd;
    }
    return {};
  }

  /// Extract blocks/segments within a global offset range [start, end).
  ///
  /// Returns a list of [TextBlock]s with tree structure preserved.
  /// Block types and nesting are maintained. For partial blocks, only
  /// the selected segment slice is included. Used for copy/encode.
  List<TextBlock> extractRange(int start, int end) {
    if (start >= end) return [];
    final flat = allBlocks;
    final startPos = blockAt(start);
    final endPos = blockAt(end);

    // Build flat list of (depth, block) pairs.
    final items = <(int, TextBlock)>[];
    for (var i = startPos.blockIndex; i <= endPos.blockIndex; i++) {
      final block = flat[i];
      final localStart = i == startPos.blockIndex ? startPos.localOffset : 0;
      final localEnd =
          i == endPos.blockIndex ? endPos.localOffset : block.length;

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
    return _buildTreeFromPairs(items, items.isEmpty ? 0 : items.first.$1);
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

  // Legacy convenience methods (used by operations via flat index).

  Document replaceBlock(int flatIndex, TextBlock newBlock) =>
      replaceBlockByFlatIndex(flatIndex, newBlock);

  Document removeBlock(int flatIndex) =>
      removeBlockByFlatIndex(flatIndex);

  int indexOfBlock(String blockId) =>
      allBlocks.indexWhere((b) => b.id == blockId);

  @override
  String toString() => 'Document(${blocks.length} roots, ${allBlocks.length} total)';
}

// -- Tree manipulation internals --

List<TextBlock> _replaceInTree(List<TextBlock> nodes, String targetId, TextBlock replacement) {
  return nodes.map((node) {
    if (node.id == targetId) return replacement;
    final newChildren = _replaceInTree(node.children, targetId, replacement);
    if (identical(newChildren, node.children)) return node;
    return node.copyWith(children: newChildren);
  }).toList();
}

List<TextBlock> _removeFromTree(List<TextBlock> nodes, String targetId) {
  final result = <TextBlock>[];
  for (final node in nodes) {
    if (node.id == targetId) continue; // skip this node
    final newChildren = _removeFromTree(node.children, targetId);
    if (identical(newChildren, node.children)) {
      result.add(node);
    } else {
      result.add(node.copyWith(children: newChildren));
    }
  }
  return result;
}

List<TextBlock> _insertAfterInTree(List<TextBlock> nodes, String targetId, TextBlock newBlock) {
  final result = <TextBlock>[];
  for (final node in nodes) {
    if (node.id == targetId) {
      result.add(node);
      result.add(newBlock); // insert after
    } else {
      final newChildren = _insertAfterInTree(node.children, targetId, newBlock);
      if (identical(newChildren, node.children)) {
        result.add(node);
      } else {
        result.add(node.copyWith(children: newChildren));
      }
    }
  }
  return result;
}

int? _depthInTree(List<TextBlock> nodes, String targetId, int currentDepth) {
  for (final node in nodes) {
    if (node.id == targetId) return currentDepth;
    final found = _depthInTree(node.children, targetId, currentDepth + 1);
    if (found != null) return found;
  }
  return null;
}

TextBlock? _findParent(List<TextBlock> nodes, String targetId, TextBlock? parent) {
  for (final node in nodes) {
    if (node.id == targetId) return parent;
    final found = _findParent(node.children, targetId, node);
    if (found != null) return found;
  }
  return null;
}

/// Build a tree from (depth, block) pairs, same algorithm as MarkdownCodec._buildTree.
List<TextBlock> _buildTreeFromPairs(
    List<(int, TextBlock)> items, int minDepth) {
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
        : _buildTreeFromPairs(childItems, depth + 1);
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
