/// Structural rules for a block type.
///
/// Enforced by operations (IndentBlock, ChangeBlockType, etc.) — transactions
/// that violate policies become no-ops.
///
/// Future fields to add when needed:
/// - allowedChildren: Set<BlockType>? — restrict which types can nest under this
/// - allowedInlineStyles: Set<InlineStyle>? — restrict formatting (e.g. code blocks)
/// See context/future-enhancements.md for details.
class BlockPolicies {
  const BlockPolicies({
    this.canBeChild = true,
    this.canHaveChildren = false,
    this.maxDepth,
  });

  /// Can this block be nested under another block?
  /// Headings: false. List items, paragraphs: true.
  final bool canBeChild;

  /// Can this block contain child blocks?
  /// List items: true. Paragraphs, headings: false.
  final bool canHaveChildren;

  /// Maximum nesting depth for this block type. null = unlimited.
  final int? maxDepth;
}
