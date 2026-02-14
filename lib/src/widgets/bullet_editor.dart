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
    this.precedingSegment,
  });

  /// The global position of the tap.
  final Offset globalPosition;

  /// The segment at the tap position (prefers preceding segment at boundaries,
  /// matching the editor's active formatting behavior).
  final StyledSegment? segment;

  /// The other segment at a boundary (the forward-matching one when [segment]
  /// is the preceding, or vice versa). Null when not at a boundary.
  final StyledSegment? precedingSegment;
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
    this.onLinkTap,
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

  /// Called when the user taps on the editor content. Use for custom
  /// tap handling (image taps, mention taps, etc.).
  final EditorTapCallback? onTap;

  /// Called when the user taps on a link. Receives the URL.
  /// Convenience — equivalent to checking for a link in [onTap].
  final void Function(String url)? onLinkTap;

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
    if (widget.onTap == null && widget.onLinkTap == null) return;
    final sel = widget.controller.selection;
    if (!sel.isValid || !sel.isCollapsed) return;

    final modelOffset = widget.controller.displayToModel(sel.baseOffset);
    final seg = widget.controller.segmentAtOffset(modelOffset);
    final prevSeg =
        modelOffset > 0 ? widget.controller.segmentAtOffset(modelOffset - 1) : null;

    // Primary segment matches the editor's active formatting: at a boundary,
    // prefer the preceding segment (the one the cursor "came from").
    final primary = (prevSeg != null && prevSeg != seg) ? prevSeg : seg;
    final secondary = (primary == prevSeg) ? seg : prevSeg;

    if (widget.onTap != null) {
      widget.onTap!(EditorTapDetails(
        globalPosition: Offset.zero,
        segment: primary,
        precedingSegment: secondary,
      ));
    }

    if (widget.onLinkTap != null) {
      final url = _linkFrom(primary) ?? _linkFrom(secondary);
      if (url != null) widget.onLinkTap!(url);
    }
  }

  /// Derive the default text style from the host app's TextTheme.
  /// Falls back to fontSize 16, height 1.6 when no theme is available.
  static TextStyle _defaultStyle(BuildContext context) {
    final base = Theme.of(context).textTheme.bodyLarge;
    return (base ?? const TextStyle(fontSize: 16)).copyWith(
      height: 1.6,
    );
  }

  static String? _linkFrom(StyledSegment? seg) {
    if (seg != null &&
        seg.styles.contains(InlineStyle.link) &&
        seg.attributes['url'] != null) {
      return seg.attributes['url'] as String;
    }
    return null;
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
        style: widget.style ?? _defaultStyle(context),
        decoration: widget.decoration ??
            const InputDecoration(
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            ),
        onTap: _onTap,
      ),
    );
  }
}
