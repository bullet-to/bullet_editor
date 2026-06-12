import 'package:flutter/widgets.dart';

import '../model/block.dart';
import '../model/doc_selection.dart';
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
    this.selection,
    this.showCaret = false,
    this.onLinkTap,
  });

  final Document document;
  final EditorSchema schema;
  final TextStyle baseStyle;

  /// The current selection; components derive their block-local slice.
  final DocSelection? selection;

  /// Whether the caret should render (the editor has focus).
  final bool showCaret;

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
              // Flat order is pre-order, so the block preceding a root is
              // the previous root subtree's deepest last descendant.
              previousBlockType: index == 0
                  ? null
                  : _lastDescendant(roots[index - 1]).blockType,
              isFirstInDocument: index == 0,
              containsDocumentEnd: index == roots.length - 1,
              selection: selection,
              showCaret: showCaret,
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

/// The flat-order last block within [block]'s subtree.
TextBlock _lastDescendant(TextBlock block) =>
    block.children.isEmpty ? block : _lastDescendant(block.children.last);

/// Renders one block — gutter slot (prefixBuilder) + component — plus its
/// children Column, recursing through the componentBuilder registry.
///
/// Consumes only plain values (the [BlockComponentContext] seam plus what the
/// parent walk already knows) — never the [Document]. This keeps every input
/// value-comparable for the day-10 rebuild-skip predicate: a keystroke
/// elsewhere must not change this widget's inputs.
class BlockSubtree extends StatelessWidget {
  const BlockSubtree({
    super.key,
    required this.block,
    required this.depth,
    required this.ordinal,
    required this.previousBlockType,
    required this.isFirstInDocument,
    required this.containsDocumentEnd,
    required this.schema,
    required this.baseStyle,
    this.selection,
    this.showCaret = false,
    this.onLinkTap,
  });

  final TextBlock block;
  final int depth;
  final int ordinal;

  /// Block type of the flat-order predecessor (spacing collapse partner);
  /// null for the document's first block.
  final String? previousBlockType;

  final bool isFirstInDocument;

  /// Whether this subtree's last descendant is the document's last block.
  final bool containsDocumentEnd;

  /// The document selection; this widget derives only same-block slices
  /// (caret offset, void atomic selection), so no [Document] is needed.
  final DocSelection? selection;

  /// Whether the caret should render (the editor has focus).
  final bool showCaret;

  final EditorSchema schema;
  final TextStyle baseStyle;
  final void Function(String blockId, int offset, InlineEntitySnapshot entity)?
  onLinkTap;

  /// The collapsed caret offset when it sits in this block (and the editor
  /// has focus).
  int? get _caretOffset {
    final sel = selection;
    if (!showCaret || sel == null || !sel.isCollapsed) return null;
    return sel.extent.blockId == block.id ? sel.extent.offset : null;
  }

  /// Whether this block is atomically selected (a void's whole-block
  /// selection: both endpoints in this block, non-collapsed).
  bool get _isSelected {
    final sel = selection;
    return sel != null &&
        !sel.isCollapsed &&
        sel.base.blockId == block.id &&
        sel.extent.blockId == block.id;
  }

  @override
  Widget build(BuildContext context) {
    final def = schema.blockDef(block.blockType);
    final resolvedStyle = def.baseStyle?.call(baseStyle) ?? baseStyle;
    final baseFontSize = baseStyle.fontSize ?? kFallbackFontSize;

    final gutter = GutterContext(
      ordinal: ordinal,
      depth: depth,
      isFirstInDocument: isFirstInDocument,
      isLastInDocument: containsDocumentEnd && block.children.isEmpty,
    );

    final componentContext = BlockComponentContext(
      block: block,
      schema: schema,
      gutter: gutter,
      resolvedStyle: resolvedStyle,
      caretOffset: _caretOffset,
      isSelected: _isSelected,
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
    if (previousBlockType != null) {
      final prevAfter = schema.blockDef(previousBlockType!).spacingAfter;
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
    for (var i = 0; i < block.children.length; i++) {
      final child = block.children[i];
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
          // Pre-order: a first child follows its parent; later children
          // follow the previous sibling subtree's deepest last descendant.
          previousBlockType: i == 0
              ? block.blockType
              : _lastDescendant(block.children[i - 1]).blockType,
          isFirstInDocument: false,
          containsDocumentEnd:
              containsDocumentEnd && i == block.children.length - 1,
          selection: selection,
          showCaret: showCaret,
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
