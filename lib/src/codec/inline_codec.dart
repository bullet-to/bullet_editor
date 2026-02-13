/// Encode/decode logic for one inline style in one format.
///
/// Register on [InlineStyleDef.codecs] keyed by [Format].
///
/// For symmetric delimiter styles (bold = `**`, italic = `*`, etc.),
/// use the [wrap] shorthand. The format orchestrator handles wrapping
/// on encode and regex construction on decode.
///
/// For asymmetric or data-carrying styles (links, mentions), add full
/// `encode`/`decode` function fields in a future extension.
class InlineCodec {
  const InlineCodec({this.wrap});

  /// Symmetric delimiter for this style (e.g. `'**'` for bold).
  /// The orchestrator wraps content as `'$wrap$text$wrap'` on encode,
  /// and builds a combined regex from all registered wraps on decode.
  final String? wrap;
}
