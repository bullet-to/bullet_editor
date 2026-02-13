import 'package:flutter/material.dart';

import '../editor/editor_controller.dart';
import '../model/block.dart';
import '../model/inline_style.dart';
import '../schema/editor_schema.dart';

/// A single toggle button for an inline style.
///
/// Highlights when the style is active at the cursor. Tapping calls
/// [EditorController.toggleStyle]. Use this to build custom toolbars.
class StyleToggleButton extends StatelessWidget {
  const StyleToggleButton({
    required this.controller,
    required this.style,
    required this.icon,
    this.tooltip,
    this.editorFocusNode,
    super.key,
  });

  final EditorController controller;
  final InlineStyle style;
  final IconData icon;
  final String? tooltip;
  final FocusNode? editorFocusNode;

  @override
  Widget build(BuildContext context) {
    final isActive = controller.activeStyles.contains(style);
    return IconButton(
      icon: Icon(icon),
      tooltip: tooltip ?? style.name,
      isSelected: isActive,
      style: IconButton.styleFrom(
        backgroundColor: isActive
            ? Theme.of(context).colorScheme.primaryContainer
            : null,
        splashFactory: NoSplash.splashFactory,
      ),
      onPressed: () {
        controller.toggleStyle(style);
        editorFocusNode?.requestFocus();
      },
    );
  }
}

/// A dropdown for picking the block type at the cursor.
///
/// Labels and available types come from the [EditorSchema], so adding new
/// block types to the schema automatically populates the dropdown.
///
/// Reads [EditorController.currentBlockType] and calls
/// [EditorController.setBlockType] on change. Use this to build custom toolbars.
class BlockTypeSelector extends StatelessWidget {
  const BlockTypeSelector({required this.controller, super.key});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final schema = controller.schema;
    // Exclude void blocks (e.g. divider) — they aren't selectable from the dropdown.
    final entries = schema.blocks.entries
        .where((e) => !e.value.isVoid)
        .toList();

    // If cursor is on a void block, the value won't match any item.
    // Fall back to null to avoid assertion errors.
    final currentType = controller.currentBlockType;
    final hasValue = entries.any((e) => e.key == currentType);

    return DropdownButton<Object>(
      value: hasValue ? currentType : null,
      hint: const Text('—', style: TextStyle(fontSize: 13)),
      underline: const SizedBox.shrink(),
      isDense: true,
      items: entries.map((entry) {
        final canSet = entry.key is BlockType &&
            controller.canSetBlockType(entry.key as BlockType);
        return DropdownMenuItem<Object>(
          value: entry.key,
          enabled: canSet,
          child: Text(
            entry.value.label,
            style: TextStyle(
              fontSize: 13,
              color: canSet ? null : const Color(0xFFAAAAAA),
            ),
          ),
        );
      }).toList(),
      onChanged: (key) {
        if (key is BlockType) controller.setBlockType(key);
      },
    );
  }
}

/// Pre-composed toolbar with inline style toggles, block type selector,
/// and undo/redo buttons.
///
/// This is a convenience widget. For custom toolbars, use [StyleToggleButton],
/// [BlockTypeSelector], and the controller methods directly.
///
/// Pass [editorFocusNode] so the toolbar can restore focus to the TextField
/// after button taps (prevents IME reconnection delay on macOS).
class EditorToolbar extends StatelessWidget {
  const EditorToolbar({
    required this.controller,
    this.editorFocusNode,
    super.key,
  });

  final EditorController controller;
  final FocusNode? editorFocusNode;

  void _action(VoidCallback fn) {
    fn();
    editorFocusNode?.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        // Prevent toolbar buttons from stealing focus from the TextField.
        return FocusScope(
          canRequestFocus: false,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Row(
              children: [
                // Block type selector.
                BlockTypeSelector(controller: controller),
                const VerticalDivider(width: 16, indent: 8, endIndent: 8),

                // Inline style toggles.
                StyleToggleButton(
                  controller: controller,
                  style: InlineStyle.bold,
                  icon: Icons.format_bold,
                  tooltip: 'Bold (Cmd+B)',
                  editorFocusNode: editorFocusNode,
                ),
                StyleToggleButton(
                  controller: controller,
                  style: InlineStyle.italic,
                  icon: Icons.format_italic,
                  tooltip: 'Italic (Cmd+I)',
                  editorFocusNode: editorFocusNode,
                ),
                StyleToggleButton(
                  controller: controller,
                  style: InlineStyle.strikethrough,
                  icon: Icons.format_strikethrough,
                  tooltip: 'Strikethrough',
                  editorFocusNode: editorFocusNode,
                ),
                const VerticalDivider(width: 16, indent: 8, endIndent: 8),

                // Divider insert.
                IconButton(
                  icon: const Icon(Icons.horizontal_rule),
                  tooltip: 'Insert divider (---)',
                  style: IconButton.styleFrom(
                    splashFactory: NoSplash.splashFactory,
                  ),
                  onPressed: controller.canInsertDivider
                      ? () => _action(() => controller.insertDivider())
                      : null,
                ),

                // Task toggle.
                if (controller.currentBlockType == BlockType.taskItem)
                  IconButton(
                    icon: Icon(
                      controller.isTaskChecked
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                    ),
                    tooltip: 'Toggle checked',
                    style: IconButton.styleFrom(
                      splashFactory: NoSplash.splashFactory,
                    ),
                    onPressed: () =>
                        _action(() => controller.toggleTaskChecked()),
                  ),
                const VerticalDivider(width: 16, indent: 8, endIndent: 8),

                // Indent / outdent.
                IconButton(
                  icon: const Icon(Icons.format_indent_decrease),
                  tooltip: 'Outdent (Shift+Tab)',
                  style: IconButton.styleFrom(
                    splashFactory: NoSplash.splashFactory,
                  ),
                  onPressed: controller.canOutdent
                      ? () => _action(() => controller.outdent())
                      : null,
                ),
                IconButton(
                  icon: const Icon(Icons.format_indent_increase),
                  tooltip: 'Indent (Tab)',
                  style: IconButton.styleFrom(
                    splashFactory: NoSplash.splashFactory,
                  ),
                  onPressed: controller.canIndent
                      ? () => _action(() => controller.indent())
                      : null,
                ),
                const VerticalDivider(width: 16, indent: 8, endIndent: 8),

                // Undo / redo.
                IconButton(
                  icon: const Icon(Icons.undo),
                  tooltip: 'Undo (Cmd+Z)',
                  splashRadius: 1,
                  onPressed: controller.canUndo
                      ? () => _action(() => controller.undo())
                      : null,
                ),
                IconButton(
                  icon: const Icon(Icons.redo),
                  tooltip: 'Redo (Cmd+Shift+Z)',
                  splashRadius: 1,
                  onPressed: controller.canRedo
                      ? () => _action(() => controller.redo())
                      : null,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
