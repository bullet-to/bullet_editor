/// Structural rules for a block type.
///
/// Enforced by operations (IndentBlock, ChangeBlockType, etc.) — batches
/// that violate policies are rejected.
///
/// Future fields to add when needed:
/// - allowedChildren: `Set<String>?` — restrict which types can nest under this
/// - allowedInlineStyles: `Set<String>?` — restrict formatting (e.g. code blocks)
/// See docs/archive/future-enhancements.md for details.
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

// -- Behavior policies --
//
// Convention (stated once, architecture §BlockDef): behavior variation is
// expressed as named policies with enumerated values, never as booleans.
// Booleans are reserved for structural *kind* facts (e.g. `isVoid`).

/// What Enter does at all on this block type.
enum OnEnter {
  /// Split the block (the default for every text block).
  split,

  /// Insert a literal `\n` at the caret instead of splitting — code blocks
  /// store multi-line content as a single block.
  insertLineBreak,
}

/// What type the new block gets when Enter splits a block.
enum SplitNewBlockType {
  /// The new block keeps the split block's type (list items continue lists).
  inherit,

  /// The new block is the schema's default type (headings, paragraphs).
  defaultType,
}

/// What Enter does on an *empty* block of this type.
enum OnSplitEmpty {
  /// Convert the block to the schema's default type instead of splitting
  /// (empty list item + Enter ends the list).
  convertToDefault,

  /// Just split normally.
  none,
}

/// What Enter does for a block type. Consulted by the controller's Enter
/// path ([OnEnter], [OnSplitEmpty]) and by `SplitBlock.apply` via
/// `EditContext` ([SplitNewBlockType]).
class SplitPolicy {
  const SplitPolicy({
    this.onEnter = OnEnter.split,
    this.newBlockType = SplitNewBlockType.defaultType,
    this.onSplitEmpty = OnSplitEmpty.none,
  });

  /// The list-item shape: Enter continues the type, Enter-on-empty converts
  /// to the default type.
  static const listLike = SplitPolicy(
    newBlockType: SplitNewBlockType.inherit,
    onSplitEmpty: OnSplitEmpty.convertToDefault,
  );

  /// The code-block shape: Enter inserts a literal line break.
  static const lineBreak = SplitPolicy(onEnter: OnEnter.insertLineBreak);

  final OnEnter onEnter;
  final SplitNewBlockType newBlockType;
  final OnSplitEmpty onSplitEmpty;
}

/// What backspace at offset 0 does, for TEXT blocks. (Void blocks have the
/// separate [VoidBackspacePolicy].)
enum BackspaceAtStartPolicy {
  /// Merge with the previous block (the paragraph default).
  merge,

  /// Convert to the schema's default type (headings).
  convertToDefault,

  /// Outdent if nested, else convert to the default type (list items).
  outdentOrConvert,
}

/// What backspace does when the caret sits at the start of the block AFTER
/// a void block — the behavior belongs to the void block's type.
enum VoidBackspacePolicy {
  /// First backspace selects the void (`[0,1)`); the second deletes it
  /// (image — Notion behavior).
  selectFirst,

  /// The void is deleted on the first backspace (divider — v2 behavior).
  immediateDelete,
}
