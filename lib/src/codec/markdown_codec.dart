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
    var numberedOrdinal = 0;
    for (final block in blocks) {
      final content = _encodeSegments(block.segments);
      final indent = '  ' * depth;
      if (block.blockType == BlockType.numberedList) {
        numberedOrdinal++;
      } else {
        numberedOrdinal = 0;
      }
      switch (block.blockType) {
        case BlockType.h1:
          lines.add('$indent# $content');
        case BlockType.h2:
          lines.add('$indent## $content');
        case BlockType.h3:
          lines.add('$indent### $content');
        case BlockType.listItem:
          lines.add('$indent- $content');
        case BlockType.numberedList:
          lines.add('$indent$numberedOrdinal. $content');
        case BlockType.taskItem:
          final checked = block.metadata['checked'] == true;
          lines.add('$indent- [${checked ? 'x' : ' '}] $content');
        case BlockType.paragraph:
          lines.add('$indent$content');
      }
      _encodeBlocks(block.children, depth + 1, lines);
    }
  }

  String _encodeSegments(List<StyledSegment> segments) {
    final buffer = StringBuffer();
    for (final seg in segments) {
      var text = seg.text;
      // Wrap in delimiters from innermost to outermost.
      if (seg.styles.contains(InlineStyle.strikethrough)) {
        text = '~~$text~~';
      }
      if (seg.styles.contains(InlineStyle.italic)) {
        text = '*$text*';
      }
      if (seg.styles.contains(InlineStyle.bold)) {
        text = '**$text**';
      }
      buffer.write(text);
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
    Map<String, dynamic> metadata = const {};

    if (text.startsWith('### ')) {
      type = BlockType.h3;
      content = text.substring(4);
    } else if (text.startsWith('## ')) {
      type = BlockType.h2;
      content = text.substring(3);
    } else if (text.startsWith('# ')) {
      type = BlockType.h1;
      content = text.substring(2);
    } else if (text.startsWith('- [x] ')) {
      type = BlockType.taskItem;
      content = text.substring(6);
      metadata = {'checked': true};
    } else if (text.startsWith('- [ ] ')) {
      type = BlockType.taskItem;
      content = text.substring(6);
      metadata = {'checked': false};
    } else if (text.startsWith('- ')) {
      type = BlockType.listItem;
      content = text.substring(2);
    } else if (RegExp(r'^\d+\. ').hasMatch(text)) {
      type = BlockType.numberedList;
      content = text.replaceFirst(RegExp(r'^\d+\. '), '');
    } else {
      type = BlockType.paragraph;
      content = text;
    }

    return TextBlock(
      id: generateBlockId(),
      blockType: type,
      segments: _decodeSegments(content),
      metadata: metadata,
    );
  }

  /// Parse inline styles from text. Matches **bold**, ~~strikethrough~~, *italic*.
  /// Order matters: ** is checked before * to avoid ambiguity.
  List<StyledSegment> _decodeSegments(String text) {
    final segments = <StyledSegment>[];
    // Match bold (**), strikethrough (~~), then italic (*) — greedy on longer delimiters first.
    final pattern = RegExp(r'\*\*(.+?)\*\*|~~(.+?)~~|\*(.+?)\*');
    var pos = 0;

    for (final match in pattern.allMatches(text)) {
      if (match.start > pos) {
        segments.add(StyledSegment(text.substring(pos, match.start)));
      }
      if (match.group(1) != null) {
        segments.add(StyledSegment(match.group(1)!, {InlineStyle.bold}));
      } else if (match.group(2) != null) {
        segments
            .add(StyledSegment(match.group(2)!, {InlineStyle.strikethrough}));
      } else if (match.group(3) != null) {
        segments.add(StyledSegment(match.group(3)!, {InlineStyle.italic}));
      }
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
