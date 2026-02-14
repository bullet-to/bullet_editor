import 'package:flutter/widgets.dart';

import '../codec/block_codec.dart';
import '../codec/format.dart';
import '../codec/inline_codec.dart';
import '../editor/input_rule.dart';
import '../model/block.dart';
import '../model/block_policies.dart';
import '../model/document.dart';
import '../model/inline_style.dart';
import 'block_def.dart';
import 'editor_schema.dart';
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

/// Built-in [BlockDef] factories. Use these to hand-pick which blocks your
/// schema includes, or to override a single built-in while keeping the rest.
///
/// ```dart
/// EditorSchema(
///   blocks: {
///     BlockType.h1: Blocks.h1(),
///     BlockType.paragraph: Blocks.paragraph(),
///     myCustomType: BlockDef(label: 'Custom', ...),
///   },
///   ...
/// );
/// ```
abstract final class Blocks {
  /// Heading 3.
  static BlockDef h3({HeadingStyle? style, double prefixWidthFactor = 1.5}) {
    return BlockDef(
      label: 'Heading 3',
      spacingBefore: style?.spacingBefore ?? 0.6,
      policies: const BlockPolicies(canBeChild: false, canHaveChildren: false),
      baseStyle: (base) {
        final size =
            (base?.fontSize ?? kFallbackFontSize) * (style?.scale ?? 1.125);
        return (base ?? const TextStyle()).copyWith(
          fontSize: size,
          fontWeight: style?.fontWeight ?? FontWeight.w600,
          height: style?.lineHeight ?? 1.3,
        );
      },
      codecs: {
        Format.markdown: BlockCodec(
          encode: (block, ctx) => '${ctx.indent}### ${ctx.content}',
          decode: (line) {
            if (!line.startsWith('### ')) return null;
            return DecodeMatch(line.substring(4));
          },
        ),
      },
      inputRules: [PrefixBlockRule('###', BlockType.h3)],
    );
  }

  /// Heading 2.
  static BlockDef h2({HeadingStyle? style, double prefixWidthFactor = 1.5}) {
    return BlockDef(
      label: 'Heading 2',
      spacingBefore: style?.spacingBefore ?? 0.8,
      policies: const BlockPolicies(canBeChild: false, canHaveChildren: false),
      baseStyle: (base) {
        final size =
            (base?.fontSize ?? kFallbackFontSize) * (style?.scale ?? 1.375);
        return (base ?? const TextStyle()).copyWith(
          fontSize: size,
          fontWeight: style?.fontWeight ?? FontWeight.bold,
          height: style?.lineHeight ?? 1.4,
        );
      },
      codecs: {
        Format.markdown: BlockCodec(
          encode: (block, ctx) => '${ctx.indent}## ${ctx.content}',
          decode: (line) {
            if (!line.startsWith('## ')) return null;
            return DecodeMatch(line.substring(3));
          },
        ),
      },
      inputRules: [PrefixBlockRule('##', BlockType.h2)],
    );
  }

