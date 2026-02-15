import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../codec/markdown_codec.dart';
import '../editor/editor_controller.dart';

/// The main editor widget.
///
/// Wraps a [TextField] with a [EditorController], linking the document model
/// to Flutter's text input system.
///
/// All keyboard shortcuts (bold, italic, soft line break, indent/outdent,
/// undo/redo, copy/cut) are handled internally via [Shortcuts] + [Actions].
/// This avoids issues with `FocusNode.onKeyEvent` being overwritten by
/// Flutter's `EditableText` internals.
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
  late FocusNode _focusNode;
  bool _ownsNode = false;

  @override
  void initState() {
    super.initState();
    _undoHistoryController = UndoHistoryController(value: null);
    _initFocusNode();
  }

  @override
  void didUpdateWidget(covariant BulletEditor<B, S> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != oldWidget.focusNode) {
      _disposeFocusNode();
      _initFocusNode();
    }
  }

  void _initFocusNode() {
    if (widget.focusNode != null) {
      _focusNode = widget.focusNode!;
      _ownsNode = false;
    } else {
      _focusNode = FocusNode();
      _ownsNode = true;
    }
  }

  void _disposeFocusNode() {
    if (_ownsNode) _focusNode.dispose();
  }

  @override
  void dispose() {
    _undoHistoryController.dispose();
    _disposeFocusNode();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base =
        widget.style ??
        theme.textTheme.bodyLarge ??
        TextStyle(
          fontSize: 16,
          height: 1.8,
          leadingDistribution: TextLeadingDistribution.even,
          color: theme.colorScheme.onSurface,
        );

    // Build shortcuts map from schema + built-in editor shortcuts.
    final shortcuts = <ShortcutActivator, Intent>{
      // Shift+Enter → soft line break (newline within block).
      const SingleActivator(LogicalKeyboardKey.enter, shift: true):
          const _SoftBreakIntent(),
    };

    // Add schema-driven inline style shortcuts (e.g. Cmd+B → bold).
    final schema = widget.controller.schema;
    for (final entry in schema.inlineStyles.entries) {
      final shortcut = entry.value.shortcut;
      if (shortcut != null) {
        shortcuts[shortcut] = _ToggleInlineStyleIntent(entry.key);
      }
    }

    // Shortcuts maps key combos → intents. Actions maps intents → handlers.
    // Both sit above the TextField so they intercept events that bubble up
    // from EditableText's Focus node, regardless of host app widget tree.
    return Shortcuts(
      shortcuts: shortcuts,
      child: Actions(
        actions: {
          // Soft line break.
          _SoftBreakIntent: CallbackAction<_SoftBreakIntent>(
            onInvoke: (_) {
              widget.controller.insertSoftBreak();
              return null;
            },
          ),
          // Inline style toggle (bold, italic, strikethrough, etc.).
          _ToggleInlineStyleIntent:
              CallbackAction<_ToggleInlineStyleIntent>(
            onInvoke: (intent) {
              widget.controller.toggleStyle(intent.style as S);
              return null;
            },
          ),
          // Undo/redo → route to our UndoManager instead of Flutter's
          // built-in UndoHistory (which doesn't know about our document).
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
          // Tab → indent (overrides FocusTraversalGroup's NextFocusAction).
          NextFocusIntent: CallbackAction<NextFocusIntent>(
            onInvoke: (_) {
              widget.controller.indent();
              return null;
            },
          ),
          // Shift+Tab → outdent (overrides PreviousFocusAction).
          PreviousFocusIntent: CallbackAction<PreviousFocusIntent>(
            onInvoke: (_) {
              widget.controller.outdent();
              return null;
            },
          ),
          // Cmd+C / Cmd+X → rich copy or cut (markdown-encoded).
          CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(
            onInvoke: (intent) {
              if (intent.collapseSelection) {
                widget.controller.richCut();
              } else {
                widget.controller.richCopy();
              }
              return null;
            },
          ),
        },
        child: TextField(
          controller: widget.controller,
          focusNode: _focusNode,
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
          decoration:
              widget.decoration ??
              InputDecoration(
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                hintText: 'Start writing...',
                hintStyle: base.copyWith(
                  color:
                      (base.color ?? theme.colorScheme.onSurface).withValues(
                    alpha: 0.35,
                  ),
                ),
              ),
          onTap: () {
            final ctrl = widget.controller;
            if (ctrl.onLinkTap != null && ctrl.value.selection.isValid) {
              final url = ctrl.linkAtDisplayOffset(
                ctrl.value.selection.baseOffset,
              );
              if (url != null) {
                ctrl.onLinkTap!(url);
              }
            }
          },
          scrollController: ScrollController(),
        ),
      ),
    );
  }
}

/// Intent for Shift+Enter soft line break.
class _SoftBreakIntent extends Intent {
  const _SoftBreakIntent();
}

/// Intent for toggling an inline style (bold, italic, etc.).
class _ToggleInlineStyleIntent extends Intent {
  const _ToggleInlineStyleIntent(this.style);
  final Object style;
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
