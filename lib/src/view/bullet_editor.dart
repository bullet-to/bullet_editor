import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../editor/editor_controller.dart';
import '../model/doc_selection.dart';
import '../model/inline_entity.dart';
import 'block_layout_registry.dart';
import 'block_list_view.dart';
import 'editor_hit_tester.dart';
import 'editor_view_scope.dart';

/// The v3 editor root widget (day 3–4 surface): lazy render through the
/// component registry, geometry registry (GATE-L), focus, tap-to-caret,
/// caret painting, and a deliberately minimal hardware-key editing path
/// (checkpoint 2: characters, Enter, Backspace, Tab, arrows, undo). Day 5–7
/// replaces character input with the IME delta path; day 10 brings the full
/// shortcut matrix with the composing gate.
class BulletEditor extends StatefulWidget {
  const BulletEditor({
    super.key,
    required this.controller,
    this.scrollController,
    this.focusNode,
    this.readOnly = false,
    this.autofocus = false,
    this.textStyle,
    this.padding,
    this.onLinkTap,
  });

  final EditorController controller;

  /// Optional — the editor owns one otherwise.
  final ScrollController? scrollController;

  /// Optional — the editor owns one otherwise (mirrors [scrollController];
  /// v2's exact pattern).
  final FocusNode? focusNode;

  /// When true, taps still place the caret but editing keys are inert.
  final bool readOnly;

  final bool autofocus;

  /// Base text style; block defs derive from it via `baseStyle`.
  /// Defaults to the ambient [DefaultTextStyle].
  final TextStyle? textStyle;

  /// Padding around the document content.
  final EdgeInsetsGeometry? padding;

  /// Link tap surface (D3) — driven by the link-span recognizers.
  final void Function(String blockId, int offset, InlineEntitySnapshot entity)?
  onLinkTap;

  @override
  State<BulletEditor> createState() => BulletEditorState();
}

class BulletEditorState extends State<BulletEditor> {
  /// blockId → geometry-or-null (GATE-L). Exposed for the inspector,
  /// interactors, and (day 5–7) the IME geometry reporter.
  final BlockLayoutRegistry registry = BlockLayoutRegistry();

  ScrollController? _ownedScrollController;
  FocusNode? _ownedFocusNode;

  ScrollController get _scrollController =>
      widget.scrollController ??
      (_ownedScrollController ??= ScrollController());

  FocusNode get _focusNode =>
      widget.focusNode ??
      (_ownedFocusNode ??= FocusNode(debugLabel: 'BulletEditor'));

  Offset? _pointerDownPosition;

  /// The controller/focus-node pair is attached and detached symmetrically —
  /// one helper pair covers mount, every didUpdateWidget swap combination
  /// (controller, node, or both), and unmount.
  void _attach(EditorController controller, FocusNode node) {
    controller.addListener(_onControllerChanged);
    controller.attachFocusNode(node);
    node.addListener(_onFocusChanged);
  }

  void _detach(EditorController controller, FocusNode node) {
    controller.removeListener(_onControllerChanged);
    controller.detachFocusNode(node);
    node.removeListener(_onFocusChanged);
  }

  @override
  void initState() {
    super.initState();
    // GATE-K: schema validation at the editor boundary, debug-mode.
    assert(widget.controller.schema.validate());
    _attach(widget.controller, _focusNode);
  }

  @override
  void didUpdateWidget(BulletEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final controllerChanged = !identical(
      widget.controller,
      oldWidget.controller,
    );
    final nodeChanged = !identical(widget.focusNode, oldWidget.focusNode);
    if (!controllerChanged && !nodeChanged) return;

    // The node the old pair was attached with (the owned node when the old
    // widget supplied none — initState guarantees it exists by now).
    final oldNode = (oldWidget.focusNode ?? _ownedFocusNode)!;
    _detach(oldWidget.controller, oldNode);
    // GATE-K also covers a schema swapped in via a new controller.
    assert(!controllerChanged || widget.controller.schema.validate());
    _attach(widget.controller, _focusNode);
  }

  @override
  void dispose() {
    _detach(widget.controller, _focusNode);
    _ownedScrollController?.dispose();
    _ownedFocusNode?.dispose();
    super.dispose();
  }

  void _onControllerChanged() => setState(() {});

  void _onFocusChanged() => setState(() {}); // caret visibility

  // --- Tap-to-caret (raw Listener: arena-exempt, so it composes with the
  // link-span recognizers — G11 invariant; interactor recognizers that
  // compete with the scrollable arrive days 10–13) ---

  void _onPointerDown(PointerDownEvent event) {
    _pointerDownPosition = event.position;
  }

  void _onPointerUp(PointerUpEvent event) {
    final down = _pointerDownPosition;
    _pointerDownPosition = null;
    if (down == null) return;
    if ((event.position - down).distance > kTouchSlop) return; // drag/scroll
    _handleTap(event.position);
  }

  void _handleTap(Offset globalPosition) {
    final position = hitTestDocPosition(registry, globalPosition);
    if (position != null) {
      // setSelection normalizes a void hit (midpoint-resolved offset 0/1)
      // to the [0,1) atomic selection.
      widget.controller.setSelection(DocSelection.collapsed(position));
    }
    widget.controller.requestFocus();
  }

  // --- Hardware-key skeleton (checkpoint 2) ---

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (widget.readOnly) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final controller = widget.controller;
    final pressed = HardwareKeyboard.instance;
    final isShortcut = pressed.isMetaPressed || pressed.isControlPressed;

    if (isShortcut) {
      if (event.logicalKey == LogicalKeyboardKey.keyZ) {
        pressed.isShiftPressed ? controller.redo() : controller.undo();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    switch (event.logicalKey) {
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter:
        controller.insertNewline();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.backspace:
        controller.backspace();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.tab:
        pressed.isShiftPressed ? controller.outdent() : controller.indent();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        controller.moveCaret(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        controller.moveCaret(1);
        return KeyEventResult.handled;
    }

    final character = event.character;
    if (character != null &&
        character.isNotEmpty &&
        character.codeUnits.any((u) => u >= 0x20)) {
      controller.insertText(character);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final baseStyle = widget.textStyle ?? DefaultTextStyle.of(context).style;

    Widget sliver = BlockListView(
      document: controller.document,
      schema: controller.schema,
      baseStyle: baseStyle,
      selection: controller.selection,
      showCaret: _focusNode.hasFocus && !widget.readOnly,
      onLinkTap: widget.onLinkTap,
    );
    if (widget.padding != null) {
      sliver = SliverPadding(padding: widget.padding!, sliver: sliver);
    }

    return EditorViewScope(
      registry: registry,
      child: Focus(
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        onKeyEvent: _onKeyEvent,
        child: Listener(
          onPointerDown: _onPointerDown,
          onPointerUp: _onPointerUp,
          behavior: HitTestBehavior.opaque,
          // I-beam over editor content. Per-segment refinement (click over
          // links, basic over voids) is interactor-side, day 14.
          child: MouseRegion(
            cursor: SystemMouseCursors.text,
            child: CustomScrollView(
              controller: _scrollController,
              slivers: [sliver],
            ),
          ),
        ),
      ),
    );
  }
}
