import 'package:flutter/widgets.dart';

import '../model/block.dart';
import '../model/document.dart';
import '../model/inline_style.dart';
import 'offset_mapper.dart';

/// Build a TextSpan tree from a Document for rendering in a TextField.
///
/// This is a pure function — no controller dependency. The controller's
/// buildTextSpan override delegates to this.
TextSpan buildDocumentSpan(Document doc, TextStyle? style) {
  final children = <InlineSpan>[];
  final flat = doc.allBlocks;

  for (var i = 0; i < flat.length; i++) {
    if (i > 0) {
      // Give the \n separator the style of the preceding block's last segment.
      // This prevents cursor "sticking" when the trailing text has different
      // font metrics (bold, larger size, etc.) than the default style.
      final prevBlock = flat[i - 1];
      var prevStyle = blockBaseStyle(prevBlock.blockType, style);
      if (prevBlock.segments.isNotEmpty) {
        prevStyle = resolveStyle(prevBlock.segments.last.styles, prevStyle);
      }
      children.add(TextSpan(text: '\n', style: prevStyle));
    }

    final block = flat[i];
    final bStyle = blockBaseStyle(block.blockType, style);

    // Visual prefix: bullet, number, checkbox, or indentation spacer.
    if (hasPrefix(doc, i)) {
      final depth = doc.depthOf(i);
      final prefixWidget = _buildPrefixContent(doc, i, block);
      children.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: SizedBox(
            width: 20.0 + (depth * 16.0),
            child: prefixWidget,
          ),
        ),
      );
    }

    if (block.segments.isEmpty) {
      children.add(TextSpan(text: '', style: bStyle));
    } else {
      for (final seg in block.segments) {
        children.add(
          TextSpan(
            text: seg.text,
            style: resolveStyle(seg.styles, bStyle),
          ),
        );
      }
    }
  }

  return TextSpan(style: style, children: children);
}

/// Build the prefix content widget for a block's WidgetSpan.
Widget? _buildPrefixContent(Document doc, int flatIndex, TextBlock block) {
  const prefixStyle = TextStyle(fontSize: 14, color: Color(0xFF666666));

  switch (block.blockType) {
    case BlockType.listItem:
      return const Text('•  ', textAlign: TextAlign.right, style: prefixStyle);

    case BlockType.numberedList:
      final ordinal = _computeOrdinal(doc, flatIndex);
      return Text(
        '$ordinal.  ',
        textAlign: TextAlign.right,
        style: prefixStyle,
      );

    case BlockType.taskItem:
      final checked = block.metadata['checked'] == true;
      return Text(
        checked ? '☑  ' : '☐  ',
        textAlign: TextAlign.right,
        style: prefixStyle,
      );

    default:
      return null; // Indentation spacer only (nested paragraph).
  }
}

/// Compute the 1-based ordinal for a numbered list item among its siblings.
int _computeOrdinal(Document doc, int flatIndex) {
  // Walk backwards through siblings to count consecutive numbered list items.
  var ordinal = 1;
  final flat = doc.allBlocks;
  final depth = doc.depthOf(flatIndex);

  for (var j = flatIndex - 1; j >= 0; j--) {
    if (doc.depthOf(j) != depth) break;
    if (flat[j].blockType != BlockType.numberedList) break;
    ordinal++;
  }
  return ordinal;
}

/// Get the base TextStyle for a block type (e.g. H1 gets larger font).
TextStyle? blockBaseStyle(BlockType type, TextStyle? base) {
  switch (type) {
    case BlockType.h1:
      return (base ?? const TextStyle()).copyWith(
        fontSize: 24,
        fontWeight: FontWeight.bold,
        height: 1.3,
      );
    case BlockType.listItem:
    case BlockType.numberedList:
    case BlockType.taskItem:
    case BlockType.paragraph:
      return base;
  }
}

/// Resolve inline styles (bold, italic, strikethrough) into a TextStyle.
TextStyle? resolveStyle(Set<InlineStyle> styles, TextStyle? base) {
  if (styles.isEmpty) return base;
  var result = base ?? const TextStyle();
  if (styles.contains(InlineStyle.bold)) {
    result = result.copyWith(fontWeight: FontWeight.bold);
  }
  if (styles.contains(InlineStyle.italic)) {
    result = result.copyWith(fontStyle: FontStyle.italic);
  }
  if (styles.contains(InlineStyle.strikethrough)) {
    result = result.copyWith(decoration: TextDecoration.lineThrough);
  }
  return result;
}
