import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../model/doc_selection.dart';
import '../model/document.dart';
import 'block_layout_registry.dart';
import 'editor_hit_tester.dart';

/// Selection gestures for mouse/trackpad-kind pointers, on every platform
/// (architecture §Gestures: per-kind dispatch, not platform-at-build — iPad
/// Magic Keyboard and Android mouse are launch surfaces, and the mouse
/// interactor is web's only selection path, never-cut).
///
/// Click places a caret (voids atomic-select `[0,1)`); double-click selects
/// the word (`wordBoundaryAt`); triple-click the whole block; shift-click and
/// press-drag extend from the recorded `expandBase` (G6). A drag updates the
/// extent each move via the shared hit tester, autoscrolls in the viewport
/// edge zone, and — through [onScroll] — re-hit-tests under the stationary
/// pointer on every scroll notification so wheel/trackpad scroll mid-drag
/// tracks the pointer's visual position (G5). The final selection is exact by
/// construction: a void-edge collapse normalizes to the atomic selection in
/// `setSelection`.
///
/// The interactor owns no widgets — `BulletEditorState` feeds it pointer
/// events (dispatched by `PointerDeviceKind`) and scroll notifications, and
/// supplies the document/selection/scroll surfaces as callbacks so the
/// interactor stays render-agnostic and unit-reachable.
class MouseInteractor {
  MouseInteractor({
    required this.registry,
    required this.documentOf,
    required void Function(DocSelection selection) setSelection,
    required this.requestFocus,
    required this.scrollPositionOf,
    required this.viewportRectOf,
  }) : _rawSetSelection = setSelection;

  final BlockLayoutRegistry registry;
  final Document Function() documentOf;
  final void Function(DocSelection selection) _rawSetSelection;
  final void Function() requestFocus;

  /// The editor's scroll position, or null before the viewport is laid out.
  final ScrollPosition? Function() scrollPositionOf;

  /// The editor viewport's global rect, for the autoscroll edge zone.
  final Rect? Function() viewportRectOf;

  /// Distance from a viewport edge within which a drag autoscrolls.
  static const _edgeZone = 50.0;

  /// Pixels scrolled per autoscroll frame tick.
  static const _autoScrollStep = 16.0;

  /// The anchored selection a drag/shift-click extends from — the click point
  /// (collapsed), the double-clicked word, or the triple-clicked block. Never
  /// shrunk below its own granularity while extending (native word/block
  /// drag). Survives across edits only as data: every use routes back through
  /// [setSelection], which clamps stale offsets and rejects gone ids (the
  /// stale-anchor invalidation — a queued delta that shortened the block
  /// cannot produce an out-of-bounds shift-click).
  DocSelection? _expandBase;

  /// The last selection this interactor pushed. A drag re-hit-tests on every
  /// pointer move AND on every scroll notification (wheel, trackpad, autoscroll
  /// tick) — frequently resolving the SAME offset for consecutive samples. We
  /// push only on an actual change so the editor doesn't rebuild (and the caret
  /// doesn't visibly flicker) on no-op samples (manual-test B5). Compared
  /// pre-normalization, which is fine: a stable input maps to a stable output.
  DocSelection? _lastPushed;

  void _setSelection(DocSelection selection) {
    if (selection == _lastPushed) return;
    _lastPushed = selection;
    _rawSetSelection(selection);
  }

  bool _dragging = false;
  Offset? _dragPointer;
  bool get isDragging => _dragging;

  // Multi-click bookkeeping (timeStamp/position deltas, the SerialTap rule).
  Duration? _lastDownTime;
  Offset? _lastDownPosition;
  int _clickCount = 0;

  // Autoscroll ticker.
  double _autoScrollVelocity = 0;
  bool _autoScrollScheduled = false;
  bool _rehitScheduled = false;

  Document get _doc => documentOf();

  void handlePointerDown(PointerDownEvent event) {
    if (event.buttons != kPrimaryMouseButton) return;
    requestFocus();
    // Start each gesture with a clean dedup baseline: the selection may have
    // moved since our last push (a keyboard caret move between clicks), so the
    // first push of this gesture must always go through.
    _lastPushed = null;
    final global = event.position;
    _dragPointer = global;
    _dragging = true;

    if (HardwareKeyboard.instance.isShiftPressed && _expandBase != null) {
      // Shift-click extends from the existing anchor; the anchor is unchanged.
      _clickCount = 0;
      _lastDownTime = null;
      final hit = hitTestDocPosition(registry, global);
      if (hit != null) _extendTo(hit);
      return;
    }

    _clickCount = _isConsecutive(event.timeStamp, global) ? _clickCount + 1 : 1;
    _lastDownTime = event.timeStamp;
    _lastDownPosition = global;

    final hit = hitTestDocPosition(registry, global);
    if (hit == null) return;
    final anchor = _selectionForClick(hit, _clickCount);
    _expandBase = anchor;
    _setSelection(anchor);
  }

