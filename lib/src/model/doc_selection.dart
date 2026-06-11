import 'package:flutter/services.dart' show TextAffinity, TextRange;

import 'document.dart';

/// A position in the document: a block id plus a local offset.
///
/// For text blocks, [offset] is a grapheme-cluster-aligned character offset
/// into the block's plain text, in `[0, block.length]`.
///
/// For void blocks (image, divider), `offset == 0` means upstream of the
/// block and `offset == 1` means downstream; a void is selected when its
/// `[0, 1)` lies inside a range. Void-edge positions exist only transiently
/// as drag-range endpoints — selection normalization forbids a collapsed
/// caret on a void block.
class DocPosition {
  const DocPosition(
    this.blockId,
    this.offset, {
    this.affinity = TextAffinity.downstream,
  });

  final String blockId;
  final int offset;

  /// Consumed only by geometry (soft-wrap caret placement, Home/End).
  /// Ignored by the model and by edit operations — offsets are sufficient
  /// for editing.
  final TextAffinity affinity;

  DocPosition copyWith({String? blockId, int? offset, TextAffinity? affinity}) {
    return DocPosition(
      blockId ?? this.blockId,
      offset ?? this.offset,
      affinity: affinity ?? this.affinity,
    );
  }

  /// Equality ignores [affinity] — two positions at the same model location
  /// are the same position; affinity only disambiguates rendering.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DocPosition &&
          blockId == other.blockId &&
          offset == other.offset;

  @override
  int get hashCode => Object.hash(blockId, offset);

  @override
  String toString() => 'DocPosition($blockId, $offset)';
}

/// A selection: a base (where the gesture started) and an extent (where it
/// is now — the caret end). Either may come earlier in the document.
class DocSelection {
  const DocSelection({required this.base, required this.extent});

  /// A collapsed selection (caret) at [position].
  DocSelection.collapsed(DocPosition position)
    : base = position,
      extent = position;

  /// Where the selecting gesture started.
  final DocPosition base;

  /// Where the gesture is now (the caret end).
  final DocPosition extent;

  bool get isCollapsed => base == extent;

  /// Document-order endpoints, resolved against [doc] via its id map.
  ///
  /// Positions in the same block order by offset. Positions whose block is
  /// not in [doc] sort as if at the document end (callers are expected to
  /// reject gone-id selections before this matters).
  (DocPosition start, DocPosition end) normalized(Document doc) {
    final baseIndex = doc.indexOfBlock(base.blockId);
    final extentIndex = doc.indexOfBlock(extent.blockId);
    final bi = baseIndex < 0 ? doc.allBlocks.length : baseIndex;
    final ei = extentIndex < 0 ? doc.allBlocks.length : extentIndex;
    final baseFirst = bi < ei || (bi == ei && base.offset <= extent.offset);
    return baseFirst ? (base, extent) : (extent, base);
  }

  DocSelection copyWith({DocPosition? base, DocPosition? extent}) {
    return DocSelection(base: base ?? this.base, extent: extent ?? this.extent);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DocSelection && base == other.base && extent == other.extent;

  @override
  int get hashCode => Object.hash(base, extent);

  @override
  String toString() => isCollapsed
      ? 'DocSelection.collapsed($extent)'
      : 'DocSelection($base → $extent)';
}

/// The active IME composing region: which block it lives in and the local
/// text range it covers.
///
/// Lifecycle (see architecture §Selection): set only by IME-originated input;
/// remapped block-locally when a composing batch's structural ops leave the
/// window equal to the shadow; cleared only by `terminateComposition(reason)`
/// or by IME input reporting an empty composing region; never restored by
/// undo/redo.
class ComposingState {
  const ComposingState({required this.blockId, required this.range});

  final String blockId;
  final TextRange range;

  ComposingState copyWith({String? blockId, TextRange? range}) {
    return ComposingState(
      blockId: blockId ?? this.blockId,
      range: range ?? this.range,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ComposingState &&
          blockId == other.blockId &&
          range == other.range;

  @override
  int get hashCode => Object.hash(blockId, range);

  @override
  String toString() => 'ComposingState($blockId, $range)';
}
