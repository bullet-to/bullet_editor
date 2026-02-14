import '../editor/input_rule.dart';
import '../model/block.dart';
import '../model/block_policies.dart';
import 'block_def.dart';
import 'default_schema.dart';
import 'inline_style_def.dart';

/// Central configuration for the editor.
///
/// Maps block type keys and inline style keys to their definitions.
/// [B] is the block type key (typically an enum like [BlockType]).
/// [S] is the inline style key (typically an enum like [InlineStyle]).
///
/// Use [EditorSchema.standard()] for the built-in block types and styles.
class EditorSchema<B extends Object, S extends Object> {
  EditorSchema({
    required this.defaultBlockType,
    required this.blocks,
    required this.inlineStyles,
    this.prefixWidthFactor = 1.5,
    this.indentPerDepthFactor = 1.5,
  });

  /// Creates the standard schema with all built-in block types and inline styles.
  static EditorSchema<BlockType, InlineStyle> standard() =>
      buildStandardSchema();

  /// The block type used for new blocks (Enter on non-list blocks, empty
  /// list item → paragraph, heading backspace → paragraph, etc.).
  final B defaultBlockType;

  /// Block type definitions keyed by block type identifier.
  final Map<B, BlockDef> blocks;

  /// Inline style definitions keyed by style identifier.
  final Map<S, InlineStyleDef> inlineStyles;

  /// Width of the prefix area (bullet/number/checkbox) as a multiplier of
  /// the block's resolved font size.
  final double prefixWidthFactor;

  /// Additional indent per nesting depth level as a multiplier of the base
  /// font size.
  final double indentPerDepthFactor;

  /// Look up a block definition. Returns a minimal fallback if not found.
  BlockDef blockDef(Object key) => blocks[key] ?? _fallbackBlockDef;

  /// Look up an inline style definition. Returns a no-op fallback if not found.
  InlineStyleDef inlineStyleDef(Object key) =>
      inlineStyles[key] ?? _fallbackInlineStyleDef;

  /// Aggregate policies map from all registered block defs.
  /// Used by edit operations that need to check structural rules.
  Map<B, BlockPolicies> get policies =>
      blocks.map((k, v) => MapEntry(k, v.policies));

  /// Whether the block type identified by [key] is list-like.
  bool isListLike(Object key) => blocks[key]?.isListLike ?? false;

  /// Whether the block type identified by [key] is a void block (no text).
  bool isVoid(Object key) => blocks[key]?.isVoid ?? false;

  /// Whether the block type identified by [key] is a heading.
  bool isHeading(Object key) => blocks[key]?.isHeading ?? false;

  /// Collect all input rules from block defs then inline style defs,
  /// in map insertion order. This determines rule priority — specific
  /// rules must come before general ones in the schema's map ordering.
  List<InputRule> get inputRules => [
        for (final def in blocks.values) ...def.inputRules,
        for (final def in inlineStyles.values) ...def.inputRules,
      ];

  static const _fallbackBlockDef = BlockDef(label: 'Unknown');
  static final _fallbackInlineStyleDef = InlineStyleDef(
    label: 'Unknown',
    applyStyle: (base, {attributes = const {}}) => base,
  );
}
