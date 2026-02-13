import 'package:flutter/widgets.dart';

import '../model/block.dart';
import '../model/document.dart';
import '../model/inline_style.dart';
import 'edit_operation.dart';
import 'transaction.dart';

/// Input rules intercept pending transactions before commit and can
/// transform them. This is how markdown shortcuts work in WYSIWYG mode.
///
/// Return a modified [Transaction] to transform the edit, or null to
/// let it pass through unchanged.
abstract class InputRule {
  Transaction? tryTransform(Transaction pending, Document doc);
}

/// Detects a wrap-delimiter pattern (e.g. `**text**`, `*text*`, `~~text~~`)
/// and converts it to the corresponding inline style.
///
/// When the user types the closing delimiter that completes the pattern:
/// 1. Find the delimiter pair in the resulting text
/// 2. Strip both delimiters
/// 3. Apply the style to the enclosed text
class InlineWrapRule extends InputRule {
  InlineWrapRule(this.delimiter, this.style)
    : _pattern = RegExp(
        '${RegExp.escape(delimiter)}(.+?)${RegExp.escape(delimiter)}',
      );

  final String delimiter;
  final InlineStyle style;
  final RegExp _pattern;

  @override
  Transaction? tryTransform(Transaction pending, Document doc) {
    final insertOp = _findInsertOp(pending);
    if (insertOp == null) return null;

    final resultDoc = pending.apply(doc);
    final delimLen = delimiter.length;

    for (var i = 0; i < resultDoc.allBlocks.length; i++) {
      final block = resultDoc.allBlocks[i];
      final text = block.plainText;

      final editBlock = insertOp.blockIndex;
      final editEnd = insertOp.offset + insertOp.text.length;
      if (editBlock != i) continue;

      final match = _pattern
          .allMatches(text)
          .cast<RegExpMatch?>()
          .firstWhere((m) => m!.end == editEnd, orElse: () => null);
      if (match == null) continue;

      final fullMatchStart = match.start;
      final innerText = match.group(1)!;
      final innerEnd = fullMatchStart + delimLen + innerText.length;

      final ops = <EditOperation>[
        ...pending.operations,
        DeleteText(i, innerEnd, delimLen), // remove closing delimiter
        DeleteText(i, fullMatchStart, delimLen), // remove opening delimiter
        ToggleStyle(
          i,
          fullMatchStart,
          fullMatchStart + innerText.length,
          style,
        ),
      ];

      final blockStartGlobal = resultDoc.globalOffset(i, 0);
      final cursorOffset =
          blockStartGlobal + fullMatchStart + innerText.length;

      return Transaction(
        operations: ops,
        selectionAfter: pending.selectionAfter?.copyWith(
          baseOffset: cursorOffset,
          extentOffset: cursorOffset,
        ),
      );
    }

    return null;
  }
}

/// Convenience constructors for common inline wrap rules.
/// Order matters: register BoldWrapRule before ItalicWrapRule so `**` is
/// checked before `*`.
class BoldWrapRule extends InlineWrapRule {
  BoldWrapRule() : super('**', InlineStyle.bold);
}

class ItalicWrapRule extends InlineWrapRule {
  ItalicWrapRule() : super('*', InlineStyle.italic);
}

class StrikethroughWrapRule extends InlineWrapRule {
  StrikethroughWrapRule() : super('~~', InlineStyle.strikethrough);
}

/// Detects `[text](url)` typed inline and converts to a link.
///
/// Fires when the user types the closing `)` that completes the pattern.
/// Strips the markdown syntax, applies the link style, and sets the URL
/// attribute on the resulting text.
class LinkWrapRule extends InputRule {
  static final _pattern = RegExp(r'\[([^\]]+)\]\(([^)]+)\)');

  @override
  Transaction? tryTransform(Transaction pending, Document doc) {
    final insertOp = _findInsertOp(pending);
    if (insertOp == null || insertOp.text != ')') return null;

    final resultDoc = pending.apply(doc);
    final i = insertOp.blockIndex;
    if (i >= resultDoc.allBlocks.length) return null;

    final block = resultDoc.allBlocks[i];
    final text = block.plainText;
    final editEnd = insertOp.offset + insertOp.text.length;

    final match = _pattern
        .allMatches(text)
        .cast<RegExpMatch?>()
        .firstWhere((m) => m!.end == editEnd, orElse: () => null);
    if (match == null) return null;

    final linkText = match.group(1)!;
    final url = match.group(2)!;
    final fullMatchStart = match.start;
    final fullMatchLength = match.end - match.start;

    final blockStartGlobal = resultDoc.globalOffset(i, 0);
    final cursorOffset = blockStartGlobal + fullMatchStart + linkText.length;

    return Transaction(
      operations: [
        ...pending.operations,
        // Delete the entire [text](url) and replace with just the text.
        DeleteText(i, fullMatchStart, fullMatchLength),
        InsertText(i, fullMatchStart, linkText,
            styles: {InlineStyle.link}, attributes: {'url': url}),
      ],
      selectionAfter: pending.selectionAfter?.copyWith(
        baseOffset: cursorOffset,
        extentOffset: cursorOffset,
      ),
    );
  }
}

