import '../model/block.dart';
import '../model/block_policies.dart';
import '../model/document.dart';
import '../model/inline_style.dart';

/// A single atomic edit to the document.
///
/// Each operation knows how to [apply] itself to a Document, returning
/// a new Document. The controller composes these into Transactions.
sealed class EditOperation {
  Document apply(Document doc);
}

/// Insert [text] into the block at [blockIndex] at [offset].
///
/// If [styles] is provided, the inserted text gets those styles explicitly
/// (from the controller's active styles). If null, inherits from the
/// segment at the insertion point.
class InsertText extends EditOperation {
  InsertText(
    this.blockIndex,
    this.offset,
    this.text, {
    this.styles,
    this.attributes,
  });

  final int blockIndex;
  final int offset;
  final String text;
  final Set<InlineStyle>? styles;

  /// Attributes for data-carrying styles (e.g. `{'url': '...'}` for links).
  final Map<String, dynamic>? attributes;

  @override
  Document apply(Document doc) {
    final block = doc.allBlocks[blockIndex];
    final newSegments = _spliceInsert(
      block.segments,
      offset,
      text,
      styles: styles,
      attributes: attributes,
    );
    final newBlock = block.copyWith(segments: mergeSegments(newSegments));
    return doc.replaceBlock(blockIndex, newBlock);
  }

  @override
  String toString() =>
      'InsertText(block: $blockIndex, offset: $offset, "$text")';
}

/// Delete [length] characters from block at [blockIndex] starting at [offset].
class DeleteText extends EditOperation {
  DeleteText(this.blockIndex, this.offset, this.length);

  final int blockIndex;
  final int offset;
  final int length;

  @override
  Document apply(Document doc) {
    final block = doc.allBlocks[blockIndex];
    final newSegments = _spliceDelete(block.segments, offset, length);
    final newBlock = block.copyWith(segments: mergeSegments(newSegments));
    return doc.replaceBlock(blockIndex, newBlock);
  }

  @override
  String toString() =>
      'DeleteText(block: $blockIndex, offset: $offset, len: $length)';
}

/// Toggle [style] on the range [start]..[end] in block at [blockIndex].
///
/// If the entire range already has the style, remove it.
/// Otherwise, apply it to the entire range.
class ToggleStyle extends EditOperation {
  ToggleStyle(
    this.blockIndex,
    this.start,
    this.end,
    this.style, {
    this.attributes,
  });

  final int blockIndex;
  final int start;
  final int end;
  final InlineStyle style;

  /// Attributes to set when applying a data-carrying style (e.g. link URL).
  /// Ignored when removing a style.
  final Map<String, dynamic>? attributes;

  @override
  Document apply(Document doc) {
    final block = doc.allBlocks[blockIndex];
    final segments = block.segments;

    // Expand segments into per-character style sets and attribute maps.
    final charStyles = <Set<InlineStyle>>[];
    final charAttrs = <Map<String, dynamic>>[];
    for (final seg in segments) {
      for (var i = 0; i < seg.text.length; i++) {
        charStyles.add(Set.of(seg.styles));
        charAttrs.add(Map.of(seg.attributes));
      }
    }

    // Check if the entire range already has the style.
    final allHaveStyle = charStyles
        .skip(start)
        .take(end - start)
        .every((s) => s.contains(style));

    // Toggle: remove if all have it, add if any don't.
    for (var i = start; i < end; i++) {
      if (allHaveStyle) {
        charStyles[i].remove(style);
        // Clear attributes from data-carrying styles when removing.
        if (attributes != null) {
          for (final key in attributes!.keys) {
            charAttrs[i].remove(key);
          }
        }
      } else {
        charStyles[i].add(style);
        // Set attributes when adding a data-carrying style.
        if (attributes != null) {
          charAttrs[i].addAll(attributes!);
        }
      }
    }

    // Rebuild segments from per-character styles + attributes.
    final plainText = block.plainText;
    final newSegments = <StyledSegment>[];
    for (var i = 0; i < plainText.length; i++) {
      newSegments.add(StyledSegment(plainText[i], charStyles[i], charAttrs[i]));
    }

    final newBlock = block.copyWith(segments: mergeSegments(newSegments));
    return doc.replaceBlock(blockIndex, newBlock);
  }

