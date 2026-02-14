import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../codec/markdown_codec.dart';
import '../editor/editor_controller.dart';

/// The main editor widget.
///
/// Wraps a [TextField] with a [EditorController], linking the document model
/// to Flutter's text input system.
///
/// [B] is the block type key, [S] is the inline style key.
class BulletEditor<B extends Object, S extends Object> extends StatefulWidget {
  const BulletEditor({
    super.key,
    required this.controller,
    this.focusNode,
    this.decoration,
    this.style,
    this.maxLines,
    this.minLines,
    this.readOnly = false,
    this.autofocus = false,
    this.expands = false,
  });

  final EditorController<B, S> controller;
  final FocusNode? focusNode;

  /// Optional decoration for the TextField.
  ///
  /// Defaults to a minimal style with no border — just a subtle hint text.
  /// To restore the Flutter default, pass `const InputDecoration()`.
  final InputDecoration? decoration;
  final TextStyle? style;
  final int? maxLines;
  final int? minLines;
  final bool readOnly;
  final bool autofocus;
  final bool expands;

  @override
  State<BulletEditor<B, S>> createState() => _BulletEditorState<B, S>();
}

class _BulletEditorState<B extends Object, S extends Object>
    extends State<BulletEditor<B, S>> {
  late final UndoHistoryController _undoHistoryController;

  @override
  void initState() {
    super.initState();
    _undoHistoryController = UndoHistoryController(value: null);
  }

  @override
  void dispose() {
    _undoHistoryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Derive base style from the host app's TextTheme.bodyLarge with a sane
    // fallback if none is set.
    final base = widget.style ??
        theme.textTheme.bodyLarge ??
        TextStyle(
          fontSize: 16,
          height: 1.8,
          leadingDistribution: TextLeadingDistribution.even,
          color: theme.colorScheme.onSurface,
        );

    // Intercept undo/redo intents so they route to our UndoManager instead of
    // Flutter's built-in UndoHistory (which doesn't know about our document
    // model and would corrupt the display text).
    return Actions(
      actions: {
        UndoTextIntent: CallbackAction<UndoTextIntent>(
          onInvoke: (_) {
            widget.controller.undo();
            return null;
          },
        ),
        RedoTextIntent: CallbackAction<RedoTextIntent>(
          onInvoke: (_) {
            widget.controller.redo();
            return null;
          },
        ),
      },
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.tab, shift: true):
              _OutdentIntent(),
        },
        child: Actions(
          actions: {
            _OutdentIntent: CallbackAction<_OutdentIntent>(
              onInvoke: (_) {
                widget.controller.outdent();
                return null;
              },
            ),
          },
          child: TextField(
        controller: widget.controller,
        focusNode: widget.focusNode,
        // Disable Flutter's built-in undo/redo history.
        undoController: _undoHistoryController,
        style: base,
        maxLines: widget.maxLines,
        minLines: widget.minLines,
        readOnly: widget.readOnly,
        autofocus: widget.autofocus,
        expands: widget.expands,
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        decoration: widget.decoration ??
            InputDecoration(
              border: InputBorder.none,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              hintText: 'Start writing...',
              hintStyle: base.copyWith(
                color: (base.color ?? theme.colorScheme.onSurface)
                    .withValues(alpha: 0.35),
              ),
            ),
        onTap: () {
          final ctrl = widget.controller;
          if (ctrl.onLinkTap != null && ctrl.value.selection.isValid) {
            final url =
                ctrl.linkAtDisplayOffset(ctrl.value.selection.baseOffset);
            if (url != null) {
              ctrl.onLinkTap!(url);
            }
          }
        },
        scrollController: ScrollController(),
      ),
      ),
      ),
    );
  }
}

class _OutdentIntent extends Intent {
  const _OutdentIntent();
}

/// Extension on EditorController for markdown import/export convenience.
extension MarkdownExtension<B extends Object, S extends Object>
    on EditorController<B, S> {
  /// Convenience: get the markdown text for the current document.
  String get markdown {
    final codec = MarkdownCodec(schema: schema);
    return codec.encode(document);
  }
}
