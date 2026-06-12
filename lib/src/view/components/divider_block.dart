import 'package:flutter/widgets.dart';

import '../block_component_context.dart';
import '../block_geometry_mixins.dart';
import 'void_block_geometry.dart';

/// Component for the void divider block: a thin horizontal rule.
///
/// Registers [VoidBlockGeometry] (midpoint hit rule) and tints itself when
/// atomically selected.
class DividerBlockComponent extends StatefulWidget {
  const DividerBlockComponent(this.componentContext, {super.key, this.color});

  final BlockComponentContext componentContext;

  /// Override color; defaults to the resolved text color at 20% opacity.
  final Color? color;

  @override
  State<DividerBlockComponent> createState() => _DividerBlockComponentState();
}

class _DividerBlockComponentState extends State<DividerBlockComponent>
    with BlockGeometryRegistration, VoidBlockGeometry {
  @override
  String get geometryBlockId => widget.componentContext.block.id;

  @override
  Widget build(BuildContext context) {
    final isSelected = widget.componentContext.isSelected;
    final resolved = isSelected
        ? const Color(0xFF2196F3)
        : widget.color ??
              (widget.componentContext.resolvedStyle.color ??
                      const Color(0xFF000000))
                  .withValues(alpha: 0.2);
    // Major vertical breathing room comes from the def's spacingBefore/After
    // policy; the band around the 1px rule gives the midpoint hit rule a
    // real target and makes the selection tint visible (checkpoint-2
    // finding: a 1px tint was imperceptible).
    return VoidSelectionTint(
      isSelected: isSelected,
      child: SizedBox(
        width: double.infinity,
        height: 9,
        child: Center(
          child: Container(
            width: double.infinity,
            height: isSelected ? 2 : 1,
            color: resolved,
          ),
        ),
      ),
    );
  }
}