  @override
  String toString() =>
      'ToggleStyle(block: $blockIndex, $start..$end, ${style.name})';
}

/// Split block at [blockIndex] at [offset], creating a new block after it.
///
/// This is what happens when the user presses Enter.
/// - Headings: new block is always a paragraph (Notion-style).
/// - List items: new block is another list item (continue the list).
/// - Paragraphs: new block is a paragraph.
class SplitBlock extends EditOperation {
  SplitBlock(this.blockIndex, this.offset);

  final int blockIndex;
  final int offset;

  @override
  Document apply(Document doc) {
    final block = doc.allBlocks[blockIndex];
    final beforeSegments = _splitSegmentsAt(
      block.segments,
      offset,
      takeBefore: true,
    );
    final afterSegments = _splitSegmentsAt(
      block.segments,
      offset,
      takeBefore: false,
    );

    final newBlockType = isListLike(block.blockType)
        ? block.blockType
        : BlockType.paragraph;

    // For tasks, new block starts unchecked.
    final newMetadata = block.blockType == BlockType.taskItem
        ? <String, dynamic>{'checked': false}
        : <String, dynamic>{};

    final updatedBlock = block.copyWith(
      segments: mergeSegments(beforeSegments),
    );
    final newBlock = TextBlock(
      id: generateBlockId(),
      blockType: newBlockType,
      segments: mergeSegments(afterSegments),
      metadata: newMetadata,
    );

    // Insert the new block as a sibling after the split block in the tree.
    var result = doc.replaceBlock(blockIndex, updatedBlock);
    result = result.insertAfterFlatIndex(blockIndex, newBlock);
    return result;
  }

  @override
  String toString() => 'SplitBlock(block: $blockIndex, offset: $offset)';
}

/// Merge block at [secondBlockIndex] into the block before it.
///
/// This is what happens when the user presses Backspace at the start of a block.
class MergeBlocks extends EditOperation {
  MergeBlocks(this.secondBlockIndex);

  final int secondBlockIndex;

  @override
  Document apply(Document doc) {
    final flat = doc.allBlocks;
    if (secondBlockIndex <= 0 || secondBlockIndex >= flat.length) return doc;

    final first = flat[secondBlockIndex - 1];
    final second = flat[secondBlockIndex];

    final mergedSegments = mergeSegments([
      ...first.segments,
      ...second.segments,
    ]);
    final mergedBlock = first.copyWith(segments: mergedSegments);

    var result = doc.replaceBlock(secondBlockIndex - 1, mergedBlock);
    result = result.removeBlock(secondBlockIndex);
    return result;
  }

  @override
  String toString() => 'MergeBlocks(second: $secondBlockIndex)';
}

/// Change the block type of the block at [blockIndex].
class ChangeBlockType extends EditOperation {
  ChangeBlockType(this.blockIndex, this.newType, {this.policies});

  final int blockIndex;
  final BlockType newType;

  /// Optional policies map. Falls back to [defaultPolicies] if not provided.
  final Map<Object, BlockPolicies>? policies;

  @override
  Document apply(Document doc) {
    final policyMap = policies ?? defaultPolicies;
    // Policy: if the new type can't be a child and the block is nested, reject.
    final newPolicy = policyMap[newType];
    if (newPolicy != null &&
        !newPolicy.canBeChild &&
        doc.depthOf(blockIndex) > 0) {
      return doc;
    }

    final block = doc.allBlocks[blockIndex];
    if (block.blockType == newType) return doc;
    // Clear metadata when changing type — stale metadata from the old type
    // (e.g. task 'checked' state) shouldn't carry over.
    return doc.replaceBlock(
      blockIndex,
      block.copyWith(blockType: newType, metadata: const {}),
    );
  }

  @override
  String toString() => 'ChangeBlockType(block: $blockIndex, ${newType.name})';
}

/// Delete a range of text that may span multiple blocks.
///
/// If the range is within a single block, behaves like [DeleteText].
/// If cross-block: truncates the start block, removes middle blocks entirely,
/// truncates the end block, and merges the remaining end text into the start block.
class DeleteRange extends EditOperation {
  DeleteRange(
    this.startBlockIndex,
    this.startOffset,
    this.endBlockIndex,
    this.endOffset,
  );