  void handlePointerMove(PointerMoveEvent event) {
    if (!_dragging) return;
    _dragPointer = event.position;
    final hit = hitTestDocPosition(registry, event.position);
    if (hit != null) _extendTo(hit);
    _updateAutoScroll(event.position);
  }

  void handlePointerUp(PointerUpEvent event) {
    _endDrag();
  }

  void handlePointerCancel(PointerCancelEvent event) {
    _endDrag();
  }

  void _endDrag() {
    _dragging = false;
    _dragPointer = null;
    _autoScrollVelocity = 0;
  }

  /// Re-hit-test under the stationary pointer after a scroll (autoscroll tick,
  /// wheel, or trackpad) committed and the sliver re-laid the revealed
  /// content — scheduled post-frame so the hit always lands on laid-out
  /// content, never an estimate (G5). Called by the editor's scroll-
  /// notification listener while a drag is active.
  void onScroll() {
    if (!_dragging || _dragPointer == null || _rehitScheduled) return;
    _rehitScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rehitScheduled = false;
      final pointer = _dragPointer;
      if (!_dragging || pointer == null) return;
      final hit = hitTestDocPosition(registry, pointer);
      if (hit != null) _extendTo(hit);
    });
  }

  bool _isConsecutive(Duration time, Offset position) {
    final lastTime = _lastDownTime;
    final lastPosition = _lastDownPosition;
    if (lastTime == null || lastPosition == null) return false;
    return time - lastTime < kDoubleTapTimeout &&
        (position - lastPosition).distance < kDoubleTapSlop;
  }

  /// The selection a click of [clickCount] at [hit] produces. Voids
  /// atomic-select regardless of count (no word/block granularity); text
  /// blocks: caret (1), word (2), whole block (3+, wrapping).
  DocSelection _selectionForClick(DocPosition hit, int clickCount) {
    final block = _doc.blockById(hit.blockId);
    if (block == null) return DocSelection.collapsed(hit);

    final geometry = registry.geometryOf(hit.blockId);
    // A void hit (midpoint-resolved 0/1) collapses onto the void, which
    // setSelection normalizes to the atomic [0,1) selection.
    if (geometry == null) return DocSelection.collapsed(hit);

    switch (clickCount) {
      case 2:
        final word = geometry.wordBoundaryAt(hit.offset);
        return DocSelection(
          base: DocPosition(hit.blockId, word.start),
          extent: DocPosition(hit.blockId, word.end),
        );
      case 3:
        return DocSelection(
          base: DocPosition(hit.blockId, 0),
          extent: DocPosition(hit.blockId, block.length),
        );
      default:
        return DocSelection.collapsed(hit);
    }
  }

  /// Extends the current drag/shift selection to [point], oriented in
  /// document order against the anchor and never shrinking the anchor's own
  /// word/block span (native multi-click-drag behavior).
  void _extendTo(DocPosition point) {
    final anchor = _expandBase;
    if (anchor == null) {
      _setSelection(DocSelection.collapsed(point));
      return;
    }
    final (start, end) = anchor.normalized(_doc);
    final DocSelection extended;
    if (_compare(point, start) < 0) {
      extended = DocSelection(base: end, extent: point);
    } else if (_compare(point, end) > 0) {
      extended = DocSelection(base: start, extent: point);
    } else {
      extended = anchor;
    }
    _setSelection(extended);
  }

  /// Document order of two positions: by flat block index, then offset.
  int _compare(DocPosition a, DocPosition b) {
    final ia = _doc.indexOfBlock(a.blockId);
    final ib = _doc.indexOfBlock(b.blockId);
    if (ia != ib) return ia.compareTo(ib);
    return a.offset.compareTo(b.offset);
  }

  // --- Autoscroll (edge zone) ---

  void _updateAutoScroll(Offset globalPointer) {
    final viewport = viewportRectOf();
    if (viewport == null) {
      _autoScrollVelocity = 0;
      return;
    }
    if (globalPointer.dy < viewport.top + _edgeZone) {
      _autoScrollVelocity = -_autoScrollStep;
    } else if (globalPointer.dy > viewport.bottom - _edgeZone) {
      _autoScrollVelocity = _autoScrollStep;
    } else {
      _autoScrollVelocity = 0;
      return;
    }
    if (!_autoScrollScheduled) {
      _autoScrollScheduled = true;
      SchedulerBinding.instance.scheduleFrameCallback(_autoScrollTick);
      SchedulerBinding.instance.scheduleFrame();
    }
  }

  void _autoScrollTick(Duration _) {
    _autoScrollScheduled = false;
    if (!_dragging || _autoScrollVelocity == 0) return;
    final position = scrollPositionOf();
    if (position == null) return;
    final target = (position.pixels + _autoScrollVelocity).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    // jumpTo dispatches a ScrollNotification; the editor's listener routes it
    // back through onScroll, which re-hit-tests the extent under the
    // stationary pointer post-frame. No extent update here — one path.
    if (target != position.pixels) position.jumpTo(target);
    // Keep ticking while the pointer stays in the edge zone.
    _autoScrollScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback(_autoScrollTick);
    SchedulerBinding.instance.scheduleFrame();
  }
}
