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

  @override
  void initState() {
    super.initState();
    // GATE-K: schema validation at the editor boundary, debug-mode.
    assert(widget.controller.schema.validate());
    widget.controller.addListener(_onControllerChanged);
    widget.controller.attachFocusNode(_focusNode);
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(BulletEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.controller, oldWidget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      oldWidget.controller.detachFocusNode(_focusNode);
      // GATE-K also covers a schema swapped in via a new controller.
      assert(widget.controller.schema.validate());
      widget.controller.addListener(_onControllerChanged);
      widget.controller.attachFocusNode(_focusNode);
    }
    if (!identical(widget.focusNode, oldWidget.focusNode)) {
      final old = oldWidget.focusNode ?? _ownedFocusNode;
      old?.removeListener(_onFocusChanged);
      widget.controller.detachFocusNode(old ?? _focusNode);
      _focusNode.addListener(_onFocusChanged);
      widget.controller.attachFocusNode(_focusNode);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    widget.controller.detachFocusNode(_focusNode);
    _focusNode.removeListener(_onFocusChanged);
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
        _moveCaret(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        _moveCaret(1);
        return KeyEventResult.handled;
    }

    final character = event.character;
    if (character != null &&
        character.isNotEmpty &&
        !character.codeUnits.every((u) => u < 0x20)) {
      controller.insertText(character);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Grapheme-aware left/right caret movement with block hops. Vertical
  /// movement needs line geometry and lands with the day-10 key matrix.
  void _moveCaret(int direction) {
    final controller = widget.controller;
    final sel = controller.selection;
    if (sel == null) return;

    final doc = controller.document;

    if (!sel.isCollapsed) {
      // Off a void's atomic selection: hop to the adjacent block (collapsing
      // onto the void would just re-normalize to the atomic selection).
      final sameBlock = sel.base.blockId == sel.extent.blockId;
      final block = doc.blockById(sel.extent.blockId);
      if (sameBlock &&
          block != null &&
          controller.schema.isVoid(block.blockType)) {
        _hopToAdjacentBlock(doc.idToFlatIndex[block.id]!, direction);
        return;
      }
      // Otherwise collapse to the directional edge (standard behavior).
      final (start, end) = sel.normalized(doc);
      controller.setSelection(
        DocSelection.collapsed(direction < 0 ? start : end),
      );
      return;
    }

    final caret = sel.extent;
    final block = doc.blockById(caret.blockId);
    final flatIndex = doc.idToFlatIndex[caret.blockId];
    if (block == null || flatIndex == null) return;

    final text = block.plainText;
    if (direction < 0 && caret.offset > 0) {
      final step = text.substring(0, caret.offset).characters.last.length;
      controller.setSelection(
        DocSelection.collapsed(DocPosition(caret.blockId, caret.offset - step)),
      );
      return;
    }
    if (direction > 0 && caret.offset < block.length) {
      final step = text.substring(caret.offset).characters.first.length;
      controller.setSelection(
        DocSelection.collapsed(DocPosition(caret.blockId, caret.offset + step)),
      );
      return;
    }

    _hopToAdjacentBlock(flatIndex, direction);
  }

  void _hopToAdjacentBlock(int fromFlatIndex, int direction) {
    final controller = widget.controller;
    final doc = controller.document;
    final targetIndex = fromFlatIndex + (direction < 0 ? -1 : 1);
    if (targetIndex < 0 || targetIndex >= doc.allBlocks.length) return;
    final target = doc.allBlocks[targetIndex];
    final offset = controller.schema.isVoid(target.blockType)
        ? 0 // setSelection normalizes to the atomic selection
        : direction < 0
        ? target.length
        : 0;
    controller.setSelection(
      DocSelection.collapsed(DocPosition(target.id, offset)),
    );
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
          child: CustomScrollView(
            controller: _scrollController,
            slivers: [sliver],
          ),
        ),
      ),
    );
  }
}