  /// Heading 1.
  static BlockDef h1({HeadingStyle? style, double prefixWidthFactor = 1.5}) {
    return BlockDef(
      label: 'Heading 1',
      spacingBefore: style?.spacingBefore ?? 1.0,
      policies: const BlockPolicies(canBeChild: false, canHaveChildren: false),
      baseStyle: (base) {
        final size =
            (base?.fontSize ?? kFallbackFontSize) * (style?.scale ?? 1.75);
        return (base ?? const TextStyle()).copyWith(
          fontSize: size,
          fontWeight: style?.fontWeight ?? FontWeight.bold,
          height: style?.lineHeight ?? 1.4,
        );
      },
      codecs: {
        Format.markdown: BlockCodec(
          encode: (block, ctx) => '${ctx.indent}# ${ctx.content}',
          decode: (line) {
            if (!line.startsWith('# ')) return null;
            return DecodeMatch(line.substring(2));
          },
        ),
      },
      inputRules: [HeadingRule()],
    );
  }

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
      isListLike: true,
      splitInheritsType: true,
      prefixBuilder: (doc, i, block, style) =>
          _taskPrefix(doc, i, block, style, prefixWidthFactor, accentColor),
      codecs: {
        Format.markdown: BlockCodec(
          encode: (block, ctx) {
            final checked = block.metadata[kCheckedKey] == true;
            return '${ctx.indent}- [${checked ? 'x' : ' '}] ${ctx.content}';
          },
          decode: (line) {
            if (line.startsWith('- [x] ')) {
              return DecodeMatch(
                line.substring(6),
                metadata: {kCheckedKey: true},
              );
            }
            if (line.startsWith('- [ ] ')) {
              return DecodeMatch(
                line.substring(6),
                metadata: {kCheckedKey: false},
              );
            }
            return null;
          },
        ),
      },
      inputRules: [TaskItemRule()],
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
      isListLike: true,
      splitInheritsType: true,
      prefixBuilder: (doc, i, block, style) =>
          _bulletPrefix(doc, i, block, style, prefixWidthFactor, bulletChar),
      codecs: {
        Format.markdown: BlockCodec(
          encode: (block, ctx) => '${ctx.indent}- ${ctx.content}',
          decode: (line) {
            if (!line.startsWith('- ')) return null;
            return DecodeMatch(line.substring(2));
          },
        ),
      },
      inputRules: [
        ListItemRule(),
        EmptyListItemRule(),
        ListItemBackspaceRule(),
      ],
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
      isListLike: true,
      splitInheritsType: true,
      prefixBuilder: (doc, i, block, style) =>
          _numberedPrefix(doc, i, block, style, prefixWidthFactor),
      codecs: {
        Format.markdown: BlockCodec(
          encode: (block, ctx) =>
              '${ctx.indent}${ctx.ordinal}. ${ctx.content}',
          decode: (line) {
            final match = RegExp(r'^\d+\. ').firstMatch(line);
            if (match == null) return null;
            return DecodeMatch(line.substring(match.end));
          },
        ),
      },
      inputRules: [NumberedListRule()],
    );
  }

  /// Horizontal divider (void block).
  static BlockDef divider({
    Color? color,
    double spacingBefore = 0.4,
  }) {
    return BlockDef(
      label: 'Divider',
      isVoid: true,
      spacingBefore: spacingBefore,
      policies: const BlockPolicies(canBeChild: false, canHaveChildren: false),
      prefixBuilder: (doc, i, block, style) =>
          _dividerPrefix(doc, i, block, style, color),
      codecs: {
        Format.markdown: BlockCodec(
          encode: (block, ctx) => '${ctx.indent}---',
          decode: (line) {
            if (line != '---') return null;
            return const DecodeMatch('');
          },
        ),
      },
      inputRules: [DividerRule(), DividerBackspaceRule()],
    );
  }

  /// Plain paragraph.
  static BlockDef paragraph() {
    return BlockDef(
      label: 'Paragraph',
      policies: const BlockPolicies(canBeChild: true, canHaveChildren: false),
      codecs: {
        Format.markdown: BlockCodec(
          encode: (block, ctx) => '${ctx.indent}${ctx.content}',
        ),
      },
      inputRules: [NestedBackspaceRule()],
    );
  }
}

// ---------------------------------------------------------------------------
// Inlines — built-in inline style definitions.
// ---------------------------------------------------------------------------

