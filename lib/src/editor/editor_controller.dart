import 'package:flutter/widgets.dart';

import '../model/block.dart';
import '../model/document.dart';
import '../model/inline_style.dart';
import 'edit_operation.dart';
import 'input_rule.dart';
import 'transaction.dart';

/// The bridge between Flutter's TextField and our document model.
///
/// Owns the [Document], intercepts text changes, creates transactions,
/// runs input rules, and rebuilds the TextField value from the model.
///
/// buildTextSpan() reads the model's styled segments to render bold text.
class EditorController extends TextEditingController {
  EditorController({
    Document? document,
    List<InputRule>? inputRules,
  })  : _document = document ?? Document.empty(),
        _inputRules = inputRules ?? [] {
    // Sync initial document state to the controller's text.
    _syncFromModel();
    _updateActiveStyles(value.selection);
    addListener(_onValueChanged);
  }

  Document _document;
  final List<InputRule> _inputRules;

  /// Guard against re-entrant updates. When we push model state to the
  /// controller, we don't want that change to trigger another transaction.
  bool _isSyncing = false;

  /// Previous value, used to diff against the new value.
  TextEditingValue _previousValue = TextEditingValue.empty;

  /// The styles that will be applied to the next character typed.
  /// Updated when the cursor moves (reads from segment at cursor position).
  /// Can be overridden by toolbar toggles (Phase 5).
  Set<InlineStyle> _activeStyles = {};

  /// Public read access to the current document.
  Document get document => _document;

  /// The styles that will apply to the next inserted character.
  Set<InlineStyle> get activeStyles => _activeStyles;

  /// Called whenever the controller's value changes (user typing, paste, etc).
  void _onValueChanged() {
    if (_isSyncing) return;

    final oldText = _previousValue.text;
    final newText = text;
    final newSelection = value.selection;

    // Skip during IME composition — wait for the final commit.
    if (value.composing.isValid && value.composing.start != value.composing.end) {
      _previousValue = value;
      return;
    }

    // Diff old vs new to find the edit range.
    // Pass cursor position to disambiguate when inserted text matches
    // adjacent characters (e.g. space inserted at a style boundary).
    final cursorOffset = newSelection.isValid ? newSelection.baseOffset : null;
    final diff = _diffTexts(oldText, newText, cursorOffset: cursorOffset);
    if (diff == null) {
      // Selection-only change — update active styles from new cursor position.
      _updateActiveStyles(newSelection);
      _previousValue = value;
      return;
    }

    // Build a transaction from the diff.
    final tx = _buildTransaction(diff, newSelection);
    if (tx == null) {
      _previousValue = value;
      return;
    }

    // Run through input rules. First rule to return non-null wins.
    var finalTx = tx;
    for (final rule in _inputRules) {
      final transformed = rule.tryTransform(finalTx, _document);
      if (transformed != null) {
        finalTx = transformed;
        break;
      }
    }

    // Apply the transaction to the document.
    _document = finalTx.apply(_document);

    // Sync the model back to the controller.
    final sel = finalTx.selectionAfter ?? newSelection;
    _syncFromModel(selection: sel);

    // Update active styles from the new cursor position.
    _updateActiveStyles(value.selection);
  }

  /// Build a [Transaction] from a text diff.
  Transaction? _buildTransaction(_TextDiff diff, TextSelection selection) {
    final ops = <EditOperation>[];

    // Handle deletions and insertions that might span block boundaries.
    if (diff.deletedLength > 0 || diff.insertedText.isNotEmpty) {
      // Check if the edit involves newlines (block splits/merges).
      final deletedText = _previousValue.text.substring(
        diff.start,
        diff.start + diff.deletedLength,
      );
      final containsDeletedNewline = deletedText.contains('\n');
      final containsInsertedNewline = diff.insertedText.contains('\n');

      if (containsDeletedNewline && !containsInsertedNewline && diff.insertedText.isEmpty) {
        // Backspace across a block boundary — merge blocks.
        final pos = _document.blockAt(diff.start);
        // The newline is the separator between blocks, so the block after
        // the newline should merge into the block before it.
        if (pos.blockIndex + 1 < _document.blocks.length) {
          ops.add(MergeBlocks(pos.blockIndex + 1));
        }
      } else if (containsInsertedNewline && !containsDeletedNewline && diff.deletedLength == 0) {
        // Enter key — split block.
        final pos = _document.blockAt(diff.start);
        ops.add(SplitBlock(pos.blockIndex, pos.localOffset));
      } else {
        // General text replacement within a single block.
        final pos = _document.blockAt(diff.start);
        if (diff.deletedLength > 0) {
          ops.add(DeleteText(pos.blockIndex, pos.localOffset, diff.deletedLength));
        }
        if (diff.insertedText.isNotEmpty) {
          ops.add(InsertText(pos.blockIndex, pos.localOffset, diff.insertedText,
              styles: _activeStyles));
        }
      }
    }

    if (ops.isEmpty) return null;
    return Transaction(operations: ops, selectionAfter: selection);
  }

