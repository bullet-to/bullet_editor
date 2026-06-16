import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart' show BrowserContextMenu;
import 'package:flutter/widgets.dart';

import '../editor/editor_controller.dart';
import '../input/ime_service.dart';
import '../model/inline_entity.dart';
import 'block_layout_registry.dart';
import 'block_list_view.dart';
import 'editor_view_scope.dart';
import 'keyboard_interactor.dart';
import 'menus/context_menus.dart';
import 'mouse_interactor.dart';
import 'selection_handles.dart';
import 'selection_magnifier.dart';
import 'touch_interactor.dart';

/// The v3 editor root widget: lazy render through the component registry,
/// geometry registry (GATE-L), focus, tap-to-caret, caret + composing
/// painting, the IME path (days 5–8 — character input arrives through
/// [ImeService], never as key events: engine deltas on delta platforms,
/// diffed full-value snapshots behind the web fallback, per [imeFrontend]),
/// and the hardware-key matrix the IME doesn't own behind the full composing
/// gate — Enter, Backspace, Tab, undo/redo, ←/→ grapheme movement, ↑/↓
/// vertical movement, Cmd/Ctrl line/document boundaries, Shift extension, and
/// Alt+↑/↓ `MoveBlock`. Selection gestures route to [MouseInteractor] and key
/// events to [KeyboardInteractor] (symmetric per-concern extraction); touch
/// gestures arrive days 11–13.
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
  /// dispatch). Touch/stylus gestures route to [_touchInteractor].
  late final MouseInteractor _mouseInteractor = MouseInteractor(
    registry: registry,
    documentOf: () => widget.controller.document,
    isVoid: _isVoidBlock,
    setSelection: (selection) => widget.controller.setSelection(selection),
    requestFocus: () => widget.controller.requestFocus(),
    scrollPositionOf: _scrollPosition,
    viewportRectOf: _editorGlobalRect,
  );

  /// Touch/stylus selection gestures (architecture §Gestures, per-kind
  /// dispatch): tap-to-caret, long-press word-select, long-press-drag
  /// extension, the G11 handle drag (pointer-route owned), and the source of
  /// truth for the handle / magnifier / toolbar overlays. Always mounted, so it
  /// owns the handle pointer route across a handle widget unmounting mid-drag.
  late final TouchInteractor _touchInteractor = TouchInteractor(
    registry: registry,
    documentOf: () => widget.controller.document,
    selectionOf: () => widget.controller.selection,
    isVoid: _isVoidBlock,
    setSelection: (selection) => widget.controller.setSelection(selection),
    requestFocus: () => widget.controller.requestFocus(),
    scrollPositionOf: _scrollPosition,
    viewportRectOf: _editorGlobalRect,
  );

  /// Touch/stylus pointer kinds — the per-kind acceptance gate on the
  /// interactor-owned recognizers (architecture §Gestures): mouse-kind never
  /// reaches them (it drives the mouse interactor off the raw Listener), so a
  /// mouse press-drag is unaffected and a plain touch drag without a long-press
  /// still falls through to the scrollable.
  static const _touchKinds = {
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
  };

  /// The interactor-owned recognizers that put touch/stylus gestures in the
  /// gesture arena (architecture §Gestures arena participation): the tap fires
  /// only when the scrollable loses the arena, and the long-press win
  /// suppresses the scroll drag for that pointer and drives word
  /// drag-extension. A bare `Listener` cannot deny an accepted drag recognizer,
  /// so without these a finger drift after long-press would scroll the list
  /// under the live selection. Hosted by the [RawGestureDetector] in [build]
  /// (the mechanism of Flutter's own `TextSelectionGestureDetector`).
  late final Map<Type, GestureRecognizerFactory> _touchGestures = {
    TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<
      TapGestureRecognizer
    >(
      () => TapGestureRecognizer(supportedDevices: _touchKinds),
      (recognizer) {
        recognizer.onTapUp = (details) {
          _touchInteractor.handleTap(details.globalPosition);
        };
      },
    ),
    LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<
      LongPressGestureRecognizer
    >(
      () => LongPressGestureRecognizer(supportedDevices: _touchKinds),
      (recognizer) {
        recognizer
          ..onLongPressStart = (details) {
            _touchInteractor.handleLongPressStart(details.globalPosition);
          }
          ..onLongPressMoveUpdate = (details) {
            _touchInteractor.handleLongPressMoveUpdate(details.globalPosition);
          }
          ..onLongPressEnd = (_) {
            _touchInteractor.handleLongPressEnd();
          };
      },
    ),
  };

  /// The touch interactor — exposed for handle/anchor geometry assertions in
  /// widget tests (the same role `imeService` plays for IME-delta tests).
  @visibleForTesting
  TouchInteractor get touchInteractorForTest => _touchInteractor;

  bool _isVoidBlock(String blockId) {
    final block = widget.controller.document.blockById(blockId);
    return block != null && widget.controller.schema.isVoid(block.blockType);
  }


  /// Hardware-key matrix behind the composing gate (architecture §hardware
  /// keyboard), symmetric with [_mouseInteractor]. Reads the controller/IME
  /// through getters so a controller swap is transparent.
  late final KeyboardInteractor _keyboardInteractor = KeyboardInteractor(
    controllerOf: () => widget.controller,
    imeServiceOf: () => imeService,
    registry: registry,
    scrollPositionOf: _scrollPosition,
    editorRectOf: _editorGlobalRect,
    isReadOnly: () => widget.readOnly,
    isMounted: () => mounted,
  );

  ScrollPosition? _scrollPosition() =>
      _scrollController.hasClients ? _scrollController.position : null;

  /// The editor's global rect — the autoscroll edge zone (mouse interactor)
  /// and the keyboard ensure-visible margin (B4) both measure against it.
  Rect? _editorGlobalRect() {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;
    return renderObject.localToGlobal(Offset.zero) & renderObject.size;
  }

  ScrollController? _ownedScrollController;
  FocusNode? _ownedFocusNode;

  ScrollController get _scrollController =>
      widget.scrollController ??
      (_ownedScrollController ??= ScrollController());

  FocusNode get _focusNode =>
      widget.focusNode ??
      (_ownedFocusNode ??= FocusNode(debugLabel: 'BulletEditor'));

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
    // Web: suppress the browser's own context menu over the page so our
    // (never-cut) fallback toolbar shows (architecture §Gestures web). Global
    // by API design — the editor is the page's primary text surface.
    if (kIsWeb) BrowserContextMenu.disableContextMenu();
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
    if (kIsWeb) BrowserContextMenu.enableContextMenu();
    _detach(widget.controller, _focusNode);
    _touchInteractor.dispose();
    _ownedScrollController?.dispose();
    _ownedFocusNode?.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    // The selection may have moved by any path (gesture, keyboard, or an app
    // call); the touch interactor is the overlays' source of truth, so poke it
    // to recompute handle/toolbar geometry off the new selection.
    _touchInteractor.onSelectionChanged();
    setState(() {});
  }

  void _onFocusChanged() {
    _syncImeAttachment();
    setState(() {}); // caret visibility
  }

  // --- Pointer dispatch by kind (architecture §Gestures). Mouse/trackpad
  // pointers drive the mouse interactor directly off the raw Listener
  // (click/drag/multi-click/shift-click + autoscroll). Touch/stylus selection
  // gestures go through the interactor-owned recognizers in the
  // RawGestureDetector below (arena participation: a long-press win suppresses
  // the scroll drag; a plain touch drag still scrolls) — the raw Listener
  // ignores them. The raw Listener is arena-exempt, so both compose with the
  // link-span recognizers — G11 invariant. Mouse drag does not fight the
  // scrollable: the editor pins a ScrollBehavior whose dragDevices exclude
  // mouse (see [build]). ---

  void _onPointerDown(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      _mouseInteractor.handlePointerDown(event);
    }
    // Touch/stylus downs are claimed by the RawGestureDetector's recognizers
    // (per-kind via supportedDevices); the raw Listener ignores them here.
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      _mouseInteractor.handlePointerMove(event);
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      _mouseInteractor.handlePointerUp(event);
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      _mouseInteractor.handlePointerCancel(event);
    }
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

    Widget editor = EditorViewScope(
      registry: registry,
      child: Focus(
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        onKeyEvent: (_, event) => _keyboardInteractor.handleKeyEvent(event),
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
                // tracks the pointer's visual position (G5). The touch
                // interactor's onScroll ALSO recomputes handle/toolbar
                // visibility on every tick (the shared scroll tick), so it
                // runs unconditionally.
                if (_mouseInteractor.isDragging) _mouseInteractor.onScroll();
                _touchInteractor.onScroll();
                return false;
              },
              // Arena participation for touch (architecture §Gestures): the
              // interactor's tap + long-press recognizers compete with the
              // scrollable's drag recognizer, so a long-press win suppresses
              // the scroll for that pointer (and drives word drag-extension)
              // while a plain touch drag still scrolls. Mouse-kind never
              // reaches these (supportedDevices), so the mouse path is
              // unaffected. behavior: translucent so the detector adds its
              // recognizers to the arena WITHOUT stealing the hit from the
              // scrollable/content beneath — a plain touch drag still reaches
              // the scrollable's drag recognizer (it competes, and wins absent
              // a long-press).
              child: RawGestureDetector(
                gestures: _touchGestures,
                behavior: HitTestBehavior.translucent,
                child: ScrollConfiguration(
                  // Force mouse out of the scrollable's drag devices so mouse
                  // drag-select is never claimed by it (architecture
                  // §Gestures: the dragDevices-excludes-mouse invariant). The
                  // set is the framework default MINUS mouse only — trackpad
                  // must stay in, or two-finger (trackpad-pan) scrolling dies
                  // with it (the day-10 manual-test regression B1). We keep the
                  // ambient behavior's scrollbars/overscroll but override
                  // dragDevices, so an app that enabled mouse-drag scrolling
                  // (common on web) cannot reintroduce the two-writers
                  // pathology under the editor.
                  behavior: ScrollConfiguration.of(context).copyWith(
                    dragDevices: const {
                      PointerDeviceKind.touch,
                      PointerDeviceKind.stylus,
                      PointerDeviceKind.invertedStylus,
                      PointerDeviceKind.trackpad,
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
      ),
    );

    // The fallback selection toolbar overlays the editor subtree (it mounts its
    // menu into the ambient Overlay via a ContextMenuController; the editor is
    // its anchor source). It coexists with the handle/magnifier overlay below.
    editor = SelectionToolbar(
      interactor: _touchInteractor,
      controllerOf: () => widget.controller,
      viewportRectOf: _editorGlobalRect,
      child: editor,
    );

    // Selection handles + magnifier sit in a Stack SIBLING to the scrollable
    // (not inside it), so they are NOT clipped by the scroll viewport while
    // their in-code viewport predicate governs visibility. The bulbs position
    // from global anchor rects converted to this Stack's local space via
    // [_overlayOrigin] (the Stack's own global top-left), so they remain
    // correct wherever the editor is placed in the app. A Stack here — rather
    // than the app Overlay — keeps the handle bulbs' opaque Listeners reliably
    // in the editor's hit-test path (G11 pointer-down exclusivity).
    return Stack(
      children: [
        Positioned.fill(child: editor),
        Positioned.fill(
          child: SelectionHandles(
            interactor: _touchInteractor,
            viewportRectOf: _editorGlobalRect,
            originOf: _overlayOrigin,
          ),
        ),
        Positioned.fill(
          child: SelectionMagnifier(
            interactor: _touchInteractor,
            originOf: _overlayOrigin,
          ),
        ),
      ],
    );
  }

  /// The global top-left of the editor's render box — the origin the overlay
  /// Stack's local coordinate space is measured from, so global anchor rects
  /// can be converted to Stack-local positions. Zero before layout.
  Offset _overlayOrigin() => _editorGlobalRect()?.topLeft ?? Offset.zero;
}
