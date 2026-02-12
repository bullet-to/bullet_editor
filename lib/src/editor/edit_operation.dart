import '../model/block.dart';
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
  InsertText(this.blockIndex, this.offset, this.text, {this.styles});

  final int blockIndex;
  final int offset;
  final String text;
  final Set<InlineStyle>? styles;

  @override
  Document apply(Document doc) {
    final block = doc.blocks[blockIndex];
    final List<StyledSegment> newSegments;
    if (styles != null) {
      // Explicit styles from active style set — splice in with those styles.
      newSegments = _spliceInsertWithStyle(block.segments, offset, text, styles!);
    } else {
      // No explicit styles — inherit from the segment at the insertion point.
      newSegments = _spliceInsert(block.segments, offset, text);
    }
    final newBlock = block.copyWith(segments: mergeSegments(newSegments));
    return doc.replaceBlock(blockIndex, newBlock);
  }

  @override
  String toString() => 'InsertText(block: $blockIndex, offset: $offset, "$text")';
}

/// Delete [length] characters from block at [blockIndex] starting at [offset].
class DeleteText extends EditOperation {
  DeleteText(this.blockIndex, this.offset, this.length);

  final int blockIndex;
  final int offset;
  final int length;

  @override
  Document apply(Document doc) {
    final block = doc.blocks[blockIndex];
    final newSegments = _spliceDelete(block.segments, offset, length);
    final newBlock = block.copyWith(segments: mergeSegments(newSegments));
    return doc.replaceBlock(blockIndex, newBlock);
  }

  @override
  String toString() => 'DeleteText(block: $blockIndex, offset: $offset, len: $length)';
}

/// Toggle [style] on the range [start]..[end] in block at [blockIndex].
///
/// If the entire range already has the style, remove it.
/// Otherwise, apply it to the entire range.
class ToggleStyle extends EditOperation {
  ToggleStyle(this.blockIndex, this.start, this.end, this.style);

  final int blockIndex;
  final int start;
  final int end;
  final InlineStyle style;

  @override
  Document apply(Document doc) {
    final block = doc.blocks[blockIndex];
    final segments = block.segments;

    // Expand segments into per-character style sets.
    final charStyles = <Set<InlineStyle>>[];
    for (final seg in segments) {
      for (var i = 0; i < seg.text.length; i++) {
        charStyles.add(Set.of(seg.styles));
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
      } else {
        charStyles[i].add(style);
      }
    }

    // Rebuild segments from per-character styles.
    final plainText = block.plainText;
    final newSegments = <StyledSegment>[];
    for (var i = 0; i < plainText.length; i++) {
      newSegments.add(StyledSegment(plainText[i], charStyles[i]));
    }

    final newBlock = block.copyWith(segments: mergeSegments(newSegments));
    return doc.replaceBlock(blockIndex, newBlock);
  }

  @override
  String toString() => 'ToggleStyle(block: $blockIndex, $start..$end, ${style.name})';
}

/// Split block at [blockIndex] at [offset], creating a new block after it.
///
/// This is what happens when the user presses Enter.
class SplitBlock extends EditOperation {
  SplitBlock(this.blockIndex, this.offset);

  final int blockIndex;
  final int offset;

  @override
  Document apply(Document doc) {
    final block = doc.blocks[blockIndex];
    // Rebuild segments for each half, preserving styles at the split point.
    final beforeSegments = _splitSegmentsAt(block.segments, offset, takeBefore: true);
    final afterSegments = _splitSegmentsAt(block.segments, offset, takeBefore: false);

    final updatedBlock = block.copyWith(segments: mergeSegments(beforeSegments));
    final newBlock = TextBlock(
      id: generateBlockId(),
      segments: mergeSegments(afterSegments),
    );

    var result = doc.replaceBlock(blockIndex, updatedBlock);
    result = result.insertBlock(blockIndex + 1, newBlock);
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
    if (secondBlockIndex <= 0) return doc; // Can't merge first block upward.

    final first = doc.blocks[secondBlockIndex - 1];
    final second = doc.blocks[secondBlockIndex];

    final mergedSegments = mergeSegments([...first.segments, ...second.segments]);
    final mergedBlock = first.copyWith(segments: mergedSegments);

    var result = doc.replaceBlock(secondBlockIndex - 1, mergedBlock);
    result = result.removeBlock(secondBlockIndex);
    return result;
  }

  @override
  String toString() => 'MergeBlocks(second: $secondBlockIndex)';
}

// --- Helpers ---

/// Insert [text] into segments at [offset], inheriting the style of the
/// segment at the insertion point. If inserting at the end, inherits from
/// the last segment. If segments are empty, inserts unstyled.
List<StyledSegment> _spliceInsert(
  List<StyledSegment> segments,
  int offset,
  String text,
) {
  if (segments.isEmpty) {
    return [StyledSegment(text)];
  }

  final result = <StyledSegment>[];
  var pos = 0;
  var inserted = false;

  for (final seg in segments) {
    final segStart = pos;
    final segEnd = pos + seg.text.length;

    if (!inserted && offset <= segEnd) {
      // Insertion point is within (or at the boundary of) this segment.
      final localOffset = offset - segStart;
      final before = seg.text.substring(0, localOffset);
      final after = seg.text.substring(localOffset);
      if (before.isNotEmpty) result.add(StyledSegment(before, seg.styles));
      result.add(StyledSegment(text, seg.styles)); // inherit style
      if (after.isNotEmpty) result.add(StyledSegment(after, seg.styles));
      inserted = true;
    } else {
      result.add(seg);
    }

    pos = segEnd;
  }

  // If offset is past all segments (shouldn't happen with valid offset),
  // append with the last segment's style.
  if (!inserted) {
    result.add(StyledSegment(text, segments.last.styles));
  }

  return result;
}

/// Insert [text] at [offset] with explicit [styles], splitting the existing
/// segment at the insertion point.
List<StyledSegment> _spliceInsertWithStyle(
  List<StyledSegment> segments,
  int offset,
  String text,
  Set<InlineStyle> styles,
) {
  if (segments.isEmpty) {
    return [StyledSegment(text, styles)];
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
      if (before.isNotEmpty) result.add(StyledSegment(before, seg.styles));
      result.add(StyledSegment(text, styles)); // use explicit styles
      if (after.isNotEmpty) result.add(StyledSegment(after, seg.styles));
      inserted = true;
    } else {
      result.add(seg);
    }

    pos = segEnd;
  }

  if (!inserted) {
    result.add(StyledSegment(text, styles));
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
      final keepBefore = seg.text.substring(0, (deleteStart - segStart).clamp(0, seg.text.length));
      final keepAfter = seg.text.substring((deleteEnd - segStart).clamp(0, seg.text.length));
      if (keepBefore.isNotEmpty) result.add(StyledSegment(keepBefore, seg.styles));
      if (keepAfter.isNotEmpty) result.add(StyledSegment(keepAfter, seg.styles));
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
        result.add(StyledSegment(seg.text.substring(0, offset - segStart), seg.styles));
      }
    } else {
      if (segStart >= offset) {
        result.add(seg);
      } else if (segEnd > offset) {
        result.add(StyledSegment(seg.text.substring(offset - segStart), seg.styles));
      }
    }

    pos = segEnd;
  }

  return result;
}
