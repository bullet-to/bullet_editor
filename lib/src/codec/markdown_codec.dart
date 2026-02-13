import '../model/block.dart';
import '../model/document.dart';
import '../model/inline_style.dart';
import '../schema/editor_schema.dart';
import 'block_codec.dart';
import 'format.dart';
import 'inline_codec.dart';

/// Markdown codec: encode/decode documents using schema-driven block and
/// inline codecs.
///
/// Block-level formatting (prefixes like `# `, `- `, etc.) is delegated to
/// each block type's [BlockCodec] registered under [Format.markdown].
/// Inline formatting (delimiters like `**`, `*`, `~~`) is delegated to each
/// inline style's [InlineCodec] registered under [Format.markdown].
///
/// This class owns the format-level grammar: paragraph splitting (`\n\n`),
/// indentation (2-space nesting), and tree building.
class MarkdownCodec {
  MarkdownCodec({EditorSchema? schema})
    : _schema = schema ?? EditorSchema.standard();

  final EditorSchema _schema;

  // -----------------------------------------------------------------------
  // Encode
  // -----------------------------------------------------------------------

  String encode(Document doc) {
    final entries = <_EncodedLine>[];
    _encodeBlocks(doc.blocks, 0, entries);

    // Join: use \n between consecutive list-like siblings at the same depth,
    // \n\n otherwise (paragraph breaks).
    final buf = StringBuffer();
    for (var i = 0; i < entries.length; i++) {
      if (i > 0) {
        final prev = entries[i - 1];
        final curr = entries[i];
        final tightPair = _isListLike(prev.blockType) &&
            _isListLike(curr.blockType);
        buf.write(tightPair ? '\n' : '\n\n');
      }
      buf.write(entries[i].line);
    }
    return buf.toString();
  }

  void _encodeBlocks(
      List<TextBlock> blocks, int depth, List<_EncodedLine> entries) {
    var numberedOrdinal = 0;
    for (final block in blocks) {
      final content = _encodeSegments(block.segments);
      final indent = '  ' * depth;

      if (block.blockType == BlockType.numberedList) {
        numberedOrdinal++;
      } else {
        numberedOrdinal = 0;
      }

      final ctx = EncodeContext(
        depth: depth,
        indent: indent,
        ordinal: numberedOrdinal,
        content: content,
      );

      final codec = _blockCodec(block.blockType);
      final line = codec != null
          ? codec.encode(block, ctx)
          : '$indent$content';

      entries.add(_EncodedLine(line, block.blockType, depth));

      _encodeBlocks(block.children, depth + 1, entries);
    }
  }

  /// Encode segments using inline codecs.
  ///
  /// Uses a style-stack to correctly nest wrap delimiters across segments.
  /// For example, segments [bold:"1 ", bold+italic:"2", bold:" 3"] produce
  /// `**1 *2* 3**` instead of per-segment wrapping which creates ambiguous
  /// adjacent delimiters.
  ///
  /// Data-carrying styles (links) use their full encode function.
  String _encodeSegments(List<StyledSegment> segments) {
    final wrapMap = _inlineWrapMap();
    final encodeMap = _inlineEncodeMap();

    // Fixed nesting order: longer delimiters are outer (bold before italic).
    final wrapOrder = wrapMap.keys.toList()
      ..sort((a, b) {
        final cmp = wrapMap[b]!.length.compareTo(wrapMap[a]!.length);
        return cmp != 0 ? cmp : wrapMap[a]!.compareTo(wrapMap[b]!);
      });

    final buffer = StringBuffer();
    final open = <Object>[]; // Currently open wrap styles, in wrapOrder.

    for (final seg in segments) {
      var text = seg.text;

      // Apply data-carrying style encoders (e.g. link → [text](url)).
      for (final style in seg.styles) {
        final encodeFn = encodeMap[style];
        if (encodeFn != null) {
          text = encodeFn(text, seg.attributes);
        }
      }

      // Desired stack for this segment, in nesting order.
      final desired = wrapOrder.where((s) => seg.styles.contains(s)).toList();

      // Find longest common prefix between open and desired.
      var commonLen = 0;
      while (commonLen < open.length &&
          commonLen < desired.length &&
          open[commonLen] == desired[commonLen]) {
        commonLen++;
      }

      // Close everything after the common prefix (innermost first).
      for (var i = open.length - 1; i >= commonLen; i--) {
        buffer.write(wrapMap[open[i]]);
      }
      open.removeRange(commonLen, open.length);

      // Open everything after the common prefix.
      for (var i = commonLen; i < desired.length; i++) {
        open.add(desired[i]);
        buffer.write(wrapMap[desired[i]]);
      }

      buffer.write(text);
    }

    // Close all remaining open styles (innermost first).
    for (var i = open.length - 1; i >= 0; i--) {
      buffer.write(wrapMap[open[i]]);
    }

    return buffer.toString();
  }