/// Built-in [InlineStyleDef] factories.
///
/// ```dart
/// EditorSchema(
///   inlineStyles: {
///     InlineStyle.bold: Inlines.bold(),
///     InlineStyle.link: Inlines.link(color: Colors.teal),
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
          resolvedLink =
              isDark ? const Color(0xFF6CB4EE) : const Color(0xFF1A73E8);
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
            final url = attributes['url'] ?? '';
            return '[$text]($url)';
          },
          decode: (text) {
            final match =
                RegExp(r'^\[([^\]]+)\]\(([^)]+)\)').firstMatch(text);
            if (match == null) return null;
            return InlineDecodeMatch(
              text: match.group(1)!,
              fullMatchLength: match.end,
              attributes: {'url': match.group(2)!},
            );
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
      applyStyle: (base, {attributes = const {}}) =>
          base.copyWith(decoration: TextDecoration.lineThrough),
      codecs: {Format.markdown: const InlineCodec(wrap: '~~')},
      inputRules: [StrikethroughWrapRule()],
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
/// [additionalBlocks] and [additionalInlineStyles] are merged after the
/// built-ins, so custom keys (your own enum) can never collide with future
/// built-in types. Passing a built-in key (e.g. [BlockType.h1]) intentionally
/// overrides that definition.
///
/// **Block ordering matters for input rules and codec decode.** More-specific
/// prefixes must come before shorter ones (h3 before h2 before h1, taskItem
/// before listItem) so they are tried first.
EditorSchema buildStandardSchema({
  // Per-heading overrides (null fields keep defaults).
  HeadingStyle? h1,
  HeadingStyle? h2,
  HeadingStyle? h3,
  // Colors (null = derive from text color brightness).
  Color? linkColor,
  Color? accentColor,
  Color? dividerColor,
  // Spacing & layout.
  double? dividerSpacingBefore,
  double? prefixWidthFactor,
  double? indentPerDepthFactor,
  String? bulletChar,
  // Extensions — merged after built-ins.
  Map<Object, BlockDef>? additionalBlocks,
  Map<Object, InlineStyleDef>? additionalInlineStyles,
}) {
  final pwf = prefixWidthFactor ?? 1.5;

  return EditorSchema(
    prefixWidthFactor: pwf,
    indentPerDepthFactor: indentPerDepthFactor ?? 1.5,
    blocks: {
      // --- Order: specific prefix rules before general ones ---
      BlockType.h3: Blocks.h3(style: h3, prefixWidthFactor: pwf),
      BlockType.h2: Blocks.h2(style: h2, prefixWidthFactor: pwf),
      BlockType.h1: Blocks.h1(style: h1, prefixWidthFactor: pwf),
      BlockType.taskItem:
          Blocks.taskItem(accentColor: accentColor, prefixWidthFactor: pwf),
      BlockType.listItem: Blocks.listItem(
        bulletChar: bulletChar ?? '•',
        prefixWidthFactor: pwf,
      ),
      BlockType.numberedList: Blocks.numberedList(prefixWidthFactor: pwf),
      BlockType.divider: Blocks.divider(
        color: dividerColor,
        spacingBefore: dividerSpacingBefore ?? 0.4,
      ),
      BlockType.paragraph: Blocks.paragraph(),
      if (additionalBlocks != null) ...additionalBlocks,
    },
    inlineStyles: {
      InlineStyle.link: Inlines.link(color: linkColor),
      InlineStyle.bold: Inlines.bold(),
      InlineStyle.italic: Inlines.italic(),
      InlineStyle.strikethrough: Inlines.strikethrough(),
      if (additionalInlineStyles != null) ...additionalInlineStyles,
    },
  );
}

// ---------------------------------------------------------------------------
// Prefix builders — moved from span_builder.dart
// ---------------------------------------------------------------------------

/// Fallback font size when no style is provided.
const double kFallbackFontSize = 16.0;

/// Compute prefix width from a resolved font size and factor.
double prefixWidth(double fontSize, [double factor = 1.5]) => fontSize * factor;

/// Compute indent per depth level from a base font size and factor.
double indentPerDepth(double fontSize, [double factor = 1.5]) =>
    fontSize * factor;

Widget? _bulletPrefix(
  Document doc,
  int flatIndex,
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
  Document doc,
  int flatIndex,
  TextBlock block,
  TextStyle resolvedStyle,
  double pwf,
) {
  final ordinal = computeOrdinal(doc, flatIndex);
  final fontSize = resolvedStyle.fontSize ?? kFallbackFontSize;
  return SizedBox(
    width: prefixWidth(fontSize, pwf),
    child: Center(
      child: Text('$ordinal.', style: TextStyle(fontSize: fontSize, height: 1)),
    ),
  );
}

Widget? _dividerPrefix(
  Document doc,
  int flatIndex,
  TextBlock block,
  TextStyle resolvedStyle,
  Color? overrideColor,
) {
  final color =
      overrideColor ??
      (resolvedStyle.color ?? const Color(0xFF000000)).withOpacity(0.2);
  return Container(
    width: double.infinity,
    height: 1,
    margin: const EdgeInsets.symmetric(vertical: 8),
    color: color,
  );
}

Widget? _taskPrefix(
  Document doc,
  int flatIndex,
  TextBlock block,
  TextStyle resolvedStyle,
  double pwf,
  Color? overrideAccent,
) {
  final checked = block.metadata[kCheckedKey] == true;
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
            color: checked ? accentColor : textColor.withOpacity(0.4),
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

/// Compute the 1-based ordinal for a numbered list item among its siblings.
///
/// Exported so it can be reused by custom numbered-list block defs.
int computeOrdinal(Document doc, int flatIndex) {
  var ordinal = 1;
  final flat = doc.allBlocks;
  final depth = doc.depthOf(flatIndex);

  for (var j = flatIndex - 1; j >= 0; j--) {
    if (doc.depthOf(j) != depth) break;
    if (flat[j].blockType != BlockType.numberedList) break;
    ordinal++;
  }
  return ordinal;
}
