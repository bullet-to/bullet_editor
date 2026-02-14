import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../editor/editor_controller.dart';
import '../model/block.dart';
import '../model/inline_style.dart';

/// Callback when the user taps at a position in the editor.
/// Receives the [StyledSegment] at the tap position (may be a link, image, etc.)
/// and the global tap position for positioning popups.
typedef EditorTapCallback = void Function(EditorTapDetails details);

/// Details about a tap in the editor.
class EditorTapDetails {
  const EditorTapDetails({
    required this.globalPosition,
    required this.segment,
  });

  /// The global position of the tap.
  final Offset globalPosition;

  /// The styled segment at the tap position, or null if tapping empty space.
  final StyledSegment? segment;

  /// Convenience: the link URL if the tap landed on a link, otherwise null.
  String? get linkUrl {
    final seg = segment;
    if (seg != null &&
        seg.styles.contains(InlineStyle.link) &&
        seg.attributes['url'] != null) {
      return seg.attributes['url'] as String;
    }
    return null;
  }
}

/// A rich text editor widget built on Flutter's TextField.
///
/// Encapsulates the TextField, focus management, keyboard shortcuts (Tab/Shift+Tab),
/// and tap detection for links and other interactive segments.
///
/// ```dart
/// BulletEditor(
///   controller: myController,
///   onTap: (details) {
///     if (details.linkUrl != null) launchUrl(details.linkUrl!);
///   },
/// )
/// ```
class BulletEditor extends StatefulWidget {
  const BulletEditor({
    super.key,
    required this.controller,
    this.focusNode,
    this.style,
    this.decoration,
    this.onTap,
    this.onKeyEvent,
    this.expands = true,
    this.readOnly = false,
  });

  /// The editor controller that manages the document model.
  final EditorController controller;

  /// Focus node for the editor. If null, one is created internally.
  final FocusNode? focusNode;

  /// Base text style for the editor content.
  final TextStyle? style;

  /// Input decoration for the underlying TextField.
  final InputDecoration? decoration;

  /// Called when the user taps on the editor content. Use to handle
  /// link taps, image taps, or any interactive segment.
  final EditorTapCallback? onTap;

  /// Optional key event handler for custom keyboard shortcuts.
  /// Called before the editor's built-in handling.
  final KeyEventResult Function(FocusNode, KeyEvent)? onKeyEvent;

  /// Whether the editor expands to fill available space.
  final bool expands;

  /// Whether the editor is read-only.
  final bool readOnly;

  @override
  State<BulletEditor> createState() => _BulletEditorState();
}

class _BulletEditorState extends State<BulletEditor> {
  final _textFieldKey = GlobalKey();
  final _undoController = UndoHistoryController();
  late final FocusNode _focusNode;
  bool _ownsFocusNode = false;

  @override
  void initState() {
    super.initState();
    if (widget.focusNode != null) {
      _focusNode = widget.focusNode!;
    } else {
      _focusNode = FocusNode();
      _ownsFocusNode = true;
    }
  }

  @override
  void dispose() {
    _undoController.dispose();
    if (_ownsFocusNode) _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    // Let consumer handle first.
    if (widget.onKeyEvent != null) {
      final result = widget.onKeyEvent!(node, event);
      if (result == KeyEventResult.handled) return result;
    }

    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final isMeta = HardwareKeyboard.instance.isMetaPressed;
    final isShift = HardwareKeyboard.instance.isShiftPressed;

    // Tab / Shift+Tab → indent / outdent.
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      if (isShift) {
        widget.controller.outdent();
      } else {
        widget.controller.indent();
      }
      return KeyEventResult.handled;
    }

    // Cmd+Z / Cmd+Shift+Z → undo / redo.
    if (isMeta && event.logicalKey == LogicalKeyboardKey.keyZ) {
      if (isShift) {
        widget.controller.redo();
      } else {
        widget.controller.undo();
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _onTap() {
    if (widget.onTap == null) return;
    final sel = widget.controller.selection;
    if (!sel.isValid || !sel.isCollapsed) return;

    final seg = widget.controller.segmentAtOffset(
      widget.controller.displayToModel(sel.baseOffset),
    );
    widget.onTap!(EditorTapDetails(
      globalPosition: Offset.zero,
      segment: seg,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: _handleKeyEvent,
      child: TextField(
        key: _textFieldKey,
        controller: widget.controller,
        focusNode: _focusNode,
        undoController: _undoController,
        maxLines: null,
        readOnly: widget.readOnly,
        expands: widget.expands,
        enableInteractiveSelection: true,
        stylusHandwritingEnabled: false,
        textAlignVertical: TextAlignVertical.top,
        style: widget.style ?? const TextStyle(fontSize: 16, height: 1.5),
        decoration: widget.decoration ??
            const InputDecoration(
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.all(12),
            ),
        onTap: _onTap,
      ),
    );
  }
}
