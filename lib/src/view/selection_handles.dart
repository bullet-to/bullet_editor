import 'package:flutter/widgets.dart';

import 'touch_interactor.dart';

/// Feel-tunable visual constants for the selection handle bulbs. Device-feel
/// (exact dimensions, color) is verified on-device later; these are sensible
/// defaults marked tunable, not final values.
const double _kBulbDiameter = 12.0;
const double _kStemWidth = 2.0;
const Color _kHandleColor = Color(0xFF2196F3);

/// The two text-selection handles (architecture §Gestures): one bulb per
/// endpoint, positioned from `geometryOf(blockId)?.rectForOffset(...)` via the
/// interactor's `handleAnchorRectGlobal`.
///
/// **Visibility is a viewport predicate, not a layout predicate** (arch
/// 1377-1386): a handle shows iff its anchor rect exists AND intersects the
/// scroll viewport's visible bounds. This overlay paints in the app Overlay,
/// which the viewport does NOT clip, so a handle keyed only to "laid out" would
/// draw over the app bar as its anchor scrolls past the edge (the sliver's
/// cacheExtent keeps it laid out beyond the visible viewport). [viewportRectOf]
/// supplies the visible bounds.
///
/// **G11 pointer-down exclusivity**: each bulb's `Listener` is
/// `HitTestBehavior.opaque` over its whole hit region so a pointer that goes
/// down on a handle never seeds the scrollable. **G11 drag continuity**: the
/// down only *starts* the drag in the interactor (which owns the pointer route);
/// the handle never owns the active gesture, so it may unmount mid-drag.
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
    return Stack(
      children: [
        _handle(SelectionHandleKind.start, _startAnchor, viewport, origin),
        _handle(SelectionHandleKind.end, _endAnchor, viewport, origin),
      ],
    );
  }

  Widget _handle(
    SelectionHandleKind kind,
    Rect? anchor,
    Rect? viewport,
    Offset origin,
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
      // Convert the global anchor to this Stack's local space.
      anchorRect: anchor.shift(-origin),
      interactor: widget.interactor,
    );
  }
}

/// A single positioned handle: a stem at the text edge + a draggable bulb. The
/// start handle's bulb hangs above the line, the end handle's below — the iOS
/// convention, and the full-line-height hang the grab-offset compensation is
/// calibrated against.
class _SelectionHandle extends StatelessWidget {
  const _SelectionHandle({
    required this.kind,
    required this.anchorRect,
    required this.interactor,
  });

  final SelectionHandleKind kind;
  final Rect anchorRect;
  final TouchInteractor interactor;

  @override
  Widget build(BuildContext context) {
    final isStart = kind == SelectionHandleKind.start;
    final stemHeight = anchorRect.height;
    final bulbTop = isStart ? anchorRect.top - _kBulbDiameter : anchorRect.top;
    final left = anchorRect.left - _kBulbDiameter / 2 + _kStemWidth / 2;

    return Positioned(
      left: left,
      top: bulbTop,
      child: Listener(
        // G11 pointer-down exclusivity: opaque over the whole hit region so a
        // pointer down here never appears in the viewport's hit-test path.
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) =>
            interactor.handleHandlePointerDown(event, kind),
        // No move/up handlers: the interactor owns the pointer route from the
        // down, so move/up arrive there even after this widget unmounts (G11).
        child: SizedBox(
          width: _kBulbDiameter,
          height: stemHeight + _kBulbDiameter,
          child: CustomPaint(
            painter: _HandlePainter(isStart: isStart, stemHeight: stemHeight),
          ),
        ),
      ),
    );
  }
}

class _HandlePainter extends CustomPainter {
  _HandlePainter({required this.isStart, required this.stemHeight});

  final bool isStart;
  final double stemHeight;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = _kHandleColor;
    final centerX = size.width / 2;
    final radius = _kBulbDiameter / 2;
    if (isStart) {
      // Bulb on top, stem descending to the text line.
      canvas.drawCircle(Offset(centerX, radius), radius, paint);
      canvas.drawRect(
        Rect.fromLTWH(centerX - _kStemWidth / 2, radius, _kStemWidth, stemHeight),
        paint,
      );
    } else {
      // Stem from the text line down to the bulb at the bottom.
      canvas.drawRect(
        Rect.fromLTWH(centerX - _kStemWidth / 2, 0, _kStemWidth, stemHeight),
        paint,
      );
      canvas.drawCircle(Offset(centerX, stemHeight + radius), radius, paint);
    }
  }

  @override
  bool shouldRepaint(_HandlePainter oldDelegate) =>
      oldDelegate.isStart != isStart || oldDelegate.stemHeight != stemHeight;
}
