import '../model/block_policies.dart';
import 'block_def.dart';
import 'default_schema.dart';
import 'inline_style_def.dart';

/// Central configuration for the editor.
///
/// Maps block type keys and inline style keys to their definitions.
/// Keys can be any type (typically an enum like [BlockType] or [InlineStyle]),
/// allowing third parties to add custom types alongside the built-in set.
///
/// Use [EditorSchema.standard()] for the built-in block types and styles.
class EditorSchema {
  EditorSchema({
    required this.blocks,
    required this.inlineStyles,
  });

  /// Creates the standard schema with all built-in block types and inline styles.
  factory EditorSchema.standard() => buildStandardSchema();

  /// Block type definitions keyed by block type identifier.
  final Map<Object, BlockDef> blocks;

  /// Inline style definitions keyed by style identifier.
  final Map<Object, InlineStyleDef> inlineStyles;

  /// Look up a block definition. Returns a minimal fallback if not found.
  BlockDef blockDef(Object key) => blocks[key] ?? _fallbackBlockDef;

  /// Look up an inline style definition. Returns a no-op fallback if not found.
  InlineStyleDef inlineStyleDef(Object key) =>
      inlineStyles[key] ?? _fallbackInlineStyleDef;

  /// Aggregate policies map from all registered block defs.
  /// Used by edit operations that need to check structural rules.
  Map<Object, BlockPolicies> get policies =>
      blocks.map((k, v) => MapEntry(k, v.policies));

  /// Whether the block type identified by [key] is list-like.
  bool isListLike(Object key) => blocks[key]?.isListLike ?? false;

  static const _fallbackBlockDef = BlockDef(label: 'Unknown');
  static final _fallbackInlineStyleDef = InlineStyleDef(
    label: 'Unknown',
    applyStyle: (base) => base,
  );
}
