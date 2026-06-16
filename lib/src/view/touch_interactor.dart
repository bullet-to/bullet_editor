import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../model/doc_selection.dart';
import '../model/document.dart';
import 'block_layout_registry.dart';
import 'editor_auto_scroller.dart';
import 'editor_hit_tester.dart';

/// Which selection endpoint a handle drives — the document-order start
/// (upstream bulb) or end (downstream bulb).
enum SelectionHandleKind { start, end }

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
///   word (mirror of the mouse `expandBase`), fires haptic feedback, and — via
///   [notifyListeners] — surfaces the handles, magnifier, and toolbar.
/// - **Long-press drag** extends the selection BY WORD from the anchor (never
///   shrinking below the anchored word), through the shared hit tester, driving
///   the shared autoscroller (D7) and the post-frame re-hit-test on scroll
///   exactly like the mouse drag (G5).
/// - **Handle drag** (G11) is owned here, not by the handle widget: the handle
///   is visual-only and routes its pointer to this always-mounted object via
///   `pointerRouter`, so it survives the handle unmounting mid-drag. Grab-offset
///   compensation keeps the hit-test on the anchor, not the finger.
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
      isActive: () => _dragging,
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

  /// The anchored word a long-press drag extends from (never shrunk below its
  /// own word while extending — native word-drag). Survives across edits only
  /// as data: every use routes back through [setSelection], which clamps stale
  /// offsets and rejects gone ids.
  DocSelection? _wordAnchor;

  // -- Active-drag bookkeeping (one of: long-press drag, or a handle drag) --
  bool _dragging = false;

  /// True while a handle drag is live (vs. a long-press drag). Handle drags
  /// move the named endpoint; long-press drags extend the anchored word.
  bool _draggingHandle = false;
  SelectionHandleKind? _activeHandle;

  /// Whether the active long-press has actually moved (a drag-extension is
  /// under way). Until the finger moves, the long-press is a stationary
  /// word-select and a scroll re-hit-test must NOT re-extend it — an incidental
  /// focus-driven `scrollTo(caret)` would otherwise drag the selection to
  /// whatever now sits under the stationary press point.
  bool _longPressMoved = false;

  /// The vector from the anchor's on-screen position to the finger at handle
  /// pointer-down: every hit-test during the drag adds it back so we resolve
  /// at the anchor, not a line away under the bulb (architecture §Gestures
  /// grab-offset compensation).
  Offset _fingerToAnchorDelta = Offset.zero;

  /// The last (compensated) global point a drag resolved at — the magnifier's
  /// focal point and the scroll re-hit-test position.
  Offset? _dragFocalPoint;

  /// The active drag's compensated focal point, or null when no drag is live —
  /// the magnifier reads this (architecture §Gestures: the magnifier follows
  /// the compensated finger point, surviving the extent block leaving the
  /// viewport).
  Offset? get dragFocalPoint => _dragging ? _dragFocalPoint : null;

  /// Whether a selection drag (long-press or handle) is live — the magnifier
  /// shows iff this is true.
  bool get isDragging => _dragging;

  /// Whether the live selection was made by a TOUCH gesture (long-press or a
  /// handle drag) — handles, magnifier, and the fallback toolbar are touch
  /// chrome and must NOT appear over a mouse drag-select (architecture
  /// §Gestures: "handles and magnifier are suppressed for mouse-kind
  /// pointers"). Set by [handleLongPressStart] / [handleHandlePointerDown];
  /// cleared by a touch tap (collapses to a caret) and by any non-touch
  /// selection change ([onSelectionChanged]). The overlays read it.
  bool get touchSelectionActive => _touchSelectionActive;
  bool _touchSelectionActive = false;

  bool _rehitScheduled = false;

  /// True from a handle pointer-down until just after its up — the handle's
  /// opaque `Listener` stops the hit-test within the overlay subtree, but the
  /// editor's tap/long-press recognizers sit in a SEPARATE Overlay entry below
  /// and still see the pointer (per-widget `HitTestBehavior` does not absorb
  /// across Overlay entries). Without this, releasing a handle without moving
  /// would also fire the editor's tap → a collapsed caret (arch 1427 violated).
  /// The interactor owns both the handle route and the editor recognizers, so
  /// it suppresses its own tap/long-press while a handle gesture owns the
  /// pointer — the G11 "pointer that goes down on a handle never seeds the
  /// scrollable/caret" invariant, enforced at the one place that knows both.
  bool _handleGestureActive = false;

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
    _wordAnchor = word;
    _touchSelectionActive = true;
    _dragging = true;
    _draggingHandle = false;
    _longPressMoved = false;
    _dragFocalPoint = globalPosition;
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
    if (!_dragging || _draggingHandle) return;
    _longPressMoved = true;
    _dragFocalPoint = globalPosition;
    final hit = hitTestDocPosition(registry, globalPosition);
    if (hit != null) _extendWordTo(hit);
    _autoScroller.update(globalPosition);
    notifyListeners(); // magnifier focal point moved
  }

  /// Long-press / handle drag ended: stop autoscroll, drop the drag flag, and
  /// refresh overlays (magnifier hides, toolbar re-anchors to the final
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
    _fingerToAnchorDelta = anchorGlobal - event.position;
    _handleGestureActive = true;
    _touchSelectionActive = true;
    _activeHandle = kind;
    _draggingHandle = true;
    _dragging = true;
    _dragFocalPoint = anchorGlobal;
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
    if (!_draggingHandle) return;
    // Grab-offset compensation: hit-test at the anchor's projected position,
    // not the raw finger (the bulb hangs a line off the anchor).
    final compensated = fingerPosition + _fingerToAnchorDelta;
    _dragFocalPoint = compensated;
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
    if (_dragging) return; // a live drag already notifies on each move
    // A selection change from a non-touch path (mouse drag-select, keyboard,
    // an app call) is not touch chrome's selection — drop the flag so handles /
    // magnifier / toolbar don't appear over it.
    _touchSelectionActive = false;
    notifyListeners();
  }

  // ===========================================================================
  // Scroll re-hit-test (G5) — identical mechanics to the mouse interactor.
  // ===========================================================================

  /// Re-hit-test under the stationary (compensated) drag point after a scroll
  /// committed and the sliver re-laid the revealed content — scheduled
  /// post-frame so the hit always lands on laid-out content (G5). Called by the
  /// editor's scroll-notification listener while a drag is active; this is also
  /// the tick that recomputes handle/toolbar visibility (the shared scroll tick
  /// — §Gestures handle visibility / §Context menus hide-on-offscreen).
  void onScroll() {
    // Recompute overlay visibility (handles/toolbar) on every scroll tick.
    notifyListeners();
    // Re-hit only for an ACTIVE drag: a handle drag, or a long-press that has
    // actually moved. A stationary long-press (or a mouse-path scroll) must not
    // re-extend under an incidental focus-driven scroll.
    final reHits = _draggingHandle || _longPressMoved;
    final focal = _dragFocalPoint;
    if (!_dragging || !reHits || focal == null || _rehitScheduled) return;
    _rehitScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rehitScheduled = false;
      final point = _dragFocalPoint;
      if (!_dragging || point == null) return;
      final hit = hitTestDocPosition(registry, point);
      if (hit == null) return;
      if (_draggingHandle) {
        _moveActiveEndpointTo(hit);
      } else {
        _extendWordTo(hit);
      }
      notifyListeners();
    });
  }

  // ===========================================================================
  // Selection math.
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

  /// Extends the long-press selection to the WORD at [point], oriented in
  /// document order against the anchored word and never shrinking below it
  /// (native word-drag: both ends snap to word boundaries). Mirrors the mouse
  /// interactor's `_extendTo`, but the moving end snaps to the word containing
  /// the drag point rather than landing mid-word.
  void _extendWordTo(DocPosition point) {
    final anchor = _wordAnchor;
    if (anchor == null) {
      _setSelection(DocSelection.collapsed(point));
      return;
    }
    final (start, end) = anchor.normalized(_doc);
    point = _resolveSweptVoid(point, start);
    final DocSelection extended;
    if (_compare(point, start) < 0) {
      // Dragging upstream: the moving end snaps to the START of the word at the
      // point; the anchor's downstream end stays fixed.
      final wordStart = _wordEdgeAt(point, toStart: true);
      extended = DocSelection(base: end, extent: wordStart);
    } else if (_compare(point, end) > 0) {
      // Dragging downstream: the moving end snaps to the END of the word at the
      // point; the anchor's upstream start stays fixed.
      final wordEnd = _wordEdgeAt(point, toStart: false);
      extended = DocSelection(base: start, extent: wordEnd);
    } else {
      extended = anchor;
    }
    _setSelection(extended);
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
    final selection = selectionOf();
    final handle = _activeHandle;
    if (selection == null || handle == null) return;
    final (start, end) = selection.normalized(_doc);
    // The fixed endpoint is the OTHER document-order end; resolve a swept void
    // by direction against it so a handle dragged onto an image covers it.
    final fixed = handle == SelectionHandleKind.start ? end : start;
    point = _resolveSweptVoid(point, fixed);
    _setSelection(DocSelection(base: fixed, extent: point));
  }

  /// Selects a swept void the moment the drag enters its box (D6, web feel),
  /// resolving the void edge by direction against [anchorStart] so its `[0,1)`
  /// is covered. Identical rule to the mouse interactor.
  DocPosition _resolveSweptVoid(DocPosition point, DocPosition anchorStart) {
    if (!isVoid(point.blockId)) return point;
    final voidIndex = _doc.indexOfBlock(point.blockId);
    final anchorIndex = _doc.indexOfBlock(anchorStart.blockId);
    return DocPosition(point.blockId, voidIndex >= anchorIndex ? 1 : 0);
  }

  int _compare(DocPosition a, DocPosition b) {
    final ia = _doc.indexOfBlock(a.blockId);
    final ib = _doc.indexOfBlock(b.blockId);
    if (ia != ib) return ia.compareTo(ib);
    return a.offset.compareTo(b.offset);
  }

  // ===========================================================================
  // Handle anchor geometry (also the handle widgets' positioning source).
  // ===========================================================================

  /// The caret rect of [kind]'s endpoint in global coordinates — the single
  /// source for both handle positioning (the widget) and grab-offset
  /// compensation (the drag start). Null when that block is not laid out
  /// (scrolled out of the lazy viewport); a handle drag refuses to start on
  /// null (the drag-start race, consistent with GATE-L).
  Rect? handleAnchorRectGlobal(SelectionHandleKind kind) {
    final selection = selectionOf();
    if (selection == null || selection.isCollapsed) return null;
    final (start, end) = selection.normalized(_doc);
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
  /// block has a visible rect (every endpoint and the interior scrolled off):
  /// the menu hides on that tick (§Context menus zero-visible-rects case).
  Rect? selectionBoundsGlobal() {
    final selection = selectionOf();
    if (selection == null || selection.isCollapsed) return null;
    final (start, end) = selection.normalized(_doc);
    final startIndex = _doc.indexOfBlock(start.blockId);
    final endIndex = _doc.indexOfBlock(end.blockId);
    if (startIndex < 0 || endIndex < 0) return null;

    Rect? bounds;
    for (var i = startIndex; i <= endIndex; i++) {
      final block = _doc.allBlocks[i];
      final geometry = registry.geometryOf(block.id);
      if (geometry == null) continue; // not laid out — skip (lazy-safe)
      final box = geometry.renderBox;
      if (!box.attached || !box.hasSize) continue;
      // The selected slice within this block: [start.offset, end.offset] at
      // the endpoints, the whole block in the interior.
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

  void _endDrag() {
    final wasDragging = _dragging;
    _dragging = false;
    _draggingHandle = false;
    _activeHandle = null;
    _dragFocalPoint = null;
    _autoScroller.stop();
    if (wasDragging) notifyListeners();
  }

  @override
  void dispose() {
    _autoScroller.stop();
    super.dispose();
  }
}