  final int startBlockIndex;
  final int startOffset;
  final int endBlockIndex;
  final int endOffset;

  @override
  Document apply(Document doc) {
    final flat = doc.allBlocks;
    if (startBlockIndex >= flat.length || endBlockIndex >= flat.length) {
      return doc;
    }

    // Same block — just delete within it.
    if (startBlockIndex == endBlockIndex) {
      final length = endOffset - startOffset;
      if (length <= 0) return doc;
      return DeleteText(startBlockIndex, startOffset, length).apply(doc);
    }

    // Cross-block delete.
    final startBlock = flat[startBlockIndex];
    final endBlock = flat[endBlockIndex];

    // 1. Truncate start block: keep text before startOffset.
    final startSegs = _splitSegmentsAt(
      startBlock.segments,
      startOffset,
      takeBefore: true,
    );

    // 2. Truncate end block: keep text after endOffset.
    final endSegs = _splitSegmentsAt(
      endBlock.segments,
      endOffset,
      takeBefore: false,
    );

    // 3. Merge remaining: start block's head + end block's tail.
    final mergedSegments = mergeSegments([...startSegs, ...endSegs]);
    final mergedBlock = startBlock.copyWith(segments: mergedSegments);

    // 4. Apply: replace start block, then remove end block and all middle blocks.
    //    Remove from high index to low to avoid index shifting.
    var result = doc.replaceBlock(startBlockIndex, mergedBlock);
    for (var i = endBlockIndex; i > startBlockIndex; i--) {
      result = result.removeBlock(i);
    }

    return result;
  }

  @override
  String toString() =>
      'DeleteRange(start: $startBlockIndex:$startOffset, end: $endBlockIndex:$endOffset)';
}

/// Remove a block entirely from the document.
///
/// Used for deleting void blocks (e.g. divider) where merging makes no sense.
class RemoveBlock extends EditOperation {
  RemoveBlock(this.flatIndex);

  final int flatIndex;

  @override
  Document apply(Document doc) {
    final flat = doc.allBlocks;
    if (flatIndex < 0 || flatIndex >= flat.length) return doc;
    // Don't remove the last block — always keep at least one.
    if (flat.length <= 1) return doc;
    return doc.removeBlock(flatIndex);
  }

  @override
  String toString() => 'RemoveBlock(flat: $flatIndex)';
}

/// Paste one or more blocks at [blockIndex]:[offset] in the document.
///
/// Single-block paste: merges the pasted block's segments into the target
/// block at the given offset, preserving styles and attributes.
///
/// Multi-block paste: splits the target block at the offset, merges the
/// first pasted block into the first half, inserts middle blocks as siblings,
/// and merges the last pasted block with the second half.
class PasteBlocks extends EditOperation {
  PasteBlocks(this.blockIndex, this.offset, this.pastedBlocks);

  final int blockIndex;
  final int offset;
  final List<TextBlock> pastedBlocks;

  @override
  Document apply(Document doc) {
    if (pastedBlocks.isEmpty) return doc;
    final flat = doc.allBlocks;
    if (blockIndex >= flat.length) return doc;

    final target = flat[blockIndex];

    if (pastedBlocks.length == 1) {
      // Single block paste: insert pasted segments at offset, preserving styles.
      final pasted = pastedBlocks[0];
      final before = _splitSegmentsAt(
        target.segments,
        offset,
        takeBefore: true,
      );
      final after = _splitSegmentsAt(
        target.segments,
        offset,
        takeBefore: false,
      );
      final merged = mergeSegments([...before, ...pasted.segments, ...after]);
      return doc.replaceBlock(blockIndex, target.copyWith(segments: merged));
    }

    // Multi-block paste:
    // 1. Split target into head (before offset) and tail (after offset).
    final headSegs = _splitSegmentsAt(
      target.segments,
      offset,
      takeBefore: true,
    );
    final tailSegs = _splitSegmentsAt(
      target.segments,
      offset,
      takeBefore: false,
    );

    // 2. Merge first pasted block's segments into the head.
    final firstPasted = pastedBlocks.first;
    final headBlock = target.copyWith(
      segments: mergeSegments([...headSegs, ...firstPasted.segments]),
    );

    // 3. Merge last pasted block's segments with the tail.
    final lastPasted = pastedBlocks.last;
    final tailBlock = TextBlock(
      id: generateBlockId(),
      blockType: lastPasted.blockType,
      segments: mergeSegments([...lastPasted.segments, ...tailSegs]),
    );

    // 4. Middle blocks (if any) go between head and tail.
    final middleBlocks = pastedBlocks.length > 2
        ? pastedBlocks.sublist(1, pastedBlocks.length - 1)
        : <TextBlock>[];

    // 5. Apply: replace target with head, then insert middle + tail after.
    var result = doc.replaceBlock(blockIndex, headBlock);
    var insertAfter = blockIndex;
    for (final mid in middleBlocks) {
      result = result.insertAfterFlatIndex(insertAfter, mid);
      insertAfter++;
    }
    result = result.insertAfterFlatIndex(insertAfter, tailBlock);

    return result;
  }