/// Detects a prefix (e.g. "# ", "- ") typed at the start of a paragraph
/// and converts the block to the specified type.
///
/// Fires when the user types a space after the prefix character at position 0.
class PrefixBlockRule extends InputRule {
  PrefixBlockRule(this.prefix, this.targetType);

  /// The prefix character before the space (e.g. "#", "-").
  final String prefix;
  final BlockType targetType;

  @override
  Transaction? tryTransform(Transaction pending, Document doc) {
    final insertOp = _findInsertOp(pending);
    if (insertOp == null || insertOp.text != ' ') return null;
    if (insertOp.offset != prefix.length) return null;

    final resultDoc = pending.apply(doc);
    final i = insertOp.blockIndex;
    if (i >= resultDoc.allBlocks.length) return null;

    final block = resultDoc.allBlocks[i];
    final fullPrefix = '$prefix ';
    if (!block.plainText.startsWith(fullPrefix) ||
        block.blockType != BlockType.paragraph) {
      return null;
    }

    final blockStart = resultDoc.globalOffset(i, 0);
    return Transaction(
      operations: [
        ...pending.operations,
        DeleteText(i, 0, fullPrefix.length),
        ChangeBlockType(i, targetType),
      ],
      selectionAfter: pending.selectionAfter?.copyWith(
        baseOffset: blockStart,
        extentOffset: blockStart,
      ),
    );
  }
}

/// Convenience constructors for common prefix rules.
class HeadingRule extends PrefixBlockRule {
  HeadingRule() : super('#', BlockType.h1);
}

class ListItemRule extends PrefixBlockRule {
  ListItemRule() : super('-', BlockType.listItem);
}

class NumberedListRule extends PrefixBlockRule {
  NumberedListRule() : super('1.', BlockType.numberedList);
}

/// Detects task shortcut patterns and converts to a taskItem with metadata.
///
/// Two trigger paths:
/// 1. `- [ ] ` or `- [x] ` typed on a paragraph (full shortcut)
/// 2. `[ ] ` or `[x] ` typed at the start of a list item (since "- " already
///    converted it to a list item via ListItemRule)
class TaskItemRule extends InputRule {
  @override
  Transaction? tryTransform(Transaction pending, Document doc) {
    final insertOp = _findInsertOp(pending);
    if (insertOp == null || insertOp.text != ' ') return null;

    final resultDoc = pending.apply(doc);
    final i = insertOp.blockIndex;
    if (i >= resultDoc.allBlocks.length) return null;

    final block = resultDoc.allBlocks[i];
    final text = block.plainText;

    bool? checked;
    int prefixLen;

    if (block.blockType == BlockType.paragraph) {
      // Path 1: full "- [ ] " on a paragraph.
      if (text.startsWith('- [ ] ')) {
        checked = false;
        prefixLen = 6;
      } else if (text.startsWith('- [x] ')) {
        checked = true;
        prefixLen = 6;
      } else {
        return null;
      }
    } else if (block.blockType == BlockType.listItem) {
      // Path 2: "[ ] " at start of a list item (user typed "- [ ] ",
      // ListItemRule ate the "- ", leaving "[ ] " on a listItem).
      if (text.startsWith('[ ] ')) {
        checked = false;
        prefixLen = 4;
      } else if (text.startsWith('[x] ')) {
        checked = true;
        prefixLen = 4;
      } else {
        return null;
      }
    } else {
      return null;
    }

    final blockStart = resultDoc.globalOffset(i, 0);
    return Transaction(
      operations: [
        ...pending.operations,
        DeleteText(i, 0, prefixLen),
        ChangeBlockType(i, BlockType.taskItem),
        SetBlockMetadata(i, 'checked', checked),
      ],
      selectionAfter: pending.selectionAfter?.copyWith(
        baseOffset: blockStart,
        extentOffset: blockStart,
      ),
    );
  }
}

/// Enter on an empty list item converts it to a paragraph instead of splitting.
///
/// This rule checks for SplitBlock on an empty list item and replaces it
/// with a ChangeBlockType to paragraph.
class EmptyListItemRule extends InputRule {
  @override
  Transaction? tryTransform(Transaction pending, Document doc) {
    final splitOp = pending.operations.whereType<SplitBlock>().firstOrNull;
    if (splitOp == null) return null;

    final block = doc.allBlocks[splitOp.blockIndex];
    if (!isListLike(block.blockType)) return null;
    if (block.plainText.isNotEmpty) return null;

    // Replace the split with a type change to paragraph.
    return Transaction(
      operations: [ChangeBlockType(splitOp.blockIndex, BlockType.paragraph)],
      selectionAfter: pending.selectionAfter,
    );
  }
}

