import 'package:flutter/widgets.dart';

import '../model/doc_selection.dart';
import '../model/document.dart';
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

/// ↑/↓: the position one line above/below the caret at the same global x.
/// Resolves within the block across soft-wrapped lines and across blocks at
/// the block edges through the shared hit tester (a void lands as a `[0,1)`
/// atomic selection once normalized).
DocPosition? verticalCaretTarget(
  BlockLayoutRegistry registry,
  DocSelection selection,
  int direction,
) {
  final extent = selection.extent;
  final geometry = registry.geometryOf(extent.blockId);
  if (geometry == null) return null;
  final caret = geometry.rectForOffset(extent.offset);
  if (caret == null) return null;

  final box = geometry.renderBox;
  final globalCenterX = box.localToGlobal(caret.center).dx;
  final globalTop = box.localToGlobal(caret.topLeft).dy;
  final globalBottom = box.localToGlobal(caret.bottomLeft).dy;
  // Aim half a line beyond the current line's edge so the probe lands on the
  // neighbouring line/block, never back on the current caret line.
  final targetY = direction < 0
      ? globalTop - caret.height * 0.5
      : globalBottom + caret.height * 0.5;

  return hitTestDocPosition(registry, Offset(globalCenterX, targetY));
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