  @override
  String toString() =>
      'PasteBlocks(block: $blockIndex, offset: $offset, ${pastedBlocks.length} blocks)';
}

/// Set a metadata field on a block.
///
/// Used for toggling task checked state, etc.
class SetBlockMetadata extends EditOperation {
  SetBlockMetadata(this.blockIndex, this.key, this.value);

  final int blockIndex;
  final String key;
  final dynamic value;

  @override
  Document apply(Document doc) {
    final flat = doc.allBlocks;
    if (blockIndex < 0 || blockIndex >= flat.length) return doc;

    final block = flat[blockIndex];
    final newMeta = Map<String, dynamic>.of(block.metadata);
    newMeta[key] = value;
    return doc.replaceBlock(blockIndex, block.copyWith(metadata: newMeta));
  }

  @override
  String toString() => 'SetBlockMetadata(block: $blockIndex, $key: $value)';
}

/// Indent a block: make it a child of its previous sibling.
///
/// Only valid for list items that have a previous sibling.
/// The block is removed from its current position and appended
/// as the last child of the previous sibling.
class IndentBlock extends EditOperation {
  IndentBlock(this.flatIndex, {this.policies});
  final int flatIndex;

  /// Optional policies map. Falls back to [defaultPolicies] if not provided.
  final Map<Object, BlockPolicies>? policies;

  @override
  Document apply(Document doc) {
    final policyMap = policies ?? defaultPolicies;
    final prevSibling = doc.previousSibling(flatIndex);
    if (prevSibling == null) return doc; // No previous sibling — can't indent.

    final block = doc.allBlocks[flatIndex];

    // Policy: block must be allowed to be a child.
    final blockPolicy = policyMap[block.blockType];
    if (blockPolicy != null && !blockPolicy.canBeChild) return doc;

    // Policy: target parent must accept children.
    final parentPolicy = policyMap[prevSibling.blockType];
    if (parentPolicy != null && !parentPolicy.canHaveChildren) return doc;

    // Policy: respect maxDepth.
    if (blockPolicy?.maxDepth != null) {
      final newDepth = doc.depthOf(flatIndex) + 1;
      if (newDepth > blockPolicy!.maxDepth!) return doc;
    }

    // Remove block from current position.
    var result = doc.removeBlockByFlatIndex(flatIndex);

    // Add as last child of previous sibling.
    final prevFlatIndex = result.indexOfBlock(prevSibling.id);
    if (prevFlatIndex < 0) return doc; // Safety check.
    result = result.addChild(prevFlatIndex, block);

    return result;
  }

  @override
  String toString() => 'IndentBlock(flat: $flatIndex)';
}

/// Outdent a block: move it from its parent's children to be a sibling
/// after its parent.
///
/// Only valid for nested blocks (depth > 0).
class OutdentBlock extends EditOperation {
  OutdentBlock(this.flatIndex);
  final int flatIndex;

