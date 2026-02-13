import '../model/block.dart';
import '../model/document.dart';
import '../model/inline_style.dart';

/// Markdown codec: paragraphs, H1, list items (with nesting), bold.
///
/// Nested list items use 2-space indentation per level.
class MarkdownCodec {
  String encode(Document doc) {
    final lines = <String>[];
    _encodeBlocks(doc.blocks, 0, lines);
    return lines.join('\n\n');
  }

  Document decode(String markdown) {
    if (markdown.isEmpty) return Document.empty();
    final paragraphs = markdown.split('\n\n');

    // Parse each paragraph into (depth, block).
    final parsed = paragraphs.map((text) {
      var depth = 0;
      var remaining = text;
      while (remaining.startsWith('  ')) {
        depth++;
        remaining = remaining.substring(2);
      }
      return (depth, _decodeBlock(remaining));
    }).toList();

    // Build tree from flat (depth, block) list.
    return Document(_buildTree(parsed, 0));
  }

  void _encodeBlocks(List<TextBlock> blocks, int depth, List<String> lines) {
    for (final block in blocks) {
      final content = _encodeSegments(block.segments);
      final indent = '  ' * depth;
      switch (block.blockType) {
        case BlockType.h1:
          lines.add('$indent# $content');
        case BlockType.listItem:
          lines.add('$indent- $content');
        case BlockType.paragraph:
          lines.add('$indent$content');
      }
      _encodeBlocks(block.children, depth + 1, lines);
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

  /// Build a tree from a flat list of (depth, block) pairs.
  /// Recursively consumes entries at [minDepth] or deeper.
  List<TextBlock> _buildTree(List<(int, TextBlock)> items, int minDepth) {
    final result = <TextBlock>[];
    var i = 0;

    while (i < items.length) {
      final (depth, block) = items[i];
      if (depth < minDepth) break; // Back to parent level.

      // Collect children: items immediately following at depth + 1.
      i++;
      final childItems = <(int, TextBlock)>[];
      while (i < items.length && items[i].$1 > depth) {
        childItems.add(items[i]);
        i++;
      }

      final children = childItems.isEmpty
          ? const <TextBlock>[]
          : _buildTree(childItems, depth + 1);

      result.add(children.isEmpty ? block : block.copyWith(children: children));
    }

    return result;
  }

  TextBlock _decodeBlock(String text) {
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
