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
    final resolved =
        widget.color ??
        (widget.componentContext.resolvedStyle.color ?? const Color(0xFF000000))
            .withValues(alpha: 0.2);
    // Vertical breathing room comes from the def's spacingBefore/After
    // policy, not the component. A few px of tappable height around the
    // 1px rule comes from the selection tint container.
    return VoidSelectionTint(
      isSelected: widget.componentContext.isSelected,
      child: Container(width: double.infinity, height: 1, color: resolved),
    );
  }
}
