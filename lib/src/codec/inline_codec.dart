/// Encode/decode logic for one inline style in one format.
///
/// Register on [InlineStyleDef.codecs] keyed by [Format].
///
/// **Simple styles** (bold, italic, strikethrough): use [wrap] for symmetric
/// delimiters. The format orchestrator handles wrapping on encode and regex
/// construction on decode.
///
/// **Data-carrying styles** (links, mentions): use [encode] and [decode]
/// functions. These receive/produce the segment's [attributes] map.
class InlineCodec {
  const InlineCodec({this.wrap, this.encode, this.decode});

  /// Symmetric delimiter for this style (e.g. `'**'` for bold).
  /// The orchestrator wraps content as `'$wrap$text$wrap'` on encode,
  /// and builds a combined regex from all registered wraps on decode.
  final String? wrap;

  /// Full encode function for asymmetric / data-carrying styles.
  /// Receives the text content and the segment's attributes map.
  /// Returns the encoded string (e.g. `'[text](url)'` for links).
  final String Function(String text, Map<String, dynamic> attributes)? encode;

  /// Full decode function for asymmetric / data-carrying styles.
  /// Given a raw string, returns a match if this style is found at the start,
  /// or null if no match.
  final InlineDecodeMatch? Function(String text)? decode;
}

/// Result of a successful inline decode match.
class InlineDecodeMatch {
  const InlineDecodeMatch({
    required this.text,
    required this.fullMatchLength,
    this.attributes = const {},
  });

  /// The decoded display text (e.g. 'click here' from '[click here](url)').
  final String text;

  /// How many characters of the source string this match consumed.
  final int fullMatchLength;

  /// Extracted attributes (e.g. `{'url': 'https://...'}` for links).
  final Map<String, dynamic> attributes;
}
