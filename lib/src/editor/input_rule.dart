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

/// Detects **text** pattern and converts to bold formatting.
///
/// When the user types the closing `*` that completes `**text**`:
/// 1. Find the `**...**` in the resulting text
/// 2. Strip both `**` delimiters
/// 3. Apply bold to the enclosed text
///
/// This produces a clean model transition in one transaction.
class BoldWrapRule extends InputRule {
  @override
  Transaction? tryTransform(Transaction pending, Document doc) {
    // Only consider single-character insertions (the closing *).
    // This prevents firing on unrelated edits to blocks that happen
    // to already contain **text**.
    final insertOp = _findInsertOp(pending);
    if (insertOp == null) return null;

    // Apply the pending transaction to see what the document would look like.
    final resultDoc = pending.apply(doc);

    // Check each block for a completed **text** pattern.
    for (var i = 0; i < resultDoc.allBlocks.length; i++) {
      final block = resultDoc.allBlocks[i];
      final text = block.plainText;

      // Look for a **content** pattern whose closing ** was just completed
      // by the current edit. Check all matches, not just the first.
      final editBlock = insertOp.blockIndex;
      final editEnd = insertOp.offset + insertOp.text.length;
      if (editBlock != i) continue;

      final match = _boldPattern
          .allMatches(text)
          .cast<RegExpMatch?>()
          .firstWhere((m) => m!.end == editEnd, orElse: () => null);
      if (match == null) continue;

      final fullMatchStart = match.start;
      final innerText = match.group(1)!;
      final innerStart = fullMatchStart + 2; // after opening **
      final innerEnd = innerStart + innerText.length;

      // Build a new transaction that:
      // 1. Starts from the ORIGINAL doc (not the pending result)
      // 2. Applies the original text edit
      // 3. Then removes the ** delimiters and applies bold

      // First, apply the original ops to get us to the state with asterisks.
      // Then remove closing ** (do this first so offsets don't shift).
      // Then remove opening **.
      // Then toggle bold on the inner text (now at adjusted offsets).
      final ops = <EditOperation>[
        ...pending.operations,
        // Remove closing ** (at innerEnd position)
        DeleteText(i, innerEnd, 2),
        // Remove opening ** (at fullMatchStart position)
        DeleteText(i, fullMatchStart, 2),
        // Apply bold to the inner text (now shifted left by 2 due to opening ** removal)
        ToggleStyle(
          i,
          fullMatchStart,
          fullMatchStart + innerText.length,
          InlineStyle.bold,
        ),
      ];

      // Cursor should land right after the bolded text in the FINAL document.
      // In the final text, the bold content starts at fullMatchStart (opening **
      // removed) and has length innerText.length. Only the opening ** is before
      // the cursor; the closing ** is after, so it doesn't shift the position.
      final blockStartGlobal = resultDoc.globalOffset(i, 0);
      final cursorOffset = blockStartGlobal + fullMatchStart + innerText.length;

      return Transaction(
        operations: ops,
        selectionAfter: pending.selectionAfter?.copyWith(
          baseOffset: cursorOffset,
          extentOffset: cursorOffset,
        ),
      );
    }

    return null; // No pattern found, let the transaction pass unchanged.
  }
}

// Matches **content** where content is one or more non-* characters.
final _boldPattern = RegExp(r'\*\*([^*]+)\*\*');

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
    if (block.blockType != BlockType.listItem) return null;
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
    if (block.blockType != BlockType.listItem) return null;

    // Convert to paragraph instead of merging.
    // Cursor should stay at the start of this block, not jump to the previous one.
    final cursorOffset = doc.globalOffset(mergeOp.secondBlockIndex, 0);
    return Transaction(
      operations: [ChangeBlockType(mergeOp.secondBlockIndex, BlockType.paragraph)],
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
