import 'package:flutter/widgets.dart';

import 'touch_interactor.dart';

/// Feel-tunable loupe constants. Magnifier feel (size, magnification, the hang
/// above the finger) is device-verified later; these are sensible defaults.
const Size _kMagnifierSize = Size(80, 48);
const double _kMagnification = 1.25;

/// Vertical offset of the loupe ABOVE the focal point so the finger doesn't
/// occlude what's being magnified (native behavior). Feel-tunable.
const double _kVerticalHang = 56.0;

/// The selection loupe (architecture §Gestures: a [RawMagnifier] following the
/// COMPENSATED finger point during long-press-drag and handle-drag). Reads the
/// focal point from the [interactor] (`dragFocalPoint` — already grab-offset
/// compensated for handle drags), so it survives the extent block leaving the
/// viewport (G11).
///
/// Shows iff a selection drag is live; hides on drag end. Pure visual loupe
/// rendering is device-feel and not widget-tested headlessly (the focal-point
/// tracking that drives it IS tested via the interactor) — see the touch test.
class SelectionMagnifier extends StatelessWidget {
  const SelectionMagnifier({
    super.key,
    required this.interactor,
    required this.originOf,
  });

  final TouchInteractor interactor;

  /// The overlay Stack's global top-left — the global focal point is converted
  /// to Stack-local by subtracting this.
  final Offset Function() originOf;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: interactor,
      builder: (context, _) {
        final globalFocal = interactor.dragFocalPoint;
        if (globalFocal == null) return const SizedBox.shrink();
        // RawMagnifier magnifies the layer beneath it at its absolute screen
        // position, so its focal point stays in GLOBAL space; only the widget's
        // Positioned placement is converted to this Stack's local space.
        final focal = globalFocal - originOf();
        // Center the loupe horizontally over the focal point, hung above it.
        final left = focal.dx - _kMagnifierSize.width / 2;
        final top = focal.dy - _kVerticalHang - _kMagnifierSize.height;
        // A Stack so the Positioned has a Stack parent (this widget is placed
        // in a Positioned.fill by the editor).
        return Stack(
          children: [
            Positioned(
              left: left,
              top: top,
              child: RawMagnifier(
                size: _kMagnifierSize,
                magnificationScale: _kMagnification,
                // The magnifier's focal point is the (compensated) finger
                // point, expressed relative to the magnifier's own top-left.
                focalPointOffset: Offset(
                  _kMagnifierSize.width / 2,
                  _kVerticalHang + _kMagnifierSize.height,
                ),
                decoration: const MagnifierDecoration(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(8)),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
