import '../model/block.dart';
import '../model/document.dart';
import '../model/inline_style.dart';

/// Minimal markdown codec: paragraphs + bold only.
///
/// Encode: wrap bold segments in **, join blocks with double newline.
/// Decode: split on double newline, parse **...** patterns.
class MarkdownCodec {
  /// Encode a [Document] to a markdown string.
  String encode(Document doc) {
    return doc.blocks.map(_encodeBlock).join('\n\n');
  }

  /// Decode a markdown string to a [Document].
  Document decode(String markdown) {
    if (markdown.isEmpty) return Document.empty();

    final paragraphs = markdown.split('\n\n');
    final blocks = paragraphs.map(_decodeBlock).toList();
    return Document(blocks);
  }

  String _encodeBlock(TextBlock block) {
    final buffer = StringBuffer();
    for (final segment in block.segments) {
      if (segment.styles.contains(InlineStyle.bold)) {
        buffer.write('**${segment.text}**');
      } else {
        buffer.write(segment.text);
      }
    }
    return buffer.toString();
  }

  TextBlock _decodeBlock(String text) {
    final segments = <StyledSegment>[];
    final pattern = RegExp(r'\*\*([^*]+)\*\*');
    var pos = 0;

    for (final match in pattern.allMatches(text)) {
      // Text before the match (unstyled).
      if (match.start > pos) {
        segments.add(StyledSegment(text.substring(pos, match.start)));
      }
      // Bold text.
      segments.add(StyledSegment(match.group(1)!, {InlineStyle.bold}));
      pos = match.end;
    }

    // Trailing text after last match.
    if (pos < text.length) {
      segments.add(StyledSegment(text.substring(pos)));
    }

    // If no segments were created, add a single empty segment.
    if (segments.isEmpty) {
      segments.add(const StyledSegment(''));
    }

    return TextBlock(id: generateBlockId(), segments: segments);
  }
}
