import 'package:flutter/widgets.dart';

import '../codec/markdown_codec.dart';
import '../model/block.dart';
import '../model/document.dart';
import '../model/inline_style.dart';
import '../schema/editor_schema.dart';
import 'edit_operation.dart';
import 'input_rule.dart';
import 'offset_mapper.dart' as mapper;
import 'span_builder.dart' as spans;
import 'text_diff.dart';
import 'transaction.dart';
import 'undo_manager.dart';

/// Callback for link taps. Receives the URL from the segment's attributes.
typedef LinkTapCallback = void Function(String url);

/// The bridge between Flutter's TextField and our document model.
///
/// Offset translation is handled by [offset_mapper.dart].
/// Rendering is handled by [span_builder.dart].
/// This class owns the edit pipeline, undo/redo, and public actions.
class EditorController extends TextEditingController {
  EditorController({
    Document? document,
    EditorSchema? schema,
    List<InputRule>? additionalInputRules,
    LinkTapCallback? onLinkTap,
    ShouldGroupUndo? undoGrouping,
    int maxUndoStack = 100,
  }) : _document = document ?? Document.empty(),
       _schema = schema ?? EditorSchema.standard(),
       _onLinkTap = onLinkTap,
       _undoManager = UndoManager(
         grouping: undoGrouping,
         maxStackSize: maxUndoStack,
       ) {
    _inputRules = [
      ..._schema.inputRules,
      if (additionalInputRules != null) ...additionalInputRules,
    ];
    _syncToTextField();
    _activeStyles = _document.stylesAt(
      mapper.displayToModel(_document, value.selection.baseOffset, _schema),
    );
    addListener(_onValueChanged);
  }

  Document _document;
  late final List<InputRule> _inputRules;
  final EditorSchema _schema;
  final UndoManager _undoManager;
  LinkTapCallback? _onLinkTap;
  bool _isSyncing = false;

  /// The cursor offset at which _activeStyles was manually set (by toggleStyle).
  /// While the cursor stays at this offset, the override is preserved.
  /// Set to -1 when no override is active.
  int _styleOverrideOffset = -1;
  TextEditingValue _previousValue = TextEditingValue.empty;

  /// Snapshot of the value BEFORE composing started.
  /// Set on the first composing frame; used to diff when composing resolves.
  TextEditingValue? _preComposingValue;
  Set<InlineStyle> _activeStyles = {};

  Document get document => _document;
  EditorSchema get schema => _schema;
  Set<InlineStyle> get activeStyles => _activeStyles;
  LinkTapCallback? get onLinkTap => _onLinkTap;
  set onLinkTap(LinkTapCallback? value) => _onLinkTap = value;
  bool get canUndo => _undoManager.canUndo;
  bool get canRedo => _undoManager.canRedo;

  /// Get the segment attributes at the cursor position.
  /// Returns the attributes of the segment the cursor is inside (e.g.
  /// `{'url': '...'}` for a link). Empty map if no attributes.
  Map<String, dynamic> get currentAttributes {
    if (!value.selection.isValid) return const {};
    final modelOffset = displayToModel(value.selection.baseOffset);
    final pos = _document.blockAt(modelOffset);
    final block = _document.allBlocks[pos.blockIndex];
    var offset = 0;
    for (final seg in block.segments) {
      final segEnd = offset + seg.text.length;
      if (pos.localOffset <= segEnd &&
          (pos.localOffset > offset || offset == 0)) {
        return seg.attributes;
      }
      offset = segEnd;
    }
    return const {};
  }

  // -- Offset helpers (delegate to offset_mapper) --

  /// Return ordered (start, end) from a possibly-reversed selection.
  static (int, int) _orderedRange(TextSelection sel) {
    final a = sel.baseOffset;
    final b = sel.extentOffset;
    return a < b ? (a, b) : (b, a);
  }

