import 'package:flutter/widgets.dart';

import 'block_layout_registry.dart';

/// Inherited access to the editor's per-view services. Components reach the
/// [BlockLayoutRegistry] through this; the day 3–4 controller skeleton adds
/// the controller reference.
class EditorViewScope extends InheritedWidget {
  const EditorViewScope({
    super.key,
    required this.registry,
    required super.child,
  });

  final BlockLayoutRegistry registry;

  static EditorViewScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<EditorViewScope>();

  static EditorViewScope of(BuildContext context) => maybeOf(context)!;

  @override
  bool updateShouldNotify(EditorViewScope oldWidget) =>
      !identical(registry, oldWidget.registry);
}
