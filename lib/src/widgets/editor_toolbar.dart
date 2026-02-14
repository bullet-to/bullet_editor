import 'package:flutter/material.dart';

import '../editor/editor_controller.dart';

/// A toolbar that provides block type selection and inline style toggles.
///
/// [B] is the block type key, [S] is the inline style key.
///
/// Connects to an [EditorController] via [ListenableBuilder] so it
/// rebuilds automatically when the cursor/selection changes.
class EditorToolbar<B extends Object, S extends Object> extends StatelessWidget {
  const EditorToolbar({
    super.key,
    required this.controller,
    this.blockTypeSelector,
    this.styleButtons = const [],
    this.extraActions = const [],
    this.padding,
    this.decoration,
  });

  final EditorController<B, S> controller;

  /// The block type selector dropdown (or custom widget).
  /// If null, no block type selector is shown.
  final Widget? blockTypeSelector;

  /// Inline style toggle buttons.
  final List<StyleToggleButton<B, S>> styleButtons;

  /// Additional action widgets (divider insert, undo/redo, etc.).
  final List<Widget> extraActions;

  /// Padding around the toolbar content.
  final EdgeInsetsGeometry? padding;

  /// Optional decoration for the toolbar container.
  final BoxDecoration? decoration;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Container(
          decoration: decoration,
          padding: padding ?? const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              if (blockTypeSelector != null) ...[
                blockTypeSelector!,
                const SizedBox(width: 8),
              ],
              ...styleButtons.map((btn) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: btn,
              )),
              if (extraActions.isNotEmpty) ...[
                const SizedBox(width: 8),
                ...extraActions.map((a) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: a,
                )),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// A toggle button for an inline style.
///
/// Highlights when the style is active at the cursor/selection.
class StyleToggleButton<B extends Object, S extends Object> extends StatelessWidget {
  const StyleToggleButton({
    super.key,
    required this.controller,
    required this.style,
    required this.icon,
    this.tooltip,
  });

  final EditorController<B, S> controller;
  final S style;
  final IconData icon;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final isActive = controller.activeStyles.contains(style);
    final theme = Theme.of(context);
    final color = isActive
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface.withValues(alpha: 0.6);

    return IconButton(
      icon: Icon(icon, color: color, size: 20),
      tooltip: tooltip ?? '$style',
      onPressed: () => controller.toggleStyle(style),
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      padding: EdgeInsets.zero,
    );
  }
}

/// A dropdown for selecting block types.
///
/// [B] is the block type key.
class BlockTypeSelector<B extends Object, S extends Object> extends StatelessWidget {
  const BlockTypeSelector({
    super.key,
    required this.controller,
    required this.items,
  });

  final EditorController<B, S> controller;

  /// The block types to show in the dropdown, with display labels.
  final List<BlockTypeSelectorItem<B>> items;

  @override
  Widget build(BuildContext context) {
    final current = controller.currentBlockType;
    final theme = Theme.of(context);

    return DropdownButton<B>(
      value: items.any((i) => i.type == current) ? current : items.first.type,
      items: items.map((item) {
        return DropdownMenuItem(
          value: item.type,
          enabled: controller.canSetBlockType(item.type),
          child: Text(
            item.label,
            style: TextStyle(
              fontSize: 14,
              color: controller.canSetBlockType(item.type)
                  ? null
                  : theme.colorScheme.onSurface.withValues(alpha: 0.3),
            ),
          ),
        );
      }).toList(),
      onChanged: (type) {
        if (type != null) controller.setBlockType(type);
      },
      underline: const SizedBox.shrink(),
      isDense: true,
    );
  }
}

/// An item in the [BlockTypeSelector] dropdown.
class BlockTypeSelectorItem<B> {
  const BlockTypeSelectorItem({required this.type, required this.label});

  final B type;
  final String label;
}
