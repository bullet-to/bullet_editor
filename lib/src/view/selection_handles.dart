import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show cupertinoTextSelectionControls;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'touch_interactor.dart';

/// Touch target floor for a handle — the platform handle glyph is small (~22px
/// for Material), so we pad the interactive region out to this so a finger
/// reliably grabs it. Native `TextSelectionOverlay` expands handles to the same
/// `kMinInteractiveDimension`.
const double _kMinTouchTarget = 48.0;

/// Touch-class devices whose pointer-down on a handle must win the gesture
/// arena outright (below): mouse is excluded — a mouse drag-select never shows
/// handles in the first place (arch 1248).
const Set<PointerDeviceKind> _kHandleDevices = {
  PointerDeviceKind.touch,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
};

/// The platform's selection controls — Material on Android/desktop (bottom-
/// corner teardrops), Cupertino on iOS/macOS (bar + knob). Rendering through the
/// framework's own controls keeps the handles native per platform (device
/// finding: the hand-drawn iOS-style bulb+stem was wrong on Android) and correct
/// as the OS evolves.
TextSelectionControls _controlsFor(BuildContext context) {
  switch (Theme.of(context).platform) {
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return cupertinoTextSelectionControls;
    case TargetPlatform.android:
    case TargetPlatform.fuchsia:
    case TargetPlatform.linux:
    case TargetPlatform.windows:
      return materialTextSelectionControls;
  }
}

/// The two text-selection handles (architecture §Gestures), rendered with the
/// platform's native [TextSelectionControls] and positioned from the
/// interactor's `handleAnchorRectGlobal`. Each handle attaches at the bottom
/// corner of its endpoint's caret line (the native convention both Material and
/// Cupertino use): the start endpoint takes the `left` handle, the end the
/// `right`.
///
/// **Visibility is a viewport predicate, not a layout predicate** (arch
/// 1377-1386): a handle shows iff its anchor rect exists AND intersects the
/// scroll viewport's visible bounds. This overlay paints in a Stack the viewport
/// does NOT clip, so a handle keyed only to "laid out" would draw over the app
/// bar as its anchor scrolls past the edge (the sliver's cacheExtent keeps it
/// laid out beyond the visible viewport). [viewportRectOf] supplies the bounds.
///
/// **G11 pointer-down exclusivity**: opacity alone is NOT enough — a raw
/// `Listener` does not enter the gesture arena, so an ancestor drag recognizer
/// (the editor's own scrollable, *or* a host `TabBarView`/`PageView` the editor
/// is nested in) wins the arena uncontested and drags the thing underneath
/// while the finger is on the handle (device finding). So the region also mounts
/// an [EagerGestureRecognizer], which claims victory the instant the pointer
/// goes down — defeating every ancestor recognizer for that pointer. **G11 drag
/// continuity**: the `Listener`'s down only *starts* the drag in the interactor
/// (which owns the pointer route); pointer routes deliver events independently
/// of the arena, so the drag survives even after this widget unmounts.
///
/// Anchor rects are read POST-FRAME (the interactor can notify mid-build — e.g.
/// from a scroll tick fired during another block's layout — and querying a
/// `RenderParagraph` that still needs layout asserts). The widget caches the
/// last computed rects and rebuilds from them; the one-frame lag is the same
/// the architecture accepts for the autoscroll re-hit-test (G5).
class SelectionHandles extends StatefulWidget {
  const SelectionHandles({
    super.key,
    required this.interactor,
    required this.viewportRectOf,
    required this.originOf,
  });

  final TouchInteractor interactor;

  /// The scroll viewport's visible global bounds — the visibility predicate.
  /// Null before layout (handles hide).
  final Rect? Function() viewportRectOf;

  /// The overlay Stack's global top-left — global anchor rects are converted to
  /// Stack-local positions by subtracting this, so the handles are correct
  /// regardless of where the editor sits in the app.
  final Offset Function() originOf;

  @override
  State<SelectionHandles> createState() => _SelectionHandlesState();
}

