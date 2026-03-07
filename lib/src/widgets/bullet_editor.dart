import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
/// [B] is the block type key, [S] is the inline style key, and [E] is the
/// inline entity key.
class BulletEditor<B extends Object, S extends Object, E extends Object>
    extends StatefulWidget {
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

  final EditorController<B, S, E> controller;
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
  State<BulletEditor<B, S, E>> createState() => _BulletEditorState<B, S, E>();
}

class _BulletEditorState<B extends Object, S extends Object, E extends Object>
    extends State<BulletEditor<B, S, E>> {
  late final UndoHistoryController _undoHistoryController;
  late FocusNode _focusNode;
  bool _ownsNode = false;
  final _textFieldKey = GlobalKey();
  Offset? _lastPointerDown;

  @override
  void initState() {
    super.initState();
    _undoHistoryController = UndoHistoryController(value: null);
    _initFocusNode();
  }

  @override
  void didUpdateWidget(covariant BulletEditor<B, S, E> oldWidget) {
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
          _ToggleInlineStyleIntent: CallbackAction<_ToggleInlineStyleIntent>(
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
        child: Listener(
          onPointerDown: (event) => _lastPointerDown = event.position,
          child: TextField(
            key: _textFieldKey,
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
                    color: (base.color ?? theme.colorScheme.onSurface)
                        .withValues(alpha: 0.35),
                  ),
                ),
            onTap: () => _handleInlineEntityTap(base),
            scrollController: ScrollController(),
          ),
        ),
      ),
    );
  }

  void _handleInlineEntityTap(TextStyle base) {
    final ctrl = widget.controller;
    if (!ctrl.value.selection.isValid) return;
    final entity = ctrl.inlineEntityAtDisplayOffset(
      ctrl.value.selection.baseOffset,
    );
    if (entity == null) return;

    if (!_isTapOnText(base)) return;
    if (ctrl.onInlineEntityTap != null) {
      ctrl.onInlineEntityTap!(entity);
    }
  }

  /// Verify the last pointer-down was on actual text, not empty space
  /// below or to the right of a line.
  bool _isTapOnText(TextStyle base) {
    if (_lastPointerDown == null) return true;

    final editable = _findRenderEditable();
    if (editable == null) return true;

    final localPos = editable.globalToLocal(_lastPointerDown!);
    final span = widget.controller.buildTextSpan(
      context: context,
      style: base,
      withComposing: false,
    );
    final painter = TextPainter(
      text: span,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    );
    painter.layout(maxWidth: editable.size.width);
    final metrics = painter.computeLineMetrics();
    painter.dispose();

    for (final line in metrics) {
      final lineTop = line.baseline - line.ascent;
      final lineBottom = line.baseline + line.descent;
      if (localPos.dy >= lineTop && localPos.dy < lineBottom) {
        return localPos.dx >= 0 && localPos.dx <= line.left + line.width;
      }
    }
    return false;
  }

  RenderEditable? _findRenderEditable() {
    final renderObj = _textFieldKey.currentContext?.findRenderObject();
    if (renderObj == null) return null;
    RenderEditable? result;
    void visit(RenderObject obj) {
      if (result != null) return;
      if (obj is RenderEditable) {
        result = obj;
        return;
      }
      obj.visitChildren(visit);
    }

    visit(renderObj);
    return result;
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
extension MarkdownExtension<
  B extends Object,
  S extends Object,
  E extends Object
>
    on EditorController<B, S, E> {
  /// Convenience: get the markdown text for the current document.
  String get markdown {
    final codec = MarkdownCodec(schema: schema);
    return codec.encode(document);
  }
}