  /// Read the styles at the cursor position and set them as active.
  /// When typing, inserted text will get these styles.
  void _updateActiveStyles(TextSelection selection) {
    if (!selection.isValid || !selection.isCollapsed) {
      _activeStyles = {};
      return;
    }

    final offset = selection.baseOffset;
    final pos = _document.blockAt(offset);
    final block = _document.blocks[pos.blockIndex];

    // Walk segments to find which one the cursor is in (or just after).
    var segOffset = 0;
    for (final seg in block.segments) {
      final segEnd = segOffset + seg.text.length;
      // Cursor is inside this segment, or right at its end.
      if (pos.localOffset <= segEnd && pos.localOffset > segOffset) {
        _activeStyles = Set.of(seg.styles);
        return;
      }
      // Cursor is at the very start of the block — use the first segment.
      if (pos.localOffset == 0 && segOffset == 0) {
        _activeStyles = Set.of(seg.styles);
        return;
      }
      segOffset = segEnd;
    }

    _activeStyles = {};
  }

  /// Push the current document model state to the controller's text/selection.
  void _syncFromModel({TextSelection? selection}) {
    _isSyncing = true;
    final newText = _document.plainText;
    final sel = selection ?? TextSelection.collapsed(offset: newText.length);
    // Clamp selection to valid range.
    final clampedSel = TextSelection(
      baseOffset: sel.baseOffset.clamp(0, newText.length),
      extentOffset: sel.extentOffset.clamp(0, newText.length),
    );
    value = TextEditingValue(text: newText, selection: clampedSel);
    _previousValue = value;
    _isSyncing = false;
  }

  /// Build a styled TextSpan tree from the document model.
  ///
  /// This is where formatting becomes visible: bold segments get
  /// FontWeight.bold, etc.
  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final children = <InlineSpan>[];

    for (var i = 0; i < _document.blocks.length; i++) {
      // Add block separator newline (except before the first block).
      if (i > 0) {
        children.add(TextSpan(text: '\n', style: style));
      }

      final block = _document.blocks[i];
      if (block.segments.isEmpty) {
        // Empty block — still need a zero-width span for the cursor to work.
        children.add(TextSpan(text: '', style: style));
      } else {
        for (final segment in block.segments) {
          children.add(TextSpan(
            text: segment.text,
            style: _styleForSegment(segment, style),
          ));
        }
      }
    }

    return TextSpan(style: style, children: children);
  }

  /// Map a segment's inline styles to a Flutter [TextStyle].
  TextStyle? _styleForSegment(StyledSegment segment, TextStyle? base) {
    if (segment.styles.isEmpty) return base;

    var result = base ?? const TextStyle();
    if (segment.styles.contains(InlineStyle.bold)) {
      result = result.copyWith(fontWeight: FontWeight.bold);
    }
    // Phase 2: add italic, code, strikethrough, etc.
    return result;
  }

  @override
  void dispose() {
    removeListener(_onValueChanged);
    super.dispose();
  }
}

// --- Text diffing ---

class _TextDiff {
  const _TextDiff(this.start, this.deletedLength, this.insertedText);
  final int start;
  final int deletedLength;
  final String insertedText;
}

/// Diff two texts to find the changed region.
///
/// [cursorOffset] is the cursor position in [newText] after the edit.
/// When provided, it anchors the diff to prevent ambiguity when inserted
/// characters match adjacent text (e.g. typing a space next to an existing space).
///
/// Returns null if the texts are identical.
_TextDiff? _diffTexts(String oldText, String newText, {int? cursorOffset}) {
  if (oldText == newText) return null;

  final lengthDiff = newText.length - oldText.length;

  // If we have a cursor and this looks like a simple insertion or deletion,
  // use the cursor to determine the exact edit position.
  if (cursorOffset != null) {
    if (lengthDiff > 0 && oldText.length >= cursorOffset - lengthDiff) {
      // Insertion: cursor is right after the inserted text.
      final insertStart = cursorOffset - lengthDiff;
      final inserted = newText.substring(insertStart, cursorOffset);
      // Verify: old text before + old text after == old text around the insertion.
      final beforeMatch = newText.substring(0, insertStart) == oldText.substring(0, insertStart);
      final afterMatch = newText.substring(cursorOffset) == oldText.substring(insertStart);
      if (beforeMatch && afterMatch) {
        return _TextDiff(insertStart, 0, inserted);
      }
    } else if (lengthDiff < 0) {
      // Deletion: cursor is at the deletion point.
      final deleteLen = -lengthDiff;
      final deleteStart = cursorOffset;
      if (deleteStart + deleteLen <= oldText.length) {
        final beforeMatch = newText.substring(0, deleteStart) == oldText.substring(0, deleteStart);
        final afterMatch = newText.substring(deleteStart) == oldText.substring(deleteStart + deleteLen);
        if (beforeMatch && afterMatch) {
          return _TextDiff(deleteStart, deleteLen, '');
        }
      }
    }
  }

  // Fallback: prefix/suffix comparison.
  var prefixLen = 0;
  final minLen = oldText.length < newText.length ? oldText.length : newText.length;
  while (prefixLen < minLen && oldText[prefixLen] == newText[prefixLen]) {
    prefixLen++;
  }

  var suffixLen = 0;
  while (suffixLen < (minLen - prefixLen) &&
      oldText[oldText.length - 1 - suffixLen] == newText[newText.length - 1 - suffixLen]) {
    suffixLen++;
  }

  final deletedLength = oldText.length - prefixLen - suffixLen;
  final insertedText = newText.substring(prefixLen, newText.length - suffixLen);

  return _TextDiff(prefixLen, deletedLength, insertedText);
}
