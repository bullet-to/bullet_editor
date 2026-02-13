import 'package:flutter/widgets.dart';

import '../model/block.dart';
import '../model/document.dart';
import '../model/inline_style.dart';
import 'edit_operation.dart';
import 'input_rule.dart';
import 'offset_mapper.dart' as mapper;
import 'span_builder.dart' as spans;
import 'text_diff.dart';
import 'transaction.dart';
import 'undo_manager.dart';

/// The bridge between Flutter's TextField and our document model.
///
/// Offset translation is handled by [offset_mapper.dart].
/// Rendering is handled by [span_builder.dart].
/// This class owns the edit pipeline, undo/redo, and public actions.
class EditorController extends TextEditingController {
  EditorController({
    Document? document,
    List<InputRule>? inputRules,
    ShouldGroupUndo? undoGrouping,
    int maxUndoStack = 100,
  }) : _document = document ?? Document.empty(),
       _inputRules = inputRules ?? [],
       _undoManager = UndoManager(
         grouping: undoGrouping,
         maxStackSize: maxUndoStack,
       ) {
    _syncToTextField();
    _activeStyles = _document.stylesAt(
      mapper.displayToModel(_document, value.selection.baseOffset),
    );
    addListener(_onValueChanged);
  }

  Document _document;
  final List<InputRule> _inputRules;
  final UndoManager _undoManager;
  bool _isSyncing = false;
  /// The cursor offset at which _activeStyles was manually set (by toggleStyle).
  /// While the cursor stays at this offset, the override is preserved.
  /// Set to -1 when no override is active.
  int _styleOverrideOffset = -1;
  TextEditingValue _previousValue = TextEditingValue.empty;
  Set<InlineStyle> _activeStyles = {};

  Document get document => _document;
  Set<InlineStyle> get activeStyles => _activeStyles;
  bool get canUndo => _undoManager.canUndo;
  bool get canRedo => _undoManager.canRedo;

  // -- Offset helpers (delegate to offset_mapper) --

  int _displayToModel(int displayOffset) =>
      mapper.displayToModel(_document, displayOffset);

  TextSelection _selectionToModel(TextSelection sel) =>
      mapper.selectionToModel(_document, sel);

  TextSelection _selectionToDisplay(TextSelection sel) =>
      mapper.selectionToDisplay(_document, sel);

  /// Compute active styles for the current selection.
  ///
  /// - Collapsed: styles at the cursor position.
  /// - Non-collapsed: intersection of styles across ALL characters in the
  ///   selection. Bold is active only if every selected character is bold.
  Set<InlineStyle> _stylesForSelection(TextSelection sel) {
    final modelSel = _selectionToModel(sel);

    if (sel.isCollapsed) {
      return _document.stylesAt(modelSel.baseOffset);
    }

    final start = modelSel.baseOffset < modelSel.extentOffset
        ? modelSel.baseOffset
        : modelSel.extentOffset;
    final end = modelSel.baseOffset < modelSel.extentOffset
        ? modelSel.extentOffset
        : modelSel.baseOffset;

    if (start == end) return _document.stylesAt(start);

    // Walk segments in the range, intersect their styles.
    final startPos = _document.blockAt(start);
    final endPos = _document.blockAt(end);
    Set<InlineStyle>? result;

    for (var i = startPos.blockIndex; i <= endPos.blockIndex; i++) {
      final block = _document.allBlocks[i];
      final blockStart = i == startPos.blockIndex ? startPos.localOffset : 0;
      final blockEnd = i == endPos.blockIndex ? endPos.localOffset : block.length;
      if (blockEnd <= blockStart) continue;

      var offset = 0;
      for (final seg in block.segments) {
        final segStart = offset;
        final segEnd = offset + seg.text.length;
        offset = segEnd;

        if (segEnd <= blockStart || segStart >= blockEnd) continue;

        if (result == null) {
          result = Set.of(seg.styles);
        } else {
          result = result.intersection(seg.styles);
        }
      }
    }

    return result ?? {};
  }

  // -- Undo / Redo --

