import 'package:flutter/material.dart'
    show AdaptiveTextSelectionToolbar, ContextMenuButtonItem, ContextMenuButtonType;
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

  @override
  void initState() {
    super.initState();
    widget.interactor.addListener(_sync);
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
  }

  void _reconcile() {
    final interactor = widget.interactor;
    // Touch chrome only: the fallback toolbar shows after a touch long-press /
    // handle selection, never over a mouse drag-select (a desktop mouse
    // selection uses native/desktop affordances, arch §Context menus). And
    // while a drag is live, no toolbar — the magnifier shows instead; it
    // settles when the drag ends.
    if (!interactor.touchSelectionActive || interactor.isDragging) {
      _menuController.remove();
      return;
    }
    final bounds = interactor.selectionBoundsGlobal();
    final viewport = widget.viewportRectOf();
    // Hide-on-fully-offscreen: no visible selection rect ⇒ no anchor.
    if (bounds == null || viewport == null || !viewport.overlaps(bounds)) {
      _menuController.remove();
      return;
    }
    final anchor = _clampAnchor(bounds, viewport);
    // show() is idempotent-ish: re-showing rebuilds at the new anchor. Remove
    // first so the toolbar re-anchors cleanly on a scroll tick.
    _menuController.remove();
    _menuController.show(
      context: context,
      contextMenuBuilder: (context) => AdaptiveTextSelectionToolbar.buttonItems(
        anchors: TextSelectionToolbarAnchors(primaryAnchor: anchor),
        buttonItems: _buttonItems(),
      ),
    );
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
          _menuController.remove();
        },
      ),
      ContextMenuButtonItem(
        type: ContextMenuButtonType.cut,
        onPressed: () {
          controller.cut();
          _menuController.remove();
        },
      ),
      ContextMenuButtonItem(
        type: ContextMenuButtonType.paste,
        onPressed: () {
          controller.pasteMarkdown();
          _menuController.remove();
        },
      ),
      ContextMenuButtonItem(
        type: ContextMenuButtonType.selectAll,
        onPressed: () {
          controller.selectAll();
          _menuController.remove();
        },
      ),
    ];
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
