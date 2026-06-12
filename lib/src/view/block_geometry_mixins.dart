import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'block_layout_registry.dart';
import 'editor_view_scope.dart';

/// Registry lifecycle for any component State implementing [BlockGeometry]
/// (GATE-L): registers on mount, re-registers when [geometryBlockId]
/// changes across widget updates, deregisters on dispose. Geometry queries
/// are left to a sibling mixin — [BlockGeometryMixin] for text components,
/// `VoidBlockGeometry` for voids.
mixin BlockGeometryRegistration<T extends StatefulWidget> on State<T>
    implements BlockGeometry {
  /// The id of the block this component renders.
  String get geometryBlockId;

  BlockLayoutRegistry? _registry;
  String? _registeredId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final registry = EditorViewScope.maybeOf(context)?.registry;
    if (!identical(registry, _registry)) {
      _unregister();
      _registry = registry;
      _register();
    }
  }

  @override
  void didUpdateWidget(covariant T oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-register when the rendered block id changed — owned here so no
    // component (including third-party ones) can forget it and serve stale
    // geometry under block-id reuse.
    if (_registeredId != geometryBlockId) {
      _unregister();
      _register();
    }
  }

  @override
  void dispose() {
    _unregister();
    _registry = null;
    super.dispose();
  }

  void _register() {
    _registry?.register(geometryBlockId, this);
    _registeredId = geometryBlockId;
  }

  void _unregister() {
    final id = _registeredId;
    if (id != null) _registry?.unregister(id, this);
    _registeredId = null;
  }
}

/// Implements the [BlockGeometry] contract over the `RenderParagraph` of a
/// component's `RichText` child.
///
/// This is the piece a custom text-like component must never re-derive:
/// apply `with BlockGeometryRegistration, BlockGeometryMixin`, provide
/// [BlockGeometryRegistration.geometryBlockId], and attach [richTextKey] to
/// your `RichText`. (Both reference editors export exactly this seam:
/// appflowy's `SelectableMixin`, super_editor's `TextComponent`.)
mixin BlockGeometryMixin<T extends StatefulWidget>
    on BlockGeometryRegistration<T> {
  /// Attach to the component's `RichText` child.
  final GlobalKey richTextKey = GlobalKey();

  RenderParagraph? get _paragraph {
    final renderObject = richTextKey.currentContext?.findRenderObject();
    if (renderObject is! RenderParagraph || !renderObject.hasSize) return null;
    return renderObject;
  }

  @override
  Rect? rectForOffset(int offset) {
    final paragraph = _paragraph;
    if (paragraph == null) return null;
    final position = TextPosition(offset: offset);
    final caretOffset = paragraph.getOffsetForCaret(position, Rect.zero);
    final height = paragraph.getFullHeightForCaret(position);
    return caretOffset & Size(1, height);
  }

  @override
  List<Rect> rectsForRange(int start, int end) {
    final paragraph = _paragraph;
    if (paragraph == null) return const [];
    return paragraph
        .getBoxesForSelection(
          TextSelection(baseOffset: start, extentOffset: end),
        )
        .map((box) => box.toRect())
        .toList();
  }

  @override
  int offsetForLocalPoint(Offset point) {
    final paragraph = _paragraph;
    if (paragraph == null) return 0;
    return paragraph.getPositionForOffset(point).offset;
  }

  @override
  TextRange wordBoundaryAt(int offset) {
    final paragraph = _paragraph;
    if (paragraph == null) return TextRange.collapsed(offset);
    return paragraph.getWordBoundary(TextPosition(offset: offset));
  }

  @override
  RenderBox get renderBox =>
      richTextKey.currentContext!.findRenderObject()! as RenderBox;
}