  // -----------------------------------------------------------------------
  // Decode
  // -----------------------------------------------------------------------

  Document decode(String markdown) {
    if (markdown.isEmpty) return Document.empty();
    // Split on \n\n for paragraph breaks, then further split tight lists
    // (consecutive lines that each match a block prefix).
    final rawParagraphs = markdown.split('\n\n');
    final paragraphs = <String>[];
    for (final p in rawParagraphs) {
      if (p.contains('\n')) {
        // Check if this paragraph has multiple lines that are each block-typed.
        final lines = p.split('\n');
        if (lines.length > 1 && lines.every(_looksLikeBlock)) {
          paragraphs.addAll(lines);
          continue;
        }
      }
      paragraphs.add(p);
    }

    final parsed = paragraphs.map((text) {
      final (depth, content) = _stripIndent(text);
      return (depth, _decodeBlock(content));
    }).toList();

    return Document(buildTreeFromPairs(parsed, 0));
  }

  /// Strip leading indentation and return (depth, remaining content).
  ///
  /// Supports 2-space, 4-space, and tab indentation. Normalizes to
  /// depth levels (each tab or 2 spaces = 1 level).
  static (int, String) _stripIndent(String text) {
    var depth = 0;
    var i = 0;
    while (i < text.length) {
      if (text[i] == '\t') {
        depth++;
        i++;
      } else if (i + 1 < text.length &&
          text[i] == ' ' &&
          text[i + 1] == ' ') {
        depth++;
        i += 2;
      } else {
        break;
      }
    }
    return (depth, text.substring(i));
  }

  /// Try all registered block decoders. If multiple match, pick the most
  /// specific one (the decoder that consumed the most prefix, i.e. whose
  /// DecodeMatch.content is shortest). Falls back to paragraph.
  TextBlock _decodeBlock(String text) {
    Object? bestKey;
    DecodeMatch? bestMatch;

    for (final entry in _schema.blocks.entries) {
      final codec = entry.value.codecs?[Format.markdown];
      if (codec?.decode == null) continue;
      final match = codec!.decode!(text);
      if (match == null) continue;

      // Pick the match that consumed the most prefix (shortest remaining
      // content). This correctly resolves '### ' over '## ' over '# ',
      // and '- [ ] ' over '- '.
      if (bestMatch == null ||
          match.content.length < bestMatch.content.length) {
        bestKey = entry.key;
        bestMatch = match;
      }
    }

    if (bestMatch != null && bestKey is BlockType) {
      return TextBlock(
        id: generateBlockId(),
        blockType: bestKey,
        segments: _decodeSegments(bestMatch.content),
        metadata: bestMatch.metadata,
      );
    }

    // Fallback: paragraph.
    return TextBlock(id: generateBlockId(), segments: _decodeSegments(text));
  }

  static const _maxDecodeDepth = 10;

