import '../model/block.dart';
import '../model/document.dart';
import '../schema/editor_schema.dart';
import 'block_codec.dart';
import 'format.dart';
import 'inline_codec.dart';

/// ASCII punctuation characters that can be backslash-escaped in CommonMark.
const _escapable =
    r'!"#$%&'
    "'"
    r'()*+,-./:;<=>?@[\]^_`{|}~';

/// Regex matching a backslash followed by an ASCII punctuation character.
final _backslashEscape = RegExp(
  r'\\([!"#$%&'
  "'"
  r'()*+,\-./:;<=>?@\[\\\]^_`{|}~])',
);

/// Unescape CommonMark backslash escapes: `\*` → `*`, `\[` → `[`, etc.
String unescapeMarkdown(String text) {
  return text.replaceAllMapped(_backslashEscape, (m) => m.group(1)!);
}

/// Escape characters in plain text that would be mis-interpreted as markdown.
/// Only escapes chars that our codec actually uses as syntax.
String escapeMarkdown(String text) {
  return text.replaceAllMapped(
    RegExp(r'[\\*_~\[\]`]'),
    (m) => '\\${m.group(0)}',
  );
}

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
class MarkdownCodec<B extends Object> {
  MarkdownCodec({EditorSchema<B, Object>? schema})
    : _schema = schema ?? EditorSchema.standard() as EditorSchema<B, Object>;

  /// Convenience constructor that returns a codec typed for the built-in
  /// [BlockType] enum using the standard schema.
  static MarkdownCodec<BlockType> standard() =>
      MarkdownCodec<BlockType>(schema: EditorSchema.standard());

  final EditorSchema<B, Object> _schema;

  // -----------------------------------------------------------------------
  // Encode
  // -----------------------------------------------------------------------

  String encode(Document<B> doc) {
    final entries = <_EncodedLine>[];
    _encodeBlocks(doc.blocks, 0, entries);

    // Join: use \n between consecutive list-like siblings at the same depth,
    // \n\n otherwise (paragraph breaks).
    final buf = StringBuffer();
    for (var i = 0; i < entries.length; i++) {
      if (i > 0) {
        final prev = entries[i - 1];
        final curr = entries[i];
        final tightPair =
            _schema.isListLike(prev.blockType) &&
            _schema.isListLike(curr.blockType);
        // An empty block already contributes "" as its line, so the \n\n
        // separator before it produces one blank line. Use \n after
        // an empty line so the next block isn't double-spaced.
        final afterEmpty = prev.line.isEmpty;
        buf.write(tightPair || afterEmpty ? '\n' : '\n\n');
      }
      buf.write(entries[i].line);
    }
    return buf.toString();
  }

