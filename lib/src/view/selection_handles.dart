import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show cupertinoTextSelectionControls;
import 'package:flutter/material.dart';

import 'touch_interactor.dart';

/// Touch target floor for a handle — the platform handle glyph is small (~22px
/// for Material), so we pad the interactive region out to this so a finger
/// reliably grabs it (and, critically, the opaque Listener over that region
/// stops the pointer reaching the scrollable beneath — device finding: a 22px
/// hit region let a near-miss fall through and scroll the list mid-grab). Native
/// `TextSelectionOverlay` expands handles to the same `kMinInteractiveDimension`.
const double _kMinTouchTarget = 48.0;

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
/// **G11 pointer-down exclusivity**: the interactive region's `Listener` is
/// `HitTestBehavior.opaque` over a full [_kMinTouchTarget] so a pointer that
/// goes down on (or near) a handle never seeds the scrollable. **G11 drag
/// continuity**: the down only *starts* the drag in the interactor (which owns
/// the pointer route); the handle never owns the active gesture, so it may
/// unmount mid-drag.
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
      if (start != _startAnchor || end != _endAnchor) {
        setState(() {
          _startAnchor = start;
          _endAnchor = end;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final viewport = widget.viewportRectOf();
    final origin = widget.originOf();
    final controls = _controlsFor(context);
    return Stack(
      children: [
        _handle(
          SelectionHandleKind.start,
          _startAnchor,
          viewport,
          origin,
          controls,
        ),
        _handle(
          SelectionHandleKind.end,
          _endAnchor,
          viewport,
          origin,
          controls,
        ),
      ],
    );
  }

  Widget _handle(
    SelectionHandleKind kind,
    Rect? anchor,
    Rect? viewport,
    Offset origin,
    TextSelectionControls controls,
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
      kind: kind,
      anchorRect: anchor,
      origin: origin,
      controls: controls,
      interactor: widget.interactor,
    );
  }
}

/// A single positioned native handle plus its padded, opaque touch target.
class _SelectionHandle extends StatelessWidget {
  const _SelectionHandle({
    required this.kind,
    required this.anchorRect,
    required this.origin,
    required this.controls,
    required this.interactor,
  });

  /// The endpoint's caret rect in GLOBAL coordinates.
  final Rect anchorRect;
  final Offset origin;
  final SelectionHandleKind kind;
  final TextSelectionControls controls;
  final TouchInteractor interactor;

  @override
  Widget build(BuildContext context) {
    // Start endpoint → left handle, end → right (LTR; RTL flip is a follow-up).
    final type = kind == SelectionHandleKind.start
        ? TextSelectionHandleType.left
        : TextSelectionHandleType.right;
    final lineHeight = anchorRect.height;
    final size = controls.getHandleSize(lineHeight);
    final handleAnchor = controls.getHandleAnchor(type, lineHeight);
    // Both handles attach at the bottom of the endpoint's line; the platform
    // anchor places the glyph's hot-spot there.
    final endpointGlobal = anchorRect.bottomLeft;
    final topLeft = endpointGlobal - handleAnchor - origin;

    // The interactive region is deliberately generous, and extends UPWARD a
    // full line: a finger aiming at a handle naturally lands on the selection
    // CORNER (where the teardrop attaches to the text), a line above the glyph
    // that hangs below. A region hugging only the glyph let that aim miss and
    // fall through to the list, which then scrolled (device finding). It is
    // opaque over the whole region so the pointer never seeds the scrollable
    // (G11). Width is the touch-target floor centered on the glyph; height runs
    // from the line top, through the glyph, to the floor below it.
    final hitWidth = math.max(_kMinTouchTarget, size.width);
    final hpad = (hitWidth - size.width) / 2;
    final upPad = lineHeight;
    final downPad = math.max(0.0, _kMinTouchTarget - size.height);
    final hitHeight = upPad + size.height + downPad;

    return Positioned(
      left: topLeft.dx - hpad,
      top: topLeft.dy - upPad,
      width: hitWidth,
      height: hitHeight,
      child: Listener(
        // G11 pointer-down exclusivity: opaque over the whole region so a
        // pointer down here never appears in the viewport's hit-test path.
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) =>
            interactor.handleHandlePointerDown(event, kind),
        // No move/up handlers: the interactor owns the pointer route from the
        // down, so move/up arrive there even after this widget unmounts (G11).
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // The glyph painted at its true position within the larger region.
            Positioned(
              left: hpad,
              top: upPad,
              child: SizedBox.fromSize(
                size: size,
                child: controls.buildHandle(context, type, lineHeight),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
