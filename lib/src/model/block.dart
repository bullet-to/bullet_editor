/// A run of text with uniform formatting.
///
/// The document's text content is stored as a list of these segments.
/// Adjacent segments with identical styles AND attributes should be merged.
///
/// [styles] holds on/off inline keys (bold, italic, link entity, etc.).
/// Keys are opaque [Object]s — use the built-in [InlineStyleKeys] /
/// [InlineEntityKeys] string constants, or your own keys.
/// [attributes] holds per-segment data for inline entities
/// (e.g. `{'url': '...'}` for links, `{'userId': '...'}` for mentions).
class StyledSegment {
  const StyledSegment(
    this.text, [
    this.styles = const {},
    this.attributes = const {},
  ]);

  final String text;
  final Set<Object> styles;

  /// Per-segment data for data-carrying styles (links, mentions, tags).
  /// Empty for simple styles like bold/italic.
  final Map<String, dynamic> attributes;

  StyledSegment copyWith({
    String? text,
    Set<Object>? styles,
    Map<String, dynamic>? attributes,
  }) {
    return StyledSegment(
      text ?? this.text,
      styles ?? this.styles,
      attributes ?? this.attributes,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StyledSegment &&
          text == other.text &&
          _setsEqual(styles, other.styles) &&
          _mapsEqual(attributes, other.attributes);

  @override
  int get hashCode => Object.hash(
    text,
    Object.hashAllUnordered(styles),
    Object.hashAll(attributes.entries),
  );

  @override
  String toString() {
    if (styles.isEmpty) return 'Segment("$text")';
    final styleStr = styles.join(', ');
    if (attributes.isEmpty) return 'Segment("$text", $styleStr)';
    return 'Segment("$text", $styleStr, $attributes)';
  }
}

// -- Built-in type keys --
//
// Block types, inline styles, and inline entities are addressed by string
// keys. These holders exist for typo-safety; custom block types register
// their own string keys in the schema.

abstract final class ParagraphKeys {
  static const type = 'paragraph';
}

abstract final class HeadingKeys {
  static const h1 = 'h1';
  static const h2 = 'h2';
  static const h3 = 'h3';
  static const h4 = 'h4';
  static const h5 = 'h5';
  static const h6 = 'h6';

  /// All heading keys, in level order.
  static const all = [h1, h2, h3, h4, h5, h6];
}

abstract final class ListItemKeys {
  static const type = 'listItem';
}

abstract final class NumberedListKeys {
  static const type = 'numberedList';
}

abstract final class TaskItemKeys {
  static const type = 'taskItem';
  static const checked = 'checked';
}

abstract final class BlockQuoteKeys {
  static const type = 'blockQuote';
}

abstract final class CodeBlockKeys {
  static const type = 'codeBlock';
  static const language = 'language';
}

abstract final class DividerKeys {
  static const type = 'divider';
}

abstract final class ImageKeys {
  static const type = 'image';

  /// Metadata key holding the image source URL (v2 markdown-codec shape).
  static const url = 'url';
}

abstract final class InlineStyleKeys {
  static const bold = 'bold';
  static const italic = 'italic';
  static const strikethrough = 'strikethrough';
  static const code = 'code';
}

abstract final class InlineEntityKeys {
  static const link = 'link';

  /// Attribute key holding a link's destination URL.
  static const linkUrl = 'url';
}

/// A single block in the document.
///
/// Immutable. Use [copyWith] to produce modified versions.
///
/// [blockType] is a string key registered in the schema (see [ParagraphKeys]
/// and friends for the built-in keys).
class TextBlock {
  TextBlock({
    required this.id,
    required this.blockType,
    this.segments = const [],
    this.children = const [],
    this.metadata = const {},
  });

  final String id;
  final String blockType;
  final List<StyledSegment> segments;
  final List<TextBlock> children;

  /// Arbitrary key-value metadata for the block.
  /// Used for task checked state (`TaskItemKeys.checked`), image source, etc.
  final Map<String, dynamic> metadata;

  /// Plain text content of this block (no formatting).
  String get plainText => segments.map((s) => s.text).join();

  /// Total character length of this block's text.
  int get length => plainText.length;

  TextBlock copyWith({
    String? id,
    String? blockType,
    List<StyledSegment>? segments,
    List<TextBlock>? children,
    Map<String, dynamic>? metadata,
  }) {
    return TextBlock(
      id: id ?? this.id,
      blockType: blockType ?? this.blockType,
      segments: segments ?? this.segments,
      children: children ?? this.children,
      metadata: metadata ?? this.metadata,
    );
  }

  @override
  String toString() => 'TextBlock($id, $blockType, segments: $segments)';
}

/// Merge adjacent segments that share the same styles AND attributes.
///
/// This keeps the segment list normalized — no two consecutive segments
/// have identical formatting. Called after any operation that modifies segments.
List<StyledSegment> mergeSegments(List<StyledSegment> segments) {
  if (segments.isEmpty) return segments;
  final result = <StyledSegment>[];
  for (final seg in segments) {
    if (seg.text.isEmpty) continue; // drop empty segments
    if (result.isNotEmpty &&
        _setsEqual(result.last.styles, seg.styles) &&
        _mapsEqual(result.last.attributes, seg.attributes)) {
      // Merge with previous
      final prev = result.removeLast();
      result.add(
        StyledSegment(prev.text + seg.text, prev.styles, prev.attributes),
      );
    } else {
      result.add(seg);
    }
  }
  return result;
}

bool _setsEqual<T>(Set<T> a, Set<T> b) {
  if (a.length != b.length) return false;
  return a.containsAll(b);
}

bool _mapsEqual(Map<String, dynamic> a, Map<String, dynamic> b) {
  if (a.length != b.length) return false;
  for (final key in a.keys) {
    if (!b.containsKey(key) || a[key] != b[key]) return false;
  }
  return true;
}