  void _encodeBlocks(
    List<TextBlock<B>> blocks,
    int depth,
    List<_EncodedLine> entries,
  ) {
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
      final line = codec != null ? codec.encode(block, ctx) : '$indent$content';

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
      var hasDataEncoder = false;
      for (final style in seg.styles) {
        final encodeFn = encodeMap[style];
        if (encodeFn != null) {
          text = encodeFn(text, seg.attributes);
          hasDataEncoder = true;
        }
      }

      // Escape markdown-significant chars in plain text to prevent
      // round-trip misinterpretation. Only escape segments that have no
      // wrap styles (bold/italic/strikethrough) and no data encoder,
      // because escaping inside delimiters creates parser ambiguity.
      final hasWrapStyle = seg.styles.any((s) => wrapMap.containsKey(s));
      if (!hasDataEncoder && !hasWrapStyle) {
        text = escapeMarkdown(text);
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

      // Encode soft breaks (\n within a block) as hard line breaks.
      buffer.write(text.replaceAll('\n', '  \n'));
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

  /// Regex matching a fenced code block opening: 3+ backticks or tildes,
  /// optionally followed by a language identifier.
  static final _fenceOpen = RegExp(r'^(`{3,}|~{3,})(.*)$');

  Document<B> decode(String markdown) {
    if (markdown.isEmpty) {
      return Document.empty(_schema.defaultBlockType);
    }

    // Fence-aware block splitter: split lines into blocks, keeping fenced
    // code block regions (including blank lines) as single multi-line strings.
    final paragraphs = _splitBlocks(markdown);

    if (paragraphs.isEmpty) {
      return Document.empty(_schema.defaultBlockType);
    }

    final parsed = paragraphs.map((text) {
      // Check for fenced code block (multi-line string starting with ```)
      final fenceMatch = _fenceOpen.firstMatch(text.split('\n').first);
      if (fenceMatch != null) {
        return (0, _decodeFencedCodeBlock(text, fenceMatch));
      }
      final (depth, content) = _stripIndent(text);
      return (depth, _decodeBlock(content));
    }).toList();

    // Normalize depths: ensure no block is nested under a parent whose
    // block type doesn't support children (e.g. headings, code blocks).
    // Also close depth gaps (no jump > 1 between consecutive blocks).
    final normalized = _normalizeDepths(parsed);

    return Document(buildTreeFromPairs(normalized, 0));
  }

  /// Split markdown into block-level strings, aware of fenced code blocks.
  ///
  /// Outside a fence: blank lines separate blocks, tight-list detection
  /// applies. Inside a fence: everything (including blank lines) is
  /// accumulated until the closing fence.
  List<String> _splitBlocks(String markdown) {
    final lines = markdown.split('\n');
    final blocks = <String>[];
    final current = StringBuffer();
    var inFence = false;
    String? fenceDelim;

    void flushCurrent() {
      if (current.isEmpty) return;
      final block = current.toString();
      current.clear();
      // Apply tight-list splitting to the flushed block.
      if (block.contains('\n')) {
        final subLines = block.split('\n');
        if (subLines.length > 1 && subLines.every(_looksLikeBlock)) {
          blocks.addAll(subLines);
          return;
        }
      }
      blocks.add(block);
    }

    for (final line in lines) {
      if (!inFence) {
        // Check for fence opening.
        final fence = _fenceOpen.firstMatch(line);
        if (fence != null) {
          flushCurrent();
          inFence = true;
          fenceDelim = fence.group(1)!;
          current.write(line);
          continue;
        }

        if (line.isEmpty) {
          flushCurrent();
        } else {
          if (current.isNotEmpty) current.write('\n');
          current.write(line);
        }
      } else {
        current.write('\n');
        current.write(line);
        // Check for fence closing: line is just the delimiter (or longer).
        final delim = fenceDelim!;
        final trimmed = line.trimRight();
        final closingChar = delim[0];
        if (RegExp('^$closingChar{${delim.length},}\$').hasMatch(trimmed)) {
          flushCurrent();
          inFence = false;
          fenceDelim = null;
        }
      }
    }

    flushCurrent();
    return blocks;
  }

  /// Decode a fenced code block from its multi-line string.
  TextBlock<B> _decodeFencedCodeBlock(String text, RegExpMatch fenceMatch) {
    final lines = text.split('\n');
    final lang = fenceMatch.group(2)!.trim();
    final fenceDelim = fenceMatch.group(1)!;
    final closingChar = fenceDelim[0];
    final closingPattern = RegExp('^$closingChar{${fenceDelim.length},}\$');

    // Find closing fence line (skip first line which is the opening).
    var endIndex = lines.length;
    for (var i = 1; i < lines.length; i++) {
      if (closingPattern.hasMatch(lines[i].trimRight())) {
        endIndex = i;
        break;
      }
    }

    // Content is everything between opening and closing fence.
    final content = lines.sublist(1, endIndex).join('\n');

    // Look up the code block type key from the schema.
    B? codeBlockKey;
    for (final entry in _schema.blocks.entries) {
      if (entry.value.label == 'Code Block') {
        codeBlockKey = entry.key;
        break;
      }
    }
    codeBlockKey ??= _schema.defaultBlockType;

    return TextBlock(
      id: generateBlockId(),
      blockType: codeBlockKey,
      segments: [StyledSegment(content)],
      metadata: lang.isNotEmpty ? {'language': lang} : const {},
    );
  }

  /// Normalize (depth, block) pairs so that:
  ///  1. No depth gap > 1 between consecutive blocks.
  ///  2. No block is nested under a parent whose type has
  ///     `canHaveChildren: false` (e.g. headings, code blocks, dividers).
  ///
  /// Iterates until stable (typically 1-2 passes).
  List<(int, TextBlock<B>)> _normalizeDepths(
      List<(int, TextBlock<B>)> parsed) {
    final adj = List<(int, TextBlock<B>)>.of(parsed);
    var changed = true;
    while (changed) {
      changed = false;
      // Close depth gaps.
      for (var i = 1; i < adj.length; i++) {
        final maxDepth = adj[i - 1].$1 + 1;
        if (adj[i].$1 > maxDepth) {
          adj[i] = (maxDepth, adj[i].$2);
          changed = true;
        }
      }
      // Collapse blocks whose would-be parent can't have children.
      for (var i = 1; i < adj.length; i++) {
        final curDepth = adj[i].$1;
        if (curDepth == 0) continue;
        // Walk backwards to find the nearest block at curDepth - 1.
        for (var j = i - 1; j >= 0; j--) {
          if (adj[j].$1 == curDepth - 1) {
            final parentDef = _schema.blockDef(adj[j].$2.blockType);
            if (!parentDef.policies.canHaveChildren) {
              adj[i] = (curDepth - 1, adj[i].$2);
              changed = true;
            }
            break;
          }
          if (adj[j].$1 < curDepth - 1) break;
        }
      }
    }
    return adj;
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
      } else if (i + 1 < text.length && text[i] == ' ' && text[i + 1] == ' ') {
        depth++;
        i += 2;
      } else {
        break;
      }
    }
    return (depth, text.substring(i));
  }

