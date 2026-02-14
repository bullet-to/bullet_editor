import 'package:flutter/widgets.dart';

import '../model/block.dart';
import '../model/document.dart';
import '../model/inline_style.dart';
import '../schema/editor_schema.dart';
import 'offset_mapper.dart';

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
TextSpan buildDocumentSpan(
  Document doc,
  TextStyle? style,
  EditorSchema schema,
) {
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

    final block = flat[i];
    final bStyle = _blockBaseStyle(block.blockType, style, schema);

    final def = schema.blockDef(block.blockType);

    // Void blocks (e.g. divider): the WidgetSpan IS the entire visual content.
    // No text spans are emitted — the prefix occupies the full line.
    if (def.isVoid && hasPrefix(doc, i, schema)) {
      final prefixWidget = def.prefixBuilder?.call(doc, i, block);
      children.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: prefixWidget ?? const SizedBox.shrink(),
        ),
      );
      continue;
    }

    // Visual prefix: bullet, number, checkbox, or indentation spacer.
    if (hasPrefix(doc, i, schema)) {
      final depth = doc.depthOf(i);
      final prefixWidget = def.prefixBuilder?.call(doc, i, block);
      children.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: SizedBox(width: 20.0 + (depth * 16.0), child: prefixWidget),
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
TextStyle? _blockBaseStyle(
  BlockType type,
  TextStyle? base,
  EditorSchema schema,
) {
  final def = schema.blockDef(type);
  return def.baseStyle?.call(base) ?? base;
}

/// Resolve inline styles into a TextStyle via schema lookup.
/// Passes segment [attributes] through for data-carrying styles.
TextStyle? _resolveStyle(
  Set<InlineStyle> styles,
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
