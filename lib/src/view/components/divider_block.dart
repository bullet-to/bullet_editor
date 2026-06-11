import 'package:flutter/widgets.dart';

import '../block_component_context.dart';

/// Component for the void divider block: a thin horizontal rule.
class DividerBlockComponent extends StatelessWidget {
  const DividerBlockComponent(this.context_, {super.key, this.color});

  final BlockComponentContext context_;

  /// Override color; defaults to the resolved text color at 20% opacity.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolved =
        color ??
        (context_.resolvedStyle.color ?? const Color(0xFF000000)).withValues(
          alpha: 0.2,
        );
    return Container(
      width: double.infinity,
      height: 1,
      margin: const EdgeInsets.symmetric(vertical: 8),
      color: resolved,
    );
  }
}
