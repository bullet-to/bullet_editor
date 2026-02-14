/// A run of text with uniform formatting.
///
/// The document's text content is stored as a list of these segments.
/// Adjacent segments with identical styles AND attributes should be merged.
///
/// [styles] holds on/off style flags (bold, italic, link, etc.).
/// Style keys are opaque [Object]s — use the built-in [InlineStyle] enum
/// or your own enum/class.
/// [attributes] holds data for styles that carry it (e.g. `{'url': '...'}`
/// for links, `{'userId': '...'}` for mentions).
class StyledSegment {
  const StyledSegment(this.text,
      [this.styles = const {}, this.attributes = const {}]);

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
      text, Object.hashAllUnordered(styles), Object.hashAll(attributes.entries));

  @override
  String toString() {
    if (styles.isEmpty) return 'Segment("$text")';
    final styleStr = styles.join(', ');
    if (attributes.isEmpty) return 'Segment("$text", $styleStr)';
    return 'Segment("$text", $styleStr, $attributes)';
  }
}

/// Built-in block type keys. Use these with the standard schema, or define
/// your own enum/class for custom block types.
enum BlockType { paragraph, h1, h2, h3, listItem, numberedList, taskItem, divider }

/// Built-in inline style keys. Use these with the standard schema, or define
/// your own enum/class for custom inline styles.
enum InlineStyle { bold, italic, strikethrough, link }

/// Standard metadata key for task item checked state.
const kCheckedKey = 'checked';

/// A single block in the document.
///
/// Immutable. Use [copyWith] to produce modified versions.
///
/// [B] is the block type key — typically an enum like [BlockType].
class TextBlock<B> {
  TextBlock({
    required this.id,
    required this.blockType,
    this.segments = const [],
    this.children = const [],
    this.metadata = const {},
  });

  final String id;
  final B blockType;
  final List<StyledSegment> segments;
  final List<TextBlock<B>> children;

  /// Arbitrary key-value metadata for the block.
  /// Used for task checked state (`'checked': true/false`), etc.
  final Map<String, dynamic> metadata;

  /// Plain text content of this block (no formatting).
  String get plainText => segments.map((s) => s.text).join();

  /// Total character length of this block's text.
  int get length => plainText.length;

  TextBlock<B> copyWith({
    String? id,
    B? blockType,
    List<StyledSegment>? segments,
    List<TextBlock<B>>? children,
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
          StyledSegment(prev.text + seg.text, prev.styles, prev.attributes));
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
