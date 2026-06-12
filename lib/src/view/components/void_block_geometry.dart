import 'package:flutter/widgets.dart';

import '../block_geometry_mixins.dart';
import '../block_layout_registry.dart';

/// Implements the [BlockGeometry] contract for void blocks (image, divider)
/// over the component's own render box.
///
/// **Midpoint hit rule (G5, direction-symmetric):** a point in the top half
/// of the box resolves to offset `0` (upstream), the bottom half to `1`
/// (downstream) — the vertical adaptation of super_editor's
/// upstream/downstream position resolution. A fixed always-downstream rule
/// would exclude an image swept by an upward drag from the selection.
///
/// Apply together with the registration mixin:
/// `with BlockGeometryRegistration, VoidBlockGeometry`.
mixin VoidBlockGeometry<T extends StatefulWidget>
    on BlockGeometryRegistration<T> {
  RenderBox? get _box {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;
    return renderObject;
  }

  @override
  Rect? rectForOffset(int offset) {
    final box = _box;
    if (box == null) return null;
    // Edge rects: upstream = leading edge, downstream = trailing edge.
    return offset <= 0
        ? Rect.fromLTWH(0, 0, 1, box.size.height)
        : Rect.fromLTWH(box.size.width - 1, 0, 1, box.size.height);
  }

  @override
  List<Rect> rectsForRange(int start, int end) {
    final box = _box;
    if (box == null) return const [];
    // The void is selected when its [0,1) lies inside the range — the
    // highlight is the whole box.
    return start <= 0 && end >= 1 ? [Offset.zero & box.size] : const [];
  }

  @override
  int offsetForLocalPoint(Offset point) {
    final box = _box;
    if (box == null) return 0;
    return point.dy < box.size.height / 2 ? 0 : 1;
  }

  @override
  TextRange wordBoundaryAt(int offset) => const TextRange(start: 0, end: 1);

  @override
  RenderBox get renderBox => context.findRenderObject()! as RenderBox;
}

/// The atomic-selection affordance for void blocks: a tint + border overlay
/// when the block's `[0,1)` is the selection (D3 — Notion behavior). The
/// full range-highlight pass (voids swept inside drags) is day-10 work.
class VoidSelectionTint extends StatelessWidget {
  const VoidSelectionTint({
    super.key,
    required this.isSelected,
    required this.child,
  });

  final bool isSelected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!isSelected) return child;
    return Container(
      foregroundDecoration: BoxDecoration(
        color: const Color(0x332196F3),
        border: Border.all(color: const Color(0xFF2196F3), width: 1.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: child,
    );
  }
}
