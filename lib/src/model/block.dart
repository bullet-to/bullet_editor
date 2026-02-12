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

/// A single block in the document. POC: always a paragraph.
///
/// Immutable. Use [copyWith] to produce modified versions.
class TextBlock {
  TextBlock({required this.id, this.segments = const []});

  final String id;
  final List<StyledSegment> segments;

  /// Plain text content of this block (no formatting).
  String get plainText => segments.map((s) => s.text).join();

  /// Total character length of this block's text.
  int get length => plainText.length;

  TextBlock copyWith({String? id, List<StyledSegment>? segments}) {
    return TextBlock(id: id ?? this.id, segments: segments ?? this.segments);
  }

  @override
  String toString() => 'TextBlock($id, segments: $segments)';
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