  /// Iterate blocks within a model offset range, calling [visitor] with
  /// the flat block index, the block, and the local (start, end) offsets.
  void _forEachBlockInRange(
    int start,
    int end,
    void Function(int flatIndex, TextBlock block, int localStart, int localEnd)
    visitor,
  ) {
    final startPos = _document.blockAt(start);
    final endPos = _document.blockAt(end);
    for (var i = startPos.blockIndex; i <= endPos.blockIndex; i++) {
      final block = _document.allBlocks[i];
      final localStart = i == startPos.blockIndex ? startPos.localOffset : 0;
      final localEnd = i == endPos.blockIndex
          ? endPos.localOffset
          : block.length;
      if (localEnd > localStart) {
        visitor(i, block, localStart, localEnd);
      }
    }
  }

  /// Convert a display offset (TextField position) to a model offset.
  int displayToModel(int displayOffset) =>
      mapper.displayToModel(_document, displayOffset, _schema);

  TextSelection _selectionToModel(TextSelection sel) =>
      mapper.selectionToModel(_document, sel, _schema);

  TextSelection _selectionToDisplay(TextSelection sel) =>
      mapper.selectionToDisplay(_document, sel, _schema);

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

    final (start, end) = _orderedRange(modelSel);
    if (start == end) return _document.stylesAt(start);

