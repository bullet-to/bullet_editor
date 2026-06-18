import 'dart:async';

import 'package:flutter/material.dart';

import 'touch_interactor.dart';

/// The selection loupe, rendered with the platform's NATIVE magnifier — Android
/// [TextMagnifier], iOS [CupertinoTextMagnifier], nothing on desktop — via
/// [TextMagnifier.adaptiveMagnifierConfiguration], the same widget the vanilla
/// `TextField` uses (so it looks and animates exactly like the OS, the way we
/// reuse the platform selection controls for handles and the adaptive toolbar
/// for the context menu).
///
/// It is driven by a [MagnifierController] + a `ValueNotifier<MagnifierInfo>`,
/// mirroring `SelectionOverlay.showMagnifier`: the controller inserts the lens
/// into the ROOT overlay (screen coordinates), which is why the magnifier reads
/// global rects directly and positions itself correctly above the finger. The
/// [MagnifierInfo] carries the drag's finger position and — crucially — the
/// EXTENT's caret rect, so the lens centers on the line being selected rather
/// than on whatever sits below-right of the finger (device finding).
///
/// Shows iff a selection drag is live (the interactor's `dragLoupeRects` is
/// non-null); hides on drag end. This widget renders nothing itself — the lens
/// lives in the overlay — so it stays an empty box in the host Stack.
class SelectionMagnifier extends StatefulWidget {
  const SelectionMagnifier({
    super.key,
    required this.interactor,
    required this.fieldBoundsOf,
  });

  final TouchInteractor interactor;

  /// The editor's global rect — the magnifier clamps its focal point within it
  /// so the lens never shows content outside the editor.
  final Rect? Function() fieldBoundsOf;

  @override
  State<SelectionMagnifier> createState() => _SelectionMagnifierState();
}

class _SelectionMagnifierState extends State<SelectionMagnifier> {
  final MagnifierController _controller = MagnifierController();
  final ValueNotifier<MagnifierInfo> _info = ValueNotifier(MagnifierInfo.empty);
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    widget.interactor.addListener(_schedule);
  }

  @override
  void didUpdateWidget(SelectionMagnifier oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.interactor, widget.interactor)) {
      oldWidget.interactor.removeListener(_schedule);
      widget.interactor.addListener(_schedule);
    }
  }

  @override
  void dispose() {
    widget.interactor.removeListener(_schedule);
    // The controller has no dispose(); hide() removes its overlay entry (after
    // any out-animation). Fire-and-forget — the root overlay outlives us.
    if (_controller.overlayEntry != null) unawaited(_controller.hide());
    _info.dispose();
    super.dispose();
  }

  /// Apply post-frame, coalesced — the interactor can notify mid-build/-layout
  /// (a scroll tick fired during another block's layout), and inserting an
  /// overlay entry or reading `localToGlobal` then would throw. The one-frame
  /// lag matches the handles' (and is below perception for the loupe).
  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      _apply();
    });
    // Request the frame the callback rides on: a notify at DRAG END dirties
    // nothing on its own, so without this the loupe would stay up until some
    // unrelated event produced a frame (device finding). No-op mid-frame.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _apply() {
    final info = _magnifierInfo();
    if (info == null) {
      if (_controller.overlayEntry != null) _controller.hide();
      return;
    }
    _info.value = info;
    if (_controller.overlayEntry != null) return; // already shown; info repositions it
    final built = TextMagnifier.adaptiveMagnifierConfiguration.magnifierBuilder(
      context,
      _controller,
      _info,
    );
    if (built == null) return; // desktop: no magnifier
    _controller.show(context: context, builder: (_) => built);
  }

  /// The current drag's [MagnifierInfo], or null when no drag is live / not
  /// laid out (the magnifier hides).
  MagnifierInfo? _magnifierInfo() {
    final focal = widget.interactor.dragFocalPoint;
    final rects = widget.interactor.dragLoupeRects();
    if (focal == null || rects == null) return null;
    return MagnifierInfo(
      globalGesturePosition: focal,
      caretRect: rects.caret,
      currentLineBoundaries: rects.block,
      fieldBounds: widget.fieldBoundsOf() ?? rects.block,
    );
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
