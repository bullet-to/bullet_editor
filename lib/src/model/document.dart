import 'block.dart';
import 'inline_style.dart';

/// Result of mapping a global TextField offset to a block + local offset.
class BlockPosition {
  const BlockPosition(this.blockIndex, this.localOffset);
  final int blockIndex;
  final int localOffset;

  @override
  String toString() =>
      'BlockPosition(block: $blockIndex, offset: $localOffset)';
}

/// The document model: an ordered list of [TextBlock]s.
///
/// Immutable. Operations return a new [Document].
/// Blocks are joined by '\n' in the TextField, so the global offset
/// space is: block0.length + 1 + block1.length + 1 + ... + blockN.length.
class Document {
  const Document(this.blocks);

  /// Start with a single empty paragraph.
  factory Document.empty() =>
      Document([TextBlock(id: _nextId(), segments: const [])]);

  final List<TextBlock> blocks;

  /// The full plain text as it appears in the TextField.
  /// Blocks are separated by '\n'.
  String get plainText => blocks.map((b) => b.plainText).join('\n');

  /// Total length of the TextField text.
  int get textLength => plainText.length;

  /// Map a global TextField offset to (blockIndex, localOffset).
  ///
  /// Global layout: block0text \n block1text \n block2text
  /// Each '\n' separator counts as 1 character.
  BlockPosition blockAt(int globalOffset) {
    var remaining = globalOffset;
    for (var i = 0; i < blocks.length; i++) {
      final blockLen = blocks[i].length;
      if (remaining <= blockLen) {
        return BlockPosition(i, remaining);
      }
      remaining -= blockLen + 1; // +1 for the '\n' separator
    }
    // Clamp to end of last block
    return BlockPosition(blocks.length - 1, blocks.last.length);
  }

  /// Reverse mapping: block index + local offset -> global TextField offset.
  int globalOffset(int blockIndex, int localOffset) {
    var offset = 0;
    for (var i = 0; i < blockIndex; i++) {
      offset += blocks[i].length + 1; // +1 for '\n'
    }
    return offset + localOffset;
  }

  /// Find a block by its ID. Returns the index, or -1 if not found.
  int indexOfBlock(String blockId) {
    return blocks.indexWhere((b) => b.id == blockId);
  }

  /// Return a new Document with the block at [index] replaced.
  Document replaceBlock(int index, TextBlock newBlock) {
    final newBlocks = List<TextBlock>.from(blocks);
    newBlocks[index] = newBlock;
    return Document(newBlocks);
  }

  /// Return a new Document with a block inserted at [index].
  Document insertBlock(int index, TextBlock block) {
    final newBlocks = List<TextBlock>.from(blocks);
    newBlocks.insert(index, block);
    return Document(newBlocks);
  }

  /// Return a new Document with the block at [index] removed.
  Document removeBlock(int index) {
    final newBlocks = List<TextBlock>.from(blocks);
    newBlocks.removeAt(index);
    return Document(newBlocks);
  }

  /// Get the inline styles at a global TextField offset.
  /// Returns the styles of the segment the offset falls within.
  /// At a segment boundary, returns the styles of the preceding segment.
  Set<InlineStyle> stylesAt(int globalOffset) {
    final pos = blockAt(globalOffset);
    final block = blocks[pos.blockIndex];

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

  @override
  String toString() => 'Document(${blocks.length} blocks)';
}

// Simple incrementing ID generator. Fine for POC.
int _idCounter = 0;
String generateBlockId() => _nextId();
String _nextId() => 'block_${_idCounter++}';