  /// Decode inline styles from text using registered InlineCodec wraps and
  /// data-carrying decoders.
  ///
  /// Data-carrying decoders (links, mentions) are tried at each position
  /// before the wrap-based regex. This ensures `[text](url)` is decoded as
  /// a link rather than being partially matched by wrap delimiters.
  ///
  /// Wrap matches are recursively decoded so that `**1 *2* 3**` correctly
  /// produces bold("1 ") + bold+italic("2") + bold(" 3").
  List<StyledSegment> _decodeSegments(String text, [int _depth = 0]) {
    final wrapEntries = _inlineWrapEntries();
    final decodeEntries = _inlineDecodeEntries();

    if (wrapEntries.isEmpty && decodeEntries.isEmpty) {
      return [StyledSegment(text)];
    }

    // Build wrap regex with combined delimiters for overlapping styles.
    // E.g. bold(**) + italic(*) → combined ***(.+?)*** tried first.
    RegExp? wrapPattern;
    final combinedEntries = <_InlineCombinedWrapEntry>[];
    if (wrapEntries.isNotEmpty) {
      wrapEntries.sort((a, b) => b.wrap.length.compareTo(a.wrap.length));

      // Generate combined entries for all pairs of wrap styles.
      for (var i = 0; i < wrapEntries.length; i++) {
        for (var j = i + 1; j < wrapEntries.length; j++) {
          final combined = wrapEntries[i].wrap + wrapEntries[j].wrap;
          combinedEntries.add(_InlineCombinedWrapEntry(
            {wrapEntries[i].key, wrapEntries[j].key},
            combined,
          ));
        }
      }
      // Sort combined by length descending so longest matches first.
      combinedEntries.sort((a, b) => b.wrap.length.compareTo(a.wrap.length));

      // Build regex: combined patterns first, then individual.
      final alternatives = <String>[
        for (final e in combinedEntries)
          '${RegExp.escape(e.wrap)}(.+?)${RegExp.escape(e.wrap)}',
        for (final e in wrapEntries)
          '${RegExp.escape(e.wrap)}(.+?)${RegExp.escape(e.wrap)}',
      ];
      wrapPattern = RegExp(alternatives.join('|'));
    }

    final segments = <StyledSegment>[];
    var pos = 0;

    while (pos < text.length) {
      // Try data-carrying decoders at the current position.
      final remaining = text.substring(pos);
      _InlineDecodedResult? decoded;
      for (final entry in decodeEntries) {
        final match = entry.decode(remaining);
        if (match != null) {
          decoded = _InlineDecodedResult(entry.key, match);
          break;
        }
      }

      if (decoded != null) {
        if (decoded.match.fullMatchLength <= 0) {
          // Safety: avoid infinite loop on zero-length match.
          pos++;
          continue;
        }
        final style = decoded.key;
        if (style is! InlineStyle) {
          pos += decoded.match.fullMatchLength;
          continue;
        }
        segments.add(
          StyledSegment(decoded.match.text, {style}, decoded.match.attributes),
        );
        pos += decoded.match.fullMatchLength;
        continue;
      }

      // Try wrap-based regex match at current position.
      if (wrapPattern != null) {
        final match = wrapPattern.matchAsPrefix(text, pos);
        if (match != null) {
          // Find which group matched. Combined entries come first in the
          // alternation, then individual wrap entries.
          final totalGroups = combinedEntries.length + wrapEntries.length;
          for (var i = 0; i < totalGroups; i++) {
            final content = match.group(i + 1);
            if (content == null) continue;

            Set<InlineStyle> styles;
            if (i < combinedEntries.length) {
              // Combined entry — extract InlineStyle keys.
              styles = combinedEntries[i]
                  .keys
                  .whereType<InlineStyle>()
                  .toSet();
            } else {
              final key = wrapEntries[i - combinedEntries.length].key;
              styles = key is InlineStyle ? {key} : {};
            }

            if (styles.isNotEmpty && _depth < _maxDecodeDepth) {
              final inner = _decodeSegments(content, _depth + 1);
              for (final seg in inner) {
                segments.add(StyledSegment(
                  seg.text,
                  {...seg.styles, ...styles},
                  seg.attributes,
                ));
              }
            } else if (styles.isNotEmpty) {
              segments.add(StyledSegment(content, styles));
            } else {
              segments.add(StyledSegment(content));
            }
            break;
          }
          pos = match.end;
          continue;
        }
      }

      // No match — consume one character as plain text.
      // Collect consecutive plain characters for efficiency.
      final plainStart = pos;
      pos++;
      while (pos < text.length) {
        // Check if any decoder matches here.
        final rem = text.substring(pos);
        var anyMatch = false;
        for (final entry in decodeEntries) {
          if (entry.decode(rem) != null) {
            anyMatch = true;
            break;
          }
        }
        if (anyMatch) break;

        // Check if wrap pattern matches here.
        if (wrapPattern != null &&
            wrapPattern.matchAsPrefix(text, pos) != null) {
          break;
        }
        pos++;
      }
      segments.add(StyledSegment(text.substring(plainStart, pos)));
    }

    if (segments.isEmpty) {
      segments.add(const StyledSegment(''));
    }

    return segments;
  }

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  /// Look up the markdown block codec for a given block type.
  BlockCodec? _blockCodec(Object blockType) {
    return _schema.blockDef(blockType).codecs?[Format.markdown];
  }

