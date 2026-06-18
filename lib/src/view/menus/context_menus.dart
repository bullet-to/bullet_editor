import 'dart:async';

import 'package:flutter/material.dart'
    show
        AdaptiveTextSelectionToolbar,
        ContextMenuButtonItem,
        ContextMenuButtonType;
import 'package:flutter/services.dart'
    show DefaultProcessTextService, ProcessTextAction, ProcessTextService;
import 'package:flutter/widgets.dart';

import '../../editor/editor_controller.dart';
import '../touch_interactor.dart';

/// Feel-tunable gap between the selection's top edge and the toolbar's bottom
/// (the toolbar floats above the selection, native convention).
const double _kToolbarGap = 8.0;

/// The Flutter-drawn fallback selection toolbar (architecture §Context menus:
/// launch-critical, never-cut, built with the days-11–13 touch work). Wires
/// `AdaptiveTextSelectionToolbar.buttonItems` through a [ContextMenuController]
/// (Copy / Cut / Paste / Select-All → controller methods).
///
/// **Anchor** = the bounding box of the laid-out selection rects (first/last
/// visible) → global → clamped to the viewport, via the interactor's
/// `selectionBoundsGlobal`. **Hide-on-fully-offscreen**: when no selected block
/// has a visible rect, `hideToolbar`; re-show when one re-enters — on the SAME
/// scroll tick that drives handle visibility (both notify off [interactor], so
/// the rebuild is shared). Showing is gated on a non-collapsed selection and no
/// live drag (the toolbar settles after the long-press/handle drag ends, native
/// behavior — a loupe is shown mid-drag instead).
///
/// On web the browser context menu is suppressed over the editor
/// (`BrowserContextMenu.disableContextMenu`, wired in `BulletEditorState`) so
/// ours shows.
class SelectionToolbar extends StatefulWidget {
  const SelectionToolbar({
    super.key,
    required this.interactor,
    required this.controllerOf,
    required this.viewportRectOf,
    required this.child,
  });

  final TouchInteractor interactor;
  final EditorController Function() controllerOf;

  /// The scroll viewport's visible global bounds — the anchor clamp + the
  /// hide-on-offscreen predicate.
  final Rect? Function() viewportRectOf;

  /// The editor subtree the toolbar overlays (the toolbar mounts into the
  /// ambient Overlay via the ContextMenuController, so this is passed through).
  final Widget child;

  @override
  State<SelectionToolbar> createState() => _SelectionToolbarState();
}

class _SelectionToolbarState extends State<SelectionToolbar> {
  final _menuController = ContextMenuController();

  /// The anchor the toolbar is currently shown at — so a scroll tick that
  /// leaves the anchor unchanged is a no-op instead of tearing down and
  /// rebuilding the whole Overlay entry every frame (review M3; the same dedup
  /// discipline the interactor's `_setSelection` and the handles' anchor cache
  /// already follow). Null when the toolbar is hidden.
  Offset? _shownAnchor;

  /// Android ProcessText actions (share, translate, dictionary, web search,
  /// "Ask Claude" …) — the system `PROCESS_TEXT` activities the stock text
  /// field shows. Queried once at mount; empty on platforms without the service
  /// (iOS/desktop/web/tests). Appended to the core verbs for native parity.
  final ProcessTextService _processText = DefaultProcessTextService();
  List<ProcessTextAction> _processActions = const [];

  @override
  void initState() {
    super.initState();
    widget.interactor.addListener(_sync);
    unawaited(_loadProcessActions());
  }

  /// Loads the system ProcessText actions once. Tolerant of platforms that don't
  /// implement the channel (the query throws there) — the list stays empty.
  Future<void> _loadProcessActions() async {
    try {
      final actions = await _processText.queryTextActions();
      if (mounted && actions.isNotEmpty) {
        setState(() => _processActions = actions);
      }
    } catch (_) {
      // No ProcessText service (iOS/desktop/web/tests) — leave the list empty.
    }
  }

