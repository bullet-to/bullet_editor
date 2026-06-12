import '../model/block.dart';

/// Context provided to block encoders.
///
/// Contains pre-computed values the encoder may need: depth/indentation,
/// ordinal position (for numbered lists), and the inline-encoded content
/// string (segments already serialized by the format's inline codecs).
class EncodeContext {
  const EncodeContext({
    required this.depth,
    required this.indent,
    required this.ordinal,
    required this.content,
  });

  /// Nesting depth (0 = top-level).
  final int depth;

  /// Pre-computed indentation string (e.g. '  ' * depth for markdown).
  final String indent;

  /// 1-based ordinal among consecutive siblings of the same type.
  /// 0 if not applicable (non-numbered blocks).
  final int ordinal;

  /// Inline-encoded segment text. Block codecs wrap this with a prefix
  /// (e.g. `'# $content'`) — they don't touch inline encoding.
  final String content;
}

/// Encode/decode logic for one block type in one format.
///
/// Register on [BlockDef.codecs] keyed by [Format].
class BlockCodec {
  const BlockCodec({required this.encode, this.decode, this.decodeFenced});

  /// Encode a block to a format string. The [ctx] provides depth, ordinal,
  /// and pre-encoded inline content.
  final String Function(TextBlock block, EncodeContext ctx) encode;

  /// Try to decode a line of input into this block type.
  /// Return a [DecodeMatch] if the line matches, null otherwise.
  /// The orchestrator tries decoders in schema registration order.
  final DecodeMatch? Function(String line)? decode;

  /// Decode a fenced region (``` / ~~~) into this block type. Declaring this
  /// makes the type the schema's fence target. [info] is the fence info
  /// string (e.g. the language), [content] the literal text between fences —
  /// it bypasses inline decoding.
  ///
  /// Recorded limitation: the fence *grammar* (delimiters, region splitting)
  /// stays in [MarkdownCodec]; custom multi-line block shapes beyond fences
  /// (front-matter, math environments) need a region-decode contract that is
  /// deliberately post-launch.
  final DecodeMatch? Function(String info, String content)? decodeFenced;
}

/// Result of a successful block decode match.
class DecodeMatch {
  const DecodeMatch(this.content, {this.metadata = const {}});

  /// The content text after stripping the block prefix.
  final String content;

  /// Additional metadata (e.g. `{'checked': true}` for task items).
  final Map<String, dynamic> metadata;
}
