import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../codec/block_codec.dart';
import '../codec/format.dart';
import '../editor/input_rule.dart';
import '../model/block.dart';
import '../model/block_policies.dart';
import '../view/block_component_context.dart';

/// Derived gutter state handed to [BlockDef.prefixBuilder] — exactly the
/// values the rebuild-skip predicate already computes, so custom gutter
/// builders never re-derive ordinals from a document walk.
class GutterContext {
  const GutterContext({
    required this.ordinal,
    required this.depth,
    required this.isFirstInDocument,
    required this.isLastInDocument,
  });

  /// 1-based position among consecutive same-type siblings (numbered lists).
  final int ordinal;

  /// Nesting depth; root blocks are 0.
  final int depth;

  final bool isFirstInDocument;
  final bool isLastInDocument;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GutterContext &&
          ordinal == other.ordinal &&
          depth == other.depth &&
          isFirstInDocument == other.isFirstInDocument &&
          isLastInDocument == other.isLastInDocument;

  @override
  int get hashCode =>
      Object.hash(ordinal, depth, isFirstInDocument, isLastInDocument);
}

/// Reserved hook for per-block editing semantics (GATE-A). Not consumed at
/// launch. Post-launch, editing semantics (`isTextField`, `onSetSelection`,
/// `onMoveCursor*`) are added by implementing this per type and routing the
/// actions to controller methods through the single-writer queue.
typedef SemanticsConfigurationHook =
    void Function(SemanticsConfiguration config, TextBlock block);

/// Defines the behavior and appearance of a block type.
///
/// Each block type in the editor has a corresponding [BlockDef] that bundles
/// its policies, rendering, codecs, and metadata in one place. Register block
/// defs in an [EditorSchema] under a string key to make them available to the
/// editor.
///
/// Behavior variation is expressed as named policies with enumerated values
/// ([split], [backspaceAtStart], [voidBackspace]), never as booleans; the only
/// boolean is [isVoid], a structural *kind* fact.
class BlockDef {
  const BlockDef({
    required this.label,
    this.policies = const BlockPolicies(),
    this.isVoid = false,
    this.split = const SplitPolicy(),
    this.backspaceAtStart = BackspaceAtStartPolicy.merge,
    this.voidBackspace,
    this.headingLevel,
    this.spacingBefore = 0.0,
    this.spacingAfter = 0.0,
    this.baseStyle,
    this.prefixBuilder,
    this.componentBuilder,
    this.semanticsBuilder,
    this.metadataKeys = const {},
    this.newBlockMetadata,
    this.codecs,
    this.inputRules = const [],
  });

  /// Human-readable label for toolbars and UI (e.g. "Heading 1", "Paragraph").
  final String label;

  /// Structural rules for this block type (nesting, children, depth limits).
  final BlockPolicies policies;

  /// Whether this block has no editable text content (e.g. divider, image).
  /// A kind fact, not a behavior toggle: selection's `[0,1)` handling, the
  /// IME's serialization, and component rendering all branch on what the
  /// block *is*. Void types must provide a [componentBuilder] and declare a
  /// [voidBackspace] policy (checked by `EditorSchema.validate()`).
  final bool isVoid;

  /// What Enter does on this block type.
  final SplitPolicy split;

  /// What backspace at offset 0 does, for text blocks.
  final BackspaceAtStartPolicy backspaceAtStart;

  /// What backspace does when the caret sits at the start of the block after
  /// a void of this type. Required for void types; null otherwise.
  final VoidBackspacePolicy? voidBackspace;

  /// Semantics-side declaration: the heading level (1–6) announced to screen
  /// readers, or null for non-headings. This is deliberately separate from
  /// editing behavior — heading-ness is a semantics fact to the a11y layer
  /// and a [backspaceAtStart] policy to the editing layer.
  final int? headingLevel;

  /// Vertical spacing before this block, in em units (multiples of the base
  /// font size). Rendered as real padding above the block's component.
  /// 0.0 means no extra spacing. Only applies when the block is not the first
  /// in the document. Typical values: h1 1.0, h2 0.8, divider 0.4.
  final double spacingBefore;

  /// Vertical spacing after this block, in em units (multiples of the base
  /// font size). Rendered as real padding below the block's component.
  /// 0.0 means no extra spacing. Only applies when the block is not the last
  /// in the document.
  final double spacingAfter;

  /// Returns the base [TextStyle] for this block type, given the editor's
  /// base style. Return null to use the base style unchanged.
  /// Example: headings return a larger font size.
  final TextStyle? Function(TextStyle? base)? baseStyle;

  /// Builds the gutter prefix widget (bullet, number, checkbox, quote bar).
  /// Return null for no prefix content (indentation-only).
  ///
  /// [gutter] carries the derived gutter state (ordinal, depth, first/last
  /// flags); [resolvedStyle] is the block's resolved [TextStyle] so prefixes
  /// can scale with the text.
  final Widget? Function(
    TextBlock block,
    GutterContext gutter,
    TextStyle resolvedStyle,
  )?
  prefixBuilder;

  /// Builds the block's component widget. Omit for text blocks to render via
  /// the default text component (styled by [baseStyle]); required for void
  /// types.
  final BlockComponentBuilder? componentBuilder;

  /// Reserved per-block editing-semantics hook (GATE-A). Null at launch.
  final SemanticsConfigurationHook? semanticsBuilder;

  /// The metadata keys this block type uses (e.g. taskItem:
  /// `{TaskItemKeys.checked}`). Declared so `validate()` can check
  /// [newBlockMetadata] and `setBlockMetadata` can assert key typos.
  final Set<String> metadataKeys;

  /// Metadata for the new block created when a block of this type splits
  /// (e.g. taskItem → `{TaskItemKeys.checked: false}`). Null ⇒ empty map.
  /// Reaches `SplitBlock.apply` through `EditContext`.
  final Map<String, dynamic> Function(TextBlock splitBlock)? newBlockMetadata;

  /// Serialization codecs keyed by [Format]. Each codec defines how this
  /// block type encodes/decodes in that format. Markdown is the canonical
  /// format and is required by `validate()`.
  final Map<Format, BlockCodec>? codecs;

  /// Input rules owned by this block type. Collected by the schema in map
  /// insertion order — define specific rules before general ones.
  final List<InputRule> inputRules;
}