  /// Capture the current state as an undo entry and push it.
  ///
  /// Uses [_previousValue.selection] because inside [_onValueChanged],
  /// Flutter has already updated [value] to the post-edit state. We want
  /// the *pre-edit* cursor position so undo restores it correctly.
  void _pushUndo() {
    final displaySel = _previousValue.selection.isValid
        ? _previousValue.selection
        : value.selection;
    final modelSel = _selectionToModel(displaySel);
    _undoManager.push(UndoEntry(
      document: _document,
      selection: modelSel,
      timestamp: DateTime.now(),
    ));
  }

  /// Undo the last edit. Restores the document and cursor from the snapshot.
  void undo() {
    final entry = _undoManager.undo();
    if (entry == null) return;

    final modelSel = _selectionToModel(value.selection);
    _undoManager.pushRedo(UndoEntry(
      document: _document,
      selection: modelSel,
      timestamp: DateTime.now(),
    ));

    _document = entry.document;
    _syncToTextField(modelSelection: entry.selection);
    _activeStyles = _document.stylesAt(
      entry.selection.baseOffset.clamp(0, _document.plainText.length),
    );
  }

  /// Redo the last undone edit. Restores the document and cursor from the snapshot.
  void redo() {
    final entry = _undoManager.redo();
    if (entry == null) return;

    final modelSel = _selectionToModel(value.selection);
    _undoManager.pushUndoRaw(UndoEntry(
      document: _document,
      selection: modelSel,
      timestamp: DateTime.now(),
    ));

    _document = entry.document;
    _syncToTextField(modelSelection: entry.selection);
    _activeStyles = _document.stylesAt(
      entry.selection.baseOffset.clamp(0, _document.plainText.length),
    );
  }

  // -- Public actions --

  void indent() {
    if (!value.selection.isValid || !value.selection.isCollapsed) return;
    final modelSel = _selectionToModel(value.selection);
    final pos = _document.blockAt(modelSel.baseOffset);

    _pushUndo();
    _document = IndentBlock(pos.blockIndex).apply(_document);
    _syncToTextField(modelSelection: modelSel);
    _activeStyles = _document.stylesAt(modelSel.baseOffset);
  }

  void outdent() {
    if (!value.selection.isValid || !value.selection.isCollapsed) return;
    final modelSel = _selectionToModel(value.selection);
    final pos = _document.blockAt(modelSel.baseOffset);

    _pushUndo();
    _document = OutdentBlock(pos.blockIndex).apply(_document);
    _syncToTextField(modelSelection: modelSel);
    _activeStyles = _document.stylesAt(modelSel.baseOffset);
  }

  /// Toggle an inline style.
  ///
  /// - Collapsed cursor: toggles the style in [_activeStyles] so the next
  ///   typed text gets (or loses) the style.
  /// - Non-collapsed selection: applies [ToggleStyle] to the selected range.
  void toggleStyle(InlineStyle style) {
    if (!value.selection.isValid) return;

    if (value.selection.isCollapsed) {
      if (_activeStyles.contains(style)) {
        _activeStyles = Set.of(_activeStyles)..remove(style);
      } else {
        _activeStyles = Set.of(_activeStyles)..add(style);
      }
      _styleOverrideOffset = _displayToModel(value.selection.baseOffset);
      notifyListeners();
      return;
    }

    // Non-collapsed: apply ToggleStyle to each block in the range.
    final modelSel = _selectionToModel(value.selection);
    final start = modelSel.baseOffset < modelSel.extentOffset
        ? modelSel.baseOffset
        : modelSel.extentOffset;
    final end = modelSel.baseOffset < modelSel.extentOffset
        ? modelSel.extentOffset
        : modelSel.baseOffset;

    final startPos = _document.blockAt(start);
    final endPos = _document.blockAt(end);

    final ops = <EditOperation>[];
    for (var i = startPos.blockIndex; i <= endPos.blockIndex; i++) {
      final block = _document.allBlocks[i];
      final blockStart = i == startPos.blockIndex ? startPos.localOffset : 0;
      final blockEnd = i == endPos.blockIndex ? endPos.localOffset : block.length;
      if (blockEnd > blockStart) {
        ops.add(ToggleStyle(i, blockStart, blockEnd, style));
      }
    }

    if (ops.isEmpty) return;

    _pushUndo();
    final tx = Transaction(operations: ops, selectionAfter: modelSel);
    _document = tx.apply(_document);
    _activeStyles = _stylesForSelection(
      TextSelection(baseOffset: start, extentOffset: end),
    );
    _syncToTextField(modelSelection: modelSel);
    // Inline style changes don't alter display text, so _syncToTextField may
    // not trigger notifyListeners. Explicit notify for toolbar rebuild.
    notifyListeners();
  }

