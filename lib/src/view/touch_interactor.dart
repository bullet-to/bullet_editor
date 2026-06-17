import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../model/doc_selection.dart';
import '../model/document.dart';
import 'block_layout_registry.dart';
import 'editor_auto_scroller.dart';
import 'editor_hit_tester.dart';
import 'selection_drag.dart';
import 'selection_geometry.dart';

export 'selection_geometry.dart' show SelectionHandleKind;

/// The active touch drag, or null when none is live. A sealed hierarchy so the
/// illegal combinations a flat set of booleans allowed (a handle drag with no
/// active handle, a "moved" flag on a handle drag) are unrepresentable, and
/// "which kind of drag" is a pattern match, not a derivation from boolean pairs
/// (review H5). Each variant carries its own [focalPoint] — the last
/// (compensated) point it resolved at, the magnifier focal point and the scroll
/// re-hit-test position.
sealed class _DragSession {
  _DragSession(this.focalPoint);
  Offset focalPoint;
}

/// A long-press word drag: extends [wordAnchor] by word. [moved] gates the
/// scroll re-hit-test — a stationary long-press must NOT re-extend under an
/// incidental focus-driven `scrollTo(caret)`, which would otherwise drag the
/// selection to whatever now sits under the stationary press point.
class _LongPressDrag extends _DragSession {
  _LongPressDrag(super.focalPoint, this.wordAnchor);
  final DocSelection wordAnchor;
  bool moved = false;
}

/// A handle drag: moves the [kind] endpoint, hit-testing at finger +
/// [fingerToAnchorDelta] (grab-offset compensation — the bulb hangs a line off
/// the anchor).
class _HandleDrag extends _DragSession {
  _HandleDrag(super.focalPoint, this.kind, this.fingerToAnchorDelta);
  final SelectionHandleKind kind;
  final Offset fingerToAnchorDelta;
}

/// Selection gestures for touch/stylus-kind pointers, on every platform
/// (architecture §Gestures: per-kind dispatch, not platform-at-build — Android
/// touch and web touch are launch surfaces). Mirrors [MouseInteractor]'s shape:
/// the editor feeds it the per-kind pointer stream and scroll notifications and
/// supplies the document/selection/scroll surfaces as callbacks, so the
/// interactor holds no widgets and stays unit-reachable.
///
/// - **Tap** places a collapsed caret + focuses (the editor opens IME on
///   selection); voids atomic-select `[0,1)` via `setSelection` normalization.
///   (Gutter/prefix-tap and link-tap ride existing recognizers — day 14.)
/// - **Long-press** word-selects via `wordBoundaryAt`, records the anchored
///   word, fires haptic feedback, and — via [notifyListeners] — surfaces the
///   handles, magnifier, and toolbar.
/// - **Long-press drag** extends the selection BY WORD from the anchor (never
///   shrinking below the anchored word), through the shared hit tester, driving
///   the shared autoscroller (D7) and the post-frame re-hit-test on scroll
///   exactly like the mouse drag (G5).
/// - **Handle drag** (G11) is owned here, not by the handle widget: the handle
///   is visual-only and routes its pointer to this always-mounted object via
///   `pointerRouter`, so it survives the handle unmounting mid-drag. Grab-offset
///   compensation keeps the hit-test on the anchor, not the finger.
///
/// The selection-math (swept-void resolution, word-granular extension,
/// document order) and the post-frame re-hit scheduling are the SHARED
/// [extendSelection] / [resolveSweptVoid] / [DragRehitScheduler] helpers, one
/// implementation with the mouse interactor (review H1–H4).
///
/// A [ChangeNotifier] so the overlay widgets (handles, magnifier, toolbar)
/// rebuild from one source of truth as the selection/drag/scroll state moves.
class TouchInteractor extends ChangeNotifier {
  TouchInteractor({
    required this.registry,
    required this.documentOf,
    required this.selectionOf,
    required this.isVoid,
    required void Function(DocSelection selection) setSelection,
    required this.requestFocus,
    required ScrollPosition? Function() scrollPositionOf,
    required Rect? Function() viewportRectOf,
  }) : _rawSetSelection = setSelection {
    _autoScroller = EditorAutoScroller(
      scrollPositionOf: scrollPositionOf,
      viewportRectOf: viewportRectOf,
      isActive: () => _session != null,
    );
    _rehitScheduler = DragRehitScheduler(
      isActive: () => _isActiveRehitDrag,
      focalPointOf: () => _session?.focalPoint,
      onRehit: (focal) {
        final hit = hitTestDocPosition(registry, focal);
        if (hit == null) return;
        final session = _session;
        if (session is _HandleDrag) {
          _moveActiveEndpointTo(hit);
        } else if (session is _LongPressDrag) {
          _extendWordTo(hit);
        }
        notifyListeners();
      },
    );
  }

