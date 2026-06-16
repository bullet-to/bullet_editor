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
import 'mouse_interactor.dart';

/// The v3 editor root widget: lazy render through the component registry,
/// geometry registry (GATE-L), focus, tap-to-caret, caret + composing
/// painting, the IME path (days 5–8 — character input arrives through
/// [ImeService], never as key events: engine deltas on delta platforms,
/// diffed full-value snapshots behind the web fallback, per [imeFrontend]),
/// and the hardware-key handlers the IME doesn't own (Enter, Backspace,
/// Tab, arrows, undo) behind the full composing gate (day-10 work pulled
/// forward — see [_classifyKeyEvent]). Day 10 brings the full key MATRIX
/// (new bindings: ↑/↓ caret movement, Cmd+arrows, Alt+↑/↓ `MoveBlock`); the
/// gate itself has landed.
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
    this.imeFrontend,
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

  /// Which engine frontend feeds the IME core (architecture §IME: one
  /// strategy, two frontends, one core). Null takes the platform default —
  /// the delta model everywhere except web, which gets the non-delta diff
  /// fallback. Override per-platform only as the R1 escape hatch (an OEM
  /// keyboard with broken delta support).
  ///
  /// A genuine runtime flip rebuilds the IME service (a connection's
  /// delta-model declaration cannot change in place), which abandons any
  /// live composition outright — the teardown goes through the service
  /// rebuild, not `terminateComposition`.
  final ImeFrontend? imeFrontend;

  @override
  State<BulletEditor> createState() => BulletEditorState();
}

