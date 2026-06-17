import 'package:flutter/widgets.dart';

import '../editor/editor_controller.dart';
import 'menus/context_menus.dart';
import 'selection_handles.dart';
import 'selection_magnifier.dart';
import 'touch_interactor.dart';

/// Hosts the three touch-selection overlays — the fallback toolbar, the
/// selection handles, and the magnifier — around the editor [child], so the
/// editor widget's `build` stays gesture/scroll/IME wiring and this owns the
/// overlay layout (review M2).
///
/// The handles and magnifier sit in a [Stack] SIBLING to the scrollable (not
/// inside it), so they are NOT clipped by the scroll viewport while their
/// in-code viewport predicate governs visibility; the bulbs position from global
/// anchor rects converted to this Stack's local space via [editorRectOf]'s
/// top-left, so they remain correct wherever the editor is placed in the app. A
/// Stack here — rather than the app Overlay — keeps the handle bulbs' opaque
/// Listeners reliably in the editor's hit-test path (G11 pointer-down
/// exclusivity). The toolbar mounts into the ambient Overlay via its
/// ContextMenuController, with the editor subtree as its anchor source.
class SelectionOverlayHost extends StatelessWidget {
  const SelectionOverlayHost({
    super.key,
    required this.interactor,
    required this.controllerOf,
    required this.editorRectOf,
    required this.child,
  });

  final TouchInteractor interactor;
  final EditorController Function() controllerOf;

  /// The editor's global rect — the overlays' viewport-visibility predicate
  /// and the origin their global anchor rects convert against. Null before
  /// layout (overlays hide).
  final Rect? Function() editorRectOf;

  /// The editor core (gesture/scroll/IME subtree) the overlays surround.
  final Widget child;

  Offset _origin() => editorRectOf()?.topLeft ?? Offset.zero;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: SelectionToolbar(
            interactor: interactor,
            controllerOf: controllerOf,
            viewportRectOf: editorRectOf,
            child: child,
          ),
        ),
        Positioned.fill(
          child: SelectionHandles(
            interactor: interactor,
            viewportRectOf: editorRectOf,
            originOf: _origin,
          ),
        ),
        Positioned.fill(
          child: SelectionMagnifier(interactor: interactor, originOf: _origin),
        ),
      ],
    );
  }
}
