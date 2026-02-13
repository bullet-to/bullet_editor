import 'inline_style.dart';

/// A run of text with uniform formatting.
///
/// The document's text content is stored as a list of these segments.
/// Adjacent segments with identical styles should be merged.
class StyledSegment {
  const StyledSegment(this.text, [this.styles = const {}]);

  final String text;
  final Set<InlineStyle> styles;

  StyledSegment copyWith({String? text, Set<InlineStyle>? styles}) {
    return StyledSegment(text ?? this.text, styles ?? this.styles);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StyledSegment &&
          text == other.text &&
          _setsEqual(styles, other.styles);

  @override
  int get hashCode => Object.hash(text, Object.hashAllUnordered(styles));

  @override
  String toString() {
    if (styles.isEmpty) return 'Segment("$text")';
    return 'Segment("$text", ${styles.map((s) => s.name).join(', ')})';
  }
}

/// The type of a block. Determines rendering and behavior.
enum BlockType { paragraph, h1, h2, h3, listItem, numberedList, taskItem, divider }

/// Whether a block type behaves like a list item (nestable, gets a prefix,
/// shares enter/backspace/indent behavior).
bool isListLike(BlockType type) =>
    type == BlockType.listItem ||
    type == BlockType.numberedList ||
    type == BlockType.taskItem;

/// A single block in the document.
///
/// Immutable. Use [copyWith] to produce modified versions.
class TextBlock {
  TextBlock({
    required this.id,
    this.blockType = BlockType.paragraph,
    this.segments = const [],
    this.children = const [],
    this.metadata = const {},
  });

  final String id;
  final BlockType blockType;
  final List<StyledSegment> segments;
  final List<TextBlock> children;

  /// Arbitrary key-value metadata for the block.
  /// Used for task checked state (`'checked': true/false`), etc.
  final Map<String, dynamic> metadata;

  /// Plain text content of this block (no formatting).
  String get plainText => segments.map((s) => s.text).join();

  /// Total character length of this block's text.
  int get length => plainText.length;

  TextBlock copyWith({
    String? id,
    BlockType? blockType,
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

/// Merge adjacent segments that share the same style set.
///
/// This keeps the segment list normalized — no two consecutive segments
/// have identical styles. Called after any operation that modifies segments.
List<StyledSegment> mergeSegments(List<StyledSegment> segments) {
  if (segments.isEmpty) return segments;
  final result = <StyledSegment>[];
  for (final seg in segments) {
    if (seg.text.isEmpty) continue; // drop empty segments
    if (result.isNotEmpty && _setsEqual(result.last.styles, seg.styles)) {
      // Merge with previous
      final prev = result.removeLast();
      result.add(StyledSegment(prev.text + seg.text, prev.styles));
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