  /// Change the block type of the block at the cursor position.
  void setBlockType(BlockType type) {
    if (!value.selection.isValid) return;
    final modelSel = _selectionToModel(value.selection);
    final pos = _document.blockAt(modelSel.baseOffset);

    _pushUndo();
    _document = ChangeBlockType(pos.blockIndex, type).apply(_document);
    _syncToTextField(modelSelection: modelSel);
  }

  /// Get the block type at the current cursor position.
  BlockType get currentBlockType {
    if (!value.selection.isValid) return BlockType.paragraph;
    final modelSel = _selectionToModel(value.selection);
    final pos = _document.blockAt(modelSel.baseOffset);
    return _document.allBlocks[pos.blockIndex].blockType;
  }

  // -- Edit pipeline --

  /// Run input rules on [tx], push undo, apply, sync to TextField, update styles.
  ///
  /// If no input rule overrides selectionAfter, the fallback selection is
  /// computed from the current display cursor against the NEW document.
  void _commitTransaction(Transaction tx) {
    var finalTx = tx;
    for (final rule in _inputRules) {
      final transformed = rule.tryTransform(finalTx, _document);
      if (transformed != null) {
        finalTx = transformed;
        break;
      }
    }

    _pushUndo();
    _document = finalTx.apply(_document);

    final TextSelection afterSel;
    if (finalTx != tx && finalTx.selectionAfter != null) {
      afterSel = finalTx.selectionAfter!;
    } else {
      // Compute fallback against the NEW document (after apply).
      final newModelOffset = _displayToModel(value.selection.baseOffset);
      afterSel = TextSelection.collapsed(offset: newModelOffset);
    }
    _syncToTextField(modelSelection: afterSel);
    _activeStyles = _document.stylesAt(
      _displayToModel(value.selection.baseOffset),
    );
  }

  /// Handle selection-only changes (no text diff). Skips prefix chars,
  /// updates active styles, preserves manual style overrides.
  void _handleSelectionChange() {
    final adjusted = mapper.skipPrefixChars(
      text,
      value.selection,
      _previousValue.selection,
    );
    if (adjusted != null) {
      _isSyncing = true;
      value = value.copyWith(selection: adjusted);
      _previousValue = value;
      _isSyncing = false;
    }
    final modelOffset = _displayToModel(value.selection.baseOffset);
    if (_styleOverrideOffset >= 0 && modelOffset == _styleOverrideOffset) {
      // Cursor still at the override position — preserve manual styles.
    } else {
      _styleOverrideOffset = -1;
      _activeStyles = _stylesForSelection(value.selection);
    }
    _previousValue = value;
  }

  /// Handle deletion of only prefix chars (user backspaced over a bullet).
  /// Treats it as backspace at block start → merge (which input rules may
  /// intercept, e.g. list item → paragraph).
  void _handlePrefixDelete(int modelStart) {
    final pos = _document.blockAt(modelStart);
    if (pos.blockIndex > 0 && pos.localOffset == 0) {
      final modelSelection = _selectionToModel(value.selection);
      final tx = Transaction(
        operations: [MergeBlocks(pos.blockIndex)],
        selectionAfter: modelSelection,
      );
      _commitTransaction(tx);
      return;
    }

    // Prefix deleted but not at block start — just re-sync to restore it.
    _syncToTextField(
      modelSelection: TextSelection.collapsed(offset: modelStart),
    );
  }