  final BlockLayoutRegistry registry;
  final Document Function() documentOf;

  /// The live model selection — handle/menu visibility and a handle drag's
  /// "other endpoint" read from this (the model is the source of truth; the
  /// interactor never caches selection it didn't push).
  final DocSelection? Function() selectionOf;

  /// Whether a block is a void (image, divider) — a swept void resolves by
  /// drag direction (D6), the same rule as the mouse interactor.
  final bool Function(String blockId) isVoid;

  final void Function(DocSelection selection) _rawSetSelection;
  final void Function() requestFocus;

  /// The edge-zone autoscroll ticker, shared with the mouse interactor (D7).
  late final EditorAutoScroller _autoScroller;

  /// The post-frame extent re-hit-test after a mid-drag scroll (G5), shared
  /// implementation with the mouse interactor (review H4).
  late final DragRehitScheduler _rehitScheduler;

  Document get _doc => documentOf();

  // -- Dedup wrapper (mirror of the mouse interactor's): a drag re-hit-tests
  // on every move AND every scroll tick, frequently resolving the same offset.
  // Push only on an actual change so the editor doesn't rebuild on no-ops.
  DocSelection? _lastPushed;
  void _setSelection(DocSelection selection) {
    if (selection == _lastPushed) return;
    _lastPushed = selection;
    _rawSetSelection(selection);
  }

  /// The active touch drag (long-press or handle), or null when none is live.
  _DragSession? _session;

  /// True from a handle pointer-down until just after its up — the handle's
  /// opaque `Listener` stops the hit-test within the overlay subtree, but the
  /// editor's tap/long-press recognizers sit in a SEPARATE Overlay entry below
  /// and still see the pointer (per-widget `HitTestBehavior` does not absorb
  /// across Overlay entries). Without this, releasing a handle without moving
  /// would also fire the editor's tap → a collapsed caret (arch 1427 violated).
  /// It outlives the drag [_session] by one frame (the editor's recognizers
  /// fire their up on the same frame as the handle's), so it is a separate flag,
  /// not part of the session: the interactor owns both the handle route and the
  /// editor recognizers, so it suppresses its own tap/long-press while a handle
  /// gesture owns the pointer — the G11 "pointer that goes down on a handle
  /// never seeds the scrollable/caret" invariant, enforced at the one place that
  /// knows both.
  bool _handleGestureActive = false;

  /// Whether the live selection was made by a TOUCH gesture (long-press or a
  /// handle drag) — handles, magnifier, and the fallback toolbar are touch
  /// chrome and must NOT appear over a mouse drag-select (architecture
  /// §Gestures: "handles and magnifier are suppressed for mouse-kind
  /// pointers"). Set by [handleLongPressStart] / [handleHandlePointerDown];
  /// cleared by a touch tap (collapses to a caret) and by any non-touch
  /// selection change ([onSelectionChanged]). The overlays read it.
  bool get touchSelectionActive => _touchSelectionActive;
  bool _touchSelectionActive = false;

