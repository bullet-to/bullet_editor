import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../model/inline_entity.dart';
import '../block_component_context.dart';
import '../block_layout_registry.dart';
import '../editor_view_scope.dart';

/// Registry lifecycle for any component implementing [BlockGeometry]:
/// registers on mount, re-registers when the rendered block id changes,
/// deregisters on dispose. Geometry queries are left to a sibling mixin —
/// [BlockGeometryMixin] for text components, `VoidBlockGeometry` for voids.
mixin BlockGeometryRegistration<T extends StatefulWidget> on State<T>
    implements BlockGeometry {
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
    with BlockGeometryRegistration, BlockGeometryMixin {
  /// Link recognizers cached across per-keystroke rebuilds, keyed by
  /// segment start offset + entity key; disposed on unmount (the standard
  /// `TextSpan.recognizer` obligation).
  final Map<String, TapGestureRecognizer> _linkRecognizers = {};
  final Set<String> _recognizersUsedThisBuild = {};

  Timer? _blinkTimer;
  bool _caretVisible = true;

  @override
  String get geometryBlockId => widget.componentContext.block.id;

  @override
  void initState() {
    super.initState();
    _syncBlink();
  }

  @override
  void didUpdateWidget(DefaultTextComponent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.componentContext.block.id !=
        widget.componentContext.block.id) {
      geometryBlockIdChanged(oldWidget.componentContext.block.id);
    }
    if (oldWidget.componentContext.caretOffset !=
        widget.componentContext.caretOffset) {
      // The caret is solid on arrival and on every move (standard rhythm).
      _caretVisible = true;
      _blinkTimer?.cancel();
      _blinkTimer = null;
      _syncBlink();
    }
  }

  void _syncBlink() {
    final hasCaret = widget.componentContext.caretOffset != null;
    if (hasCaret) {
      _blinkTimer ??= Timer.periodic(const Duration(milliseconds: 500), (_) {
        setState(() => _caretVisible = !_caretVisible);
      });
    } else {
      _blinkTimer?.cancel();
      _blinkTimer = null;
    }
  }

  @override
  void dispose() {
    _blinkTimer?.cancel();
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

    final caretOffset = ctx.caretOffset;
    if (caretOffset != null) {
      // The painter queries the RenderParagraph at paint time (post-layout)
      // through the geometry mixin — never during build.
      text = CustomPaint(
        foregroundPainter: _CaretPainter(
          geometry: this,
          offset: caretOffset,
          visible: _caretVisible,
          color:
              DefaultSelectionStyle.of(context).cursorColor ??
              ctx.resolvedStyle.color ??
              const Color(0xFF000000),
        ),
        child: text,
      );
    }

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

/// Paints the collapsed caret over the `RichText` child. Queries the caret
/// rect from [geometry] at paint time, when the paragraph is laid out.
class _CaretPainter extends CustomPainter {
  _CaretPainter({
    required this.geometry,
    required this.offset,
    required this.visible,
    required this.color,
  });

  final BlockGeometry geometry;
  final int offset;
  final bool visible;
  final Color color;

  static const _caretWidth = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (!visible) return;
    final rect = geometry.rectForOffset(offset);
    if (rect == null) return;
    final left = rect.left.clamp(0.0, size.width - _caretWidth);
    canvas.drawRect(
      Rect.fromLTWH(left, rect.top, _caretWidth, rect.height),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_CaretPainter old) =>
      offset != old.offset ||
      visible != old.visible ||
      color != old.color ||
      !identical(geometry, old.geometry);
}