  void _onValueChanged() {
    if (_isSyncing) return;

    if (value.composing.isValid &&
        value.composing.start != value.composing.end) {
      _previousValue = value;
      return;
    }

    final cursor = value.selection.isValid ? value.selection.baseOffset : null;
    final diff = diffTexts(_previousValue.text, text, cursorOffset: cursor);

    // 1. Selection-only change (no text edit).
    if (diff == null) {
      _handleSelectionChange();
      return;
    }

    // Translate diff from display to model space.
    final cleanInserted = diff.insertedText.replaceAll(mapper.prefixChar, '');
    final modelStart = _displayToModel(diff.start);
    final deletedText = _previousValue.text.substring(
      diff.start,
      diff.start + diff.deletedLength,
    );
    final prefixCharsDeleted =
        mapper.prefixChar.allMatches(deletedText).length;
    final modelDeletedLength = diff.deletedLength - prefixCharsDeleted;

    // 2. Only prefix chars deleted (backspace over bullet).
    if (modelDeletedLength == 0 &&
        prefixCharsDeleted > 0 &&
        cleanInserted.isEmpty) {
      _handlePrefixDelete(modelStart);
      return;
    }

    // 3. Normal text edit — build transaction and commit.
    final modelDiff = TextDiff(modelStart, modelDeletedLength, cleanInserted);
    final modelSelection = _selectionToModel(value.selection);

    final tx = _transactionFromDiff(modelDiff, modelSelection);
    if (tx == null) {
      _previousValue = value;
      return;
    }

    _commitTransaction(tx);
  }

  // -- Transaction building (all in model space) --

  Transaction? _transactionFromDiff(TextDiff diff, TextSelection selection) {
    if (diff.deletedLength == 0 && diff.insertedText.isEmpty) return null;

    // Tab → indent.
    if (diff.insertedText == '\t' && diff.deletedLength == 0) {
      final pos = _document.blockAt(diff.start);
      final block = _document.allBlocks[pos.blockIndex];
      if (block.blockType == BlockType.listItem) {
        return Transaction(
          operations: [IndentBlock(pos.blockIndex)],
          selectionAfter: selection,
        );
      }
      return null;
    }

    // Pure newline insert → split (no delete involved).
    if (diff.insertedText.contains('\n') && diff.deletedLength == 0) {
      final pos = _document.blockAt(diff.start);
      return Transaction(
        operations: [SplitBlock(pos.blockIndex, pos.localOffset)],
        selectionAfter: selection,
      );
    }

    // General delete (possibly cross-block) + optional insert.
    final startPos = _document.blockAt(diff.start);

    if (diff.deletedLength > 0) {
      final deleteEnd = diff.start + diff.deletedLength;
      final endPos = _document.blockAt(deleteEnd);

      final ops = <EditOperation>[];

      if (startPos.blockIndex == endPos.blockIndex) {
        ops.add(DeleteText(
          startPos.blockIndex,
          startPos.localOffset,
          diff.deletedLength,
        ));
      } else if (endPos.blockIndex == startPos.blockIndex + 1 &&
          startPos.localOffset ==
              _document.allBlocks[startPos.blockIndex].length &&
          endPos.localOffset == 0 &&
          diff.insertedText.isEmpty) {
        // Delete exactly one block boundary — use MergeBlocks for input rules.
        ops.add(MergeBlocks(endPos.blockIndex));
      } else {
        ops.add(DeleteRange(
          startPos.blockIndex,
          startPos.localOffset,
          endPos.blockIndex,
          endPos.localOffset,
        ));
      }

      if (diff.insertedText.isNotEmpty) {
        ops.add(InsertText(
          startPos.blockIndex,
          startPos.localOffset,
          diff.insertedText,
          styles: _activeStyles,
        ));
      }

      return Transaction(operations: ops, selectionAfter: selection);
    }

    // Pure insert (no delete).
    if (diff.insertedText.isNotEmpty) {
      return Transaction(
        operations: [
          InsertText(
            startPos.blockIndex,
            startPos.localOffset,
            diff.insertedText,
            styles: _activeStyles,
          ),
        ],
        selectionAfter: selection,
      );
    }

    return null;
  }

  // -- TextField sync --

  /// Push document state to the TextField. Selection is in model space and
  /// gets translated to display space.
  void _syncToTextField({TextSelection? modelSelection}) {
    _isSyncing = true;
    final displayText = mapper.buildDisplayText(_document);
    final modelSel =
        modelSelection ??
        TextSelection.collapsed(offset: _document.plainText.length);
    final displaySel = _selectionToDisplay(modelSel);
    value = TextEditingValue(
      text: displayText,
      selection: TextSelection(
        baseOffset: displaySel.baseOffset.clamp(0, displayText.length),
        extentOffset: displaySel.extentOffset.clamp(0, displayText.length),
      ),
    );
    _previousValue = value;
    _isSyncing = false;
  }

  // -- Rendering --

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    return spans.buildDocumentSpan(_document, style);
  }

  @override
  void dispose() {
    removeListener(_onValueChanged);
    super.dispose();
  }
}