  /// The active drag's compensated focal point, or null when no drag is live —
  /// the magnifier reads this (architecture §Gestures: the magnifier follows
  /// the compensated finger point, surviving the extent block leaving the
  /// viewport).
  Offset? get dragFocalPoint => _session?.focalPoint;

  /// Whether a selection drag (long-press or handle) is live — the magnifier
  /// shows iff this is true.
  bool get isDragging => _session != null;

  /// Whether a re-hit-applicable drag is live: a handle drag, or a long-press
  /// that has actually moved. A stationary long-press (or a mouse-path scroll)
  /// must not re-extend under an incidental focus-driven scroll.
  bool get _isActiveRehitDrag {
    final session = _session;
    return session is _HandleDrag ||
        (session is _LongPressDrag && session.moved);
  }

  // ===========================================================================
  // Tap & long-press (driven by the interactor-owned recognizers in
  // BulletEditorState — architecture §Gestures arena participation).
  // ===========================================================================

  /// A tap (the `TapGestureRecognizer` won the arena — the scrollable lost):
  /// place a collapsed caret + focus; the editor opens IME on the resulting
  /// selection. A void hit (midpoint-resolved 0/1) collapses onto the void,
  /// which `setSelection` normalizes to the atomic `[0,1)` selection.
  ///
  /// Gutter/prefix-tap (checkbox toggle) and link-tap are day-14 surfaces
  /// owned by their own recognizers, not this method.
  void handleTap(Offset globalPosition) {
    if (_handleGestureActive) return; // a handle owns this pointer (G11)
    _touchSelectionActive = false; // a tap collapses to a caret: no chrome
    requestFocus();
    _lastPushed = null; // a keyboard/programmatic move may have changed it
    final hit = hitTestDocPosition(registry, globalPosition);
    if (hit != null) _setSelection(DocSelection.collapsed(hit));
    // The selection changed under the model, not us: refresh overlays.
    notifyListeners();
  }

  /// A long-press started (the `LongPressGestureRecognizer` won the arena,
  /// suppressing the scroll drag for this pointer): word-select, record the
  /// anchor, haptic, and surface the handles/magnifier/toolbar.
  void handleLongPressStart(Offset globalPosition) {
    if (_handleGestureActive) return; // a handle owns this pointer (G11)
    requestFocus();
    _lastPushed = null;
    final hit = hitTestDocPosition(registry, globalPosition);
    if (hit == null) return;
    final word = _wordSelectionAt(hit);
    _session = _LongPressDrag(globalPosition, word);
    _touchSelectionActive = true;
    HapticFeedback.selectionClick(); // feel-tunable; device-verified later
    _setSelection(word);
    notifyListeners();
  }

  /// Long-press drag move: extend BY WORD from the anchor through the shared
  /// hit tester, drive the autoscroller, and track the focal point for the
  /// magnifier. The point is NOT grab-compensated — a long-press drag resolves
  /// at the raw finger (the magnifier hangs the loupe above it); only handle
  /// drags compensate (the bulb hangs off the anchor).
  void handleLongPressMoveUpdate(Offset globalPosition) {
    final session = _session;
    if (session is! _LongPressDrag) return;
    session.moved = true;
    session.focalPoint = globalPosition;
    final hit = hitTestDocPosition(registry, globalPosition);
    if (hit != null) _extendWordTo(hit);
    _autoScroller.update(globalPosition);
    notifyListeners(); // magnifier focal point moved
  }

  /// Long-press / handle drag ended: stop autoscroll, drop the drag session,
  /// and refresh overlays (magnifier hides, toolbar re-anchors to the final
  /// selection). The selection itself is already committed by the last move.
  void handleLongPressEnd() => _endDrag();

