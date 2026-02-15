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
  late final FocusNode _focusNode;
  bool _ownsNode = false;
  FocusOnKeyEventCallback? _originalOnKeyEvent;

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
    // Preserve any existing onKeyEvent (e.g. app-level shortcuts) and chain.
    _originalOnKeyEvent = _focusNode.onKeyEvent;
    _focusNode.onKeyEvent = _handleKeyEvent;
  }

  void _disposeFocusNode() {
    _focusNode.onKeyEvent = _originalOnKeyEvent;
    _originalOnKeyEvent = null;
    if (_ownsNode) _focusNode.dispose();
  }

  @override
  void dispose() {
    _undoHistoryController.dispose();
    _disposeFocusNode();
    super.dispose();
  }

  /// Handle editor key events:
  /// - Tab / Shift+Tab → indent/outdent (must intercept to prevent focus
  ///   traversal)
  /// - Cmd+C / Cmd+X → rich copy/cut (encodes selection as markdown)
  ///
  /// Chains to any pre-existing onKeyEvent (e.g. app-level shortcuts).
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      // Shift+Enter → soft line break (newline within block).
      if (event.logicalKey == LogicalKeyboardKey.enter &&
          HardwareKeyboard.instance.isShiftPressed) {
        widget.controller.insertSoftBreak();
        return KeyEventResult.handled;
      }

      // Tab / Shift+Tab → indent / outdent.
      if (event.logicalKey == LogicalKeyboardKey.tab) {
        if (HardwareKeyboard.instance.isShiftPressed) {
          widget.controller.outdent();
        } else {
          widget.controller.indent();
        }
        return KeyEventResult.handled;
      }

      // Cmd/Ctrl + C/X → rich copy/cut with markdown encoding.
      final isMeta = HardwareKeyboard.instance.isMetaPressed ||
          HardwareKeyboard.instance.isControlPressed;
      if (isMeta) {
        switch (event.logicalKey) {
          case LogicalKeyboardKey.keyC:
            final md = widget.controller.encodeSelection();
            if (md != null) {
              Clipboard.setData(ClipboardData(text: md));
              return KeyEventResult.handled;
            }
          case LogicalKeyboardKey.keyX:
            final md = widget.controller.encodeSelection();
            if (md != null) {
              Clipboard.setData(ClipboardData(text: md));
              final sel = widget.controller.value.selection;
              if (!sel.isCollapsed) {
                final start = sel.start;
                widget.controller.value =
                    widget.controller.value.copyWith(
                  text: widget.controller.text.substring(0, sel.start) +
                      widget.controller.text.substring(sel.end),
                  selection: TextSelection.collapsed(offset: start),
                );
              }
              return KeyEventResult.handled;
            }
          default:
            break;
        }
      }

      // Schema-driven inline style shortcuts (e.g. Cmd+B → bold).
      final schema = widget.controller.schema;
      for (final entry in schema.inlineStyles.entries) {
        final shortcut = entry.value.shortcut;
        if (shortcut != null && shortcut.accepts(event, HardwareKeyboard.instance)) {
          widget.controller.toggleStyle(entry.key);
          return KeyEventResult.handled;
        }
      }
    }
    // Fall through to the app's handler if one was set.
    return _originalOnKeyEvent?.call(node, event) ?? KeyEventResult.ignored;
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
                color: (base.color ?? theme.colorScheme.onSurface).withValues(
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
    );
  }
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
