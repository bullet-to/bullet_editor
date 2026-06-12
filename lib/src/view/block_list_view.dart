import 'package:flutter/widgets.dart';

import '../model/block.dart';
import '../model/document.dart';
import '../model/inline_entity.dart';
import '../schema/block_def.dart';
import '../schema/default_schema.dart' show kFallbackFontSize;
import '../schema/editor_schema.dart';
import 'block_component_context.dart';
import 'components/default_text_component.dart';

/// Lazy sliver over the document's TOP-LEVEL blocks (D5): a root block and
/// its descendants are one builder item. Outliner documents are wide at the
/// root, and this makes child indent layout trivial (a Padding per depth).
/// Nothing outside this file knows the nesting strategy.
class BlockListView extends StatelessWidget {
  const BlockListView({
    super.key,
    required this.document,
    required this.schema,
    required this.baseStyle,
    this.onLinkTap,
  });

  final Document document;
  final EditorSchema schema;
  final TextStyle baseStyle;
  final void Function(String blockId, int offset, InlineEntitySnapshot entity)?
  onLinkTap;

  @override
  Widget build(BuildContext context) {
    final roots = document.blocks;
    // Stable reconciliation under reorder: keys are block ids.
    final rootIndexById = {
      for (var i = 0; i < roots.length; i++) roots[i].id: i,
    };

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final block = roots[index];
          return KeyedSubtree(
            key: ValueKey(block.id),
            child: BlockSubtree(
              block: block,
              depth: 0,
              ordinal: _rootOrdinal(roots, index),
              document: document,
              schema: schema,
              baseStyle: baseStyle,
              onLinkTap: onLinkTap,
            ),
          );
        },
        childCount: roots.length,
        findChildIndexCallback: (key) =>
            rootIndexById[(key as ValueKey<String>).value],
      ),
    );
  }

  /// 1-based position of root [index] in its contiguous same-type run.
  static int _rootOrdinal(List<TextBlock> roots, int index) {
    var ordinal = 1;
    for (var i = index - 1; i >= 0; i--) {
      if (roots[i].blockType != roots[index].blockType) break;
      ordinal++;
    }
    return ordinal;
  }
}

/// Renders one block — gutter slot (prefixBuilder) + component — plus its
/// children Column, recursing through the componentBuilder registry.
class BlockSubtree extends StatelessWidget {
  const BlockSubtree({
    super.key,
    required this.block,
    required this.depth,
    required this.ordinal,
    required this.document,
    required this.schema,
    required this.baseStyle,
    this.onLinkTap,
  });

  final TextBlock block;
  final int depth;
  final int ordinal;
  final Document document;
  final EditorSchema schema;
  final TextStyle baseStyle;
  final void Function(String blockId, int offset, InlineEntitySnapshot entity)?
  onLinkTap;

  @override
  Widget build(BuildContext context) {
    final def = schema.blockDef(block.blockType);
    final resolvedStyle = def.baseStyle?.call(baseStyle) ?? baseStyle;
    final baseFontSize = baseStyle.fontSize ?? kFallbackFontSize;

    final allBlocks = document.allBlocks;
    final gutter = GutterContext(
      ordinal: ordinal,
      depth: depth,
      isFirstInDocument: allBlocks.isNotEmpty && block.id == allBlocks.first.id,
      isLastInDocument: allBlocks.isNotEmpty && block.id == allBlocks.last.id,
    );

    final componentContext = BlockComponentContext(
      block: block,
      schema: schema,
      gutter: gutter,
      resolvedStyle: resolvedStyle,
      onLinkTap: onLinkTap,
    );

    final component = def.componentBuilder != null
        ? def.componentBuilder!(componentContext)
        : DefaultTextComponent(componentContext);

    final prefix = def.prefixBuilder?.call(block, gutter, resolvedStyle);

    Widget row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ?prefix,
        Expanded(child: component),
      ],
    );

    // Per-block spacing as real outer padding (the point of tier 3), in em
    // units of the editor base font size. v2 semantics, ported exactly: ONE
    // collapsed gap per flat-adjacent block pair — max(previous block's
    // spacingAfter, this block's spacingBefore) — applied as top padding
    // only (checkpoint-1 finding: additive before+after double-spaced
    // pairs, and a trailing spacingAfter has no v2 equivalent).
    final flatIndex = document.idToFlatIndex[block.id];
    if (flatIndex != null && flatIndex > 0) {
      final prevBlock = document.allBlocks[flatIndex - 1];
      final prevAfter = schema.blockDef(prevBlock.blockType).spacingAfter;
      final gapEm = def.spacingBefore > prevAfter
          ? def.spacingBefore
          : prevAfter;
      if (gapEm > 0) {
        row = Padding(
          padding: EdgeInsets.only(top: gapEm * baseFontSize),
          child: row,
        );
      }
    }

    if (block.children.isEmpty) return row;

    // Children: ordinals computed per contiguous same-type run.
    final children = <Widget>[];
    var runOrdinal = 0;
    String? runType;
    for (final child in block.children) {
      if (child.blockType == runType) {
        runOrdinal++;
      } else {
        runType = child.blockType;
        runOrdinal = 1;
      }
      children.add(
        BlockSubtree(
          key: ValueKey(child.id),
          block: child,
          depth: depth + 1,
          ordinal: runOrdinal,
          document: document,
          schema: schema,
          baseStyle: baseStyle,
          onLinkTap: onLinkTap,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        Padding(
          padding: EdgeInsets.only(
            left: baseFontSize * schema.indentPerDepthFactor,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ],
    );
  }
}
