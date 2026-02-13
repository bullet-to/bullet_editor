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
    final lines = <String>[];
    _encodeBlocks(doc.blocks, 0, lines);
    return lines.join('\n\n');
  }

  void _encodeBlocks(List<TextBlock> blocks, int depth, List<String> lines) {
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
      if (codec != null) {
        lines.add(codec.encode(block, ctx));
      } else {
        // Fallback: plain content with indent.
        lines.add('$indent$content');
      }

      _encodeBlocks(block.children, depth + 1, lines);
    }
  }

  /// Encode segments using inline codecs.
  ///
  /// Simple styles use symmetric wrap delimiters. Data-carrying styles
  /// (links) use their full encode function with segment attributes.
  String _encodeSegments(List<StyledSegment> segments) {
    final wrapMap = _inlineWrapMap();
    final encodeMap = _inlineEncodeMap();
    final buffer = StringBuffer();

    for (final seg in segments) {
      var text = seg.text;

      // First, apply data-carrying style encoders (e.g. link → [text](url)).
      // These replace the text entirely for their style.
      for (final style in seg.styles) {
        final encodeFn = encodeMap[style];
        if (encodeFn != null) {
          text = encodeFn(text, seg.attributes);
        }
      }

      // Then, apply symmetric wrap delimiters for simple styles.
      for (final style in seg.styles) {
        final wrap = wrapMap[style];
        if (wrap != null) {
          text = '$wrap$text$wrap';
        }
      }
      buffer.write(text);
    }
    return buffer.toString();
  }

  // -----------------------------------------------------------------------
  // Decode
  // -----------------------------------------------------------------------

  Document decode(String markdown) {
    if (markdown.isEmpty) return Document.empty();
    final paragraphs = markdown.split('\n\n');

    final parsed = paragraphs.map((text) {
      var depth = 0;
      var remaining = text;
      while (remaining.startsWith('  ')) {
        depth++;
        remaining = remaining.substring(2);
      }
      return (depth, _decodeBlock(remaining));
    }).toList();

    return Document(_buildTree(parsed, 0));
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

    if (bestMatch != null) {
      return TextBlock(
        id: generateBlockId(),
        blockType: bestKey! as BlockType,
        segments: _decodeSegments(bestMatch.content),
        metadata: bestMatch.metadata,
      );
    }

    // Fallback: paragraph.
    return TextBlock(id: generateBlockId(), segments: _decodeSegments(text));
  }

  /// Decode inline styles from text using registered InlineCodec wraps and
  /// data-carrying decoders.
  ///
  /// Data-carrying decoders (links, mentions) are tried at each position
  /// before the wrap-based regex. This ensures `[text](url)` is decoded as
  /// a link rather than being partially matched by wrap delimiters.
  List<StyledSegment> _decodeSegments(String text) {
    final wrapEntries = _inlineWrapEntries();
    final decodeEntries = _inlineDecodeEntries();

    if (wrapEntries.isEmpty && decodeEntries.isEmpty) {
      return [StyledSegment(text)];
    }

    // Build wrap regex (same as before).
    RegExp? wrapPattern;
    if (wrapEntries.isNotEmpty) {
      wrapEntries.sort((a, b) => b.wrap.length.compareTo(a.wrap.length));
      final alternatives = wrapEntries
          .map((e) {
            final escaped = RegExp.escape(e.wrap);
            return '$escaped(.+?)$escaped';
          })
          .join('|');
      wrapPattern = RegExp(alternatives);
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
            decoded.key as InlineStyle,
          }, decoded.match.attributes),
        );
        pos += decoded.match.fullMatchLength;
        continue;
      }

      // Try wrap-based regex match at current position.
      if (wrapPattern != null) {
        final match = wrapPattern.matchAsPrefix(text, pos);
        if (match != null) {
          // Find which group matched.
          for (var i = 0; i < wrapEntries.length; i++) {
            final content = match.group(i + 1);
            if (content != null) {
              segments.add(
                StyledSegment(content, {wrapEntries[i].key as InlineStyle}),
              );
              break;
            }
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
  // Tree building (format-level grammar — unchanged)
  // -----------------------------------------------------------------------

  List<TextBlock> _buildTree(List<(int, TextBlock)> items, int minDepth) {
    final result = <TextBlock>[];
    var i = 0;

    while (i < items.length) {
      final (depth, block) = items[i];
      if (depth < minDepth) break;

      i++;
      final childItems = <(int, TextBlock)>[];
      while (i < items.length && items[i].$1 > depth) {
        childItems.add(items[i]);
        i++;
      }

      final children = childItems.isEmpty
          ? const <TextBlock>[]
          : _buildTree(childItems, depth + 1);

      result.add(children.isEmpty ? block : block.copyWith(children: children));
    }

    return result;
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
