import 'package:flutter/widgets.dart';

import '../model/document.dart';
import '../model/inline_entity.dart';
import '../schema/editor_schema.dart';
import 'block_layout_registry.dart';
import 'block_list_view.dart';
import 'editor_view_scope.dart';

/// The v3 editor root widget.
///
/// **Day 1–2 walking-skeleton surface**: read-only lazy render of a
/// [Document] through the component registry, with the geometry registry
/// mounted (GATE-L skeleton) and text/link semantics live (D4/D3). The
/// day 3–4 controller skeleton replaces [document]+[schema] with an
/// `EditorController` and adds focus, selection, and editing.
class BulletEditor extends StatefulWidget {
  const BulletEditor({
    super.key,
    required this.document,
    required this.schema,
    this.scrollController,
    this.textStyle,
    this.padding,
    this.onLinkTap,
  });

  final Document document;
  final EditorSchema schema;

  /// Optional — the editor owns one otherwise.
  final ScrollController? scrollController;

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
  /// blockId → geometry-or-null (GATE-L). Exposed for the inspector and,
  /// from day 3–4, for interactors and the IME geometry reporter.
  final BlockLayoutRegistry registry = BlockLayoutRegistry();

  ScrollController? _ownedScrollController;

  ScrollController get _scrollController =>
      widget.scrollController ??
      (_ownedScrollController ??= ScrollController());

  @override
  void initState() {
    super.initState();
    // GATE-K: schema validation at the editor boundary, debug-mode.
    assert(widget.schema.validate());
  }

  @override
  void dispose() {
    _ownedScrollController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseStyle = widget.textStyle ?? DefaultTextStyle.of(context).style;

    Widget sliver = BlockListView(
      document: widget.document,
      schema: widget.schema,
      baseStyle: baseStyle,
      onLinkTap: widget.onLinkTap,
    );
    if (widget.padding != null) {
      sliver = SliverPadding(padding: widget.padding!, sliver: sliver);
    }

    return EditorViewScope(
      registry: registry,
      child: CustomScrollView(controller: _scrollController, slivers: [sliver]),
    );
  }
}