class _SelectionHandlesState extends State<SelectionHandles> {
  Rect? _startAnchor;
  Rect? _endAnchor;
  Rect? _caretAnchor; // collapsed caret (Android caret drag-handle)
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    widget.interactor.addListener(_scheduleRecompute);
    _scheduleRecompute();
  }

  @override
  void didUpdateWidget(SelectionHandles oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.interactor, widget.interactor)) {
      oldWidget.interactor.removeListener(_scheduleRecompute);
      widget.interactor.addListener(_scheduleRecompute);
    }
  }

  @override
  void dispose() {
    widget.interactor.removeListener(_scheduleRecompute);
    super.dispose();
  }

  /// Recompute the anchor rects post-frame (after layout has settled), then
  /// rebuild from the cached values. Coalesced so a burst of notifications
  /// (drag move + scroll tick in one frame) recomputes once.
  void _scheduleRecompute() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final start = widget.interactor.handleAnchorRectGlobal(
        SelectionHandleKind.start,
      );
      final end = widget.interactor.handleAnchorRectGlobal(
        SelectionHandleKind.end,
      );
      final caret = widget.interactor.collapsedCaretRectGlobal();
      if (start != _startAnchor || end != _endAnchor || caret != _caretAnchor) {
        setState(() {
          _startAnchor = start;
          _endAnchor = end;
          _caretAnchor = caret;
        });
      }
    });
    // Request the frame the callback rides on, so a notify that dirties nothing
    // (e.g. a drag END) still recomputes promptly instead of waiting for an
    // unrelated frame. No-op mid-frame / during a drag.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) {
    final viewport = widget.viewportRectOf();
    final origin = widget.originOf();
    final controls = _controlsFor(context);
    final interactor = widget.interactor;
    // The collapsed-caret drag-handle is an Android (Material) affordance —
    // iOS/desktop don't show a persistent caret handle. The range handles show
    // on every platform.
    final platform = Theme.of(context).platform;
    final showsCaretHandle =
        platform == TargetPlatform.android ||
        platform == TargetPlatform.fuchsia;
    return Stack(
      children: [
        _handle(
          TextSelectionHandleType.left,
          _startAnchor,
          viewport,
          origin,
          controls,
          (event) => interactor.handleHandlePointerDown(
            event,
            SelectionHandleKind.start,
          ),
        ),
        _handle(
          TextSelectionHandleType.right,
          _endAnchor,
          viewport,
          origin,
          controls,
          (event) => interactor.handleHandlePointerDown(
            event,
            SelectionHandleKind.end,
          ),
        ),
        if (showsCaretHandle)
          _handle(
            TextSelectionHandleType.collapsed,
            _caretAnchor,
            viewport,
            origin,
            controls,
            interactor.handleCaretHandlePointerDown,
          ),
      ],
    );
  }

  Widget _handle(
    TextSelectionHandleType type,
    Rect? anchor,
    Rect? viewport,
    Offset origin,
    TextSelectionControls controls,
    void Function(PointerDownEvent) onPointerDown,
  ) {
    // Touch chrome only: a mouse drag-select shows no handles (arch 1248).
    // Viewport predicate (global coords): hide unless laid out AND the anchor
    // intersects the visible bounds.
    if (!widget.interactor.touchSelectionActive ||
        anchor == null ||
        viewport == null ||
        !viewport.overlaps(anchor)) {
      return const SizedBox.shrink();
    }
    return _SelectionHandle(
      type: type,
      anchorRect: anchor,
      origin: origin,
      controls: controls,
      onPointerDown: onPointerDown,
    );
  }
}

/// A single positioned native handle plus its padded, opaque touch target.
class _SelectionHandle extends StatelessWidget {
  const _SelectionHandle({
    required this.type,
    required this.anchorRect,
    required this.origin,
    required this.controls,
    required this.onPointerDown,
  });

  /// The endpoint's (or caret's) rect in GLOBAL coordinates.
  final Rect anchorRect;
  final Offset origin;

  /// left/right for the selection endpoints, collapsed for the caret handle.
  final TextSelectionHandleType type;
  final TextSelectionControls controls;
  final void Function(PointerDownEvent) onPointerDown;

  @override
  Widget build(BuildContext context) {
    final lineHeight = anchorRect.height;
    final size = controls.getHandleSize(lineHeight);
    final handleAnchor = controls.getHandleAnchor(type, lineHeight);
    // The handle attaches at the bottom of its line: the collapsed caret teardrop
    // hangs from the caret's bottom-CENTER, the left/right bulbs from the
    // endpoint's bottom corner. The platform anchor places the glyph's hot-spot
    // there.
    final endpointGlobal = type == TextSelectionHandleType.collapsed
        ? anchorRect.bottomCenter
        : anchorRect.bottomLeft;
    final topLeft = endpointGlobal - handleAnchor - origin;

    // A touch-target-floor region (the native handle expands the same way to
    // kMinInteractiveDimension). The glyph is painted at its true position
    // within the (possibly larger) region.
    final hitWidth = math.max(_kMinTouchTarget, size.width);
    final hitHeight = math.max(_kMinTouchTarget, size.height);
    final hpad = (hitWidth - size.width) / 2;
    // The COLLAPSED caret handle must NOT extend up into the text line — it hangs
    // below the caret, and the line above it stays tappable (tap the caret to
    // re-place it or summon its menu). So all its vertical slack goes downward
    // (top inset 0). The left/right selection bulbs centre on the glyph as
    // before (no caret-tap conflict on a range).
    final vpad = (hitHeight - size.height) / 2;
    final topInset = type == TextSelectionHandleType.collapsed ? 0.0 : vpad;

    return Positioned(
      left: topLeft.dx - hpad,
      top: topLeft.dy - topInset,
      width: hitWidth,
      height: hitHeight,
      // RawGestureDetector mounts an EagerGestureRecognizer so a pointer-down on
      // the handle wins the gesture arena outright — no ancestor scrollable or
      // TabBarView can snipe the drag (see class doc, G11). Opaque so the down
      // also never reaches anything below in the hit-test path.
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: <Type, GestureRecognizerFactory>{
          EagerGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
                () => EagerGestureRecognizer(supportedDevices: _kHandleDevices),
                (instance) {},
              ),
        },
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: onPointerDown,
          // No move/up handlers: the interactor owns the pointer route from the
          // down, so move/up arrive there even after this widget unmounts (G11).
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: hpad,
                top: topInset,
                child: SizedBox.fromSize(
                  size: size,
                  child: controls.buildHandle(context, type, lineHeight),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
