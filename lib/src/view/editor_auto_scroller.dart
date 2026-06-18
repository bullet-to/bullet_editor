import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// The edge-zone autoscroll ticker shared by every drag-driven interactor
/// (architecture §Gestures G5: "the hit-test helper and post-frame autoscroll
/// ticker are shared"). A drag near a viewport edge scrolls the content under
/// the stationary pointer, and on every committed scroll the interactor
/// re-hit-tests the extent post-frame — so the same machinery serves the mouse
/// press-drag, the touch long-press-drag, and the handle drag (D7: one
/// implementation, never copy-pasted into each interactor).
///
/// Owns no selection state and no hit-testing: it computes velocity from the
/// pointer's penetration into the edge zone, drives [scrollPositionOf] via
/// `jumpTo`, and reports nothing back. The interactor wires its re-hit-test to
/// the editor's `ScrollNotification` listener (the same notification `jumpTo`
/// dispatches), so the post-frame extent update lives entirely interactor-side
/// — this class is purely the velocity/tick engine.
class EditorAutoScroller {
  EditorAutoScroller({
    required this.scrollPositionOf,
    required this.viewportRectOf,
    required this.isActive,
  });

  /// The editor's scroll position, or null before the viewport is laid out.
  final ScrollPosition? Function() scrollPositionOf;

  /// The editor viewport's global rect, for the edge-zone test.
  final Rect? Function() viewportRectOf;

  /// Whether the owning drag is still live — the tick stops the instant the
  /// drag ends even if a frame callback was already scheduled.
  final bool Function() isActive;

  /// Distance from a viewport edge within which a drag autoscrolls.
  static const _edgeZone = 50.0;

  /// Peak autoscroll speed in **pixels per second** (reached when the pointer
  /// is a full [_edgeZone] past the viewport edge). A per-second rate, not a
  /// per-frame step, so the physical scroll speed is identical at 60Hz and
  /// 120Hz and doesn't stutter when frame delivery is uneven — the tick scales
  /// it by real elapsed time (manual-test B5: fixed-per-frame steps jittered
  /// under ProMotion's variable refresh). Calibrated to the framework's own
  /// select-to-scroll feel (~600 px/s: `EdgeDraggingAutoScroller` advances up to
  /// `overDragMax`=20px per ~33ms step) — 1800 read as runaway-fast on device
  /// (device finding). The ramp keeps it gentle near the boundary. Feel-tunable;
  /// identical for mouse and touch (the edge-zone behavior is the same gesture).
  static const _autoScrollMaxVelocity = 600.0;

  // Velocity is in pixels/second (signed); the tick scales it by the real
  // interval since [_lastTick] so speed is frame-rate independent.
  double _velocity = 0;
  bool _scheduled = false;
  Duration? _lastTick;

  /// Updates the autoscroll velocity from [globalPointer] (the compensated
  /// finger point for handle/touch drags) and schedules ticks while the
  /// pointer sits in a viewport edge zone. A no-op when no viewport is laid
  /// out. Call from the drag's pointer-move.
  void update(Offset globalPointer) {
    final viewport = viewportRectOf();
    if (viewport == null) {
      _velocity = 0;
      return;
    }
    final previousVelocity = _velocity;
    final topZone = viewport.top + _edgeZone;
    final bottomZone = viewport.bottom - _edgeZone;
    // Velocity RAMPS with how far the pointer has penetrated the edge zone
    // (0 at the boundary, full speed a zone-width past the edge) rather than
    // snapping between 0 and a fixed step. A binary on/off velocity stutters
    // when the pointer hovers near the boundary — every micro-movement flips
    // it (manual-test B5). The ramp eases that to zero instead.
    if (globalPointer.dy < topZone) {
      final depth = ((topZone - globalPointer.dy) / _edgeZone).clamp(0.0, 1.0);
      _velocity = -_autoScrollMaxVelocity * depth;
    } else if (globalPointer.dy > bottomZone) {
      final depth = ((globalPointer.dy - bottomZone) / _edgeZone).clamp(
        0.0,
        1.0,
      );
      _velocity = _autoScrollMaxVelocity * depth;
    } else {
      _velocity = 0;
      return;
    }
    if (previousVelocity == 0) {
      _lastTick = null; // fresh interval baseline for the first tick
    }
    if (!_scheduled) {
      _scheduled = true;
      SchedulerBinding.instance.scheduleFrameCallback(_tick);
      SchedulerBinding.instance.scheduleFrame();
    }
  }

  /// Stops the ticker (drag end/cancel) — the velocity zeroes so an in-flight
  /// frame callback no-ops, and the interval baseline resets for the next run.
  void stop() {
    _velocity = 0;
    _lastTick = null;
  }

  void _tick(Duration timeStamp) {
    _scheduled = false;
    if (!isActive() || _velocity == 0) {
      _lastTick = null;
      return;
    }
    final position = scrollPositionOf();
    if (position == null) return;

    // Scale the per-second velocity by the REAL interval since the last tick,
    // so physical scroll speed is identical regardless of refresh rate and
    // doesn't jitter when frames land at uneven intervals. The first tick of a
    // run (null baseline) assumes a nominal 60Hz frame so it still advances.
    final last = _lastTick;
    _lastTick = timeStamp;
    final dtSeconds = last == null
        ? 1 / 60
        : (timeStamp - last).inMicroseconds / Duration.microsecondsPerSecond;
    final target = (position.pixels + _velocity * dtSeconds).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    // jumpTo dispatches a ScrollNotification; the editor's listener routes it
    // back to the interactor's onScroll, which re-hit-tests the extent under
    // the stationary (compensated) pointer post-frame. No extent update here —
    // one path.
    if (target != position.pixels) position.jumpTo(target);
    // Keep ticking while the pointer stays in the edge zone.
    _scheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback(_tick);
    SchedulerBinding.instance.scheduleFrame();
  }
}
