import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../../model/inline_entity.dart';
import '../block_component_context.dart';
import '../block_geometry_mixins.dart';
import '../block_layout_registry.dart';

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
    final composing = ctx.composing;
    if (caretOffset != null || composing != null) {
      // The painter queries the RenderParagraph at paint time (post-layout)
      // through the geometry mixin — never during build. One layer paints
      // composing underline then caret (§per-block painting order).
      text = CustomPaint(
        foregroundPainter: _CaretPainter(
          geometry: this,
          offset: caretOffset,
          visible: _caretVisible,
          composing: composing,
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

/// Paints the composing-region underline and the collapsed caret over the
/// `RichText` child. Queries rects from [geometry] at paint time, when the
/// paragraph is laid out.
///
/// The composing underline is painted by the framework — us — not the
/// keyboard (G3 visibility: `EditableText` styles `value.composing` itself;
/// without it CJK marked text looks committed and a deferred input rule is
/// indistinguishable from a swallowed one).
class _CaretPainter extends CustomPainter {
  _CaretPainter({
    required this.geometry,
    required this.offset,
    required this.visible,
    required this.color,
    this.composing,
  });

  final BlockGeometry geometry;

  /// Caret offset; null when only the composing underline paints.
  final int? offset;
  final bool visible;
  final Color color;

  /// Block-local composing range; null when no composition lives here.
  final TextRange? composing;

  static const _caretWidth = 2.0;
  static const _underlineThickness = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final composing = this.composing;
    if (composing != null && composing.isValid && !composing.isCollapsed) {
      final paint = Paint()..color = color;
      for (final rect in geometry.rectsForRange(
        composing.start,
        composing.end,
      )) {
        // A solid underline rect per line fragment of the composed range.
        canvas.drawRect(
          Rect.fromLTWH(
            rect.left,
            rect.bottom - _underlineThickness,
            rect.width,
            _underlineThickness,
          ),
          paint,
        );
      }
    }

    final offset = this.offset;
    if (offset == null || !visible) return;
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
      composing != old.composing ||
      !identical(geometry, old.geometry);
}