/// Backspace at start of a list item converts it to a paragraph (keeps nesting).
///
/// Detects a MergeBlocks where the second block is a list item, and replaces
/// it with a ChangeBlockType to paragraph. The block stays in its current
/// position in the tree — only the type changes.
class ListItemBackspaceRule extends InputRule {
  @override
  Transaction? tryTransform(Transaction pending, Document doc) {
    final mergeOp = pending.operations.whereType<MergeBlocks>().firstOrNull;
    if (mergeOp == null) return null;

    final flat = doc.allBlocks;
    if (mergeOp.secondBlockIndex >= flat.length) return null;

    final block = flat[mergeOp.secondBlockIndex];
    if (!isListLike(block.blockType)) return null;

    // Convert to paragraph instead of merging.
    // Cursor should stay at the start of this block, not jump to the previous one.
    final cursorOffset = doc.globalOffset(mergeOp.secondBlockIndex, 0);
    return Transaction(
      operations: [
        ChangeBlockType(mergeOp.secondBlockIndex, BlockType.paragraph),
      ],
      selectionAfter: TextSelection.collapsed(offset: cursorOffset),
    );
  }
}

/// Backspace at start of a nested block (non-list-item) outdents instead of merging.
///
/// This gives the Notion/Google Docs behavior: backspace reduces nesting
/// step by step until root level, then merges.
class NestedBackspaceRule extends InputRule {
  @override
  Transaction? tryTransform(Transaction pending, Document doc) {
    final mergeOp = pending.operations.whereType<MergeBlocks>().firstOrNull;
    if (mergeOp == null) return null;

    final flat = doc.allBlocks;
    if (mergeOp.secondBlockIndex >= flat.length) return null;

    final block = flat[mergeOp.secondBlockIndex];
    // Only for non-list-like blocks (list-like are handled by ListItemBackspaceRule).
    if (isListLike(block.blockType)) return null;
    // Only if nested (depth > 0). Root blocks merge normally.
    if (doc.depthOf(mergeOp.secondBlockIndex) == 0) return null;

    // Outdent instead of merging.
    final cursorOffset = doc.globalOffset(mergeOp.secondBlockIndex, 0);
    return Transaction(
      operations: [OutdentBlock(mergeOp.secondBlockIndex)],
      selectionAfter: TextSelection.collapsed(offset: cursorOffset),
    );
  }
}

/// Detects `---` typed on an empty paragraph and converts it to a divider block.
///
/// Fires when the third `-` is inserted, making the block text exactly `---`.
/// The text is cleared, the block type is changed to divider, and a new empty
/// paragraph is inserted after for the cursor to land on.
class DividerRule extends InputRule {
  @override
  Transaction? tryTransform(Transaction pending, Document doc) {
    final insertOp = _findInsertOp(pending);
    if (insertOp == null || insertOp.text != '-') return null;

    final resultDoc = pending.apply(doc);
    final i = insertOp.blockIndex;
    if (i >= resultDoc.allBlocks.length) return null;

    final block = resultDoc.allBlocks[i];
    if (block.blockType != BlockType.paragraph || block.plainText != '---') {
      return null;
    }

    final blockStart = resultDoc.globalOffset(i, 0);
    return Transaction(
      operations: [
        ...pending.operations,
        DeleteText(i, 0, 3),
        ChangeBlockType(i, BlockType.divider),
        // Create a new paragraph after the divider for the cursor.
        SplitBlock(i, 0),
      ],
      selectionAfter: TextSelection.collapsed(offset: blockStart + 1),
    );
  }
}

/// Backspace at the start of a block that follows a divider deletes the divider.
///
/// Intercepts MergeBlocks where the preceding block is a void block (divider).
/// Instead of merging (which would corrupt the current block's type), we remove
/// the divider entirely and keep the current block as-is.
class DividerBackspaceRule extends InputRule {
  @override
  Transaction? tryTransform(Transaction pending, Document doc) {
    final mergeOp = pending.operations.whereType<MergeBlocks>().firstOrNull;
    if (mergeOp == null) return null;

    final flat = doc.allBlocks;
    final prevIdx = mergeOp.secondBlockIndex - 1;
    if (prevIdx < 0 || prevIdx >= flat.length) return null;
    if (flat[prevIdx].blockType != BlockType.divider) return null;

    // Remove the divider. The current block slides into its position.
    final cursorOffset = doc.globalOffset(prevIdx, 0);
    return Transaction(
      operations: [RemoveBlock(prevIdx)],
      selectionAfter: TextSelection.collapsed(offset: cursorOffset),
    );
  }
}

/// Find the first InsertText operation in a transaction, if any.
InsertText? _findInsertOp(Transaction tx) {
  for (final op in tx.operations) {
    if (op is InsertText) return op;
  }
  return null;
}
