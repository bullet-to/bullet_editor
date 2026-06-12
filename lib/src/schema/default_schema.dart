import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../codec/block_codec.dart';
import '../codec/format.dart';
import '../codec/inline_codec.dart';
import '../editor/input_rule.dart';
import '../model/block.dart';
import '../model/block_policies.dart';
import '../model/document.dart';
import '../model/inline_entity.dart';
import '../view/components/default_text_component.dart';
import '../view/components/divider_block.dart';
import '../view/components/image_block.dart';
import 'block_def.dart';
import 'editor_schema.dart';
import 'inline_entity_def.dart';
import 'inline_style_def.dart';

/// Style overrides for a heading level. All fields are nullable — `null`
/// means "use the default value."
class HeadingStyle {
  /// Create heading style overrides. Pass only the values you want to change.
  const HeadingStyle({
    this.scale,
    this.lineHeight,
    this.spacingBefore,
    this.fontWeight,
  });

  /// Font size as a multiplier of the base font size.
  final double? scale;

  /// Line height multiplier.
  final double? lineHeight;

  /// Vertical spacing before this heading, in em units.
  final double? spacingBefore;

  /// Font weight for the heading.
  final FontWeight? fontWeight;
}

// ---------------------------------------------------------------------------
// Blocks — built-in block definitions for assembling a custom schema.
// ---------------------------------------------------------------------------

/// CommonMark thematic break pattern: 3+ of the same char (`-`, `*`, `_`),
/// optionally interspersed with spaces/tabs, nothing else on the line.
/// Leading spaces are already stripped by `_decodeBlock`.
final _thematicBreakPattern = RegExp(r'^([-*_])[ \t]*(\1[ \t]*){2,}$');

/// Built-in [BlockDef] factories. Use these to hand-pick which blocks your
/// schema includes, or to override a single built-in while keeping the rest.
///
/// ```dart
/// EditorSchema(
///   blocks: {
///     HeadingKeys.h1: Blocks.h1(),
///     ParagraphKeys.type: Blocks.paragraph(),
///     'myCustomType': BlockDef(label: 'Custom', ...),
///   },
///   ...
/// );
/// ```
abstract final class Blocks {
  /// Escape trailing `#` in heading content that `_stripTrailingHashes`
  /// would strip on re-decode. E.g. content `foo ###` → `foo \###`.
  static String _escapeTrailingHashes(String content) {
    if (content.isEmpty) return content;
    // Match trailing ` #+` that would be stripped.
    final match = RegExp(r' (#+)\s*$').firstMatch(content);
    if (match != null) {
      return '${content.substring(0, match.start)} \\${match.group(1)}';
    }
    // Also handle content that is ALL hashes (would become empty heading).
    if (RegExp(r'^#+$').hasMatch(content.trim())) {
      return '\\$content';
    }
    return content;
  }

  /// Strip optional trailing `#` sequences from ATX heading content.
  ///
  /// Per CommonMark: trailing `#` preceded by a space (or the whole string is
  /// `#`s) are stripped, along with any trailing spaces. `# foo#` keeps the `#`
  /// but `# foo #` strips it.
  static String _stripTrailingHashes(String content) {
    var s = content.trimRight();
    if (s.isEmpty) return '';
    // If everything is `#`, it's an empty heading.
    if (RegExp(r'^#+$').hasMatch(s)) return '';
    // Strip trailing `#`s only when preceded by a space.
    final match = RegExp(r' +#+\s*$').firstMatch(s);
    if (match != null) {
      s = s.substring(0, match.start);
    }
    return s;
  }