class BulletEditorState extends State<BulletEditor>
    with WidgetsBindingObserver {
  /// blockId → geometry-or-null (GATE-L). Exposed for the inspector,
  /// interactors, and the IME geometry reporter.
  final BlockLayoutRegistry registry = BlockLayoutRegistry();

  /// The IME delta frontend — one service per attached controller. Exposed
  /// for the inspector pane and for tests that drive engine deltas.
  late ImeService imeService;

  /// Mouse/trackpad selection gestures (architecture §Gestures, per-kind
  /// dispatch). Touch/stylus gestures (long-press, handles, magnifier) arrive
  /// days 11–13; today touch keeps the slop-gated tap-to-caret below.
  late final MouseInteractor _mouseInteractor = MouseInteractor(
    registry: registry,
    documentOf: () => widget.controller.document,
    setSelection: (selection) => widget.controller.setSelection(selection),
    requestFocus: () => widget.controller.requestFocus(),
    scrollPositionOf: () =>
        _scrollController.hasClients ? _scrollController.position : null,
    viewportRectOf: () {
      final renderObject = context.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.hasSize) return null;
      return renderObject.localToGlobal(Offset.zero) & renderObject.size;
    },
  );

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
    imeService =
        ImeService(controller: controller, frontend: widget.imeFrontend)
          ..geometryReporter.editorRenderBox = () {
            final renderObject = context.findRenderObject();
            return renderObject is RenderBox ? renderObject : null;
          }
          ..geometryReporter.blockGeometryOf = registry.geometryOf
          // The hidden input's font metrics (TextInput.setStyle): the SAME
          // resolution the components render with — block def baseStyle over
          // the editor base style, text scaling applied (the engine sizes
          // the DOM font in px; our rendered pixels include the scaler).
          ..geometryReporter.resolvedStyleOf = (blockId) {
            if (!mounted) return null;
            final block = controller.document.blockById(blockId);
            if (block == null) return null;
            final def = controller.schema.blockDef(block.blockType);
            final base = widget.textStyle ?? DefaultTextStyle.of(context).style;
            final resolved = def.baseStyle?.call(base) ?? base;
            final fontSize = resolved.fontSize;
            if (fontSize == null) return resolved;
            return resolved.copyWith(
              fontSize: MediaQuery.textScalerOf(context).scale(fontSize),
            );
          }
          ..geometryReporter.textDirection = () =>
              mounted ? Directionality.of(context) : TextDirection.ltr;
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
    WidgetsBinding.instance.addObserver(this);
    _attach(widget.controller, _focusNode);
  }

  /// Window/app focus loss while a composition is live terminates it
  /// (`'windowBlur'`) — the browser-chrome blur recovery.
  ///
  /// The wedge (manual Safari repro): compose にほんご, click the URL bar.
  /// Browser focus leaves the page WITHOUT blurring Flutter's [FocusNode]
  /// (no detach fires), and nothing arrives from the engine either — on
  /// Safari desktop the engine deliberately attaches NO blur listener to
  /// its hidden input (engine `text_editing.dart`, `addEventHandlers`:
  /// `this is! SafariDesktopTextEditingStrategy` — "handleBlur causes
  /// Safari to reopen autofill dialogs"), so the `connectionClosed` other
  /// browsers send on window focus loss (`handleBlur`: `relatedTarget ==
  /// null` ⇒ `sendTextConnectionClosedToFrameworkIfAny`, flutter#155265)
  /// never comes, and Safari delivers no compositionend to the page on
  /// browser-chrome focus loss. The composing gate stays closed
  /// ([ImeService.engineComposing] — shadow composing / passive divergence
  /// armed with no ending snapshot ever coming), underline state goes
  /// stale, typing wedges.
  ///
  /// Page-level focus loss IS observable in the framework: on web the
  /// window blur reports [AppLifecycleState.inactive] (hidden/paused when
  /// the page hides). Terminating there matches native macOS behavior —
  /// apps commit/cancel marked text on deactivate — and guarantees the
  /// gate reopens and composition state resets through the one choke
  /// point (quarantine armed against a late engine echo, passive
  /// divergence resolved, commit-key one-shot disarmed). On [
  /// AppLifecycleState.resumed] the attachment re-syncs: a no-op where the
  /// connection survived (Safari — `attach` is idempotent), a fresh attach
  /// where the engine closed it (Chrome's `connectionClosed` path).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncImeAttachment();
      return;
    }
    if (widget.controller.composing != null || imeService.engineComposing) {
      imeService.terminateComposition('windowBlur');
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The hidden input's metrics (TextInput.setStyle) resolve through
    // ambient dependencies — MediaQuery's text scaler, DefaultTextStyle,
    // Directionality (the geometry reporter's lookups read them off this
    // context) — so a dependency change must re-report, or the engine's
    // DOM font (the caret box browsers hang the IME candidate window off)
    // goes stale. Cheap by construction: the report is post-frame
    // coalesced and setStyle is cached against the resolved style, so an
    // unchanged resolution stays silent.
    imeService.scheduleGeometryReport();
  }

  @override
  void didUpdateWidget(BulletEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The connection tracks readOnly as well as focus: flipping readOnly on
    // while focused must drop the live connection (deltas would otherwise
    // keep mutating the document against the widget contract above), and
    // flipping it off while focused must attach one.
    if (widget.readOnly != oldWidget.readOnly) _syncImeAttachment();
    // A changed style context re-sends the hidden input's metrics
    // (TextInput.setStyle rides the geometry report and is cached against
    // the resolved style, so an unchanged resolution stays silent).
    if (widget.textStyle != oldWidget.textStyle) {
      imeService.scheduleGeometryReport();
    }
    final controllerChanged = !identical(
      widget.controller,
      oldWidget.controller,
    );
    final nodeChanged = !identical(widget.focusNode, oldWidget.focusNode);
    // The frontend is fixed per ImeService (a connection's delta-model
    // declaration cannot change in place); flipping it rebuilds the
    // service, which re-attaches with the matching configuration. Compared
    // as EFFECTIVE frontends — the requested value resolved against the
    // live service's — because a raw nullable comparison would treat
    // null → the explicit platform default as a flip and tear down a live
    // connection (and any composition with it) for a no-op.
    final frontendChanged =
        (widget.imeFrontend ?? ImeFrontend.platformDefault) !=
        imeService.frontend;
    if (!controllerChanged && !nodeChanged && !frontendChanged) return;

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
    WidgetsBinding.instance.removeObserver(this);
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

  // --- Pointer dispatch by kind (architecture §Gestures). Mouse/trackpad
  // pointers drive the mouse interactor (click/drag/multi-click/shift-click +
  // autoscroll); touch/stylus keep the slop-gated tap-to-caret until the
  // touch interactor lands days 11–13. The raw Listener is arena-exempt, so
  // both compose with the link-span recognizers — G11 invariant. Mouse drag
  // does not fight the scrollable: the editor pins a ScrollBehavior whose
  // dragDevices exclude mouse (see [build]). ---

  void _onPointerDown(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      _mouseInteractor.handlePointerDown(event);
      return;
    }
    _pointerDownPosition = event.position;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      _mouseInteractor.handlePointerMove(event);
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      _mouseInteractor.handlePointerUp(event);
      return;
    }
    final down = _pointerDownPosition;
    _pointerDownPosition = null;
    if (down == null) return;
    if ((event.position - down).distance > kTouchSlop) return; // drag/scroll
    _handleTap(event.position);
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      _mouseInteractor.handlePointerCancel(event);
    }
    _pointerDownPosition = null;
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
  // connection. The composing gate covers ALL handlers below; day 10 adds
  // the remaining key matrix under the same gate.) ---

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final (:result, :handler, :deferred, :action) = _classifyKeyEvent(event);
    // Every key event lands in the IME journal so hardware keys interleave
    // with the engine traffic in one capturable stream — `handler` names
    // the controller verb that consumed it (or `ignored`), `deferred`
    // whether the composing gate left it to the IME. Recorded BEFORE the
    // verb runs so the key precedes the pushes it causes.
    imeService.journal.record(
      'key',
      () => {
        'kind': switch (event) {
          KeyDownEvent() => 'down',
          KeyRepeatEvent() => 'repeat',
          KeyUpEvent() => 'up',
          _ => event.runtimeType.toString(),
        },
        'key': event.logicalKey.keyLabel,
        'character': event.character,
        'deferred': deferred,
        'handler': handler,
      },
    );
    action?.call();
    return result;
  }

  /// The key dispatch decision, split from [_onKeyEvent] so the journal can
  /// record the outcome alongside the event before the verb runs.
  ({KeyEventResult result, String handler, bool deferred, VoidCallback? action})
  _classifyKeyEvent(KeyEvent event) {
    const ignored = (
      result: KeyEventResult.ignored,
      handler: 'ignored',
      deferred: false,
      action: null,
    );
    if (widget.readOnly) return ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return ignored;

    final controller = widget.controller;
    final pressed = HardwareKeyboard.instance;
    final isShortcut = pressed.isMetaPressed || pressed.isControlPressed;

    if (isShortcut) {
      // The composing gate's explicit whitelist (architecture §hardware
      // keyboard: "a whitelist over an ignore-all default, not a per-key
      // blacklist"): Cmd/Ctrl+Z and Shift+Cmd/Ctrl+Z stay handled even while
      // a composition is live — undo is a first-class composition terminator
      // (G7): the controller restores the pre-composition snapshot and the
      // IME push routes through terminateComposition('undo'), quarantine
      // armed. Every other key defers through the gate below.
      if (event.logicalKey == LogicalKeyboardKey.keyZ) {
        return pressed.isShiftPressed
            ? (
                result: KeyEventResult.handled,
                handler: 'redo',
                deferred: false,
                action: controller.redo,
              )
            : (
                result: KeyEventResult.handled,
                handler: 'undo',
                deferred: false,
                action: controller.undo,
              );
      }
      return ignored;
    }

    // The full composing gate — day-10 work pulled forward (architecture
    // §hardware keyboard: "the composing gate covers ALL of keyboard_service,
    // not just Enter/Backspace — ignore-everything-while-composing with an
    // explicit whitelist"; the whitelist is the shortcut block above). Day 10
    // retains only the full key MATRIX (new bindings: ↑/↓ caret movement,
    // Cmd+arrows, Alt+↑/↓ MoveBlock) — each lands under this same gate.
    // While a composition is live EVERY editing/navigation key belongs to
    // the IME: on macOS the text input plugin is a SECONDARY key responder,
    // so a key event the framework marks handled never reaches
    // NSTextInputContext — handling backspace here while marked text exists
    // both starves the IME of the keystroke it must consume (a dead key's
    // marked-text removal) and edits the document out from under the live
    // composition (terminateComposition → quarantine armed → the re-typed
    // accent's signature). Arrows are NOT exempt: Japanese conversion uses
    // ←/→ for clause segments and ↑/↓ for candidates — an ungated arrow
    // fires setSelection → terminateComposition('externalEdit'), committing
    // the marked text on the first navigation keystroke (the live
    // Safari/Chrome symptoms: → mid-composition walks the caret through the
    // text and copies it to the start of the next line; ↑/↓ while cycling
    // the candidate menu push the cursor through the document).
    //
    // Every key uses skipRemainingHandlers — NOT ignored. On web, ignored
    // lets Flutter's focus tree consume the key before the browser IME
    // sees it: FocusTraversalGroup intercepts Tab (and Shift+Tab),
    // DirectionalFocusTraversalPolicyMixin intercepts arrows, ModalRoute
    // intercepts Escape. Each calls preventDefault() on the native
    // keydown, killing the IME's use of that key. skipRemainingHandlers
    // stops focus-tree propagation WITHOUT preventDefault(), so every key
    // reaches the platform IME. On desktop this is harmless: the platform
    // result is "not handled" — same as ignored — and the key continues
    // up the macOS responder chain to NSTextInputContext.
    //
    // The gate keys on the MODEL's composing state OR the service's
    // engine-side condition ([ImeService.engineComposing]): on the diff
    // frontend a composition whose FIRST snapshot is unmappable arms the
    // passive-divergence window without ever installing a ComposingState
    // — the browser genuinely still composes, and an editing key reaching
    // the model there would external-edit terminate → mid-composition
    // push, the corruption class this gate exists to prevent.
    if (controller.composing != null || imeService.engineComposing) {
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter ||
          key == LogicalKeyboardKey.backspace ||
          key == LogicalKeyboardKey.tab) {
        // A gate-deferred commit-capable key — Enter, Backspace, Tab: the
        // editing keys an IME consumes to end a composition AND our
        // handlers act on destructively — is noted with the service: it
        // proves the keydown-first ordering (Chrome/Firefox — keyCode 229
        // while the composition is live), so the composing-clear this key
        // produces must not arm the commit-key suppression below.
        return (
          result: KeyEventResult.skipRemainingHandlers,
          handler: 'ignored',
          deferred: true,
          action: imeService.noteCommitKeyDeferred,
        );
      }
      return (
        result: KeyEventResult.skipRemainingHandlers,
        handler: 'ignored',
        deferred: true,
        action: null,
      );
    }

    switch (event.logicalKey) {
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter:
        // Safari fires compositionend BEFORE the keydown of the key that
        // ended the composition, so the Enter that COMMITS a conversion
        // arrives here with `controller.composing` already null — past the
        // gate above. The service's one-shot suppression (ProseMirror's
        // `compositionEndedAt` precedent) identifies it: swallow it
        // handled, no newline; the next Enter is genuine (the consult
        // disarmed it).
        if (imeService.consumeCommitKeySuppression()) {
          return (
            result: KeyEventResult.handled,
            handler: 'commitKeySuppressed',
            deferred: false,
            action: null,
          );
        }
        return (
          result: KeyEventResult.handled,
          handler: 'insertNewline',
          deferred: false,
          action: controller.insertNewline,
        );
      case LogicalKeyboardKey.escape:
        // ProseMirror's other suppressed key: an Escape arriving inside
        // the window is the keydown of the CANCEL that ended the
        // composition (WebKit's compositionend-before-keydown ordering),
        // and it must spend the one-shot so the user's next Enter splits.
        // Nothing here handles Escape, so it stays ignored either way —
        // only the arm is consumed (the consult journals the decision).
        return (
          result: KeyEventResult.ignored,
          handler: 'ignored',
          deferred: false,
          action: imeService.consumeCommitKeySuppression,
        );
      case LogicalKeyboardKey.backspace:
        // WebKit's ordering is not Enter-specific — it applies to EVERY
        // key the IME consumes to end a composition. The captured Safari
        // session: a lone composed `n` canceled with one Backspace
        // reflects the composing-clear snapshot FIRST (the n already
        // deleted), then the trailing Backspace keydown lands here with
        // the gate open and would eat a genuine character (the block's
        // period). Same consult, same one-shot.
        if (imeService.consumeCommitKeySuppression()) {
          return (
            result: KeyEventResult.handled,
            handler: 'commitKeySuppressed',
            deferred: false,
            action: null,
          );
        }
        return (
          result: KeyEventResult.handled,
          handler: 'backspace',
          deferred: false,
          action: controller.backspace,
        );
      case LogicalKeyboardKey.tab:
        // Tab cycles candidates in several IMEs and can end a composition
        // — the same exposure as Backspace: an unsuppressed trailing Tab
        // would indent/outdent the block the composition just ended in.
        if (imeService.consumeCommitKeySuppression()) {
          return (
            result: KeyEventResult.handled,
            handler: 'commitKeySuppressed',
            deferred: false,
            action: null,
          );
        }
        return pressed.isShiftPressed
            ? (
                result: KeyEventResult.handled,
                handler: 'outdent',
                deferred: false,
                action: controller.outdent,
              )
            : (
                result: KeyEventResult.handled,
                handler: 'indent',
                deferred: false,
                action: controller.indent,
              );
      // Arrows (and the unhandled Home/End) deliberately do NOT consult
      // the one-shot: a trailing post-compositionend arrow only moves the
      // caret — nothing destructive happens — and the selection change it
      // causes disarms a pending arm through the external-change path
      // anyway. Only keys our handlers act on destructively consult
      // (Enter/Backspace/Tab above; Escape spends the arm without
      // handling).
      case LogicalKeyboardKey.arrowLeft:
        return (
          result: KeyEventResult.handled,
          handler: 'moveCaretBack',
          deferred: false,
          action: () => controller.moveCaret(-1),
        );
      case LogicalKeyboardKey.arrowRight:
        return (
          result: KeyEventResult.handled,
          handler: 'moveCaretForward',
          deferred: false,
          action: () => controller.moveCaret(1),
        );
    }

    return ignored;
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
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerCancel,
          behavior: HitTestBehavior.opaque,
          // I-beam over editor content. Per-segment refinement (click over
          // links, basic over voids) is interactor-side, day 14.
          child: MouseRegion(
            cursor: SystemMouseCursors.text,
            // The IME's editable box is anchored to the caret/composing
            // region (ImeGeometryReporter), which scrolls with the content
            // — every scroll tick re-reports geometry (post-frame,
            // coalesced) so the engine's hidden input, and on web the IME
            // candidate window anchored to it, tracks the composition (the
            // day-15 re-send note; G15's metrics analogue).
            child: NotificationListener<ScrollNotification>(
              onNotification: (_) {
                imeService.scheduleGeometryReport();
                // While a drag is active, every scroll notification — wheel,
                // trackpad, or the autoscroll ticker — schedules a post-frame
                // re-hit-test under the stationary pointer so the extent
                // tracks the pointer's visual position (G5).
                if (_mouseInteractor.isDragging) _mouseInteractor.onScroll();
                return false;
              },
              child: ScrollConfiguration(
                // Force mouse out of the scrollable's drag devices so mouse
                // drag-select is never claimed by it (architecture §Gestures:
                // the dragDevices-excludes-mouse invariant). We keep the
                // ambient behavior's scrollbars/overscroll but override
                // dragDevices, so an app that enabled mouse-drag scrolling
                // (common on web) cannot reintroduce the two-writers
                // pathology under the editor.
                behavior: ScrollConfiguration.of(context).copyWith(
                  dragDevices: const {
                    PointerDeviceKind.touch,
                    PointerDeviceKind.stylus,
                    PointerDeviceKind.invertedStylus,
                  },
                ),
                child: CustomScrollView(
                  controller: _scrollController,
                  slivers: [sliver],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
