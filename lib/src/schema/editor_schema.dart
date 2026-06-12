import '../codec/format.dart';
import '../editor/edit_operation.dart';
import '../editor/input_rule.dart';
import '../model/block.dart';
import '../model/block_policies.dart';
import 'block_def.dart';
import 'default_schema.dart';
import 'inline_entity_def.dart';
import 'inline_style_def.dart';

/// Central configuration for the editor.
///
/// Maps block type keys and inline style/entity keys — all string keys — to
/// their definitions. Use the const key holders ([ParagraphKeys],
/// [InlineStyleKeys], …) for typo-safety; startup [validate] replaces enum
/// exhaustiveness as the "don't forget an item" guarantee.
///
/// Use [EditorSchema.standard()] for the built-in block types, formatting
/// styles, and inline entity keys.
class EditorSchema {
  EditorSchema({
    required this.defaultBlockType,
    required this.blocks,
    required this.inlineStyles,
    this.inlineEntities = const {},
    this.prefixWidthFactor = 1.5,
    this.indentPerDepthFactor = 1.5,
  });

  /// Creates the standard schema with all built-in block types and inline styles.
  static EditorSchema standard() => buildStandardSchema();

  /// The block type used for new blocks (Enter on non-list blocks, empty
  /// list item → paragraph, heading backspace → paragraph, etc.).
  final String defaultBlockType;

  /// Block type definitions keyed by block type key.
  final Map<String, BlockDef> blocks;

  /// Formatting-style definitions keyed by style key.
  final Map<String, InlineStyleDef> inlineStyles;

  /// Public inline entity definitions keyed by entity key.
  final Map<String, InlineEntityDef> inlineEntities;

  /// Width of the prefix area (bullet/number/checkbox) as a multiplier of
  /// the block's resolved font size.
  final double prefixWidthFactor;

  /// Additional indent per nesting depth level as a multiplier of the base
  /// font size.
  final double indentPerDepthFactor;

  /// Look up a block definition. Returns a minimal fallback if not found
  /// (deliberate forward-compat degradation for persisted documents carrying
  /// keys from a richer schema).
  BlockDef blockDef(Object key) => blocks[key] ?? _fallbackBlockDef;

  /// Look up an inline style definition. Returns a no-op fallback if not found.
  InlineStyleDef inlineStyleDef(Object key) =>
      inlineStyles[key] ?? _fallbackInlineStyleDef;

  /// Whether [key] is a registered formatting-style key.
  bool isInlineStyleKey(Object key) => inlineStyles.containsKey(key);

  /// Look up the rendering/codec definition for any inline key.
  InlineStyleDef inlinePresentationDef(Object key) =>
      inlineStyles[key] ??
      inlineEntities[key]?.style ??
      _fallbackInlineStyleDef;

  /// Look up an inline entity definition by its key.
  InlineEntityDef? inlineEntityDef(Object key) => inlineEntities[key];

  /// Aggregate policies map from all registered block defs.
  /// Used by edit operations that need to check structural rules.
  /// Cached — the schema is immutable after construction.
  late final Map<String, BlockPolicies> policies = Map.unmodifiable(
    blocks.map((k, v) => MapEntry(k, v.policies)),
  );

  /// Whether the block type identified by [key] is a void block (no text).
  bool isVoid(Object key) => blocks[key]?.isVoid ?? false;

  /// The Enter policy for a block type (total — unknown keys get defaults).
  SplitPolicy splitPolicyOf(String key) =>
      blocks[key]?.split ?? const SplitPolicy();

  /// The backspace-at-start policy for a text block type.
  BackspaceAtStartPolicy backspaceAtStartOf(String key) =>
      blocks[key]?.backspaceAtStart ?? BackspaceAtStartPolicy.merge;

  /// The [EditContext] this schema supplies to `EditOperation.apply` —
  /// used by the controller per batch, and directly by tests. Cached: the
  /// schema is immutable, so one context serves every batch.
  EditContext editContext() => _editContext;