  /// Shared heading definition. Level-specific defaults live in the public
  /// h1–h6 factories.
  static BlockDef _heading({
    required int level,
    required String key,
    required double defaultScale,
    required double defaultLineHeight,
    required double defaultSpacingBefore,
    required FontWeight defaultWeight,
    HeadingStyle? style,
  }) {
    final hashes = '#' * level;
    return BlockDef(
      label: 'Heading $level',
      headingLevel: level,
      backspaceAtStart: BackspaceAtStartPolicy.convertToDefault,
      spacingBefore: style?.spacingBefore ?? defaultSpacingBefore,
      policies: const BlockPolicies(canBeChild: false, canHaveChildren: false),
      baseStyle: (base) {
        final size =
            (base?.fontSize ?? kFallbackFontSize) *
            (style?.scale ?? defaultScale);
        return (base ?? const TextStyle()).copyWith(
          fontSize: size,
          fontWeight: style?.fontWeight ?? defaultWeight,
          height: style?.lineHeight ?? defaultLineHeight,
        );
      },
      codecs: {
        Format.markdown: BlockCodec(
          encode: (block, ctx) =>
              '${ctx.indent}$hashes ${_escapeTrailingHashes(ctx.content)}',
          decode: (line) {
            if (line == hashes || line.startsWith('$hashes ')) {
              final raw = line.length <= hashes.length + 1
                  ? ''
                  : line.substring(hashes.length + 1);
              return DecodeMatch(_stripTrailingHashes(raw));
            }
            return null;
          },
        ),
      },
      inputRules: [PrefixBlockRule(hashes, key)],
    );
  }

  /// Heading 1.
  static BlockDef h1({HeadingStyle? style}) => _heading(
    level: 1,
    key: HeadingKeys.h1,
    defaultScale: 1.75,
    defaultLineHeight: 1.4,
    defaultSpacingBefore: 1.2,
    defaultWeight: FontWeight.bold,
    style: style,
  );

  /// Heading 2.
  static BlockDef h2({HeadingStyle? style}) => _heading(
    level: 2,
    key: HeadingKeys.h2,
    defaultScale: 1.375,
    defaultLineHeight: 1.4,
    defaultSpacingBefore: 1.0,
    defaultWeight: FontWeight.bold,
    style: style,
  );

  /// Heading 3.
  static BlockDef h3({HeadingStyle? style}) => _heading(
    level: 3,
    key: HeadingKeys.h3,
    defaultScale: 1.125,
    defaultLineHeight: 1.3,
    defaultSpacingBefore: 0.8,
    defaultWeight: FontWeight.w600,
    style: style,
  );

  /// Heading 4.
  static BlockDef h4({HeadingStyle? style}) => _heading(
    level: 4,
    key: HeadingKeys.h4,
    defaultScale: 1.0,
    defaultLineHeight: 1.3,
    defaultSpacingBefore: 0.6,
    defaultWeight: FontWeight.w600,
    style: style,
  );

  /// Heading 5.
  static BlockDef h5({HeadingStyle? style}) => _heading(
    level: 5,
    key: HeadingKeys.h5,
    defaultScale: 0.875,
    defaultLineHeight: 1.3,
    defaultSpacingBefore: 0.6,
    defaultWeight: FontWeight.w600,
    style: style,
  );

  /// Heading 6.
  static BlockDef h6({HeadingStyle? style}) => _heading(
    level: 6,
    key: HeadingKeys.h6,
    defaultScale: 0.85,
    defaultLineHeight: 1.3,
    defaultSpacingBefore: 0.6,
    defaultWeight: FontWeight.w600,
    style: style,
  );

  /// Task / checkbox item.
  static BlockDef taskItem({
    Color? accentColor,
    double prefixWidthFactor = 1.5,
  }) {
    return BlockDef(
      label: 'Task',
      policies: const BlockPolicies(
        canBeChild: true,
        canHaveChildren: true,
        maxDepth: 6,
      ),
      split: SplitPolicy.listLike,
      backspaceAtStart: BackspaceAtStartPolicy.outdentOrConvert,
      metadataKeys: const {TaskItemKeys.checked},
      newBlockMetadata: (splitBlock) => {TaskItemKeys.checked: false},
      prefixBuilder: (block, gutter, style) =>
          _taskPrefix(block, style, prefixWidthFactor, accentColor),
      codecs: {
        Format.markdown: BlockCodec(
          encode: (block, ctx) {
            final checked = block.metadata[TaskItemKeys.checked] == true;
            return '${ctx.indent}- [${checked ? 'x' : ' '}] ${ctx.content}';
          },
          decode: (line) {
            final markers = ['- ', '* ', '+ '];
            for (final m in markers) {
              if (line.startsWith('$m[x] ')) {
                return DecodeMatch(
                  line.substring(m.length + 4),
                  metadata: {TaskItemKeys.checked: true},
                );
              }
              if (line.startsWith('$m[ ] ')) {
                return DecodeMatch(
                  line.substring(m.length + 4),
                  metadata: {TaskItemKeys.checked: false},
                );
              }
            }
            return null;
          },
        ),
      },
      inputRules: const [TaskItemRule()],
    );
  }