  // ===========================================================================
  // Handle drag (G11 — pointer routing by registration, grab-offset
  // compensation). The handle widget calls [handleHandlePointerDown] from its
  // opaque Listener; this object owns the route and drives the rest.
  // ===========================================================================

  /// Begins a handle drag for [kind] from a pointer-down at [globalPosition].
  /// Registers a pointer route so move/up arrive here even if the handle
  /// unmounts mid-drag, and records the grab-offset compensation. Refuses the
  /// drag (returns false, no route) when the anchor's geometry is unavailable
  /// at pointer-down — the handle is about to hide anyway (the drag-start race,
  /// consistent with GATE-L); the caller then leaves the pointer to no one.
  bool handleHandlePointerDown(
    PointerDownEvent event,
    SelectionHandleKind kind,
  ) {
    final rect = handleAnchorRectGlobal(kind);
    if (rect == null) return false; // null geometry ⇒ refuse the drag

    // The compensation target is where the bulb visually attaches to the text:
    // the caret rect's top for the start handle (bulb above), its bottom for
    // the end handle (bulb below). Hit-testing at finger + delta then lands on
    // the anchor line, not a line away under the bulb.
    final anchorGlobal = kind == SelectionHandleKind.start
        ? rect.topLeft
        : rect.bottomLeft;
    _session = _HandleDrag(anchorGlobal, kind, anchorGlobal - event.position);
    _handleGestureActive = true;
    _touchSelectionActive = true;
    GestureBinding.instance.pointerRouter.addRoute(
      event.pointer,
      _onHandlePointerEvent,
    );
    HapticFeedback.selectionClick(); // grab feedback; feel-tunable
    notifyListeners();
    return true;
  }