  @override
  void didUpdateWidget(SelectionToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.interactor, widget.interactor)) {
      oldWidget.interactor.removeListener(_sync);
      widget.interactor.addListener(_sync);
    }
  }

  @override
  void dispose() {
    widget.interactor.removeListener(_sync);
    _menuController.remove();
    super.dispose();
  }

  /// Reconciles the toolbar against the interactor's state on every notify
  /// (selection change, drag start/end, scroll tick). Post-frame so the
  /// geometry it anchors to reflects the just-committed scroll/selection.
  void _sync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _reconcile();
    });
    // Request the frame the callback rides on. A notify at DRAG END (the loupe
    // hiding, the toolbar settling) dirties nothing on its own, so without this
    // the post-frame callback would not run until some unrelated event produced
    // a frame — the toolbar would appear only after, say, a focus change (device
    // finding). No-op mid-frame / during an active drag (a frame is already due).
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _reconcile() {
    final interactor = widget.interactor;
    // Touch chrome only: the fallback toolbar shows after a touch long-press /
    // handle selection, never over a mouse drag-select (a desktop mouse
    // selection uses native/desktop affordances, arch §Context menus). And
    // while a drag is live, no toolbar — the magnifier shows instead; it
    // settles when the drag ends.
    if (!interactor.touchSelectionActive || interactor.isDragging) {
      _hide();
      return;
    }
    final bounds = interactor.selectionBoundsGlobal();
    final viewport = widget.viewportRectOf();
    // Hide-on-fully-offscreen: no visible selection rect ⇒ no anchor.
    if (bounds == null || viewport == null || !viewport.overlaps(bounds)) {
      _hide();
      return;
    }
    final anchor = _clampAnchor(bounds, viewport);
    // Dedup: the anchor hasn't moved since the last show ⇒ a scroll tick is a
    // no-op, not a full Overlay teardown/rebuild every frame (M3).
    if (_menuController.isShown && anchor == _shownAnchor) return;
    // Re-anchoring: remove first so the toolbar re-mounts cleanly at the new
    // anchor.
    _menuController.remove();
    _shownAnchor = anchor;
    _menuController.show(
      context: context,
      contextMenuBuilder: (context) => AdaptiveTextSelectionToolbar.buttonItems(
        anchors: TextSelectionToolbarAnchors(primaryAnchor: anchor),
        buttonItems: _buttonItems(),
      ),
    );
  }

  /// Removes the toolbar and clears the shown-anchor cache so the next show
  /// re-anchors. Idempotent.
  void _hide() {
    _shownAnchor = null;
    _menuController.remove();
  }

  /// The primary anchor: the selection's top-center, lifted by the gap, clamped
  /// into the viewport so an edge selection still shows the toolbar on-screen.
  Offset _clampAnchor(Rect bounds, Rect viewport) {
    final x = bounds.center.dx.clamp(viewport.left, viewport.right);
    final y = (bounds.top - _kToolbarGap).clamp(viewport.top, viewport.bottom);
    return Offset(x, y);
  }

  List<ContextMenuButtonItem> _buttonItems() {
    final controller = widget.controllerOf();
    return [
      ContextMenuButtonItem(
        type: ContextMenuButtonType.copy,
        onPressed: () {
          controller.copySelectionAsMarkdown();
          _hide();
        },
      ),
      ContextMenuButtonItem(
        type: ContextMenuButtonType.cut,
        onPressed: () {
          controller.cut();
          _hide();
        },
      ),
      ContextMenuButtonItem(
        type: ContextMenuButtonType.paste,
        onPressed: () {
          controller.pasteMarkdown();
          _hide();
        },
      ),
      ContextMenuButtonItem(
        type: ContextMenuButtonType.selectAll,
        onPressed: () {
          controller.selectAll();
          _hide();
        },
      ),
      // Native parity: the system ProcessText actions (share, dictionary, web
      // search, translate, "Ask Claude" …), in the overflow on Android.
      for (final action in _processActions)
        ContextMenuButtonItem(
          label: action.label,
          onPressed: () {
            final text = controller.selectedPlainText();
            _hide();
            if (text != null) unawaited(_runProcessAction(action.id, text));
          },
        ),
    ];
  }

  /// Runs an Android ProcessText action on the selected [text]. A non-null
  /// result is the transformed text (e.g. translate) and replaces the selection;
  /// a null result means the action handled itself (share, web search, "Ask
  /// Claude" — they open elsewhere) and the selection is left untouched.
  Future<void> _runProcessAction(String id, String text) async {
    try {
      // readOnly: false — the editor is editable, so transform actions may
      // return replacement text. (A read-only host is a future refinement.)
      final result = await _processText.processTextAction(id, text, false);
      if (result != null && mounted) widget.controllerOf().insertText(result);
    } catch (_) {
      // Action unavailable or cancelled — no-op.
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
