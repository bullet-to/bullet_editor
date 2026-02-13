import 'package:flutter/widgets.dart';

import '../model/block.dart';
import '../model/document.dart';
import '../model/inline_style.dart';
import 'edit_operation.dart';
import 'input_rule.dart';
import 'text_diff.dart';
import 'transaction.dart';
import 'undo_manager.dart';

/// Placeholder character used for visual-only WidgetSpan prefixes (bullets).
/// Occupies exactly 1 offset position in the display text.
const _prefixChar = '\uFFFC';

/// The bridge between Flutter's TextField and our document model.
///
/// The display text includes placeholder chars for visual prefixes (bullets,
/// indentation). The model text does not. All conversions between display
/// offsets (what Flutter sees) and model offsets (what the document uses)
/// go through [_displayToModel] and [_modelToDisplay].
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
      _displayToModel(value.selection.baseOffset),
    );
    addListener(_onValueChanged);
  }

  Document _document;
  final List<InputRule> _inputRules;
  final UndoManager _undoManager;
  bool _isSyncing = false;
  TextEditingValue _previousValue = TextEditingValue.empty;
  Set<InlineStyle> _activeStyles = {};

  Document get document => _document;
  Set<InlineStyle> get activeStyles => _activeStyles;
  bool get canUndo => _undoManager.canUndo;
  bool get canRedo => _undoManager.canRedo;

  // -- Offset translation --

  /// Whether a block gets a visual prefix WidgetSpan (bullet, indent, etc).
  /// List items always get a bullet. Nested blocks get indentation.
  bool _hasPrefix(int flatIndex) {
    final block = _document.allBlocks[flatIndex];
    return block.blockType == BlockType.listItem ||
        _document.depthOf(flatIndex) > 0;
  }

  /// Convert a display offset (TextField) to a model offset (Document).
  /// Subtracts the prefix placeholder chars that precede this position.
  int _displayToModel(int displayOffset) {
    final flat = _document.allBlocks;
    var displayPos = 0;
    var modelPos = 0;

    for (var i = 0; i < flat.length; i++) {
      if (i > 0) {
        // \n separator — same in display and model.
        displayPos++;
        modelPos++;
      }

      if (_hasPrefix(i)) {
        // Prefix placeholder char — display only.
        if (displayOffset <= displayPos) return modelPos;
        displayPos++;
      }

      final blockLen = flat[i].length;
      if (displayOffset <= displayPos + blockLen) {
        return modelPos + (displayOffset - displayPos);
      }

      displayPos += blockLen;
      modelPos += blockLen;
    }

    return modelPos;
  }

  /// Convert a model offset (Document) to a display offset (TextField).
  /// Adds the prefix placeholder chars that precede this position.
  int _modelToDisplay(int modelOffset) {
    final flat = _document.allBlocks;
    var displayPos = 0;
    var modelPos = 0;

    for (var i = 0; i < flat.length; i++) {
      if (i > 0) {
        displayPos++;
        modelPos++;
      }

      if (_hasPrefix(i)) {
        displayPos++; // prefix char in display, not in model
      }

      final blockLen = flat[i].length;
      if (modelOffset <= modelPos + blockLen) {
        return displayPos + (modelOffset - modelPos);
      }

      displayPos += blockLen;
      modelPos += blockLen;
    }

    return displayPos;
  }

  /// Convert a display TextSelection to model TextSelection.
  TextSelection _selectionToModel(TextSelection sel) {
    return TextSelection(
      baseOffset: _displayToModel(sel.baseOffset),
      extentOffset: _displayToModel(sel.extentOffset),
    );
  }

  /// Convert a model TextSelection to display TextSelection.
  TextSelection _selectionToDisplay(TextSelection sel) {
    return TextSelection(
      baseOffset: _modelToDisplay(sel.baseOffset),
      extentOffset: _modelToDisplay(sel.extentOffset),
    );
  }

  /// If the cursor is sitting on a prefix char, nudge it past.
  /// Returns null if no adjustment needed.
  TextSelection? _skipPrefixChars(TextSelection sel) {
    if (!sel.isValid || !sel.isCollapsed) return null;
    final offset = sel.baseOffset;
    final displayText = text;
    if (offset < 0 || offset >= displayText.length) return null;
    if (displayText[offset] != _prefixChar) return null;

    // Determine direction from previous cursor position.
    final prevOffset = _previousValue.selection.baseOffset;
    if (offset > prevOffset) {
      // Moving right — skip past the prefix char.
      return TextSelection.collapsed(offset: offset + 1);
    } else if (offset < prevOffset) {
      // Moving left — skip before the prefix char (to end of previous block).
      return TextSelection.collapsed(offset: offset > 0 ? offset - 1 : 0);
    }

    // Same position (e.g. click) — skip forward.
    return TextSelection.collapsed(
      offset: (offset + 1).clamp(0, displayText.length),
    );
  }

  // -- Undo / Redo --

  /// Capture the current state as an undo entry and push it.
  ///
  /// Uses [_previousValue.selection] because inside [_onValueChanged],
  /// Flutter has already updated [value] to the post-edit state. We want
  /// the *pre-edit* cursor position so undo restores it correctly.
  ///
  /// For [indent]/[outdent], [value.selection] is still the pre-edit
  /// position (key handler calls us before mutation), so both work.
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

    // Push current state to redo before restoring.
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

    // Push current state back to undo before restoring.
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

  // -- Edit pipeline --

  void _onValueChanged() {
    if (_isSyncing) return;

    if (value.composing.isValid &&
        value.composing.start != value.composing.end) {
      _previousValue = value;
      return;
    }

    // Diff in display space, then translate to model space.
    final cursor = value.selection.isValid ? value.selection.baseOffset : null;
    final diff = diffTexts(_previousValue.text, text, cursorOffset: cursor);

    if (diff == null) {
      // Selection-only change — skip cursor over prefix chars.
      final adjusted = _skipPrefixChars(value.selection);
      if (adjusted != null) {
        _isSyncing = true;
        value = value.copyWith(selection: adjusted);
        _previousValue = value;
        _isSyncing = false;
      }
      final modelOffset = _displayToModel(value.selection.baseOffset);
      _activeStyles = _document.stylesAt(modelOffset);
      _previousValue = value;
      return;
    }

    // Translate the diff start from display to model space.
    // But we need to be careful: the diff was computed on the display text
    // which includes prefix chars. We translate the diff start, and the
    // inserted/deleted text should NOT include prefix chars (they're managed
    // by us, not typed by the user). Filter them out.
    final cleanInserted = diff.insertedText.replaceAll(_prefixChar, '');
    final modelStart = _displayToModel(diff.start);

    // Compute how many prefix chars were in the deleted range.
    final deletedText = _previousValue.text.substring(
      diff.start,
      diff.start + diff.deletedLength,
    );
    final prefixCharsDeleted = _prefixChar.allMatches(deletedText).length;
    final modelDeletedLength = diff.deletedLength - prefixCharsDeleted;

    // If only prefix chars were deleted (user backspaced over a bullet),
    // treat it as backspace at the start of this block → merge.
    if (modelDeletedLength == 0 &&
        prefixCharsDeleted > 0 &&
        cleanInserted.isEmpty) {
      final pos = _document.blockAt(modelStart);
      if (pos.blockIndex > 0 && pos.localOffset == 0) {
        final modelSelection = _selectionToModel(value.selection);
        final mergeTx = Transaction(
          operations: [MergeBlocks(pos.blockIndex)],
          selectionAfter: modelSelection,
        );

        var finalMergeTx = mergeTx;
        for (final rule in _inputRules) {
          final transformed = rule.tryTransform(finalMergeTx, _document);
          if (transformed != null) {
            finalMergeTx = transformed;
            break;
          }
        }

        _pushUndo();
        _document = finalMergeTx.apply(_document);
        final TextSelection afterSel;
        if (finalMergeTx != mergeTx && finalMergeTx.selectionAfter != null) {
          afterSel = finalMergeTx.selectionAfter!;
        } else {
          afterSel = TextSelection.collapsed(
            offset: _displayToModel(value.selection.baseOffset),
          );
        }
        _syncToTextField(modelSelection: afterSel);
        _activeStyles = _document.stylesAt(
          _displayToModel(value.selection.baseOffset),
        );
        return;
      }

      // Prefix deleted but not at block start — just re-sync to restore it.
      _syncToTextField(
        modelSelection: TextSelection.collapsed(offset: modelStart),
      );
      return;
    }

    final modelDiff = TextDiff(modelStart, modelDeletedLength, cleanInserted);
    final modelSelection = _selectionToModel(value.selection);

    final tx = _transactionFromDiff(modelDiff, modelSelection);
    if (tx == null) {
      _previousValue = value;
      return;
    }

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

    // If an input rule set selectionAfter explicitly, use it (it's in model space).
    // Otherwise, translate the display cursor using the NEW document.
    final TextSelection afterSel;
    if (finalTx != tx && finalTx.selectionAfter != null) {
      // Input rule explicitly set the cursor position.
      afterSel = finalTx.selectionAfter!;
    } else {
      // Compute from display cursor against the updated document.
      final newModelOffset = _displayToModel(value.selection.baseOffset);
      afterSel = TextSelection.collapsed(offset: newModelOffset);
    }
    _syncToTextField(modelSelection: afterSel);
    _activeStyles = _document.stylesAt(
      _displayToModel(value.selection.baseOffset),
    );
  }

  // -- Transaction building (all in model space) --

  Transaction? _transactionFromDiff(TextDiff diff, TextSelection selection) {
    if (diff.deletedLength == 0 && diff.insertedText.isEmpty) return null;

    final deletedText =
        _document.plainText.length >= diff.start + diff.deletedLength
        ? _document.plainText.substring(
            diff.start,
            diff.start + diff.deletedLength,
          )
        : '';

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
      // Find the end position of the deleted range.
      final deleteEnd = diff.start + diff.deletedLength;
      final endPos = _document.blockAt(deleteEnd);

      final ops = <EditOperation>[];

      if (startPos.blockIndex == endPos.blockIndex) {
        // Same-block delete.
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
        // Delete exactly one block boundary (backspace at start of next block).
        // Use MergeBlocks so input rules can intercept (e.g. list→paragraph).
        ops.add(MergeBlocks(endPos.blockIndex));
      } else {
        // Cross-block delete spanning content.
        ops.add(DeleteRange(
          startPos.blockIndex,
          startPos.localOffset,
          endPos.blockIndex,
          endPos.localOffset,
        ));
      }

      // If there's also inserted text (replace selection), insert at the
      // start of the deleted range. After DeleteRange, the start block
      // still exists at startPos.blockIndex with cursor at startOffset.
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

  /// Build the display text: model text with prefix placeholder chars inserted
  /// before each block that has a visual prefix.
  String _buildDisplayText() {
    final flat = _document.allBlocks;
    final buf = StringBuffer();
    for (var i = 0; i < flat.length; i++) {
      if (i > 0) buf.write('\n');
      if (_hasPrefix(i)) buf.write(_prefixChar);
      buf.write(flat[i].plainText);
    }
    return buf.toString();
  }

  /// Push document state to the TextField. Selection is in model space and
  /// gets translated to display space.
  void _syncToTextField({TextSelection? modelSelection}) {
    _isSyncing = true;
    final displayText = _buildDisplayText();
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
    final children = <InlineSpan>[];
    final flat = _document.allBlocks;

    for (var i = 0; i < flat.length; i++) {
      if (i > 0) {
        // Give the \n separator the style of the preceding block's last segment.
        // This prevents cursor "sticking" when the trailing text has different
        // font metrics (bold, larger size, etc.) than the default style.
        final prevBlock = flat[i - 1];
        var prevStyle = _blockBaseStyle(prevBlock.blockType, style);
        if (prevBlock.segments.isNotEmpty) {
          prevStyle = _resolveStyle(prevBlock.segments.last.styles, prevStyle);
        }
        children.add(TextSpan(text: '\n', style: prevStyle));
      }

      final block = flat[i];
      final blockStyle = _blockBaseStyle(block.blockType, style);

      // Visual prefix: bullet for list items, indentation for nested blocks.
      if (_hasPrefix(i)) {
        final depth = _document.depthOf(i);
        final isList = block.blockType == BlockType.listItem;
        children.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: SizedBox(
              width: 20.0 + (depth * 16.0),
              child: isList
                  ? const Text(
                      '•  ',
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 14, color: Color(0xFF666666)),
                    )
                  : null, // Just indentation spacer, no bullet.
            ),
          ),
        );
      }

      if (block.segments.isEmpty) {
        children.add(TextSpan(text: '', style: blockStyle));
      } else {
        for (final seg in block.segments) {
          children.add(
            TextSpan(
              text: seg.text,
              style: _resolveStyle(seg.styles, blockStyle),
            ),
          );
        }
      }
    }

    return TextSpan(style: style, children: children);
  }

  TextStyle? _blockBaseStyle(BlockType type, TextStyle? base) {
    switch (type) {
      case BlockType.h1:
        return (base ?? const TextStyle()).copyWith(
          fontSize: 24,
          fontWeight: FontWeight.bold,
          height: 1.3,
        );
      case BlockType.listItem:
        return base;
      case BlockType.paragraph:
        return base;
    }
  }

  TextStyle? _resolveStyle(Set<InlineStyle> styles, TextStyle? base) {
    if (styles.isEmpty) return base;
    var result = base ?? const TextStyle();
    if (styles.contains(InlineStyle.bold)) {
      result = result.copyWith(fontWeight: FontWeight.bold);
    }
    return result;
  }

  @override
  void dispose() {
    removeListener(_onValueChanged);
    super.dispose();
  }
}