  /// Bullet list item.
  static BlockDef listItem({
    String bulletChar = '•',
    double prefixWidthFactor = 1.5,
  }) {
    return BlockDef(
      label: 'Bullet List',
      policies: const BlockPolicies(
        canBeChild: true,
        canHaveChildren: true,
        maxDepth: 6,
      ),
      split: SplitPolicy.listLike,
      backspaceAtStart: BackspaceAtStartPolicy.outdentOrConvert,
      prefixBuilder: (block, gutter, style) =>
          _bulletPrefix(block, style, prefixWidthFactor, bulletChar),
      codecs: {
        Format.markdown: BlockCodec(
          encode: (block, ctx) => '${ctx.indent}- ${ctx.content}',
          decode: (line) {
            if (line.startsWith('- ') ||
                line.startsWith('* ') ||
                line.startsWith('+ ')) {
              return DecodeMatch(line.substring(2));
            }
            return null;
          },
        ),
      },
      inputRules: const [ListItemRule()],
    );
  }

  /// Numbered list item.
  static BlockDef numberedList({double prefixWidthFactor = 1.5}) {
    return BlockDef(
      label: 'Numbered List',
      policies: const BlockPolicies(
        canBeChild: true,
        canHaveChildren: true,
        maxDepth: 6,
      ),
      split: SplitPolicy.listLike,
      backspaceAtStart: BackspaceAtStartPolicy.outdentOrConvert,
      prefixBuilder: (block, gutter, style) =>
          _numberedPrefix(gutter, style, prefixWidthFactor),
      codecs: {
        Format.markdown: BlockCodec(
          encode: (block, ctx) => '${ctx.indent}${ctx.ordinal}. ${ctx.content}',
          decode: (line) {
            final match = RegExp(r'^\d+[.)] ').firstMatch(line);
            if (match == null) return null;
            return DecodeMatch(line.substring(match.end));
          },
        ),
      },
      inputRules: const [NumberedListRule()],
    );
  }

  /// Fenced code block. Content is literal text (no inline styles).
  /// Language stored in metadata `{CodeBlockKeys.language: 'dart'}`.
  ///
  /// Rendered as a real container block — full-width fill + padding through
  /// the parameterizable default text component (checkpoint-1 finding: the
  /// v2 per-glyph backgroundColor trick highlighted only to each line's
  /// glyph end, not the block).
  static BlockDef codeBlock() {
    return BlockDef(
      label: 'Code Block',
      policies: const BlockPolicies(canBeChild: false, canHaveChildren: false),
      split: SplitPolicy.lineBreak,
      spacingBefore: 0.5,
      spacingAfter: 0.5,
      metadataKeys: const {CodeBlockKeys.language},
      newBlockMetadata: (splitBlock) => const {},
      baseStyle: (base) => (base ?? const TextStyle()).copyWith(
        fontFamily: _monoFontFamily,
        fontFamilyFallback: _monoFontFallbacks,
        fontSize: ((base?.fontSize ?? kFallbackFontSize) * 0.9),
      ),
      componentBuilder: (ctx) => DefaultTextComponent(
        ctx,
        background: const Color(0x1A808080),
        padding: const EdgeInsets.all(12),
      ),
      codecs: {
        Format.markdown: BlockCodec(
          encode: (block, ctx) {
            final lang = block.metadata[CodeBlockKeys.language] ?? '';
            final content = block.plainText;
            return '${ctx.indent}```$lang\n$content\n```';
          },
          // Decode handled specially in MarkdownCodec._decodeBlock
          // for multi-line fenced content.
        ),
      },
    );
  }