  @override
  Document apply(Document doc) {
    final parent = doc.parentOf(flatIndex);
    if (parent == null) return doc; // Already at root — can't outdent.

    final block = doc.allBlocks[flatIndex];

    // Remove block from parent's children.
    var result = doc.removeBlockByFlatIndex(flatIndex);

    // Insert as sibling after the parent.
    final parentFlatIndex = result.indexOfBlock(parent.id);
    if (parentFlatIndex < 0) return doc;
    result = result.insertAfterFlatIndex(parentFlatIndex, block);

    return result;
  }

  @override
  String toString() => 'OutdentBlock(flat: $flatIndex)';
}

// --- Helpers ---

/// Insert [text] at [offset] in [segments].
///
/// If [styles] is provided, the new text gets those styles explicitly.
/// If null, inherits from the segment at the insertion point.
/// [attributes] is passed through for data-carrying styles.
List<StyledSegment> _spliceInsert(
  List<StyledSegment> segments,
  int offset,
  String text, {
  Set<InlineStyle>? styles,
  Map<String, dynamic>? attributes,
}) {
  if (segments.isEmpty) {
    return [StyledSegment(text, styles ?? const {}, attributes ?? const {})];
  }

  final result = <StyledSegment>[];
  var pos = 0;
  var inserted = false;

  for (final seg in segments) {
    final segStart = pos;
    final segEnd = pos + seg.text.length;

    if (!inserted && offset <= segEnd) {
      final localOffset = offset - segStart;
      final before = seg.text.substring(0, localOffset);
      final after = seg.text.substring(localOffset);
      final insertStyles = styles ?? seg.styles;
      final insertAttrs = attributes ?? seg.attributes;
      if (before.isNotEmpty) {
        result.add(StyledSegment(before, seg.styles, seg.attributes));
      }
      result.add(StyledSegment(text, insertStyles, insertAttrs));
      if (after.isNotEmpty) {
        result.add(StyledSegment(after, seg.styles, seg.attributes));
      }
      inserted = true;
    } else {
      result.add(seg);
    }

    pos = segEnd;
  }

  if (!inserted) {
    result.add(
      StyledSegment(
        text,
        styles ?? segments.last.styles,
        attributes ?? const {},
      ),
    );
  }

  return result;
}

/// Delete [length] characters starting at [offset] from segments,
/// preserving styles on remaining text.
List<StyledSegment> _spliceDelete(
  List<StyledSegment> segments,
  int offset,
  int length,
) {
  final result = <StyledSegment>[];
  var pos = 0;
  var deleteStart = offset;
  var deleteEnd = offset + length;

  for (final seg in segments) {
    final segStart = pos;
    final segEnd = pos + seg.text.length;

    if (segEnd <= deleteStart || segStart >= deleteEnd) {
      // Entirely outside the delete range — keep as-is.
      result.add(seg);
    } else {
      // Partially or fully inside the delete range.
      final keepBefore = seg.text.substring(
        0,
        (deleteStart - segStart).clamp(0, seg.text.length),
      );
      final keepAfter = seg.text.substring(
        (deleteEnd - segStart).clamp(0, seg.text.length),
      );
      if (keepBefore.isNotEmpty) {
        result.add(StyledSegment(keepBefore, seg.styles, seg.attributes));
      }
      if (keepAfter.isNotEmpty) {
        result.add(StyledSegment(keepAfter, seg.styles, seg.attributes));
      }
    }

    pos = segEnd;
  }

  return result;
}

/// Split segment list at [offset], returning either the before or after half.
List<StyledSegment> _splitSegmentsAt(
  List<StyledSegment> segments,
  int offset, {
  required bool takeBefore,
}) {
  var pos = 0;
  final result = <StyledSegment>[];

  for (final seg in segments) {
    final segStart = pos;
    final segEnd = pos + seg.text.length;

    if (takeBefore) {
      if (segEnd <= offset) {
        result.add(seg);
      } else if (segStart < offset) {
        result.add(
          StyledSegment(
            seg.text.substring(0, offset - segStart),
            seg.styles,
            seg.attributes,
          ),
        );
      }
    } else {
      if (segStart >= offset) {
        result.add(seg);
      } else if (segEnd > offset) {
        result.add(
          StyledSegment(
            seg.text.substring(offset - segStart),
            seg.styles,
            seg.attributes,
          ),
        );
      }
    }

    pos = segEnd;
  }

  return result;
}
