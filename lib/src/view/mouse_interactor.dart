import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../model/doc_selection.dart';
import '../model/document.dart';
import 'block_layout_registry.dart';
import 'editor_auto_scroller.dart';
import 'editor_hit_tester.dart';
import 'selection_drag.dart';

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
/// tracks the pointer's visual position (G5). A swept void is selected the
/// moment the drag enters its box (resolved by direction in [resolveSweptVoid],
/// the web feel — D6), not at its vertical midpoint. The
/// final selection is exact by construction: a void-edge collapse normalizes
/// to the atomic selection in `setSelection`.
///
/// The interactor owns no widgets — `BulletEditorState` feeds it pointer
/// events (dispatched by `PointerDeviceKind`) and scroll notifications, and
/// supplies the document/selection/scroll surfaces as callbacks so the
/// interactor stays render-agnostic and unit-reachable.
class MouseInteractor {
  MouseInteractor({
    required this.registry,
    required this.documentOf,
    required this.isVoid,
    required void Function(DocSelection selection) setSelection,
    required this.requestFocus,
    required ScrollPosition? Function() scrollPositionOf,
    required Rect? Function() viewportRectOf,
  }) : _rawSetSelection = setSelection {
    _autoScroller = EditorAutoScroller(
      scrollPositionOf: scrollPositionOf,
      viewportRectOf: viewportRectOf,
      isActive: () => _dragging,
    );
    _rehitScheduler = DragRehitScheduler(
      isActive: () => _dragging,
      focalPointOf: () => _dragPointer,
      onRehit: (focal) {
        final hit = hitTestDocPosition(registry, focal);
        if (hit != null) _extendTo(hit);
      },
    );
  }

  final BlockLayoutRegistry registry;
  final Document Function() documentOf;

  /// Whether a block is a void (image, divider) — drag selection resolves a
  /// swept void by direction (D6), not the geometry's midpoint rule.
  final bool Function(String blockId) isVoid;

  final void Function(DocSelection selection) _rawSetSelection;
  final void Function() requestFocus;

  /// The edge-zone autoscroll ticker, shared with the touch interactor (D7).
  late final EditorAutoScroller _autoScroller;

  /// The post-frame extent re-hit-test after a mid-drag scroll (G5), shared
  /// implementation with the touch interactor (review H4).
  late final DragRehitScheduler _rehitScheduler;

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
    _autoScroller.update(event.position);
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
    _autoScroller.stop();
  }

  /// Re-hit-test under the stationary pointer after a scroll (autoscroll tick,
  /// wheel, or trackpad) committed and the sliver re-laid the revealed
  /// content — scheduled post-frame so the hit always lands on laid-out
  /// content, never an estimate (G5). Called by the editor's scroll-
  /// notification listener while a drag is active.
  void onScroll() => _rehitScheduler.schedule();

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

  /// Extends the current drag/shift selection to [point], oriented in document
  /// order against the anchor and never shrinking the anchor's own word/block
  /// span — the shared [extendSelection] math (mouse lands raw: no word snap).
  void _extendTo(DocPosition point) {
    _setSelection(
      extendSelection(
        anchor: _expandBase,
        point: point,
        doc: _doc,
        isVoid: isVoid,
      ),
    );
  }
}