  /// Build a map of inline style key → wrap string for encoding (simple styles).
  Map<Object, String> _inlineWrapMap() {
    final map = <Object, String>{};
    for (final entry in _schema.inlineStyles.entries) {
      final codec = entry.value.codecs?[Format.markdown];
      if (codec?.wrap != null) {
        map[entry.key] = codec!.wrap!;
      }
    }
    return map;
  }

  /// Build a map of inline style key → encode function for data-carrying styles.
  Map<Object, String Function(String, Map<String, dynamic>)>
  _inlineEncodeMap() {
    final map = <Object, String Function(String, Map<String, dynamic>)>{};
    for (final entry in _schema.inlineStyles.entries) {
      final codec = entry.value.codecs?[Format.markdown];
      if (codec?.encode != null) {
        map[entry.key] = codec!.encode!;
      }
    }
    return map;
  }

  /// Collect inline wrap entries for decoding (key + wrap string).
  List<_InlineWrapEntry> _inlineWrapEntries() {
    final entries = <_InlineWrapEntry>[];
    for (final entry in _schema.inlineStyles.entries) {
      final codec = entry.value.codecs?[Format.markdown];
      if (codec?.wrap != null) {
        entries.add(_InlineWrapEntry(entry.key, codec!.wrap!));
      }
    }
    return entries;
  }

  /// Collect inline decode entries for data-carrying styles.
  List<_InlineDecodeEntry> _inlineDecodeEntries() {
    final entries = <_InlineDecodeEntry>[];
    for (final entry in _schema.inlineStyles.entries) {
      final codec = entry.value.codecs?[Format.markdown];
      if (codec?.decode != null) {
        entries.add(_InlineDecodeEntry(entry.key, codec!.decode!));
      }
    }
    return entries;
  }

  /// Check if a line looks like a block-level element by trying registered
  /// block decoders. Schema-driven — no hardcoded prefixes.
  bool _looksLikeBlock(String line) {
    final trimmed = line.trimLeft();
    if (trimmed.isEmpty) return false;
    for (final entry in _schema.blocks.entries) {
      final codec = entry.value.codecs?[Format.markdown];
      if (codec?.decode != null && codec!.decode!(trimmed) != null) {
        return true;
      }
    }
    return false;
  }
}

class _InlineWrapEntry {
  const _InlineWrapEntry(this.key, this.wrap);
  final Object key;
  final String wrap;
}

class _InlineDecodeEntry {
  const _InlineDecodeEntry(this.key, this.decode);
  final Object key;
  final InlineDecodeMatch? Function(String) decode;
}

class _InlineDecodedResult {
  const _InlineDecodedResult(this.key, this.match);
  final Object key;
  final InlineDecodeMatch match;
}

class _InlineCombinedWrapEntry {
  const _InlineCombinedWrapEntry(this.keys, this.wrap);
  final Set<Object> keys;
  final String wrap;
}

class _EncodedLine {
  const _EncodedLine(this.line, this.blockType, this.depth);
  final String line;
  final BlockType blockType;
  final int depth;
}

bool _isListLike(BlockType type) =>
    type == BlockType.listItem ||
    type == BlockType.numberedList ||
    type == BlockType.taskItem;
