import 'package:flutter/widgets.dart';

import '../model/doc_selection.dart';
import '../model/document.dart';
import 'block_layout_registry.dart';

/// Which selection endpoint a handle drives — the document-order start
/// (upstream bulb) or end (downstream bulb).
enum SelectionHandleKind { start, end }

/// Pure selection→geometry math shared by the touch interactor (handle drag
/// start), the handle widgets (positioning), and the fallback toolbar (anchor).
/// Registry + document + selection in, global rects out — no gesture state, so
/// it is unit-testable without a live drag and keeps the menu/handle layout off
/// the gesture state machine (review M4). Returns null whenever the needed
/// blocks are not laid out (lazy viewport), per GATE-L.

/// The caret rect of [kind]'s endpoint in global coordinates — the single
/// source for both handle positioning and the grab-offset compensation a handle
/// drag is calibrated against. Null when the selection is collapsed/absent or
/// that endpoint's block is not laid out.
Rect? handleAnchorRect(
  BlockLayoutRegistry registry,
  Document doc,
  DocSelection? selection,
  SelectionHandleKind kind,
) {
  if (selection == null || selection.isCollapsed) return null;
  final (start, end) = selection.normalized(doc);
  final position = kind == SelectionHandleKind.start ? start : end;
  final geometry = registry.geometryOf(position.blockId);
  if (geometry == null) return null;
  final rect = geometry.rectForOffset(position.offset);
  final box = geometry.renderBox;
  if (rect == null || !box.attached || !box.hasSize) return null;
  return box.localToGlobal(rect.topLeft) & rect.size;
}

/// The bounding box (global) of the selection's laid-out block rects — the
/// context-menu anchor (architecture §Context menus G14: first/last visible
/// block rects, clamped to the viewport by the caller). Null when NO selected
/// block has a visible rect (every endpoint and the interior scrolled off): the
/// menu hides on that tick (§Context menus zero-visible-rects case).
Rect? selectionBoundsRect(
  BlockLayoutRegistry registry,
  Document doc,
  DocSelection? selection,
  bool Function(String blockId) isVoid,
) {
  if (selection == null || selection.isCollapsed) return null;
  final (start, end) = selection.normalized(doc);
  final startIndex = doc.indexOfBlock(start.blockId);
  final endIndex = doc.indexOfBlock(end.blockId);
  if (startIndex < 0 || endIndex < 0) return null;

  Rect? bounds;
  for (var i = startIndex; i <= endIndex; i++) {
    final block = doc.allBlocks[i];
    final geometry = registry.geometryOf(block.id);
    if (geometry == null) continue; // not laid out — skip (lazy-safe)
    final box = geometry.renderBox;
    if (!box.attached || !box.hasSize) continue;
    // The selected slice within this block: [start.offset, end.offset] at the
    // endpoints, the whole block in the interior.
    final localStart = i == startIndex ? start.offset : 0;
    final localEnd = i == endIndex ? end.offset : block.length;
    final rects = isVoid(block.id)
        ? [Offset.zero & box.size]
        : geometry.rectsForRange(localStart, localEnd);
    for (final r in rects) {
      final global = box.localToGlobal(r.topLeft) & r.size;
      bounds = bounds == null ? global : bounds.expandToInclude(global);
    }
    // An empty endpoint slice (caret-at-start) yields no rects; fall back to
    // the caret rect so a one-block selection edge still anchors the menu.
    if (rects.isEmpty) {
      final caret = geometry.rectForOffset(localStart);
      if (caret != null) {
        final global = box.localToGlobal(caret.topLeft) & caret.size;
        bounds = bounds == null ? global : bounds.expandToInclude(global);
      }
    }
  }
  return bounds;
}
