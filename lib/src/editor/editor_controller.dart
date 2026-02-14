import 'package:flutter/widgets.dart';

import '../codec/markdown_codec.dart';
import '../model/block.dart';
import '../model/document.dart';
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
/// [B] is the block type key, [S] is the inline style key.
///
/// Offset translation is handled by [offset_mapper.dart].
/// Rendering is handled by [span_builder.dart].
/// This class owns the edit pipeline, undo/redo, and public actions.
class EditorController<B extends Object, S extends Object>
    extends TextEditingController {
  EditorController({
    Document<B>? document,
    required EditorSchema<B, S> schema,
    List<InputRule>? additionalInputRules,
    LinkTapCallback? onLinkTap,
    ShouldGroupUndo? undoGrouping,
    int maxUndoStack = 100,
  }) : assert(
         B != Object && S != Object,
         'EditorController requires explicit type parameters.\n'
         'Use EditorController<BlockType, InlineStyle>(...) '
         'instead of EditorController(...).',
       ),
       _document = document ?? Document.empty(schema.defaultBlockType),
       _schema = schema,
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

  Document<B> _document;
  late final List<InputRule> _inputRules;
  final EditorSchema<B, S> _schema;
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
  Set<Object> _activeStyles = {};

  Document<B> get document => _document;
  EditorSchema<B, S> get schema => _schema;

  /// Active inline styles at the cursor. Typed as `Set<S>` for exhaustive
  /// switch. The internal set uses `Set<Object>` — the cast is safe because
  /// only S values are ever added.
  Set<S> get activeStyles => _activeStyles.cast<S>();

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
    // With a selection, prefer the segment being selected (forward).
    // With a collapsed cursor, prefer the segment the cursor is "on" (backward)
    // so that positioning at the end of a link reports that link's attributes.
    final boundary = value.selection.isCollapsed
        ? SegmentBoundary.backward
        : SegmentBoundary.forward;
    final seg = _document.segmentAt(modelOffset, boundary: boundary);
    return seg?.attributes ?? const {};
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
    void Function(
      int flatIndex,
      TextBlock<B> block,
      int localStart,
      int localEnd,
    )
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
  Set<Object> _stylesForSelection(TextSelection sel) {
    final modelSel = _selectionToModel(sel);

    if (sel.isCollapsed) {
      return _document.stylesAt(modelSel.baseOffset);
    }

    final (start, end) = _orderedRange(modelSel);
    if (start == end) return _document.stylesAt(start);

    // Walk segments in the range, intersect their styles.
    Set<Object>? result;
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

    _document = entry.document as Document<B>;
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
  bool canSetBlockType(B type) {
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
    final dividerBlock = TextBlock<B>(
      id: generateBlockId(),
      blockType: BlockType.divider as B,
    );

    // Split current block at cursor position.
    _document = SplitBlock(
      pos.blockIndex,
      pos.localOffset,
      defaultBlockType: _schema.defaultBlockType,
      isListLikeFn: _schema.isListLike,
    ).apply(_document);
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
  void toggleStyle(S style) {
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
  }

  /// Apply a link to the current selection, or update the link at the cursor.
  ///
  /// With a selection: applies [InlineStyle.link] with the given [url].
  /// With a collapsed cursor inside an existing link: updates that link's URL.
  /// To remove a link, use `toggleStyle(InlineStyle.link)` on a linked selection.
  void setLink(String url) {
    if (!value.selection.isValid) return;

    // Collapsed cursor inside an existing link → update that segment's URL.
    if (value.selection.isCollapsed) {
      final modelOffset = displayToModel(value.selection.baseOffset);
      final pos = _document.blockAt(modelOffset);
      final block = _document.allBlocks[pos.blockIndex];
      var segStart = 0;
      for (final seg in block.segments) {
        final segEnd = segStart + seg.text.length;
        if (pos.localOffset >= segStart && pos.localOffset <= segEnd &&
            seg.styles.contains(InlineStyle.link)) {
          // Found the link segment — apply remove + add over its range.
          final globalStart = _document.globalOffset(pos.blockIndex, segStart);
          _pushUndo();
          final attrs = {'url': url};
          final tx = Transaction(operations: [
            ToggleStyle(pos.blockIndex, segStart, segEnd, InlineStyle.link,
                attributes: seg.attributes),
            ToggleStyle(pos.blockIndex, segStart, segEnd, InlineStyle.link,
                attributes: attrs),
          ], selectionAfter: _selectionToModel(value.selection));
          _document = tx.apply(_document);
          _syncToTextField(
            modelSelection: TextSelection.collapsed(offset: globalStart + (pos.localOffset - segStart)),
          );
          return;
        }
        segStart = segEnd;
      }
      // Collapsed but not inside a link — nothing to do.
      return;
    }

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
  }

  /// Change the block type of the block at the cursor position.
  void setBlockType(B type) {
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
  B get currentBlockType {
    if (!value.selection.isValid) return _schema.defaultBlockType;
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
  }

  // -- Edit pipeline --

  /// Run input rules on [tx], push undo, apply, sync to TextField, update styles.
  ///
  /// If no input rule overrides selectionAfter, the fallback selection is
  /// computed from the current display cursor against the NEW document.
  void _commitTransaction(Transaction tx, {TextSelection? cursorOverride}) {
    // During composing (and the resolve frame), skip input rules and undo.
    // One undo entry was already pushed when composing started.
    final isProvisional = _preComposingValue != null;

    var finalTx = tx;
    if (!isProvisional) {
      for (final rule in _inputRules) {
        final transformed = rule.tryTransform(finalTx, _document, _schema);
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
      // Input rule overrode the selection.
      afterSel = finalTx.selectionAfter!;
    } else if (cursorOverride != null) {
      // Caller supplied an explicit post-apply cursor (model space).
      afterSel = cursorOverride;
    } else {
      // Fallback: map the display cursor through the NEW document.
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
      // Cursor should land at the merge point: end of the previous block.
      final mergePoint = _document.globalOffset(
        pos.blockIndex - 1,
        _document.allBlocks[pos.blockIndex - 1].length,
      );
      final cursorAfter = TextSelection.collapsed(offset: mergePoint);
      final tx = Transaction(
        operations: [MergeBlocks(pos.blockIndex)],
        selectionAfter: cursorAfter,
      );
      _commitTransaction(tx, cursorOverride: cursorAfter);
      return;
    } else if (pos.blockIndex == 0 && pos.localOffset == 0) {
      // First block: can't merge, but convert to default type.
      // ChangeBlockType handles outdenting children if the new type
      // doesn't allow them (via policies).
      final block = _document.allBlocks[0];
      if (block.blockType != _schema.defaultBlockType) {
        final tx = Transaction(
          operations: [
            ChangeBlockType(0, _schema.defaultBlockType,
                policies: _schema.policies),
          ],
          selectionAfter: const TextSelection.collapsed(offset: 0),
        );
        _commitTransaction(
          tx,
          cursorOverride: const TextSelection.collapsed(offset: 0),
        );
        return;
      }
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
    // Strip display-only characters (prefix chars, spacer sequences, and
    // empty block placeholders).
    final cleanInserted = diff.insertedText
        .replaceAll('${mapper.spacerChar}\n', '') // spacer \u200C\n
        .replaceAll(mapper.spacerChar, '') // lone spacer char
        .replaceAll(mapper.prefixChar, '') // prefix \uFFFC
        .replaceAll(mapper.emptyBlockChar, '');
    final modelStart = displayToModel(diff.start);
    final modelEnd = displayToModel(diff.start + diff.deletedLength);
    final modelDeletedLength = modelEnd - modelStart;
    final displayOnlyDeleted = diff.deletedLength - modelDeletedLength;

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

    final (tx, pasteCursor) = _transactionFromDiff(modelDiff, modelSelection);
    if (tx == null) {
      _previousValue = value;
      if (!isComposing && _preComposingValue != null) {
        _preComposingValue = null;
      }
      return;
    }

    _commitTransaction(tx, cursorOverride: pasteCursor);

    // Clear composing state AFTER processing the resolve frame so that
    // _commitTransaction sees it and skips undo + input rules.
    if (!isComposing && _preComposingValue != null) {
      _preComposingValue = null;
    }
  }

  // -- Transaction building (all in model space) --

  /// Returns (transaction, optional model-space cursor override).
  /// The cursor override is used by paste to position the cursor correctly.
  (Transaction?, TextSelection?) _transactionFromDiff(
    TextDiff diff,
    TextSelection selection,
  ) {
    if (diff.deletedLength == 0 && diff.insertedText.isEmpty) {
      return (null, null);
    }

    // Tab character — strip it. Indent is handled by BulletEditor's
    // onKeyEvent (which must intercept Tab to prevent focus traversal).
    // If \t somehow reaches here (e.g. external paste), just discard it.
    if (diff.insertedText == '\t' && diff.deletedLength == 0) {
      _syncToTextField(modelSelection: selection);
      return (null, null);
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
      // After split, cursor goes to the start of the new block (index + 1).
      // Compute the model offset: everything before the split point, plus the
      // separator (\n) between the two blocks = diff.start + 1 char past
      // the split point... but actually it's simpler: the new block starts
      // at model offset = (text before split point) + 1 (block separator).
      // That's diff.start + 1 if splitting at end, or the global offset of
      // the new block at local 0. We compute it post-apply via cursorOverride.
      final splitOffset = diff.start;
      // Model cursor after split = start of new block = splitOffset + 1
      // (the +1 accounts for the block separator \n in model text).
      final cursorAfter = TextSelection.collapsed(
        offset: splitOffset + 1,
      );
      return (
        Transaction(
          operations: [
            SplitBlock(
              pos.blockIndex,
              pos.localOffset,
              defaultBlockType: _schema.defaultBlockType,
              isListLikeFn: _schema.isListLike,
            ),
          ],
          selectionAfter: selection,
        ),
        cursorAfter,
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

      // Cut/delete from position 0 within a single block → reset to default.
      // Only fires for within-block deletes (e.g. selecting text from the
      // start of a heading and cutting). Does NOT fire on cross-block merges
      // (forward-delete across a boundary), which should preserve the
      // surviving block's type.
      if (startPos.localOffset == 0 &&
          diff.insertedText.isEmpty &&
          startPos.blockIndex == endPos.blockIndex) {
        final blockType = _document.allBlocks[startPos.blockIndex].blockType;
        if (blockType != _schema.defaultBlockType) {
          ops.add(
            ChangeBlockType(startPos.blockIndex, _schema.defaultBlockType,
                policies: _schema.policies),
          );
        }
      }

      return (Transaction(operations: ops, selectionAfter: selection), null);
    }

    // Pure insert (no delete).
    if (diff.insertedText.isNotEmpty) {
      return (
        Transaction(
          operations: [
            InsertText(
              startPos.blockIndex,
              startPos.localOffset,
              diff.insertedText,
              styles: _activeStyles,
            ),
          ],
          selectionAfter: selection,
        ),
        null,
      );
    }

    return (null, null);
  }

  // -- Paste helpers --

  /// Try to decode pasted text as markdown. Returns (transaction, modelCursor)
  /// if the decoded result has formatting, or null to fall through.
  (Transaction, TextSelection)? _tryMarkdownPaste(
    TextDiff diff,
    TextSelection selection,
  ) {
    final codec = MarkdownCodec(schema: _schema);
    final decoded = codec.decode(diff.insertedText);
    final blocks = decoded.allBlocks;

    // Check if the decoded result has any formatting worth preserving.
    // If it's just a single paragraph with no styles/attributes, skip — let
    // the normal plain-text pipeline handle it.
    final hasFormatting =
        blocks.length > 1 ||
        blocks.any((b) => b.blockType != _schema.defaultBlockType) ||
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

    final modelCursor = TextSelection.collapsed(offset: cursorOffset);
    return (
      Transaction(operations: ops, selectionAfter: selection),
      modelCursor,
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
    // Always notify even if the TextEditingValue is identical — the document
    // structure may have changed (e.g. indent/outdent) which affects
    // buildTextSpan output without changing the raw display text.
    notifyListeners();
    _previousValue = value;
    _isSyncing = false;
  }

  // -- Tap handling --

  /// Get the styled segment at a model offset, or null if out of range.
  /// Delegates to [Document.segmentAt] with forward boundary.
  StyledSegment? segmentAtOffset(int modelOffset) =>
      _document.segmentAt(modelOffset);

  /// Get the link URL at a display offset, or null if not on a link.
  /// Checks both forward and backward boundaries so tapping at either
  /// edge of a link detects it.
  String? linkAtDisplayOffset(int displayOffset) {
    final modelOffset = displayToModel(displayOffset);
    return _linkFrom(_document.segmentAt(modelOffset)) ??
        _linkFrom(_document.segmentAt(modelOffset, boundary: SegmentBoundary.backward));
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
