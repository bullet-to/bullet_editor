import 'package:flutter/widgets.dart';

import '../codec/block_codec.dart';
import '../codec/format.dart';
import '../editor/input_rule.dart';
import '../model/block.dart';
import '../model/block_policies.dart';
import '../model/document.dart';

/// Defines the behavior and appearance of a block type.
///
/// Each block type in the editor has a corresponding [BlockDef] that bundles
/// its policies, rendering, codecs, and metadata in one place. Register block
/// defs in an [EditorSchema] to make them available to the editor.
class BlockDef {
  const BlockDef({
    required this.label,
    this.policies = const BlockPolicies(),
    this.isListLike = false,
    this.isVoid = false,
    this.splitInheritsType = false,
    this.baseStyle,
    this.prefixBuilder,
    this.codecs,
    this.inputRules = const [],
  })  : assert(!isVoid || prefixBuilder != null,
            'Void blocks must have a prefixBuilder (it is their visual content)'),
        assert(!isVoid || !isListLike,
            'Void blocks cannot be list-like'),
        assert(!isVoid || !splitInheritsType,
            'Void blocks should not use splitInheritsType');

  /// Human-readable label for toolbars and UI (e.g. "Heading 1", "Paragraph").
  final String label;

  /// Structural rules for this block type (nesting, children, depth limits).
  final BlockPolicies policies;

  /// Whether this block behaves like a list item: gets a prefix, supports
  /// nesting via indent/outdent, Enter creates a sibling, empty+Enter
  /// converts to paragraph.
  final bool isListLike;

  /// Whether this block has no editable text content (e.g. divider).
  /// Void blocks render entirely through their [prefixBuilder] and the cursor
  /// skips over them.
  final bool isVoid;

  /// Whether Enter (SplitBlock) creates a new block of the same type.
  /// True for list-like blocks. False for headings (Enter creates paragraph).
  final bool splitInheritsType;

  /// Returns the base [TextStyle] for this block type, given the editor's
  /// base style. Return null to use the base style unchanged.
  /// Example: headings return a larger font size.
  final TextStyle? Function(TextStyle? base)? baseStyle;

  /// Builds the prefix widget for this block's WidgetSpan (bullet, number,
  /// checkbox, etc.). Return null for no prefix content (indentation-only).
  /// The [doc] and [flatIndex] are provided for context (e.g. computing
  /// ordinals for numbered lists).
  final Widget? Function(Document doc, int flatIndex, TextBlock block)?
      prefixBuilder;

  /// Serialization codecs keyed by [Format]. Each codec defines how this
  /// block type encodes/decodes in that format.
  final Map<Format, BlockCodec>? codecs;

  /// Input rules owned by this block type. Collected by the schema in map
  /// insertion order — define specific rules before general ones.
  final List<InputRule> inputRules;
}