  /// The pointer route for an active handle drag. Owned by this always-mounted
  /// object (not the handle widget), so the gesture outlives the handle's
  /// `OverlayPortal` unmounting when its anchor scrolls away (G11).
  void _onHandlePointerEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      _moveHandleTo(event.position);
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      GestureBinding.instance.pointerRouter.removeRoute(
        event.pointer,
        _onHandlePointerEvent,
      );
      _endDrag();
      // Keep suppressing the editor's tap/long-press until the same pointer's
      // arena resolves (the editor's recognizers fire their up on this frame);
      // clear post-frame so the next, independent gesture is unaffected.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleGestureActive = false;
      });
    }
  }

  void _moveHandleTo(Offset fingerPosition) {
    final session = _session;
    if (session is! _HandleDrag) return;
    // Grab-offset compensation: hit-test at the anchor's projected position,
    // not the raw finger (the bulb hangs a line off the anchor).
    final compensated = fingerPosition + session.fingerToAnchorDelta;
    session.focalPoint = compensated;
    final hit = hitTestDocPosition(registry, compensated);
    if (hit != null) _moveActiveEndpointTo(hit);
    _autoScroller.update(compensated);
    notifyListeners();
  }

  /// The selection changed by some path other than this interactor's own push
  /// (keyboard, an app `setSelection`, or another gesture). The overlays read
  /// the model selection, so they must recompute handle/toolbar geometry —
  /// poke listeners. A drag's own pushes don't route here (they notify inline),
  /// so this never double-fires mid-drag.
  void onSelectionChanged() {
    if (_session != null) return; // a live drag already notifies on each move
    // A selection change from a non-touch path (mouse drag-select, keyboard,
    // an app call) is not touch chrome's selection — drop the flag so handles /
    // magnifier / toolbar don't appear over it.
    _touchSelectionActive = false;
    notifyListeners();
  }

  // ===========================================================================
  // Scroll re-hit-test (G5) — the shared [DragRehitScheduler], plus the overlay
  // visibility recompute every tick.
  // ===========================================================================

  /// Called by the editor's scroll-notification listener. Recomputes overlay
  /// visibility (handles/toolbar) on EVERY tick — the shared scroll tick
  /// (§Gestures handle visibility / §Context menus hide-on-offscreen) — and, for
  /// an active drag, schedules the post-frame extent re-hit-test (G5).
  void onScroll() {
    notifyListeners();
    _rehitScheduler.schedule();
  }

  // ===========================================================================
  // Selection math (shared helpers; the touch interactor only supplies the
  // word-granular snap the mouse interactor omits).
  // ===========================================================================

  /// The word selection at [hit]: the `wordBoundaryAt` span for a text block,
  /// or the void's collapsed hit (normalized to `[0,1)` by `setSelection`).
  DocSelection _wordSelectionAt(DocPosition hit) {
    final geometry = registry.geometryOf(hit.blockId);
    if (geometry == null) return DocSelection.collapsed(hit);
    final block = _doc.blockById(hit.blockId);
    if (block == null || isVoid(hit.blockId)) {
      return DocSelection.collapsed(hit);
    }
    final word = geometry.wordBoundaryAt(hit.offset);
    return DocSelection(
      base: DocPosition(hit.blockId, word.start),
      extent: DocPosition(hit.blockId, word.end),
    );
  }

  /// Extends the long-press selection to the WORD at [point] via the shared
  /// [extendSelection] math, supplying [_wordEdgeAt] as the snap so the moving
  /// end lands on a word boundary rather than mid-word (native word-drag).
  void _extendWordTo(DocPosition point) {
    final session = _session;
    final anchor = session is _LongPressDrag ? session.wordAnchor : null;
    _setSelection(
      extendSelection(
        anchor: anchor,
        point: point,
        doc: _doc,
        isVoid: isVoid,
        snap: _wordEdgeAt,
      ),
    );
  }

  /// The start (or end) of the word containing [point], for word-granular drag
  /// extension. Voids and unlaid blocks pass [point] through unchanged.
  DocPosition _wordEdgeAt(DocPosition point, {required bool toStart}) {
    if (isVoid(point.blockId)) return point;
    final geometry = registry.geometryOf(point.blockId);
    if (geometry == null) return point;
    final word = geometry.wordBoundaryAt(point.offset);
    return DocPosition(point.blockId, toStart ? word.start : word.end);
  }

  /// Moves the active handle's endpoint to [point], keeping the OTHER endpoint
  /// fixed (the model selection is the source of truth for the fixed end). A
  /// handle drag moves by character, not word (native handle behavior).
  void _moveActiveEndpointTo(DocPosition point) {
    final session = _session;
    final selection = selectionOf();
    if (session is! _HandleDrag || selection == null) return;
    final (start, end) = selection.normalized(_doc);
    // The fixed endpoint is the OTHER document-order end; resolve a swept void
    // by direction against it so a handle dragged onto an image covers it.
    final fixed = session.kind == SelectionHandleKind.start ? end : start;
    point = resolveSweptVoid(point, fixed, _doc, isVoid);
    _setSelection(DocSelection(base: fixed, extent: point));
  }

  // ===========================================================================
  // Handle / menu anchor geometry — thin bindings of this interactor's state to
  // the pure [selection_geometry] helpers (review M4): the widgets read these,
  // and a handle drag start reads [handleAnchorRectGlobal].
  // ===========================================================================

  /// The caret rect of [kind]'s endpoint (global), or null when not laid out.
  Rect? handleAnchorRectGlobal(SelectionHandleKind kind) =>
      handleAnchorRect(registry, _doc, selectionOf(), kind);

  /// The bounding box (global) of the selection's laid-out block rects — the
  /// context-menu anchor — or null when no selected block is visible.
  Rect? selectionBoundsGlobal() =>
      selectionBoundsRect(registry, _doc, selectionOf(), isVoid);

  void _endDrag() {
    final wasDragging = _session != null;
    _session = null;
    _autoScroller.stop();
    if (wasDragging) notifyListeners();
  }

  @override
  void dispose() {
    _autoScroller.stop();
    super.dispose();
  }
}