  late final EditContext _editContext = EditContext(
    defaultBlockType: defaultBlockType,
    splitPolicyOf: splitPolicyOf,
    backspaceAtStartOf: backspaceAtStartOf,
    newBlockMetadataOf: (type) => blocks[type]?.newBlockMetadata,
    policies: policies,
    isVoid: isVoid,
  );

  /// Collect all input rules from block defs, inline entities, then formatting
  /// styles in map insertion order. This determines rule priority — more
  /// specific entity rules like links should run before general wrap-style
  /// rules like bold/italic.
  List<InputRule> get inputRules => [
    for (final def in blocks.values) ...def.inputRules,
    for (final def in inlineEntities.values) ...def.style.inputRules,
    for (final def in inlineStyles.values) ...def.inputRules,
  ];

  /// Startup schema validation (GATE-K). Call as `assert(schema.validate())`
  /// — runs in debug mode from the `BulletEditor` constructor.
  ///
  /// Returns true when valid; throws [StateError] naming the first violation:
  /// - every block type renders: non-void (default text component) or
  ///   `componentBuilder != null`;
  /// - every block type has a markdown codec (the canonical format);
  /// - void types declare a `voidBackspace` policy;
  /// - every inline key declared by a registered rule
  ///   ([InputRule.referencedInlineKeys]) is registered;
  /// - every type with declared `metadataKeys` defines `newBlockMetadata`,
  ///   and the keys it emits are a subset of the declared set;
  /// - the default block type is registered, text, and child-eligible enough
  ///   to serve as the universal fallback.
  bool validate() {
    final defaultDef = blocks[defaultBlockType];
    if (defaultDef == null) {
      throw StateError(
        'EditorSchema: defaultBlockType "$defaultBlockType" is not registered',
      );
    }
    if (defaultDef.isVoid) {
      throw StateError(
        'EditorSchema: defaultBlockType "$defaultBlockType" must not be void',
      );
    }

    for (final entry in blocks.entries) {
      final key = entry.key;
      final def = entry.value;
      if (def.isVoid && def.componentBuilder == null) {
        throw StateError(
          'EditorSchema: void block type "$key" must provide a '
          'componentBuilder (voids are not text-defaultable)',
        );
      }
      if (def.isVoid && def.voidBackspace == null) {
        throw StateError(
          'EditorSchema: void block type "$key" must declare a '
          'voidBackspace policy',
        );
      }
      if (def.codecs == null || !def.codecs!.containsKey(Format.markdown)) {
        throw StateError(
          'EditorSchema: block type "$key" has no markdown codec '
          '(markdown is the canonical format)',
        );
      }
      if (def.metadataKeys.isNotEmpty) {
        final newBlockMetadata = def.newBlockMetadata;
        if (newBlockMetadata == null) {
          throw StateError(
            'EditorSchema: block type "$key" declares metadataKeys '
            '${def.metadataKeys} but does not define newBlockMetadata',
          );
        }
        final probe = TextBlock(id: 'validate-probe', blockType: key);
        final emitted = newBlockMetadata(probe).keys.toSet();
        final undeclared = emitted.difference(def.metadataKeys);
        if (undeclared.isNotEmpty) {
          throw StateError(
            'EditorSchema: block type "$key"\'s newBlockMetadata emits '
            'undeclared keys $undeclared (declared: ${def.metadataKeys})',
          );
        }
      }
    }

    for (final rule in inputRules) {
      for (final inlineKey in rule.referencedInlineKeys) {
        if (!inlineStyles.containsKey(inlineKey) &&
            !inlineEntities.containsKey(inlineKey)) {
          throw StateError(
            'EditorSchema: input rule $rule references inline key '
            '"$inlineKey", which is registered as neither an inline style '
            'nor an inline entity',
          );
        }
      }
    }

    return true;
  }

  static const _fallbackBlockDef = BlockDef(label: 'Unknown');
  static final _fallbackInlineStyleDef = InlineStyleDef(
    label: 'Unknown',
    applyStyle: (base, {attributes = const {}}) => base,
  );
}
