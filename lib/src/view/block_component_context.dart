import 'package:flutter/widgets.dart';

import '../model/block.dart';
import '../model/inline_entity.dart';
import '../schema/block_def.dart';
import '../schema/editor_schema.dart';

/// Build inputs for a block component — the declared view-model seam:
/// components consume only this tuple, so a computed view-model layer can be
/// inserted behind it later without touching components.
///
/// The block-local selection slice is [caretOffset] + [isSelected] today;
/// day 10 widens it with the range-highlight slice. The reserved
/// [BlockDef.semanticsBuilder] hook covers future editing semantics (GATE-A).
class BlockComponentContext {
  const BlockComponentContext({
    required this.block,
    required this.schema,
    required this.gutter,
    required this.resolvedStyle,
    this.caretOffset,
    this.isSelected = false,
    this.onLinkTap,
  });

  final TextBlock block;
  final EditorSchema schema;

  /// Derived gutter state (ordinal, depth, first/last-in-document flags) —
  /// the value-compared half of the rebuild key.
  final GutterContext gutter;

  /// The block's resolved text style (editor base style folded through the
  /// def's `baseStyle`).
  final TextStyle resolvedStyle;

  /// The collapsed caret's block-local offset, when the caret is in this
  /// block and the editor has focus; null otherwise.
  final int? caretOffset;

  /// Whether this (void) block is atomically selected — its `[0,1)` is the
  /// whole selection (D3). Range-spanning selection slices arrive day 10.
  final bool isSelected;

  /// Link/entity tap surface (D3) — driven by the link-span recognizers in
  /// the default text component.
  final void Function(String blockId, int offset, InlineEntitySnapshot entity)?
  onLinkTap;
}

/// Builds a block's component widget. Registered on [BlockDef].
typedef BlockComponentBuilder = Widget Function(BlockComponentContext context);