    // Walk segments in the range, intersect their styles.
    Set<InlineStyle>? result;
    _forEachBlockInRange(start, end, (_, block, localStart, localEnd) {
      var offset = 0;
      for (final seg in block.segments) {
        final segStart = offset;
        final segEnd = offset + seg.text.length;
        offset = segEnd;
        if (segEnd <= localStart || segStart >= localEnd) continue;
        result = result == null
            ? Set.of(seg.styles)
            : result!.intersection(seg.styles);
      }
    });

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
    _undoManager.push(
      UndoEntry(
        document: _document,
        selection: modelSel,
        timestamp: DateTime.now(),
      ),
    );
  }

  /// Undo the last edit. Restores the document and cursor from the snapshot.
  void undo() =>
      _applyUndoRedo(retrieve: _undoManager.undo, stash: _undoManager.pushRedo);

  /// Redo the last undone edit. Restores the document and cursor from the snapshot.
  void redo() => _applyUndoRedo(
    retrieve: _undoManager.redo,
    stash: _undoManager.pushUndoRaw,
  );

  void _applyUndoRedo({
    required UndoEntry? Function() retrieve,
    required void Function(UndoEntry) stash,
  }) {
    final entry = retrieve();
    if (entry == null) return;

    stash(
      UndoEntry(
        document: _document,
        selection: _selectionToModel(value.selection),
        timestamp: DateTime.now(),
      ),
    );

    _document = entry.document;
    _syncToTextField(modelSelection: entry.selection);
    _activeStyles = _document.stylesAt(
      entry.selection.baseOffset.clamp(0, _document.plainText.length),
    );
  }

  // -- Public queries --

  /// Encode the current selection as markdown. Returns null if no selection.
  /// Used for rich copy — put the result on the clipboard.
  String? encodeSelection() {
    if (!value.selection.isValid || value.selection.isCollapsed) return null;
    final modelSel = _selectionToModel(value.selection);
    final (start, end) = _orderedRange(modelSel);
    final blocks = _document.extractRange(start, end);
    if (blocks.isEmpty) return null;
    final tempDoc = Document(blocks);
    return MarkdownCodec(schema: _schema).encode(tempDoc);
  }

  /// Whether the block at the cursor can be indented.
  bool get canIndent {
    if (!value.selection.isValid || !value.selection.isCollapsed) return false;
    final modelSel = _selectionToModel(value.selection);
    final pos = _document.blockAt(modelSel.baseOffset);
    final result = IndentBlock(
      pos.blockIndex,
      policies: _schema.policies,
    ).apply(_document);
    return !identical(result, _document);
  }

  /// Whether the block at the cursor can be changed to [type].
  /// Returns false for void types, same-type no-ops, and policy violations.
  bool canSetBlockType(BlockType type) {
    if (!value.selection.isValid) return false;
    if (_schema.isVoid(type)) return false;
    final modelSel = _selectionToModel(value.selection);
    final pos = _document.blockAt(modelSel.baseOffset);
    final block = _document.allBlocks[pos.blockIndex];
    if (block.blockType == type) return true; // already this type — "valid"
    final result = ChangeBlockType(
      pos.blockIndex,
      type,
      policies: _schema.policies,
    ).apply(_document);
    return !identical(result, _document);
  }

  /// Whether the block at the cursor can be outdented (is nested).
  bool get canOutdent {
    if (!value.selection.isValid || !value.selection.isCollapsed) return false;
    final modelSel = _selectionToModel(value.selection);
    final pos = _document.blockAt(modelSel.baseOffset);
    return _document.depthOf(pos.blockIndex) > 0;
  }

  // -- Public actions --

  void indent() {
    if (!value.selection.isValid || !value.selection.isCollapsed) return;
    final modelSel = _selectionToModel(value.selection);
    final pos = _document.blockAt(modelSel.baseOffset);

    _pushUndo();
    _document = IndentBlock(
      pos.blockIndex,
      policies: _schema.policies,
    ).apply(_document);
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

  /// Insert a divider at the cursor position.
  ///
  /// Splits the current block at the cursor, inserts a divider before the
  /// second half, and places the cursor after the divider. Only works on
  /// root-level non-void blocks.
  void insertDivider() {
    if (!value.selection.isValid) return;
    final modelSel = _selectionToModel(value.selection);
    final pos = _document.blockAt(modelSel.baseOffset);
    final block = _document.allBlocks[pos.blockIndex];

    // Don't insert divider inside a void block or nested block.
    if (_schema.isVoid(block.blockType)) return;
    if (_document.depthOf(pos.blockIndex) > 0) return;

    _pushUndo();

    // Split at cursor, then change the new block to divider, then split
    // again to create a paragraph after the divider.
    final dividerBlock = TextBlock(
      id: generateBlockId(),
      blockType: BlockType.divider,
    );

    // Split current block at cursor position.
    _document = SplitBlock(pos.blockIndex, pos.localOffset).apply(_document);
    // Insert divider between the two halves.
    _document = _document.insertAfterFlatIndex(pos.blockIndex, dividerBlock);
    // Cursor goes to the block after the divider (pos.blockIndex + 2).
    final cursorOffset = _document.globalOffset(pos.blockIndex + 2, 0);
    _syncToTextField(
      modelSelection: TextSelection.collapsed(offset: cursorOffset),
    );
    _activeStyles = _document.stylesAt(cursorOffset);
  }

  /// Whether a divider can be inserted at the cursor position.
  bool get canInsertDivider {
    if (!value.selection.isValid) return false;
    final modelSel = _selectionToModel(value.selection);
    final pos = _document.blockAt(modelSel.baseOffset);
    final block = _document.allBlocks[pos.blockIndex];
    if (_schema.isVoid(block.blockType)) return false;
    if (_document.depthOf(pos.blockIndex) > 0) return false;
    return true;
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
      _styleOverrideOffset = displayToModel(value.selection.baseOffset);
      notifyListeners();
      return;
    }

    // Non-collapsed: apply ToggleStyle to each block in the range.
    final modelSel = _selectionToModel(value.selection);
    final (start, end) = _orderedRange(modelSel);

    final ops = <EditOperation>[];
    _forEachBlockInRange(start, end, (i, _, localStart, localEnd) {
      ops.add(ToggleStyle(i, localStart, localEnd, style));
    });

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

  /// Apply a link to the current selection.
  ///
  /// Requires a non-collapsed selection. Applies [InlineStyle.link] with
  /// the given [url] as an attribute. To remove a link, use
  /// `toggleStyle(InlineStyle.link)` on a fully-linked selection.
  void setLink(String url) {
    if (!value.selection.isValid || value.selection.isCollapsed) return;

    final modelSel = _selectionToModel(value.selection);
    final (start, end) = _orderedRange(modelSel);
    final attrs = {'url': url};

    // Build ops: if any part of the range already has a link, remove it first
    // so the toggle always adds. This makes setLink idempotent for edits.
    final removeOps = <EditOperation>[];
    final addOps = <EditOperation>[];
    _forEachBlockInRange(start, end, (i, block, localStart, localEnd) {
      // Check if this range already has link style — if so, remove first.
      var hasLink = false;
      var offset = 0;
      for (final seg in block.segments) {
        final segEnd = offset + seg.text.length;
        if (segEnd > localStart &&
            offset < localEnd &&
            seg.styles.contains(InlineStyle.link)) {
          hasLink = true;
          break;
        }
        offset = segEnd;
      }
      if (hasLink) {
        removeOps.add(
          ToggleStyle(
            i,
            localStart,
            localEnd,
            InlineStyle.link,
            attributes: attrs,
          ),
        );
      }
      addOps.add(
        ToggleStyle(
          i,
          localStart,
          localEnd,
          InlineStyle.link,
          attributes: attrs,
        ),
      );
    });

    if (addOps.isEmpty) return;

    _pushUndo();
    final tx = Transaction(
      operations: [...removeOps, ...addOps],
      selectionAfter: modelSel,
    );
    _document = tx.apply(_document);
    _activeStyles = _stylesForSelection(
      TextSelection(baseOffset: start, extentOffset: end),
    );
    _syncToTextField(modelSelection: modelSel);
    notifyListeners();
  }

  /// Change the block type of the block at the cursor position.
  void setBlockType(BlockType type) {
    if (!value.selection.isValid) return;
    final modelSel = _selectionToModel(value.selection);
    final pos = _document.blockAt(modelSel.baseOffset);

    _pushUndo();
    _document = ChangeBlockType(
      pos.blockIndex,
      type,
      policies: _schema.policies,
    ).apply(_document);
    _syncToTextField(modelSelection: modelSel);
  }

  /// Get the block type at the current cursor position.
  BlockType get currentBlockType {
    if (!value.selection.isValid) return BlockType.paragraph;
    final modelSel = _selectionToModel(value.selection);
    final pos = _document.blockAt(modelSel.baseOffset);
    return _document.allBlocks[pos.blockIndex].blockType;
  }

  /// Whether the task at the cursor is checked. Returns false if not a task.
  bool get isTaskChecked {
    if (!value.selection.isValid) return false;
    final modelSel = _selectionToModel(value.selection);
    final pos = _document.blockAt(modelSel.baseOffset);
    final block = _document.allBlocks[pos.blockIndex];
    if (block.blockType != BlockType.taskItem) return false;
    return block.metadata[kCheckedKey] == true;
  }

  /// Toggle checked state of the task at the cursor.
  void toggleTaskChecked() {
    if (!value.selection.isValid) return;
    final modelSel = _selectionToModel(value.selection);
    final pos = _document.blockAt(modelSel.baseOffset);
    toggleTaskCheckedAt(pos.blockIndex);
  }

  /// Toggle checked state of the task at [flatIndex].
  ///
  /// Used by prefix tap handling — the checkbox prefix calls this directly
  /// with the block's flat index, independent of cursor position.
  void toggleTaskCheckedAt(int flatIndex) {
    final flat = _document.allBlocks;
    if (flatIndex < 0 || flatIndex >= flat.length) return;
    final block = flat[flatIndex];
    if (block.blockType != BlockType.taskItem) return;

    final current = block.metadata[kCheckedKey] == true;
    _pushUndo();
    _document = SetBlockMetadata(
      flatIndex,
      kCheckedKey,
      !current,
    ).apply(_document);

    // Preserve current selection if valid, otherwise just sync.
    final modelSel = value.selection.isValid
        ? _selectionToModel(value.selection)
        : null;
    _syncToTextField(modelSelection: modelSel);
    notifyListeners();
  }

  // -- Edit pipeline --

  /// Run input rules on [tx], push undo, apply, sync to TextField, update styles.
  ///
  /// If no input rule overrides selectionAfter, the fallback selection is
  /// computed from the current display cursor against the NEW document.
  void _commitTransaction(Transaction tx) {
    // During composing (and the resolve frame), skip input rules and undo.
    // One undo entry was already pushed when composing started.
    final isProvisional = _preComposingValue != null;

    var finalTx = tx;
    if (!isProvisional) {
      for (final rule in _inputRules) {
        final transformed = rule.tryTransform(finalTx, _document);
        if (transformed != null) {
          finalTx = transformed;
          break;
        }
      }
      _pushUndo();
    }

    _document = finalTx.apply(_document);

    final TextSelection afterSel;
    if (finalTx != tx && finalTx.selectionAfter != null) {
      afterSel = finalTx.selectionAfter!;
    } else {
      // Compute fallback against the NEW document (after apply).
      final newModelOffset = displayToModel(value.selection.baseOffset);
      afterSel = TextSelection.collapsed(offset: newModelOffset);
    }
    _syncToTextField(modelSelection: afterSel);
    _activeStyles = _document.stylesAt(
      displayToModel(value.selection.baseOffset),
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
    final modelOffset = displayToModel(value.selection.baseOffset);
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

    final isComposing =
        value.composing.isValid && value.composing.start != value.composing.end;

    // Track composing lifecycle. On first composing frame, save the
    // pre-composing state and push one undo entry for the whole sequence.
    if (isComposing && _preComposingValue == null) {
      _preComposingValue = _previousValue;
      _pushUndo();
    }

    // Incremental diff — always between previous frame and current frame.
    // This keeps the model in sync with the display text during composing,
    // so buildTextSpan renders correctly with full styling.
    final cursor = value.selection.isValid ? value.selection.baseOffset : null;
    final diff = diffTexts(_previousValue.text, text, cursorOffset: cursor);

    // 1. Selection-only change (no text edit).
    if (diff == null) {
      _handleSelectionChange();
      if (!isComposing && _preComposingValue != null) {
        _preComposingValue = null;
      }
      return;
    }

    // Translate diff from display to model space.
    // Strip display-only characters (prefix chars and empty block placeholders).
    final cleanInserted = diff.insertedText
        .replaceAll(mapper.prefixChar, '')
        .replaceAll(mapper.emptyBlockChar, '');
    final modelStart = displayToModel(diff.start);
    final deletedText = _previousValue.text.substring(
      diff.start,
      diff.start + diff.deletedLength,
    );
    final displayOnlyDeleted =
        mapper.prefixChar.allMatches(deletedText).length +
        mapper.emptyBlockChar.allMatches(deletedText).length;
    final modelDeletedLength = diff.deletedLength - displayOnlyDeleted;

    // 2. Only display-only chars deleted (backspace over bullet / empty placeholder).
    if (modelDeletedLength == 0 &&
        displayOnlyDeleted > 0 &&
        cleanInserted.isEmpty) {
      _handlePrefixDelete(modelStart);
      if (!isComposing && _preComposingValue != null) {
        _preComposingValue = null;
      }
      return;
    }

    // 3. Normal text edit — build transaction and commit.
    final modelDiff = TextDiff(modelStart, modelDeletedLength, cleanInserted);
    final modelSelection = _selectionToModel(value.selection);

    final tx = _transactionFromDiff(modelDiff, modelSelection);
    if (tx == null) {
      _previousValue = value;
      if (!isComposing && _preComposingValue != null) {
        _preComposingValue = null;
      }
      return;
    }

    _commitTransaction(tx);

    // Clear composing state AFTER processing the resolve frame so that
    // _commitTransaction sees it and skips undo + input rules.
    if (!isComposing && _preComposingValue != null) {
      _preComposingValue = null;
    }
  }

  // -- Transaction building (all in model space) --

  Transaction? _transactionFromDiff(TextDiff diff, TextSelection selection) {
    if (diff.deletedLength == 0 && diff.insertedText.isEmpty) return null;

    // Tab → indent.
    if (diff.insertedText == '\t' && diff.deletedLength == 0) {
      final pos = _document.blockAt(diff.start);
      final block = _document.allBlocks[pos.blockIndex];
      if (_schema.isListLike(block.blockType)) {
        return Transaction(
          operations: [IndentBlock(pos.blockIndex)],
          selectionAfter: selection,
        );
      }
      return null;
    }

    // Multi-character insert (paste heuristic): try markdown decode.
    // Fires for both pure inserts and selection replacements (delete + insert).
    // If the decoded result has formatting, use PasteBlocks.
    if (diff.insertedText.length > 1) {
      final pasteResult = _tryMarkdownPaste(diff, selection);
      if (pasteResult != null) return pasteResult;
    }

    // Pure newline insert → split (no delete involved).
    if (diff.insertedText == '\n' && diff.deletedLength == 0) {
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
        ops.add(
          DeleteText(
            startPos.blockIndex,
            startPos.localOffset,
            diff.deletedLength,
          ),
        );
      } else if (endPos.blockIndex == startPos.blockIndex + 1 &&
          startPos.localOffset ==
              _document.allBlocks[startPos.blockIndex].length &&
          endPos.localOffset == 0 &&
          diff.insertedText.isEmpty) {
        // Delete exactly one block boundary — use MergeBlocks for input rules.
        ops.add(MergeBlocks(endPos.blockIndex));
      } else {
        ops.add(
          DeleteRange(
            startPos.blockIndex,
            startPos.localOffset,
            endPos.blockIndex,
            endPos.localOffset,
          ),
        );
      }

      if (diff.insertedText.isNotEmpty) {
        ops.add(
          InsertText(
            startPos.blockIndex,
            startPos.localOffset,
            diff.insertedText,
            styles: _activeStyles,
          ),
        );
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

  // -- Paste helpers --

  /// Try to decode pasted text as markdown. Returns a transaction with
  /// PasteBlocks if the decoded result has formatting, or null to fall
  /// through to plain text handling.
  Transaction? _tryMarkdownPaste(TextDiff diff, TextSelection selection) {
    final codec = MarkdownCodec(schema: _schema);
    final decoded = codec.decode(diff.insertedText);
    final blocks = decoded.allBlocks;

    // Check if the decoded result has any formatting worth preserving.
    // If it's just a single paragraph with no styles/attributes, skip — let
    // the normal plain-text pipeline handle it.
    final hasFormatting =
        blocks.length > 1 ||
        blocks.any((b) => b.blockType != BlockType.paragraph) ||
        blocks.any(
          (b) => b.segments.any(
            (s) => s.styles.isNotEmpty || s.attributes.isNotEmpty,
          ),
        );

    if (!hasFormatting) return null;

    final ops = <EditOperation>[];

    // If there's a deletion (selection replacement), delete first.
    if (diff.deletedLength > 0) {
      final startPos = _document.blockAt(diff.start);
      final deleteEnd = diff.start + diff.deletedLength;
      final endPos = _document.blockAt(deleteEnd);
      if (startPos.blockIndex == endPos.blockIndex) {
        ops.add(
          DeleteText(
            startPos.blockIndex,
            startPos.localOffset,
            diff.deletedLength,
          ),
        );
      } else {
        ops.add(
          DeleteRange(
            startPos.blockIndex,
            startPos.localOffset,
            endPos.blockIndex,
            endPos.localOffset,
          ),
        );
      }
    }

    final pos = _document.blockAt(diff.start);

    ops.add(PasteBlocks(pos.blockIndex, pos.localOffset, decoded.blocks));

    // Compute cursor position: end of the last pasted block.
    var cursorOffset = diff.start;
    for (final b in blocks) {
      cursorOffset += b.length;
    }
    // Add separators between blocks.
    cursorOffset += blocks.length - 1;

    return Transaction(
      operations: ops,
      selectionAfter: TextSelection.collapsed(offset: cursorOffset),
    );
  }

  // -- TextField sync --

  /// Push document state to the TextField. Selection is in model space and
  /// gets translated to display space.
  void _syncToTextField({TextSelection? modelSelection}) {
    _isSyncing = true;
    final displayText = mapper.buildDisplayText(_document, _schema);
    final modelSel =
        modelSelection ??
        TextSelection.collapsed(offset: _document.plainText.length);
    final displaySel = _selectionToDisplay(modelSel);

    // Preserve the composing range during IME composing so the platform
    // knows composing is still active.
    final composing = _preComposingValue != null && value.composing.isValid
        ? value.composing
        : TextRange.empty;

    value = TextEditingValue(
      text: displayText,
      selection: TextSelection(
        baseOffset: displaySel.baseOffset.clamp(0, displayText.length),
        extentOffset: displaySel.extentOffset.clamp(0, displayText.length),
      ),
      composing: composing,
    );
    _previousValue = value;
    _isSyncing = false;
  }

  // -- Tap handling --

  /// Get the styled segment at a model offset, or null if out of range.
  /// Use this to detect what the user tapped on (link, image, etc.).
  /// At segment boundaries, returns the segment starting at that offset
  /// (forward-matching). Use [segmentBeforeOffset] for the preceding segment.
  StyledSegment? segmentAtOffset(int modelOffset) {
    final pos = _document.blockAt(modelOffset);
    final block = _document.allBlocks[pos.blockIndex];
    var offset = 0;
    for (final seg in block.segments) {
      final segEnd = offset + seg.text.length;
      if (pos.localOffset >= offset && pos.localOffset < segEnd) {
        return seg;
      }
      offset = segEnd;
    }
    // At block end — return last segment.
    if (block.segments.isNotEmpty && pos.localOffset == block.length) {
      return block.segments.last;
    }
    return null;
  }

  /// Get the link URL at a display offset, or null if not on a link.
  /// Checks both the segment at the offset and the preceding one, so
  /// tapping at either the start or end of a link detects it.
  String? linkAtDisplayOffset(int displayOffset) {
    final modelOffset = displayToModel(displayOffset);
    return _linkFrom(segmentAtOffset(modelOffset)) ??
        (modelOffset > 0 ? _linkFrom(segmentAtOffset(modelOffset - 1)) : null);
  }

  static String? _linkFrom(StyledSegment? seg) {
    if (seg != null &&
        seg.styles.contains(InlineStyle.link) &&
        seg.attributes['url'] != null) {
      return seg.attributes['url'] as String;
    }
    return null;
  }

  // -- Rendering --

  /// Called when a prefix widget (bullet, checkbox, etc.) is tapped.
  /// Override or set [onPrefixTap] to customize behavior.
  ///
  /// Default: toggles checked state for task items, no-op for other types.
  spans.PrefixTapCallback? onPrefixTap;

  void _defaultPrefixTap(int flatIndex, TextBlock block) {
    if (block.blockType == BlockType.taskItem) {
      toggleTaskCheckedAt(flatIndex);
    }
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    return spans.buildDocumentSpan(
      _document,
      style,
      _schema,
      onPrefixTap: onPrefixTap ?? _defaultPrefixTap,
    );
  }

  @override
  void dispose() {
    removeListener(_onValueChanged);
    super.dispose();
  }
}
