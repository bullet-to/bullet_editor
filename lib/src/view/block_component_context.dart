import 'package:flutter/widgets.dart';

import '../model/block.dart';
import '../model/inline_entity.dart';
import '../schema/block_def.dart';
import '../schema/editor_schema.dart';

/// Build inputs for a block component — the declared view-model seam:
/// components consume only this tuple, so a computed view-model layer can be
/// inserted behind it later without touching components.
///
/// The day 3–4 controller skeleton adds the controller reference and the
/// block-local selection slice; the reserved [BlockDef.semanticsBuilder] hook
/// covers future editing semantics (GATE-A).
class BlockComponentContext {
  const BlockComponentContext({
    required this.block,
    required this.schema,
    required this.gutter,
    required this.resolvedStyle,
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

  /// Link/entity tap surface (D3) — driven by the link-span recognizers in
  /// the default text component.
  final void Function(String blockId, int offset, InlineEntitySnapshot entity)?
  onLinkTap;
}

/// Builds a block's component widget. Registered on [BlockDef].
typedef BlockComponentBuilder = Widget Function(BlockComponentContext context);
