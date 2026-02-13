/// Inline formatting styles that can be applied to text segments.
///
/// Simple styles (bold, italic, strikethrough) are on/off flags.
/// Data-carrying styles (link) use the style flag plus
/// [StyledSegment.attributes] for their data (e.g. `{'url': '...'}`).
enum InlineStyle {
  bold,
  italic,
  strikethrough,
  link,
}