  /// Process CommonMark line breaks within a paragraph/block content string.
  ///
  /// - `  \n` (2+ trailing spaces + newline) → `\n` (hard line break)
  /// - `\\\n` (backslash + newline) → `\n` (hard line break)
  /// - plain `\n` → ` ` (soft continuation, join with space)
  static String _processLineBreaks(String content) {
    if (!content.contains('\n')) return content;
    // Use a placeholder so hard-break \n aren't clobbered by the soft-break pass.
    const placeholder = '\x00';
    var result = content.replaceAllMapped(
      RegExp(r' {2,}\n'),
      (m) => placeholder,
    );
    result = result.replaceAll('\\\n', placeholder);
    // Remaining plain \n are soft breaks → space.
    result = result.replaceAll('\n', ' ');
    // Restore hard breaks.
    result = result.replaceAll(placeholder, '\n');
    return result;
  }

  /// Try all registered block decoders. If multiple match, pick the most
  /// specific one (the decoder that consumed the most prefix, i.e. whose
  /// DecodeMatch.content is shortest). Falls back to the default block type.
  TextBlock<B> _decodeBlock(String text) {
    // CommonMark allows up to 3 leading spaces on block-level constructs.
    // Strip them before trying decoders (4+ spaces = indented code block,
    // which we don't support, but we still avoid stripping those).
    var stripped = text;
    var leading = 0;
    while (leading < 3 &&
        leading < stripped.length &&
        stripped[leading] == ' ') {
      leading++;
    }
    if (leading > 0) stripped = text.substring(leading);

    B? bestKey;
    DecodeMatch? bestMatch;

    for (final entry in _schema.blocks.entries) {
      final codec = entry.value.codecs?[Format.markdown];
      if (codec?.decode == null) continue;
      final match = codec!.decode!(stripped);
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

    if (bestMatch != null && bestKey != null) {
      final content = _processLineBreaks(bestMatch.content);
      return TextBlock(
        id: generateBlockId(),
        blockType: bestKey,
        segments: _decodeSegments(content),
        metadata: bestMatch.metadata,
      );
    }

    // Fallback: default block type.
    return TextBlock(
      id: generateBlockId(),
      blockType: _schema.defaultBlockType,
      segments: _decodeSegments(_processLineBreaks(text)),
    );
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
  List<StyledSegment> _decodeSegments(String text, [int depth = 0]) {
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
          combinedEntries.add(
            _InlineCombinedWrapEntry({
              wrapEntries[i].key,
              wrapEntries[j].key,
            }, combined),
          );
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
        segments.add(
          StyledSegment(decoded.match.text, {
            decoded.key,
          }, decoded.match.attributes),
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

            Set<Object> styles;
            if (i < combinedEntries.length) {
              styles = combinedEntries[i].keys.toSet();
            } else {
              styles = {wrapEntries[i - combinedEntries.length].key};
            }

            if (styles.isNotEmpty && depth < _maxDecodeDepth) {
              final inner = _decodeSegments(content, depth + 1);
              for (final seg in inner) {
                segments.add(
                  StyledSegment(seg.text, {
                    ...seg.styles,
                    ...styles,
                  }, seg.attributes),
                );
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

      // No match — consume plain text characters.
      // Handle backslash escapes: `\*` → `*`, `\[` → `[`, etc.
      final plainBuf = StringBuffer();
      void consumePlain() {
        // Backslash escape: if current char is `\` followed by ASCII punct,
        // consume both and emit the literal punctuation character.
        if (text[pos] == '\\' &&
            pos + 1 < text.length &&
            _escapable.contains(text[pos + 1])) {
          plainBuf.write(text[pos + 1]);
          pos += 2;
          return;
        }
        plainBuf.write(text[pos]);
        pos++;
      }

      consumePlain();
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
        consumePlain();
      }
      segments.add(StyledSegment(plainBuf.toString()));
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
  final Object blockType;
  final int depth;
}
