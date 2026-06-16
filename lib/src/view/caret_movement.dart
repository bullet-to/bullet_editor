import 'package:flutter/widgets.dart';

import '../model/doc_selection.dart';
import '../model/document.dart';
import '../schema/editor_schema.dart';
import 'block_layout_registry.dart';
import 'editor_hit_tester.dart';

/// Geometry-aware caret movement targets (architecture §hardware keyboard:
/// "cross-block caret movement via geometry-x affinity"). Each returns the
/// new extent [DocPosition], or null when it cannot be computed (no geometry
/// yet, empty document); the caller turns it into a collapsed or
/// base-anchored (Shift) selection through `controller.setSelection`, which
/// applies the void `[0,1)` normalization and offset clamping.
///
/// Horizontal grapheme movement (←/→) stays on `EditorController.moveCaret`
/// (pure model — no geometry); these are the keys that need the laid-out
/// `RenderParagraph`.

/// A vertical-move result: the new extent [target] (null when nothing is laid
/// out) plus the [goalX] (global x) the caller remembers so a CONSECUTIVE run
/// of ↑/↓ holds its column. Native goal-column behaviour: only a vertical move
/// preserves the column; any horizontal move, click, or edit recomputes it
/// (the caller resets by comparing the live extent against where the last
/// vertical move left it — see `BulletEditorState._moveVertically`).
typedef VerticalMove = ({DocPosition? target, double goalX});

/// ↑/↓: the position one line above/below the caret at the same global x. The
/// column is [goalX] when carried from a consecutive vertical run, else the
/// current caret's global centre x. Resolves within the block across soft-
/// wrapped lines and across blocks at the block edges through the shared hit
/// tester. A void target resolves by travel DIRECTION (down → downstream
/// `1`, up → upstream `0`) rather than the midpoint rule, so a Shift-extension
/// includes the whole void and a plain move normalizes to its `[0,1)` atomic
/// selection.
VerticalMove? verticalCaretTarget(
  BlockLayoutRegistry registry,
  EditorSchema schema,
  Document document,
  DocSelection selection,
  int direction, {
  double? goalX,
}) {
  final extent = selection.extent;
  final geometry = registry.geometryOf(extent.blockId);
  if (geometry == null) return null;
  final caret = geometry.rectForOffset(extent.offset);
  if (caret == null) return null;

  final box = geometry.renderBox;
  final extentBlock = document.blockById(extent.blockId);
  final fromVoid = extentBlock != null && schema.isVoid(extentBlock.blockType);

  // The column to aim for. A void extent's caret rect is the box's leading or
  // trailing EDGE (not a text column), so when a run STARTS on a void with no
  // carried goal x we fall back to the box centre to keep the column sensible.
  final caretGlobalX = fromVoid
      ? box.localToGlobal(Offset(box.size.width / 2, caret.center.dy)).dx
      : box.localToGlobal(caret.center).dx;
  final probeX = goalX ?? caretGlobalX;

  // A void has no internal lines, and its box is often tall enough that
  // probing half its height overshoots the next block (manual-test B3) while
  // a small step lands in the inter-block gap and re-hits the void itself
  // (the bands aren't flush). So leaving a void targets the ADJACENT block
  // directly and resolves the column on its near edge.
  if (fromVoid) {
    final target = _adjacentBlockTarget(
      registry,
      schema,
      document,
      extent.blockId,
      direction,
      probeX,
    );
    return (target: target, goalX: probeX);
  }

  final globalTop = box.localToGlobal(caret.topLeft).dy;
  final globalBottom = box.localToGlobal(caret.bottomLeft).dy;
  // Aim half a line beyond the current line's edge so the probe lands on the
  // neighbouring line/block, never back on the current caret line.
  final step = caret.height * 0.5;
  final targetY = direction < 0 ? globalTop - step : globalBottom + step;

  final target = _resolveVoidByDirection(
    schema,
    document,
    hitTestDocPosition(registry, Offset(probeX, targetY)),
    direction,
  );
  return (target: target, goalX: probeX);
}

/// The vertical target when leaving a void block: the flat-order neighbour in
/// [direction], with the column resolved on its near edge (top edge going
/// down, bottom edge going up). Falls back to the neighbour's near offset when
/// it isn't laid out (a document-boundary jump); null at the document edge.
DocPosition? _adjacentBlockTarget(
  BlockLayoutRegistry registry,
  EditorSchema schema,
  Document document,
  String fromBlockId,
  int direction,
  double globalX,
) {
  final blocks = document.allBlocks;
  final neighborIndex = document.indexOfBlock(fromBlockId) + direction;
  if (neighborIndex < 0 || neighborIndex >= blocks.length) return null;
  final neighbor = blocks[neighborIndex];

  final geometry = registry.geometryOf(neighbor.id);
  if (geometry == null) {
    // Not laid out — resolve to the near offset; the caller scrolls it in.
    final off = schema.isVoid(neighbor.blockType)
        ? (direction < 0 ? 0 : 1)
        : (direction < 0 ? neighbor.length : 0);
    return DocPosition(neighbor.id, off);
  }
  final box = geometry.renderBox;
  // A point just inside the neighbour's near edge at the goal column. The
  // shared hit tester clamps the global x into the block and resolves the
  // offset (a void by its own midpoint, overridden by direction below).
  final nearLocalY = direction < 0 ? box.size.height - 1 : 1.0;
  final nearGlobalY = box.localToGlobal(Offset(0, nearLocalY)).dy;
  return _resolveVoidByDirection(
    schema,
    document,
    hitTestDocPosition(registry, Offset(globalX, nearGlobalY)),
    direction,
  );
}

/// Overrides a void [target]'s offset by travel [direction] (down → downstream
/// `1`, up → upstream `0`) so a Shift-extension includes the whole void rather
/// than landing on its midpoint-resolved edge. Text targets pass through.
DocPosition? _resolveVoidByDirection(
  EditorSchema schema,
  Document document,
  DocPosition? target,
  int direction,
) {
  if (target == null) return null;
  final block = document.blockById(target.blockId);
  if (block != null && schema.isVoid(block.blockType)) {
    return DocPosition(target.blockId, direction < 0 ? 0 : 1);
  }
  return target;
}

/// Cmd/Ctrl+←/→: the start/end of the caret's visual line (soft-wrap aware),
/// within the block — the line probe clamps x to the block's edges at the
/// caret's y.
DocPosition? lineBoundaryTarget(
  BlockLayoutRegistry registry,
  DocSelection selection,
  bool forward,
) {
  final extent = selection.extent;
  final geometry = registry.geometryOf(extent.blockId);
  if (geometry == null) return null;
  final caret = geometry.rectForOffset(extent.offset);
  if (caret == null) return null;

  final y = caret.center.dy;
  final x = forward ? geometry.renderBox.size.width : 0.0;
  return DocPosition(extent.blockId, geometry.offsetForLocalPoint(Offset(x, y)));
}

/// Cmd/Ctrl+↑/↓: the document start (first block, offset 0) or end (last
/// block, its length). Pure model — no geometry.
DocPosition? documentBoundaryTarget(Document document, bool forward) {
  final blocks = document.allBlocks;
  if (blocks.isEmpty) return null;
  final block = forward ? blocks.last : blocks.first;
  return DocPosition(block.id, forward ? block.length : 0);
}
