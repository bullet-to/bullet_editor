import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../editor/editor_controller.dart';
import '../input/ime_service.dart';
import '../model/doc_selection.dart';
import '../model/inline_entity.dart';
import 'block_layout_registry.dart';
import 'block_list_view.dart';
import 'editor_hit_tester.dart';
import 'editor_view_scope.dart';

/// The v3 editor root widget: lazy render through the component registry,
/// geometry registry (GATE-L), focus, tap-to-caret, caret + composing
/// painting, the IME delta path (day 5–7 — character input arrives as
/// engine deltas through [ImeService], never as key events), and the
/// hardware-key handlers the IME doesn't own (Enter, Backspace, Tab,
/// arrows, undo). Day 10 brings the full shortcut matrix with the composing
/// gate over all handlers.
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
  /// interactors, and the IME geometry reporter.
  final BlockLayoutRegistry registry = BlockLayoutRegistry();

  /// The IME delta frontend — one service per attached controller. Exposed
  /// for the inspector pane and for tests that drive engine deltas.
  late ImeService imeService;

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
  /// (controller, node, or both), and unmount. The IME service rides the
  /// same lifecycle: one per controller, its geometry reporter wired to the
  /// registry and the editor's render box.
  void _attach(EditorController controller, FocusNode node) {
    controller.addListener(_onControllerChanged);
    controller.attachFocusNode(node);
    node.addListener(_onFocusChanged);
    imeService = ImeService(controller: controller)
      ..geometryReporter.editorRenderBox = () {
        final renderObject = context.findRenderObject();
        return renderObject is RenderBox ? renderObject : null;
      }
      ..geometryReporter.blockGeometryOf = registry.geometryOf;
    _syncImeAttachment();
  }

  void _detach(EditorController controller, FocusNode node) {
    controller.removeListener(_onControllerChanged);
    controller.detachFocusNode(node);
    node.removeListener(_onFocusChanged);
    imeService.dispose();
  }

  /// The connection follows focus (architecture §IME: attached whenever the
  /// editor has focus — including with the selection on a void block).
  void _syncImeAttachment() {
    if (_focusNode.hasFocus && !widget.readOnly) {
      imeService.attach();
    } else {
      imeService.detach();
    }
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
    // The connection tracks readOnly as well as focus: flipping readOnly on
    // while focused must drop the live connection (deltas would otherwise
    // keep mutating the document against the widget contract above), and
    // flipping it off while focused must attach one.
    if (widget.readOnly != oldWidget.readOnly) _syncImeAttachment();
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

  void _onFocusChanged() {
    _syncImeAttachment();
    setState(() {}); // caret visibility
  }

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

  // --- Hardware keys (the division of labor: keys the IME doesn't own.
  // Character input goes through the IME delta path exclusively — a
  // hardware character-insert here would double-type against the engine
  // connection. The composing gate over all handlers is day-10 work.) ---

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
      composing: controller.composing,
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
