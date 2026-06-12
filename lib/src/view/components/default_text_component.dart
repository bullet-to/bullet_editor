import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../model/inline_entity.dart';
import '../block_component_context.dart';
import '../block_layout_registry.dart';
import '../editor_view_scope.dart';

/// Implements the [BlockGeometry] contract over the `RenderParagraph` of a
/// component's `RichText` child, and handles registry lifecycle.
///
/// This is the piece a custom text-like component must never re-derive:
/// provide [geometryBlockId] and attach [richTextKey] to your `RichText`,
/// and the mixin registers/answers geometry for you. (Both reference editors
/// export exactly this seam: appflowy's `SelectableMixin`, super_editor's
/// `TextComponent`.)
mixin BlockGeometryMixin<T extends StatefulWidget> on State<T>
    implements BlockGeometry {
  /// Attach to the component's `RichText` child.
  final GlobalKey richTextKey = GlobalKey();

  /// The id of the block this component renders.
  String get geometryBlockId;

  BlockLayoutRegistry? _registry;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final registry = EditorViewScope.maybeOf(context)?.registry;
    if (!identical(registry, _registry)) {
      _registry?.unregister(geometryBlockId, this);
      _registry = registry;
      _registry?.register(geometryBlockId, this);
    }
  }

  /// Call from `didUpdateWidget` when the rendered block id changed.
  void geometryBlockIdChanged(String oldId) {
    _registry?.unregister(oldId, this);
    _registry?.register(geometryBlockId, this);
  }

  @override
  void dispose() {
    _registry?.unregister(geometryBlockId, this);
    _registry = null;
    super.dispose();
  }

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

/// The public, parameterizable text component (architecture §Rendering).
///
/// Renders a real `RichText` child — `RenderParagraph` contributes the
/// attributed label, locale/direction, and per-link tappable semantics child
/// nodes (D4), because link spans carry real [TapGestureRecognizer]s whose
/// lifecycle this State owns (D3). Selection/squiggle/composing/caret
/// painters layer around the child (days 3–13). Geometry comes from
/// [BlockGeometryMixin] over the child's `RenderParagraph` (GATE-L).
class DefaultTextComponent extends StatefulWidget {
  const DefaultTextComponent(
    this.componentContext, {
    super.key,
    this.background,
    this.padding,
  });

  final BlockComponentContext componentContext;

  /// Optional fill behind the text (the callout-extension seam).
  final Color? background;

  /// Optional padding inside the background.
  final EdgeInsetsGeometry? padding;

  @override
  State<DefaultTextComponent> createState() => _DefaultTextComponentState();
}

class _DefaultTextComponentState extends State<DefaultTextComponent>
    with BlockGeometryMixin {
  /// Link recognizers cached across per-keystroke rebuilds, keyed by
  /// segment start offset + entity key; disposed on unmount (the standard
  /// `TextSpan.recognizer` obligation).
  final Map<String, TapGestureRecognizer> _linkRecognizers = {};
  final Set<String> _recognizersUsedThisBuild = {};

  @override
  String get geometryBlockId => widget.componentContext.block.id;

  @override
  void didUpdateWidget(DefaultTextComponent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.componentContext.block.id !=
        widget.componentContext.block.id) {
      geometryBlockIdChanged(oldWidget.componentContext.block.id);
    }
  }

  @override
  void dispose() {
    for (final recognizer in _linkRecognizers.values) {
      recognizer.dispose();
    }
    super.dispose();
  }

  TapGestureRecognizer _recognizerFor(
    String cacheKey,
    String entityKey,
    int start,
    int end,
    String text,
    Map<String, dynamic> attributes,
  ) {
    _recognizersUsedThisBuild.add(cacheKey);
    final recognizer = _linkRecognizers.putIfAbsent(
      cacheKey,
      TapGestureRecognizer.new,
    );
    recognizer.onTap = () {
      widget.componentContext.onLinkTap?.call(
        widget.componentContext.block.id,
        start,
        InlineEntitySnapshot(
          key: entityKey,
          start: start,
          end: end,
          text: text,
          attributes: attributes,
        ),
      );
    };
    return recognizer;
  }

  void _disposeStaleRecognizers() {
    final stale = _linkRecognizers.keys
        .where((key) => !_recognizersUsedThisBuild.contains(key))
        .toList();
    for (final key in stale) {
      _linkRecognizers.remove(key)!.dispose();
    }
    _recognizersUsedThisBuild.clear();
  }

  TextSpan _buildSpan() {
    final ctx = widget.componentContext;
    final block = ctx.block;
    final schema = ctx.schema;

    final children = <InlineSpan>[];
    var offset = 0;
    for (final segment in block.segments) {
      var style = ctx.resolvedStyle;
      String? entityKey;
      for (final styleKey in segment.styles) {
        style = schema
            .inlinePresentationDef(styleKey)
            .applyStyle(style, attributes: segment.attributes);
        if (schema.inlineEntityDef(styleKey) != null) {
          entityKey = styleKey as String;
        }
      }

      TapGestureRecognizer? recognizer;
      if (entityKey != null) {
        recognizer = _recognizerFor(
          '$offset|$entityKey',
          entityKey,
          offset,
          offset + segment.text.length,
          segment.text,
          segment.attributes,
        );
      }

      children.add(
        TextSpan(text: segment.text, style: style, recognizer: recognizer),
      );
      offset += segment.text.length;
    }

    return TextSpan(style: ctx.resolvedStyle, children: children);
  }

  @override
  Widget build(BuildContext context) {
    final ctx = widget.componentContext;
    final span = _buildSpan();
    _disposeStaleRecognizers();

    Widget text = RichText(
      key: richTextKey,
      text: span,
      textScaler: MediaQuery.textScalerOf(context),
    );

    if (widget.padding != null || widget.background != null) {
      text = Container(
        width: double.infinity,
        padding: widget.padding,
        decoration: widget.background != null
            ? BoxDecoration(
                color: widget.background,
                borderRadius: BorderRadius.circular(4),
              )
            : null,
        child: text,
      );
    }

    final headingLevel = ctx.schema.blockDef(ctx.block.blockType).headingLevel;
    if (headingLevel != null) {
      text = Semantics(header: true, child: text);
    }

    return text;
  }
}
