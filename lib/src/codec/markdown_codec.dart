import '../model/block.dart';
import '../model/document.dart';
import '../model/inline_style.dart';

/// Markdown codec: paragraphs, H1, list items, bold.
///
/// Encode: block type determines prefix (# , - ), bold wrapped in **.
/// Decode: line prefix determines block type, ** patterns become bold.
class MarkdownCodec {
  String encode(Document doc) {
    return doc.blocks.map(_encodeBlock).join('\n\n');
  }

  Document decode(String markdown) {
    if (markdown.isEmpty) return Document.empty();
    final paragraphs = markdown.split('\n\n');
    return Document(paragraphs.map(_decodeBlock).toList());
  }

  String _encodeBlock(TextBlock block) {
    final content = _encodeSegments(block.segments);
    switch (block.blockType) {
      case BlockType.h1:
        return '# $content';
      case BlockType.listItem:
        return '- $content';
      case BlockType.paragraph:
        return content;
    }
  }

  String _encodeSegments(List<StyledSegment> segments) {
    final buffer = StringBuffer();
    for (final seg in segments) {
      if (seg.styles.contains(InlineStyle.bold)) {
        buffer.write('**${seg.text}**');
      } else {
        buffer.write(seg.text);
      }
    }
    return buffer.toString();
  }

  TextBlock _decodeBlock(String text) {
    // Detect block type from prefix.
    BlockType type;
    String content;

    if (text.startsWith('# ')) {
      type = BlockType.h1;
      content = text.substring(2);
    } else if (text.startsWith('- ')) {
      type = BlockType.listItem;
      content = text.substring(2);
    } else {
      type = BlockType.paragraph;
      content = text;
    }

    return TextBlock(
      id: generateBlockId(),
      blockType: type,
      segments: _decodeSegments(content),
    );
  }

  List<StyledSegment> _decodeSegments(String text) {
    final segments = <StyledSegment>[];
    final pattern = RegExp(r'\*\*([^*]+)\*\*');
    var pos = 0;

    for (final match in pattern.allMatches(text)) {
      if (match.start > pos) {
        segments.add(StyledSegment(text.substring(pos, match.start)));
      }
      segments.add(StyledSegment(match.group(1)!, {InlineStyle.bold}));
      pos = match.end;
    }

    if (pos < text.length) {
      segments.add(StyledSegment(text.substring(pos)));
    }

    if (segments.isEmpty) {
      segments.add(const StyledSegment(''));
    }

    return segments;
  }
}
