import 'package:flutter/widgets.dart';

import '../model/block.dart';
import '../model/document.dart';
import '../schema/default_schema.dart'
    show indentPerDepth, kFallbackFontSize, prefixWidth;
import '../schema/editor_schema.dart';
import 'offset_mapper.dart' show hasPrefix, hasSpacerBefore, spacerChar;

/// Callback when a prefix widget (bullet, checkbox, etc.) is tapped.
typedef PrefixTapCallback = void Function(int flatIndex, TextBlock block);

/// Build a TextSpan tree from a Document for rendering in a TextField.
///
/// This is a pure function — no controller dependency. The controller's
/// buildTextSpan override delegates to this.
///
/// Rendering is driven by the [schema]: block base styles, prefix widgets,
/// and inline style resolution all come from schema lookups — no hardcoded
/// switch statements.
///
/// Link taps are NOT handled via TextSpan.recognizer — Flutter asserts
/// `readOnly` when recognizers are present on non-macOS platforms. Instead,
/// link taps are detected at the gesture level via the controller's
/// `segmentAtOffset` helper.
///
/// If [onPrefixTap] is provided, prefix widgets are wrapped in a
/// [GestureDetector] so taps on bullets/checkboxes/numbers fire the callback.
TextSpan buildDocumentSpan(
  Document doc,
  TextStyle? style,
  EditorSchema schema, {
  PrefixTapCallback? onPrefixTap,
}) {
  final children = <InlineSpan>[];
  final flat = doc.allBlocks;

  for (var i = 0; i < flat.length; i++) {
    if (i > 0) {
      // Give the \n separator the style of the preceding block's last segment.
      // This prevents cursor "sticking" when the trailing text has different
      // font metrics (bold, larger size, etc.) than the default style.
      final prevBlock = flat[i - 1];
      var prevStyle = _blockBaseStyle(prevBlock.blockType, style, schema);
      if (prevBlock.segments.isNotEmpty) {
        prevStyle = _resolveStyle(
          prevBlock.segments.last.styles,
          prevStyle,
          schema,
          attributes: prevBlock.segments.last.attributes,
        );
      }
      children.add(TextSpan(text: '\n', style: prevStyle));
    }

    // Spacer: a \u200C marker + styled \n that creates an empty line.
    // The spacerChar is distinct from prefixChar (\uFFFC) so cursor-skip
    // logic doesn't confuse a block separator \n after a prefix with
    // a spacer line break.
    if (hasSpacerBefore(doc, i, schema)) {
      final block = flat[i];
      final spacingEm = schema.blockDef(block.blockType).spacingBefore;
      final baseFontSize = style?.fontSize ?? kFallbackFontSize;
      final gapPx = baseFontSize * spacingEm;
      children.add(
        TextSpan(
          text: '$spacerChar\n',
          style: TextStyle(fontSize: gapPx, height: 1.0),
        ),
      );
    }

    final block = flat[i];
    final bStyle = _blockBaseStyle(block.blockType, style, schema);

    final def = schema.blockDef(block.blockType);

    // Void blocks (e.g. divider): the WidgetSpan IS the entire visual content.
    // No text spans are emitted — the prefix occupies the full line.
    if (def.isVoid && hasPrefix(doc, i, schema)) {
      final prefixWidget = def.prefixBuilder?.call(
        doc,
        i,
        block,
        bStyle ?? const TextStyle(),
      );
      children.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _wrapPrefixTap(
            prefixWidget ?? const SizedBox.shrink(),
            onPrefixTap,
            i,
            block,
          ),
        ),
      );
      continue;
    }

    // Visual prefix: bullet, number, checkbox, or indentation spacer.
    if (hasPrefix(doc, i, schema)) {
      final depth = doc.depthOf(i);
      final isNested = depth > 0;
      final isLL = schema.isListLike(block.blockType);
      final prefixWidget = def.prefixBuilder?.call(
        doc,
        i,
        block,
        bStyle ?? const TextStyle(),
      );

      // Derive indent spacing from the base font size (style param, not bStyle,
      // so indentation is consistent across block types).
      final baseFontSize = style?.fontSize ?? kFallbackFontSize;
      final ipdf = schema.indentPerDepthFactor;
      final pwf = schema.prefixWidthFactor;
      final indentPx = indentPerDepth(baseFontSize, ipdf);
      final prefixPx = prefixWidth(bStyle?.fontSize ?? baseFontSize, pwf);

      // List-like blocks: indent by depth, then show their prefix (bullet etc).
      // Non-list nested blocks: align text with the parent's text start,
      // using a zero-width WidgetSpan so the offset mapper still has a
      // placeholder char.
      final double indent;
      final Widget child;
      if (isLL || prefixWidget != null) {
        indent = depth * indentPx;
        child = _wrapPrefixTap(
          prefixWidget ?? SizedBox(width: prefixPx),
          onPrefixTap,
          i,
          block,
        );
      } else {
        // Nested non-list block: align with parent's text start.
        indent = isNested
            ? (depth - 1) * indentPx + prefixWidth(baseFontSize, pwf)
            : 0;
        child = const SizedBox.shrink();
      }

      children.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: EdgeInsets.only(left: indent),
            child: child,
          ),
        ),
      );
    }

    if (block.segments.isEmpty) {
      // Use zero-width space for empty blocks so the line has layout metrics
      // and the cursor renders on the correct line (not stuck on the previous).
      final placeholder = hasPrefix(doc, i, schema) ? '' : '\u200B';
      children.add(TextSpan(text: placeholder, style: bStyle));
    } else {
      for (final seg in block.segments) {
        children.add(
          TextSpan(
            text: seg.text,
            style: _resolveStyle(
              seg.styles,
              bStyle,
              schema,
              attributes: seg.attributes,
            ),
          ),
        );
      }
    }
  }

  return TextSpan(style: style, children: children);
}

/// Get the base TextStyle for a block type via schema lookup.
TextStyle? _blockBaseStyle(Object type, TextStyle? base, EditorSchema schema) {
  final def = schema.blockDef(type);
  return def.baseStyle?.call(base) ?? base;
}

/// Wrap a prefix widget in a [GestureDetector] if [onTap] is provided.
Widget _wrapPrefixTap(
  Widget child,
  PrefixTapCallback? onTap,
  int flatIndex,
  TextBlock block,
) {
  if (onTap == null) return child;
  return GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => onTap(flatIndex, block),
    child: child,
  );
}

/// Resolve inline styles into a TextStyle via schema lookup.
/// Passes segment [attributes] through for data-carrying styles.
TextStyle? _resolveStyle(
  Set<Object> styles,
  TextStyle? base,
  EditorSchema schema, {
  Map<String, dynamic> attributes = const {},
}) {
  if (styles.isEmpty) return base;
  var result = base ?? const TextStyle();
  for (final style in styles) {
    final def = schema.inlineStyleDef(style);
    result = def.applyStyle(result, attributes: attributes);
  }
  return result;
}
