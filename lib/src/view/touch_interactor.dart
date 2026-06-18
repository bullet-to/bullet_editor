import 'package:flutter/foundation.dart' show defaultTargetPlatform;
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

/// A handle drag: moves the grabbed [kind] endpoint, hit-testing at finger +
/// [fingerToAnchorDelta] (grab-offset compensation — the bulb hangs a line off
/// the anchor). [anchor] is the OPPOSITE endpoint, captured at drag-start and
/// held FIXED for the whole drag (so it never walks with the finger). The
/// grabbed handle stays on its own side of [anchor]: it clamps to a one-
/// character minimum and never crosses or inverts (native handle behavior);
/// [kind] tells which side it is.
class _HandleDrag extends _DragSession {
  _HandleDrag(super.focalPoint, this.kind, this.anchor, this.fingerToAnchorDelta);
  final SelectionHandleKind kind;
  final DocPosition anchor;
  final Offset fingerToAnchorDelta;
}

/// A caret (collapsed-handle) gesture: a TAP on the Android caret handle toggles
/// its context menu; a DRAG moves the COLLAPSED caret to the (grab-compensated)
/// finger. The two are told apart by movement past [kTouchSlop] from
/// [downPosition] — until then it may still be a tap. [fingerToAnchorDelta]
/// projects the finger back onto the caret's line centre (not the bottom edge,
/// which resolves to the line below). The whole selection stays collapsed.
class _CaretDrag extends _DragSession {
  _CaretDrag(super.focalPoint, this.downPosition, this.fingerToAnchorDelta);
  final Offset downPosition;
  final Offset fingerToAnchorDelta;
  bool moved = false;
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
        } else if (session is _CaretDrag) {
          _setSelection(DocSelection.collapsed(hit));
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

  /// The active drag's compensated focal point, or null when the magnifier
  /// should not show — it follows this (architecture §Gestures: the magnifier
  /// tracks the compensated finger point, surviving the extent block leaving the
  /// viewport).
  Offset? get dragFocalPoint => _loupeActive ? _session?.focalPoint : null;

  /// Whether a selection drag (long-press or handle) is live — the magnifier
  /// shows iff this is true.
  bool get isDragging => _session != null;

  /// Whether the loupe should show: a live drag, EXCEPT a caret-handle press
  /// that hasn't moved yet (it may resolve to a tap → menu; showing the loupe
  /// and then flashing it away on the up reads as a glitch — device finding).
  bool get _loupeActive {
    final session = _session;
    if (session is _CaretDrag) return session.moved;
    return session != null;
  }

  /// Whether a re-hit-applicable drag is live: a handle drag, or a long-press
  /// that has actually moved. A stationary long-press (or a mouse-path scroll)
  /// must not re-extend under an incidental focus-driven scroll.
  bool get _isActiveRehitDrag {
    final session = _session;
    return session is _HandleDrag ||
        session is _CaretDrag ||
        (session is _LongPressDrag && session.moved);
  }

  /// Whether the user re-tapped a collapsed caret to summon its context menu
  /// (native Android: tap the caret → Paste / Select-all). The toolbar reads
  /// this to anchor a menu on the caret. Cleared whenever the caret moves or the
  /// selection changes by any other path.
  bool get caretMenuShown => _caretMenuShown;
  bool _caretMenuShown = false;

  // ===========================================================================
  // Tap & long-press (driven by the interactor-owned recognizers in
  // BulletEditorState — architecture §Gestures arena participation).
  // ===========================================================================

  /// Consecutive-tap tracking (timer-free, native multi-tap). The editor's
  /// arena-exempt raw `Listener` calls [registerTapDown] on every touch/stylus
  /// down — first, before the tap recognizer resolves — so [handleTap] knows the
  /// count without a lingering double-tap timer (which would trip the test
  /// binding's pending-timer check on every editor tap).
  int _tapCount = 0;
  Duration _lastTapDownTime = Duration.zero;
  Offset? _lastTapDownPosition;

  /// The live consecutive-tap count (1 = first tap of a series). Read by the
  /// editor's double-tap-drag recognizer at pointer-down to decide whether to
  /// engage (≥2 ⇒ a multi-tap is in progress).
  int get tapCount => _tapCount;

  /// Records a touch/stylus pointer-down for consecutive-tap counting: a down
  /// within [kDoubleTapTimeout] AND [kDoubleTapSlop] of the previous one
  /// increments the count, otherwise it resets to 1. Computed at down-time so
  /// the count is ready when the tap's up fires.
  void registerTapDown(Offset position, Duration timeStamp) {
    final last = _lastTapDownPosition;
    final withinTime =
        (timeStamp - _lastTapDownTime).abs() <= kDoubleTapTimeout;
    final withinSlop =
        last != null && (position - last).distance <= kDoubleTapSlop;
    _tapCount = (withinTime && withinSlop) ? _tapCount + 1 : 1;
    _lastTapDownTime = timeStamp;
    _lastTapDownPosition = position;

    // A multi-tap acts on the DOWN, not the up: a double-tap that becomes a HOLD
    // must select the word IMMEDIATELY (native feel), not wait for the finger to
    // lift or for the long-press timeout to elapse (device finding). A single
    // tap still resolves on the up (in [handleTap]) so it can be told apart from
    // the start of a scroll drag.
    if (_tapCount >= 2) _selectByTapCount(position);
  }

  /// A tap UP (the `TapGestureRecognizer` won the arena — the scrollable lost).
  /// A SINGLE tap places a collapsed caret + focus here; the editor opens IME on
  /// it. (A void hit, midpoint-resolved 0/1, collapses onto the void, which
  /// `setSelection` normalizes to the atomic `[0,1)` selection.) A double/triple
  /// tap already selected on the down (see [registerTapDown]), so it is a no-op
  /// here.
  ///
  /// Gutter/prefix-tap (checkbox toggle) and link-tap are day-14 surfaces
  /// owned by their own recognizers, not this method.
  void handleTap(Offset globalPosition) {
    if (_handleGestureActive) return; // a handle owns this pointer (G11)
    if (_tapCount >= 2) return; // the multi-tap already acted on the down
    requestFocus();
    _lastPushed = null; // a keyboard/programmatic move may have changed it
    // A tap on the TEXT places/moves the caret and dismisses any caret menu (the
    // menu is summoned by tapping the caret handle, not the text — device
    // finding). The Android caret drag-handle shows for the touch caret.
    _caretMenuShown = false;
    final hit = hitTestDocPosition(registry, globalPosition);
    if (hit == null) {
      _touchSelectionActive = false;
      notifyListeners();
      return;
    }
    // Push FIRST — the controller's synchronous selection-change callback runs
    // `onSelectionChanged`, which (no live drag to shield it) resets the
    // touch-chrome flag; set it after so the caret handle stays.
    _setSelection(DocSelection.collapsed(hit));
    _touchSelectionActive = true;
    notifyListeners();
  }

  /// Selects per the current [_tapCount] at [globalPosition] (a multi-tap, on
  /// the down): **2** → the word under the finger; **3 or more** → the whole
  /// block under the finger (NOT the document — native paragraph select). Both
  /// are touch chrome, so the handles/toolbar surface.
  void _selectByTapCount(Offset globalPosition) {
    if (_handleGestureActive) return; // a handle owns this pointer (G11)
    requestFocus();
    _lastPushed = null;
    final hit = hitTestDocPosition(registry, globalPosition);
    if (hit == null) {
      notifyListeners();
      return;
    }
    final selection = _tapCount >= 3 ? _blockSelectionAt(hit) : _wordSelectionAt(hit);
    // Push FIRST — the controller's selection-change callback runs synchronously
    // and (no live drag session to shield it) would otherwise reset
    // `_touchSelectionActive`; set the flag after so the chrome stays.
    HapticFeedback.selectionClick();
    _setSelection(selection);
    _touchSelectionActive = true;
    notifyListeners();
  }

  /// The whole block containing [hit] — `[0, length)` of that block (triple-tap
  /// paragraph select). Voids fall back to their collapsed hit (normalized to
  /// the atomic `[0,1)` by `setSelection`).
  DocSelection _blockSelectionAt(DocPosition hit) {
    final block = _doc.blockById(hit.blockId);
    if (block == null || isVoid(hit.blockId)) {
      return DocSelection.collapsed(hit);
    }
    return DocSelection(
      base: DocPosition(hit.blockId, 0),
      extent: DocPosition(hit.blockId, block.length),
    );
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
    _longPressHaptic();
    _setSelection(word);
    notifyListeners();
  }

  /// The haptic when a long-press grabs a selection — matched to the vanilla
  /// field. Android/Fuchsia fire the native LONG_PRESS feedback (a clearly-felt
  /// buzz via [HapticFeedback.vibrate], exactly what the framework's
  /// `Feedback.forLongPress` does there); the plain selection tick is too subtle
  /// to read as "I grabbed a selection" on Android (device finding). Other
  /// platforms keep the lighter tick.
  void _longPressHaptic() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
        HapticFeedback.vibrate();
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        HapticFeedback.selectionClick();
    }
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
  // Double-tap-(or-triple)-and-drag: the multi-tap already selected a word/block
  // (on the down, [registerTapDown]); holding the second tap and dragging
  // extends BY WORD immediately — the same machinery as a long-press drag, but
  // with no 500ms wait and guaranteed to beat the scrollable (the recognizer
  // claims the arena eagerly). Driven by [_MultiTapDragGestureRecognizer].
  // ===========================================================================

  /// A move during a double-tap-and-drag. The drag session is created LAZILY on
  /// the first move (anchored on the already-selected word/block), so a plain
  /// double-tap with no drag never starts a session — hence shows no magnifier
  /// and leaves the word simply selected.
  void handleMultiTapDragUpdate(Offset globalPosition) {
    if (_handleGestureActive) return; // a handle owns this pointer (G11)
    if (_session is! _LongPressDrag) {
      final selection = selectionOf();
      if (selection == null) return; // nothing to anchor on
      _session = _LongPressDrag(globalPosition, selection);
      _touchSelectionActive = true;
    }
    // Reuse the long-press word-drag move (extend by word, autoscroll, magnifier
    // focal point, scroll re-hit) — the session type is identical.
    handleLongPressMoveUpdate(globalPosition);
  }

  /// A double-tap-and-drag ended (or was cancelled): same teardown as any drag.
  void handleMultiTapDragEnd() => _endDrag();

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
    final selection = selectionOf();
    final rect = handleAnchorRectGlobal(kind);
    if (rect == null || selection == null) {
      return false; // null geometry/selection ⇒ refuse the drag
    }

    // Lock the OPPOSITE endpoint as the fixed anchor for the whole drag — the
    // grabbed handle moves against it (and is clamped so it never crosses it).
    // Reading it once here, not per-move from the live selection, is what keeps
    // it from walking with the finger as the selection shrinks.
    final (start, end) = selection.normalized(_doc);
    final fixedAnchor = kind == SelectionHandleKind.start ? end : start;

    // The compensation target is the endpoint the handle glyph attaches to —
    // the bottom of the caret line (both native handles, Material and Cupertino,
    // anchor there). The glyph hangs below the line, so hit-testing the raw
    // finger would land a line low; finger + delta resolves back on the
    // endpoint's own line. bottomLeft is inside the endpoint's block (it is that
    // block's own caret-rect bottom), so the hit clamps onto the right line.
    final glyphGlobal = rect.bottomLeft;
    _session = _HandleDrag(
      glyphGlobal,
      kind,
      fixedAnchor,
      glyphGlobal - event.position,
    );
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

  /// Begins a CARET drag from the Android collapsed-caret handle: the whole
  /// (collapsed) selection follows the grab-compensated finger. Same pointer-
  /// route ownership as [handleHandlePointerDown] (G11). Refuses when the caret
  /// isn't laid out.
  bool handleCaretHandlePointerDown(PointerDownEvent event) {
    final rect = collapsedCaretRectGlobal();
    if (rect == null) return false;
    // Compensate to the caret's LINE CENTRE: the teardrop hangs below the line,
    // and hit-testing the bottom edge resolves to the line below (device finding:
    // the caret jumped down a line). Whether this becomes a tap (→ menu) or a
    // drag (→ move) is decided on move/up, so don't touch the menu flag yet.
    final caretCentre = rect.center;
    _session = _CaretDrag(caretCentre, event.position, caretCentre - event.position);
    _handleGestureActive = true;
    _touchSelectionActive = true;
    GestureBinding.instance.pointerRouter.addRoute(
      event.pointer,
      _onHandlePointerEvent,
    );
    HapticFeedback.selectionClick();
    notifyListeners();
    return true;
  }

  /// The pointer route for an active handle/caret drag. Owned by this always-
  /// mounted object (not the handle widget), so the gesture outlives the handle's
  /// `OverlayPortal` unmounting when its anchor scrolls away (G11).
  void _onHandlePointerEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      _moveHandleTo(event.position);
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      GestureBinding.instance.pointerRouter.removeRoute(
        event.pointer,
        _onHandlePointerEvent,
      );
      // A TAP on the caret handle (down + up, no drag) toggles its context menu
      // — the native Android trigger (tap the teardrop, not the text). A drag
      // already moved the caret and left the menu dismissed.
      final session = _session;
      if (event is PointerUpEvent && session is _CaretDrag && !session.moved) {
        _caretMenuShown = !_caretMenuShown;
      }
      _endDrag();
      // Keep suppressing the editor's tap/long-press until the same pointer's
      // arena resolves (the editor's recognizers fire their up on this frame);
      // clear post-frame so the next, independent gesture is unaffected.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleGestureActive = false;
      });
    }
  }

  // Grab-offset compensation: both routed drags hit-test at the glyph's
  // projected anchor, not the raw finger (the teardrop hangs a line off the
  // caret/endpoint). A handle drag moves its endpoint; a caret drag re-collapses
  // the whole selection onto the hit.
  void _moveHandleTo(Offset fingerPosition) {
    final session = _session;
    if (session is _HandleDrag) {
      final compensated = fingerPosition + session.fingerToAnchorDelta;
      session.focalPoint = compensated;
      final hit = hitTestDocPosition(registry, compensated);
      if (hit != null) _moveActiveEndpointTo(hit);
      _autoScroller.update(compensated);
      notifyListeners();
    } else if (session is _CaretDrag) {
      // Below the slop it might still be a tap (→ menu on up); don't move yet.
      if (!session.moved &&
          (fingerPosition - session.downPosition).distance <= kTouchSlop) {
        return;
      }
      session.moved = true;
      _caretMenuShown = false; // a drag dismisses any menu
      final compensated = fingerPosition + session.fingerToAnchorDelta;
      session.focalPoint = compensated;
      final hit = hitTestDocPosition(registry, compensated);
      if (hit != null) _setSelection(DocSelection.collapsed(hit));
      _autoScroller.update(compensated);
      notifyListeners();
    }
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
    // magnifier / toolbar don't appear over it, and dismiss any caret menu.
    _touchSelectionActive = false;
    _caretMenuShown = false;
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

  /// Moves the grabbed handle to [point] against the session's FIXED [anchor]
  /// (captured at drag-start, never re-derived — so the anchor never walks with
  /// the finger). A handle drag moves by character, not word (native handle
  /// behavior). A swept void is resolved by direction against the anchor so a
  /// handle dragged onto an image covers it. The grabbed handle is CLAMPED to
  /// its own side of the anchor with a one-character minimum: native handles
  /// stop at one character, they do not cross or invert (device finding).
  void _moveActiveEndpointTo(DocPosition point) {
    final session = _session;
    if (session is! _HandleDrag) return;
    point = resolveSweptVoid(point, session.anchor, _doc, isVoid);

    final draggedIsEnd = session.kind == SelectionHandleKind.end;
    final cmp = point.compareInDocument(session.anchor, _doc);
    // End handle must stay strictly AFTER the anchor; start handle strictly
    // BEFORE. On reaching or crossing it, clamp to a one-character selection.
    if (draggedIsEnd ? cmp <= 0 : cmp >= 0) {
      point = _oneCharFromAnchor(session.anchor, draggedIsEnd: draggedIsEnd);
    }
    _setSelection(DocSelection(base: session.anchor, extent: point));
  }

  /// The position one character to the [draggedIsEnd] side of [anchor], within
  /// the anchor's block (the one-character clamp floor). For a word/block
  /// selection the anchor is never at the block edge on the dragged side, so a
  /// one-char span always exists; the `clamp` guards the degenerate edge.
  DocPosition _oneCharFromAnchor(
    DocPosition anchor, {
    required bool draggedIsEnd,
  }) {
    final length = _doc.blockById(anchor.blockId)?.length ?? anchor.offset;
    final offset = draggedIsEnd
        ? (anchor.offset + 1).clamp(0, length)
        : (anchor.offset - 1).clamp(0, length);
    return DocPosition(anchor.blockId, offset);
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

  /// The caret rect (global) of a collapsed caret — the anchor for the Android
  /// caret drag-handle and the re-tap caret menu. Null unless collapsed + laid
  /// out.
  Rect? collapsedCaretRectGlobal() =>
      collapsedCaretRect(registry, _doc, selectionOf());

  /// The loupe geometry (extent caret rect + its block bounds, global) for the
  /// live drag — what the magnifier centers on. Null when the loupe should not
  /// show (no drag, an unmoved caret press, or the extent isn't laid out).
  ({Rect caret, Rect block})? dragLoupeRects() =>
      _loupeActive ? extentLoupeRects(registry, _doc, selectionOf()) : null;

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