  /// Block quote.
  static BlockDef blockQuote({Color? barColor}) {
    return BlockDef(
      label: 'Block Quote',
      policies: const BlockPolicies(
        canBeChild: true,
        canHaveChildren: true,
        maxDepth: 6,
      ),
      baseStyle: (base) {
        final size = (base?.fontSize ?? kFallbackFontSize) * 1.1;
        return (base ?? const TextStyle()).copyWith(
          fontSize: size,
          fontStyle: FontStyle.italic,
          color: const Color(0xFF9E9E9E),
          height: 1.5,
        );
      },
      spacingBefore: 0.4,
      spacingAfter: 0.4,
      prefixBuilder: (block, gutter, style) {
        final fontSize = style.fontSize ?? kFallbackFontSize;
        final barHeight = fontSize * 1.4;
        return SizedBox(
          width: 16,
          height: barHeight,
          child: Center(
            child: Container(
              width: 3,
              height: barHeight,
              decoration: BoxDecoration(
                color: barColor ?? const Color(0xFFBDBDBD),
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
          ),
        );
      },
      codecs: {
        Format.markdown: BlockCodec(
          encode: (block, ctx) => '${ctx.indent}> ${ctx.content}',
          decode: (line) {
            if (!line.startsWith('> ')) return null;
            return DecodeMatch(line.substring(2));
          },
        ),
      },
      inputRules: const [PrefixBlockRule('>', BlockQuoteKeys.type)],
    );
  }

  /// Horizontal divider (void block).
  static BlockDef divider({Color? color}) {
    return BlockDef(
      label: 'Divider',
      isVoid: true,
      voidBackspace: VoidBackspacePolicy.immediateDelete,
      policies: const BlockPolicies(canBeChild: false, canHaveChildren: false),
      // v2 hardcoded 8px margins inside the prefix widget; v3 expresses the
      // same gap as block spacing policy (0.5em = 8px at the default size).
      spacingBefore: 0.5,
      spacingAfter: 0.5,
      componentBuilder: (ctx) => DividerBlockComponent(ctx, color: color),
      codecs: {
        Format.markdown: BlockCodec(
          encode: (block, ctx) => '${ctx.indent}---',
          decode: (line) {
            // CommonMark thematic breaks: 3+ of the same char (-, *, _),
            // optionally interspersed with spaces/tabs.
            if (!_thematicBreakPattern.hasMatch(line)) return null;
            return const DecodeMatch('');
          },
        ),
      },
      inputRules: const [DividerRule()],
    );
  }

  /// Image (void block). Alt text stored as content, URL in metadata.
  static BlockDef image() {
    return BlockDef(
      label: 'Image',
      isVoid: true,
      voidBackspace: VoidBackspacePolicy.selectFirst,
      policies: const BlockPolicies(canBeChild: false, canHaveChildren: false),
      metadataKeys: const {ImageKeys.url},
      newBlockMetadata: (splitBlock) => const {},
      componentBuilder: (ctx) => ImageBlockComponent(ctx),
      codecs: {
        Format.markdown: BlockCodec(
          encode: (block, ctx) {
            final url = block.metadata[ImageKeys.url] ?? '';
            return '${ctx.indent}![${ctx.content}]($url)';
          },
          decode: (line) {
            final m = RegExp(r'^!\[([^\]]*)\]\(([^)]+)\)$').firstMatch(line);
            if (m == null) return null;
            return DecodeMatch(
              m.group(1)!,
              metadata: {ImageKeys.url: m.group(2)!},
            );
          },
        ),
      },
    );
  }

  /// Plain paragraph.
  static BlockDef paragraph() {
    return BlockDef(
      label: 'Paragraph',
      policies: const BlockPolicies(canBeChild: true, canHaveChildren: false),
      spacingBefore: 0.5,
      codecs: {
        Format.markdown: BlockCodec(
          encode: (block, ctx) {
            var content = ctx.content;
            // Escape leading `#` that would be re-decoded as ATX heading.
            if (RegExp(r'^#{1,6}( |$)').hasMatch(content)) {
              content = '\\$content';
            }
            return '${ctx.indent}$content';
          },
        ),
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Inlines — built-in inline style definitions.
// ---------------------------------------------------------------------------

/// Built-in inline presentation factories.
///
/// ```dart
/// EditorSchema(
///   inlineEntities: {
///     InlineEntityKeys.link: InlineEntityDef(
///       type: InlineEntityKeys.link,
///       style: Inlines.link(color: Colors.teal),
///       label: 'Link',
///       decode: _decodeLink,
///       encode: _encodeLink,
///     ),
///   },
///   ...
/// );
/// ```
abstract final class Inlines {
  /// Hyperlink (data-carrying).
  static InlineStyleDef link({Color? color}) {
    return InlineStyleDef(
      label: 'Link',
      isDataCarrying: true,
      applyStyle: (base, {attributes = const {}}) {
        final Color resolvedLink;
        if (color != null) {
          resolvedLink = color;
        } else {
          final baseColor = base.color ?? const Color(0xFF000000);
          final isDark = baseColor.computeLuminance() > 0.5;
          resolvedLink = isDark
              ? const Color(0xFF6CB4EE)
              : const Color(0xFF1A73E8);
        }
        return base.copyWith(
          color: resolvedLink,
          decoration: TextDecoration.underline,
          decorationColor: resolvedLink,
        );
      },
      codecs: {
        Format.markdown: InlineCodec(
          encode: (text, attributes) {
            final url = attributes[InlineEntityKeys.linkUrl] ?? '';
            return '[$text]($url)';
          },
          decode: (text) {
            // Standard inline link: [text](url)
            final inline = RegExp(r'^\[([^\]]+)\]\(([^)]+)\)').firstMatch(text);
            if (inline != null) {
              return InlineDecodeMatch(
                text: inline.group(1)!,
                fullMatchLength: inline.end,
                attributes: {InlineEntityKeys.linkUrl: inline.group(2)!},
              );
            }
            // Autolink: <https://...> or <http://...>
            final angle = RegExp(r'^<(https?://[^>]+)>').firstMatch(text);
            if (angle != null) {
              final url = angle.group(1)!;
              return InlineDecodeMatch(
                text: url,
                fullMatchLength: angle.end,
                attributes: {InlineEntityKeys.linkUrl: url},
              );
            }
            // Bare URL: https://... or http://...
            final bare = RegExp(r'^https?://[^\s<>\[\])]+').firstMatch(text);
            if (bare != null) {
              final url = bare.group(0)!;
              return InlineDecodeMatch(
                text: url,
                fullMatchLength: bare.end,
                attributes: {InlineEntityKeys.linkUrl: url},
              );
            }
            return null;
          },
        ),
      },
      inputRules: [LinkWrapRule()],
    );
  }

  /// Bold.
  static InlineStyleDef bold() {
    return InlineStyleDef(
      label: 'Bold',
      shortcut: const SingleActivator(LogicalKeyboardKey.keyB, meta: true),
      applyStyle: (base, {attributes = const {}}) =>
          base.copyWith(fontWeight: FontWeight.bold),
      codecs: {Format.markdown: const InlineCodec(wrap: '**')},
      inputRules: [BoldWrapRule()],
    );
  }

  /// Italic.
  static InlineStyleDef italic() {
    return InlineStyleDef(
      label: 'Italic',
      shortcut: const SingleActivator(LogicalKeyboardKey.keyI, meta: true),
      applyStyle: (base, {attributes = const {}}) =>
          base.copyWith(fontStyle: FontStyle.italic),
      codecs: {Format.markdown: const InlineCodec(wrap: '*')},
      inputRules: [ItalicWrapRule()],
    );
  }

  /// Strikethrough.
  static InlineStyleDef strikethrough() {
    return InlineStyleDef(
      label: 'Strikethrough',
      shortcut: const SingleActivator(
        LogicalKeyboardKey.keyS,
        meta: true,
        shift: true,
      ),
      applyStyle: (base, {attributes = const {}}) =>
          base.copyWith(decoration: TextDecoration.lineThrough),
      codecs: {Format.markdown: const InlineCodec(wrap: '~~')},
      inputRules: [StrikethroughWrapRule()],
    );
  }

  /// Inline code (monospace).
  static InlineStyleDef code() {
    return InlineStyleDef(
      label: 'Code',
      applyStyle: (base, {attributes = const {}}) => base.copyWith(
        fontFamily: _monoFontFamily,
        fontFamilyFallback: _monoFontFallbacks,
        fontSize: (base.fontSize ?? kFallbackFontSize) * 0.9,
        backgroundColor: const Color(0x30808080),
      ),
      codecs: {
        Format.markdown: InlineCodec(
          encode: (text, attributes) => '`$text`',
          decode: (text) {
            final m = RegExp(r'^`([^`]+)`').firstMatch(text);
            if (m == null) return null;
            return InlineDecodeMatch(text: m.group(1)!, fullMatchLength: m.end);
          },
        ),
      },
      inputRules: [InlineWrapRule('`', InlineStyleKeys.code)],
    );
  }
}

// ---------------------------------------------------------------------------
// buildStandardSchema — the "just works" path
// ---------------------------------------------------------------------------

/// Builds the standard [EditorSchema] with all built-in block types and
/// inline styles, including markdown codecs and input rules.
///
/// All parameters are optional — omit them to get the default appearance.
/// Pass overrides for only the values you want to change.
///
/// For full control, use [Blocks] and [Inlines] to hand-pick which
/// definitions your [EditorSchema] includes.
///
/// **Block ordering matters for input rules and codec decode.** More-specific
/// prefixes must come before shorter ones (h3 before h2 before h1, taskItem
/// before listItem) so they are tried first.
///
/// The `additional*` maps are merged after built-ins, so custom string keys
/// can never collide with future built-in types, and passing a built-in key
/// (e.g. [HeadingKeys.h1]) intentionally overrides that definition.
EditorSchema buildStandardSchema({
  // Per-heading overrides (null fields keep defaults).
  HeadingStyle? h1,
  HeadingStyle? h2,
  HeadingStyle? h3,
  HeadingStyle? h4,
  HeadingStyle? h5,
  HeadingStyle? h6,
  // Colors (null = derive from text color brightness).
  Color? linkColor,
  Color? accentColor,
  Color? dividerColor,
  // Spacing & layout.
  double? prefixWidthFactor,
  double? indentPerDepthFactor,
  String? bulletChar,
  // Extensions — merged after built-ins.
  Map<String, BlockDef>? additionalBlocks,
  Map<String, InlineStyleDef>? additionalInlineStyles,
  Map<String, InlineEntityDef>? additionalInlineEntities,
}) {
  final pwf = prefixWidthFactor ?? 1.5;

  return EditorSchema(
    defaultBlockType: ParagraphKeys.type,
    prefixWidthFactor: pwf,
    indentPerDepthFactor: indentPerDepthFactor ?? 1.5,
    blocks: {
      // --- Order: specific prefix rules before general ones ---
      HeadingKeys.h6: Blocks.h6(style: h6),
      HeadingKeys.h5: Blocks.h5(style: h5),
      HeadingKeys.h4: Blocks.h4(style: h4),
      HeadingKeys.h3: Blocks.h3(style: h3),
      HeadingKeys.h2: Blocks.h2(style: h2),
      HeadingKeys.h1: Blocks.h1(style: h1),
      TaskItemKeys.type: Blocks.taskItem(
        accentColor: accentColor,
        prefixWidthFactor: pwf,
      ),
      ListItemKeys.type: Blocks.listItem(
        bulletChar: bulletChar ?? '•',
        prefixWidthFactor: pwf,
      ),
      NumberedListKeys.type: Blocks.numberedList(prefixWidthFactor: pwf),
      BlockQuoteKeys.type: Blocks.blockQuote(),
      CodeBlockKeys.type: Blocks.codeBlock(),
      DividerKeys.type: Blocks.divider(color: dividerColor),
      ImageKeys.type: Blocks.image(),
      ParagraphKeys.type: Blocks.paragraph(),
      if (additionalBlocks != null) ...additionalBlocks,
    },
    inlineStyles: {
      InlineStyleKeys.code: Inlines.code(),
      InlineStyleKeys.bold: Inlines.bold(),
      InlineStyleKeys.italic: Inlines.italic(),
      InlineStyleKeys.strikethrough: Inlines.strikethrough(),
      if (additionalInlineStyles != null) ...additionalInlineStyles,
    },
    inlineEntities: {
      InlineEntityKeys.link: InlineEntityDef(
        type: InlineEntityKeys.link,
        style: Inlines.link(color: linkColor),
        label: 'Link',
        decode: (attributes) => LinkData(
          url: attributes[InlineEntityKeys.linkUrl] as String? ?? '',
        ),
        encode: (data) => {InlineEntityKeys.linkUrl: (data as LinkData).url},
        defaultText: (data) => (data as LinkData).url,
      ),
      if (additionalInlineEntities != null) ...additionalInlineEntities,
    },
  );
}

// ---------------------------------------------------------------------------
// Prefix builders
// ---------------------------------------------------------------------------

/// Fallback font size when no style is provided.
const double kFallbackFontSize = 16.0;

/// Primary monospace font family (platform-appropriate).
const String _monoFontFamily = 'Menlo';

/// Fallback monospace families for cross-platform coverage.
const List<String> _monoFontFallbacks = [
  'Consolas',
  'SF Mono',
  'Roboto Mono',
  'monospace',
];

/// Compute prefix width from a resolved font size and factor.
double prefixWidth(double fontSize, [double factor = 1.5]) => fontSize * factor;

/// Compute indent per depth level from a base font size and factor.
double indentPerDepth(double fontSize, [double factor = 1.5]) =>
    fontSize * factor;

Widget? _bulletPrefix(
  TextBlock block,
  TextStyle resolvedStyle,
  double pwf,
  String bullet,
) {
  final fontSize = resolvedStyle.fontSize ?? kFallbackFontSize;
  return SizedBox(
    width: prefixWidth(fontSize, pwf),
    child: Center(
      child: Text(
        bullet,
        style: TextStyle(fontSize: fontSize * 1.2, height: 1),
      ),
    ),
  );
}

Widget? _numberedPrefix(
  GutterContext gutter,
  TextStyle resolvedStyle,
  double pwf,
) {
  final fontSize = resolvedStyle.fontSize ?? kFallbackFontSize;
  return SizedBox(
    width: prefixWidth(fontSize, pwf),
    child: Center(
      child: Text(
        '${gutter.ordinal}.',
        style: TextStyle(fontSize: fontSize, height: 1),
      ),
    ),
  );
}

Widget? _taskPrefix(
  TextBlock block,
  TextStyle resolvedStyle,
  double pwf,
  Color? overrideAccent,
) {
  final checked = block.metadata[TaskItemKeys.checked] == true;
  final fontSize = resolvedStyle.fontSize ?? kFallbackFontSize;
  final size = fontSize * 0.85;
  final borderRadius = size * 0.2;
  final textColor = resolvedStyle.color ?? const Color(0xFF333333);
  final Color accentColor;
  if (overrideAccent != null) {
    accentColor = overrideAccent;
  } else {
    final isDark = textColor.computeLuminance() > 0.5;
    accentColor = isDark ? const Color(0xFF64B5F6) : const Color(0xFF2196F3);
  }

  return SizedBox(
    width: prefixWidth(fontSize, pwf),
    child: Center(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(borderRadius),
          border: Border.all(
            color: checked ? accentColor : textColor.withValues(alpha: 0.4),
            width: 1.5,
          ),
          color: checked ? accentColor : null,
        ),
        child: checked
            ? CustomPaint(
                painter: _CheckPainter(color: const Color(0xFFFFFFFF)),
              )
            : null,
      ),
    ),
  );
}

class _CheckPainter extends CustomPainter {
  _CheckPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = size.width * 0.15
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final path = Path()
      ..moveTo(size.width * 0.2, size.height * 0.5)
      ..lineTo(size.width * 0.42, size.height * 0.72)
      ..lineTo(size.width * 0.8, size.height * 0.28);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_CheckPainter old) => color != old.color;
}

/// Compute the 1-based ordinal of a block among the contiguous run of
/// same-type, same-depth blocks preceding it. Used by the view to build
/// [GutterContext] and exported for custom numbered-list block defs.
int computeOrdinal(Document doc, int flatIndex) {
  var ordinal = 1;
  final flat = doc.allBlocks;
  final block = flat[flatIndex];
  final depth = doc.depthOf(flatIndex);

  for (var j = flatIndex - 1; j >= 0; j--) {
    if (doc.depthOf(j) != depth) break;
    if (flat[j].blockType != block.blockType) break;
    ordinal++;
  }
  return ordinal;
}
