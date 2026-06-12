import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show TextRange;
import 'package:flutter/widgets.dart' show FocusNode;

import '../model/block.dart';
import '../model/block_policies.dart';
import '../model/doc_selection.dart';
import '../model/document.dart';
import '../schema/editor_schema.dart';
import 'edit_operation.dart';
import 'input_rule.dart';
import 'undo_manager.dart';

/// The single writer over the document (architecture §Operations).
///
/// Every mutation — public ops, conveniences, undo/redo — executes through
/// one choke point ([_edit]): mutations are serialized, listeners are
/// notified only after a batch fully commits, and a rejected batch leaves
/// document and selection untouched. Synchronous producers (gestures,
/// hardware keys, app calls) arrive pre-serialized on the UI thread; the
/// `ImeService` feeds its delta batches through this same choke point in
/// arrival order (the IME surface below).
class EditorController extends ChangeNotifier {
  EditorController({
    required Document document,
    required this.schema,
    ShouldGroupUndo? undoGrouping,
  }) : _document = document,
       _undoManager = UndoManager(grouping: undoGrouping);

  final EditorSchema schema;
  final UndoManager _undoManager;

  Document _document;
  Document get document => _document;

  DocSelection? _selection;
  DocSelection? get selection => _selection;

  /// The active IME composing region (architecture §Selection). Lifecycle:
  /// set only by IME-originated input (the `ImeService` batch path); cleared
  /// by `terminateComposition(reason)` via [imeClearComposing], or by IME
  /// input reporting an empty composing region; never restored by undo/redo.
  ComposingState? _composing;
  ComposingState? get composing => _composing;

  bool get canUndo => _undoManager.canUndo;
  bool get canRedo => _undoManager.canRedo;

  // --- Focus surface (architecture §public API) ---
  //
  // The internal Focus widget is package-private, so focusing a new note or
  // dismissing the keyboard on save/navigate has no app-side workaround
  // without this. The widget's focus listener drives the IME connection
  // lifecycle off this node (ImeService attach/detach).

  FocusNode? _focusNode;

  /// Binds the editor widget's focus node. Called by `BulletEditor`; not for
  /// app use — pass a `focusNode` to the widget instead.
  void attachFocusNode(FocusNode node) => _focusNode = node;

  /// Unbinds [node] if it is the bound focus node.
  void detachFocusNode(FocusNode node) {
    if (identical(_focusNode, node)) _focusNode = null;
  }

  bool get hasFocus => _focusNode?.hasFocus ?? false;
  void requestFocus() => _focusNode?.requestFocus();
  void clearFocus() => _focusNode?.unfocus();

  // --- IME surface (consumed by ImeService — not for app use) ---
  //
  // The IME layer produces ops/intents and calls back through this surface
  // so every delta batch executes through the same choke point as any other
  // mutation (architecture §single writer). The `ime*` verbs assert they run
  // inside [imeEdit]; composing-state setters own the composition-scoped
  // undo group transitions.

  /// Registered by `ImeService`: invoked synchronously after every commit or
  /// selection change that did NOT originate from the IME path, with the
  /// `terminateComposition` reason the change implies. This is the no-echo
  /// invariant's clause (a)/(b) trigger (IME §no-echo) and the G3 latch
  /// invalidation signal.
  void Function(String reason)? imeExternalChangeHandler;

  /// An open composition-scoped undo group (architecture §Undo): per-batch
  /// undo pushes are suppressed until the composition commits or terminates.
  bool _composingUndoGroup = false;

  /// Whether the open group's pre-composition snapshot has been pushed. A
  /// group opened by a composing-only update (no text batch) defers its push
  /// to the first text batch — the document is still the pre-composition
  /// state at that point.
  bool _composingGroupPushed = false;

  /// Whether a batch already committed inside the current [imeEdit] group —
  /// one delta batch is one logical edit, so follow-up batches in the same
  /// group (multi-delta batches, input-rule outcomes) never push.
  bool _imeGroupHadBatch = false;

  /// Runs [body] as ONE IME-originated edit group: a single notify, a single
  /// undo entry (or none, under the composition-scoped suppression), and no
  /// external-change echo back to the IME.
  T imeEdit<T>(T Function() body) {
    return _asIme(() {
      _imeGroupHadBatch = false;
      return _edit(body);
    });
  }

  /// Applies one delta's ops inside [imeEdit] through the batch loop.
  EditResult imeApplyOps(
    List<EditOperation> ops, {
    DocSelection? Function(Document newDoc)? selectionAfter,
  }) {
    assert(_inEdit && _currentEditIsIme, 'imeApplyOps runs inside imeEdit');
    return _applyBatch(ops, selectionAfter: selectionAfter);
  }

  /// Selection moved by the IME (delta selections, `NonTextUpdate`) — applied
  /// without the external-change echo a [setSelection] would produce.
  void imeSetSelection(DocSelection selection) {
    assert(_inEdit && _currentEditIsIme, 'imeSetSelection runs inside imeEdit');
    final normalized = _normalizeSelection(selection, _document);
    if (normalized != null) _selection = normalized;
  }

  /// IME text insertion at the current selection — insertion/replacement
  /// deltas set the mapped selection first, then insert (type-over of a
  /// selected void replaces it, the ordinary path).
  void imeInsertText(String text) {
    assert(_inEdit && _currentEditIsIme, 'imeInsertText runs inside imeEdit');
    if (text.isEmpty) return;
    _insertTextAtSelection(text);
  }

  /// IME Enter: a `\n` insertion delta or `performAction(newline)`. Consults
  /// the block type's [SplitPolicy] exactly like hardware Enter (G10).
  void imeInsertNewline() {
    assert(
      _inEdit && _currentEditIsIme,
      'imeInsertNewline runs inside imeEdit',
    );
    _insertNewlineAtSelection();
  }

  /// IME deletion of the current (non-collapsed) selection.
  void imeDeleteSelection() {
    assert(
      _inEdit && _currentEditIsIme,
      'imeDeleteSelection runs inside imeEdit',
    );
    final sel = _selection;
    if (sel == null || sel.isCollapsed) return;
    _deleteSelectionNow(sel);
  }

  /// G1: a deletion delta intersecting the sentinel maps to "structural
  /// backspace at block start" — the block type's declared `backspaceAtStart`
  /// policy, the same path hardware backspace consults.
  void imeStructuralBackspace(String blockId) {
    assert(
      _inEdit && _currentEditIsIme,
      'imeStructuralBackspace runs inside imeEdit',
    );
    final block = _document.blockById(blockId);
    if (block == null || schema.isVoid(block.blockType)) return;
    _structuralBackspace(block);
  }

  /// Sets the composing state from an applied delta batch (block-locally
  /// remapped by the caller). Opens/closes the composition-scoped undo group.
  /// Usable inside or outside [imeEdit] (the `NonTextUpdate`-only case).
  void imeSetComposing(ComposingState? value) {
    void apply() {
      if (value != null && !_composingUndoGroup) {
        _composingUndoGroup = true;
        // If this imeEdit group already committed a batch, that batch's push
        // IS the pre-composition snapshot.
        _composingGroupPushed = _imeGroupHadBatch;
      } else if (value == null) {
        _composingUndoGroup = false;
        _composingGroupPushed = false;
      }
      _composing = value;
    }

    if (_inEdit) {
      assert(_currentEditIsIme, 'imeSetComposing inside a non-IME edit');
      apply();
    } else {
      _asIme(() => _edit(apply));
    }
  }

  /// `terminateComposition`'s controller half: clears composing and closes
  /// the composition-scoped undo group. Never snapshots or restores
  /// composing (architecture §Undo).
  void imeClearComposing() {
    void apply() {
      _clearComposingState();
    }

    if (_inEdit) {
      apply();
    } else {
      _asIme(() => _edit(apply));
    }
  }

  /// The post-state input-rule run path (G3): runs the schema's
  /// insert-pattern rules against the current document at [blockId] /
  /// [editedRange]; the first match's ops apply through the batch loop
  /// (inside the same [imeEdit] group, so insert + rule transform is one
  /// undo entry). Returns whether a rule fired.
  bool imeRunInputRules(String blockId, TextRange editedRange) {
    assert(
      _inEdit && _currentEditIsIme,
      'imeRunInputRules runs inside imeEdit',
    );
    if (_document.blockById(blockId) == null) return false;
    for (final rule in schema.inputRules) {
      if (rule is! PatternInputRule) continue;
      final outcome = rule.tryTransform(
        _document,
        blockId,
        editedRange,
        schema,
      );
      if (outcome == null) continue;
      final selectionAfter = outcome.selectionAfter;
      final result = _applyBatch(
        outcome.operations,
        selectionAfter: selectionAfter == null ? null : (_) => selectionAfter,
      );
      return result is EditApplied;
    }
    return false;
  }

  // --- The choke point ---

  bool _inEdit = false;

  /// Whether the current edit originates from the IME path. Non-IME edits
  /// reach [imeExternalChangeHandler] post-commit (the no-echo invariant's
  /// clause (a)/(b) trigger — IME §no-echo); IME edits never echo.
  bool _currentEditIsIme = false;

  /// Runs one mutation exclusively, notifying listeners afterward iff
  /// document, selection, or composing changed. Reentrant mutation (a
  /// listener editing synchronously from a change notification) is a
  /// programming error — the notification fires post-commit, so a listener
  /// that wants to edit must schedule, not recurse.
  ///
  /// [reason] is the `terminateComposition` reason a non-IME change implies
  /// ('undo' for undo/redo, 'externalEdit' otherwise — IME §choke point).
  T _edit<T>(T Function() body, {String reason = 'externalEdit'}) {
    assert(
      !_inEdit,
      'Reentrant EditorController mutation: listeners are notified after a '
      'batch commits and must schedule follow-up edits, not apply them '
      'synchronously.',
    );
    _inEdit = true;
    final docBefore = _document;
    final selBefore = _selection;
    final composingBefore = _composing;
    final isIme = _currentEditIsIme;
    try {
      return body();
    } finally {
      _inEdit = false;
      final changed =
          !identical(_document, docBefore) ||
          _selection != selBefore ||
          _composing != composingBefore;
      if (changed) {
        notifyListeners();
        // After listeners, so the IME bridge reads final state. The handler
        // may terminate a live composition (which re-enters _edit as an
        // IME-marked mutation — never recursing back here).
        if (!isIme) imeExternalChangeHandler?.call(reason);
      }
    }
  }

  /// Marks mutations within [body] as IME-originated: the external-change
  /// handler is skipped and the composition-scoped undo rules apply.
  T _asIme<T>(T Function() body) {
    final previous = _currentEditIsIme;
    _currentEditIsIme = true;
    try {
      return body();
    } finally {
      _currentEditIsIme = previous;
    }
  }

  // --- Document & selection ---

  /// Replaces the document wholesale (open-a-different-note). Resets undo
  /// history. A live composition terminates through the external-change
  /// handler (`terminateComposition('externalEdit')`); composing is cleared
  /// here too — undo-group flags included, or a stale "snapshot pushed"
  /// flag makes the next composition's first batch skip its pre-composition
  /// undo push in headless use — because its block id references the
  /// outgoing document.
  void setDocument(Document document, {DocSelection? selection}) {
    _edit(() {
      _undoManager.clear();
      _clearComposingState();
      _document = document;
      _selection = selection == null
          ? null
          : _normalizeSelection(selection, document);
    });
  }

  /// Sets the selection, normalized (architecture §Selection G6):
  /// - a selection naming a gone block id is **rejected** (no-op) — the
  ///   mirror of the op missing-id policy: a missing id cannot be clamped;
  /// - text-block offsets are clamped to `[0, block.length]`;
  /// - void positions are clamped to `[0, 1]`, and a selection collapsed on
  ///   a void becomes the `[0,1)` atomic selection (a collapsed caret on a
  ///   void never exists — D3).
  void setSelection(DocSelection selection) {
    _edit(() {
      final normalized = _normalizeSelection(selection, _document);
      if (normalized != null) _selection = normalized;
    });
  }

  DocSelection? _normalizeSelection(DocSelection selection, Document doc) {
    final base = _normalizePosition(selection.base, doc);
    final extent = _normalizePosition(selection.extent, doc);
    if (base == null || extent == null) return null;

    // Collapsed on a void → the atomic [0,1) selection.
    if (base.blockId == extent.blockId && base.offset == extent.offset) {
      final block = doc.blockById(base.blockId)!;
      if (schema.isVoid(block.blockType)) {
        return DocSelection(
          base: DocPosition(base.blockId, 0),
          extent: DocPosition(base.blockId, 1),
        );
      }
    }
    return DocSelection(base: base, extent: extent);
  }

  DocPosition? _normalizePosition(DocPosition position, Document doc) {
    final block = doc.blockById(position.blockId);
    if (block == null) return null;
    final maxOffset = schema.isVoid(block.blockType) ? 1 : block.length;
    final clamped = position.offset.clamp(0, maxOffset);
    return clamped == position.offset
        ? position
        : position.copyWith(offset: clamped);
  }

  /// Current selection revalidated against a new document: clamped, or
  /// dropped entirely if it names a gone id.
  DocSelection? _revalidatedSelection(Document doc) {
    final selection = _selection;
    if (selection == null) return null;
    return _normalizeSelection(selection, doc);
  }

  // --- The batch loop (public escape hatch + every convenience) ---

  /// Applies [ops] atomically through the batch loop: each op resolves its
  /// own ids against the document the previous op produced
  /// (resolve-at-apply); the first rejection (gone id, out-of-bounds offset,
  /// failed gate) aborts the whole batch pre-commit and the document is
  /// unchanged.
  ///
  /// [selectionAfter] is normalized against the new document; when omitted,
  /// the current selection is revalidated (clamped, or dropped if its block
  /// is gone).
  EditResult apply(List<EditOperation> ops, {DocSelection? selectionAfter}) {
    return _edit(
      () => _applyBatch(
        ops,
        selectionAfter: selectionAfter == null ? null : (_) => selectionAfter,
      ),
    );
  }

  /// The batch loop body. [selectionAfter] receives the post-batch document
  /// so callers can place the caret by ids that only exist after apply
  /// (split's new block, G9's surviving neighbor).
  EditResult _applyBatch(
    List<EditOperation> ops, {
    DocSelection? Function(Document newDoc)? selectionAfter,
  }) {
    assert(_inEdit, 'batches run only inside the choke point');
    final ctx = schema.editContext();
    var doc = _document;
    for (final op in ops) {
      final next = op.apply(doc, ctx);
      if (next == null) return EditRejected(op);
      doc = next;
    }
    if (identical(doc, _document)) {
      // Nothing to commit (empty batch, or every op no-oped — e.g. a
      // boundary MoveBlock): no undo entry, redo stack untouched.
      return const EditApplied();
    }
    // Composition-scoped undo (architecture §Undo): the first batch of an
    // IME group pushes the pre-state once; while a composing undo group is
    // open (its pre-composition snapshot already pushed), per-batch pushes
    // are suppressed so converting 日本語 is one undo entry, not one per
    // kana. Suppressed batches still invalidate redo — they are edits.
    final suppressPush =
        _currentEditIsIme &&
        (_imeGroupHadBatch || (_composingUndoGroup && _composingGroupPushed));
    if (suppressPush) {
      _undoManager.clearRedo();
    } else {
      _undoManager.push(_snapshotNow());
      if (_composingUndoGroup) _composingGroupPushed = true;
    }
    if (_currentEditIsIme) _imeGroupHadBatch = true;
    _document = doc;
    final desired = selectionAfter?.call(doc);
    _selection = desired == null
        ? _revalidatedSelection(doc)
        : (_normalizeSelection(desired, doc) ?? _revalidatedSelection(doc));
    return const EditApplied();
  }

  // --- Undo / redo ---

  UndoEntry _snapshotNow() => UndoEntry(
    document: _document,
    selection: _selection,
    timestamp: DateTime.now(),
  );

  void undo() {
    _edit(reason: 'undo', () {
      _clearComposingState();
      final entry = _undoManager.undo();
      if (entry == null) return;
      _undoManager.pushRedo(_snapshotNow());
      _restore(entry);
    });
  }

  void redo() {
    _edit(reason: 'undo', () {
      _clearComposingState();
      final entry = _undoManager.redo();
      if (entry == null) return;
      _undoManager.pushUndoRaw(_snapshotNow());
      _restore(entry);
    });
  }

  /// Undo/redo never restore composing state (G7): the engine's conversion
  /// state is gone, and a stale ComposingState would wedge every
  /// composing-gated mechanism. Unconditional — the IME push routes through
  /// `terminateComposition('undo')` via the external-change handler.
  void _clearComposingState() {
    _composing = null;
    _composingUndoGroup = false;
    _composingGroupPushed = false;
  }

  void _restore(UndoEntry entry) {
    _document = entry.document;
    final selection = entry.selection;
    _selection = selection == null
        ? null
        : _normalizeSelection(selection, entry.document);
  }

  // --- Editing conveniences (the hardware-key/IME-facing verbs) ---

  /// Inserts [text] at the caret. A non-collapsed selection is replaced
  /// (deletion + insertion, one atomic batch). A selected void block is
  /// replaced by a default-type block containing the text.
  void insertText(String text) {
    if (text.isEmpty) return;
    _edit(() => _insertTextAtSelection(text));
  }

  /// [insertText]'s body — also the IME verb shared by insertion and
  /// replacement deltas (which set the selection to the delta's mapped
  /// range first).
  void _insertTextAtSelection(String text) {
    assert(_inEdit);
    {
      final sel = _selection;
      if (sel == null) return;

      if (sel.isCollapsed) {
        final caret = sel.extent;
        _applyBatch(
          [InsertText(caret.blockId, caret.offset, text)],
          selectionAfter: (_) => DocSelection.collapsed(
            DocPosition(caret.blockId, caret.offset + text.length),
          ),
        );
        return;
      }

      final plan = _rangeDeletionPlan(sel);
      if (plan == null) return;

      switch (plan) {
        case _TextRangeDeletion(:final ops, :final anchor):
          _applyBatch(
            [...ops, InsertText(anchor.blockId, anchor.offset, text)],
            selectionAfter: (_) => DocSelection.collapsed(
              DocPosition(anchor.blockId, anchor.offset + text.length),
            ),
          );
        case _VoidDeletion(:final ops, :final voidId):
          // Type-over a selected void: a default-type block carrying the
          // text takes its place. The replacement chains after the void's
          // id, so it must insert BEFORE the removal runs.
          final replacement = TextBlock(
            id: generateBlockId(),
            blockType: schema.defaultBlockType,
            segments: [StyledSegment(text)],
          );
          _applyBatch(
            [
              InsertBlocks(voidId, [replacement]),
              ...ops,
            ],
            selectionAfter: (_) => DocSelection.collapsed(
              DocPosition(replacement.id, text.length),
            ),
          );
      }
    }
  }

  /// Enter at the caret, per the block type's [SplitPolicy]:
  /// - `onEnter: insertLineBreak` inserts `\n` (code blocks);
  /// - an empty block with `onSplitEmpty: convertToDefault` climbs the
  ///   outdent-or-convert ladder instead of splitting — outdent one level if
  ///   nested, convert to the default type at root (the empty list item
  ///   escapes the list one level per Enter);
  /// - otherwise splits; at offset 0 of a non-empty block an empty block is
  ///   inserted above and the caret stays.
  void insertNewline() {
    _edit(_insertNewlineAtSelection);
  }

  /// [insertNewline]'s body — also the IME verb for `\n` insertion deltas
  /// and `performAction(newline)` (G10).
  void _insertNewlineAtSelection() {
    assert(_inEdit);
    {
      var sel = _selection;
      if (sel == null) return;
      if (!sel.isCollapsed) {
        _deleteSelectionNow(sel);
        sel = _selection;
        if (sel == null || !sel.isCollapsed) return;
      }

      final caret = sel.extent;
      final block = _document.blockById(caret.blockId);
      if (block == null) return;
      final split = schema.splitPolicyOf(block.blockType);

      if (split.onEnter == OnEnter.insertLineBreak) {
        _applyBatch(
          [InsertText(caret.blockId, caret.offset, '\n')],
          selectionAfter: (_) => DocSelection.collapsed(
            DocPosition(caret.blockId, caret.offset + 1),
          ),
        );
        return;
      }

      if (block.plainText.isEmpty &&
          split.onSplitEmpty == OnSplitEmpty.convertToDefault) {
        // The standard outliner ladder (checkpoint-2/3 feedback): a nested
        // empty list-like block outdents one level per Enter — keeping its
        // type — and only converts to the default type at root. Converting
        // in place at depth 2+ stranded a paragraph mid-list.
        if (_outdentOrConvertBlock(block)) return;
        // Root and already the default type: fall through to split.
      }

      // Splitting at offset 0 of a non-empty block inserts an empty block
      // ABOVE and the caret stays in the original block; otherwise the caret
      // lands at the start of the split-off block, whose id the op carries.
      final splitAtStart = caret.offset == 0 && block.plainText.isNotEmpty;
      final splitOp = SplitBlock(caret.blockId, caret.offset);
      _applyBatch(
        [splitOp],
        selectionAfter: (_) => DocSelection.collapsed(
          DocPosition(splitAtStart ? caret.blockId : splitOp.newBlockId, 0),
        ),
      );
    }
  }

  /// Backspace at the caret. A non-collapsed selection deletes. At offset 0
  /// the block type's [BackspaceAtStartPolicy] decides: outdent-or-convert
  /// (lists), convert-to-default (headings), or merge into the previous
  /// block — where a previous *void* block consults its `voidBackspace`
  /// policy instead (select it, or delete it immediately).
  void backspace() {
    _edit(() {
      final sel = _selection;
      if (sel == null) return;
      if (!sel.isCollapsed) {
        _deleteSelectionNow(sel);
        return;
      }

      final caret = sel.extent;
      final block = _document.blockById(caret.blockId);
      if (block == null) return;

      if (caret.offset > 0) {
        // Delete one grapheme cluster, never half a surrogate pair.
        final length = _graphemeLengthBefore(block.plainText, caret.offset);
        _applyBatch(
          [DeleteText(caret.blockId, caret.offset - length, length)],
          selectionAfter: (_) => DocSelection.collapsed(
            DocPosition(caret.blockId, caret.offset - length),
          ),
        );
        return;
      }

      _structuralBackspace(block);
    });
  }

  /// Length in code units of the grapheme cluster ending at [offset].
  static int _graphemeLengthBefore(String text, int offset) =>
      text.substring(0, offset).characters.last.length;

  /// Length in code units of the grapheme cluster starting at [offset].
  static int _graphemeLengthAfter(String text, int offset) =>
      text.substring(offset).characters.first.length;

  /// The outdent-or-convert ladder shared by backspace-at-start
  /// (`BackspaceAtStartPolicy.outdentOrConvert`) and Enter on an empty
  /// list-like block (`OnSplitEmpty.convertToDefault`): nested → outdent one
  /// level via [OutdentBlock] (G13 semantics — children ride along and later
  /// siblings are adopted, exactly like [outdent]); at root → convert to the
  /// default type. The caret stays on the block at offset 0. Returns false
  /// when neither applies (root and already the default type) so each caller
  /// falls through to its own terminal behavior (merge / split).
  bool _outdentOrConvertBlock(TextBlock block) {
    final flatIndex = _document.idToFlatIndex[block.id]!;
    if (_document.depthOf(flatIndex) > 0) {
      _applyBatch(
        [OutdentBlock(block.id)],
        selectionAfter: (_) => DocSelection.collapsed(DocPosition(block.id, 0)),
      );
      return true;
    }
    if (block.blockType != schema.defaultBlockType) {
      _applyBatch(
        [ChangeBlockType(block.id, schema.defaultBlockType)],
        selectionAfter: (_) => DocSelection.collapsed(DocPosition(block.id, 0)),
      );
      return true;
    }
    return false;
  }

  void _structuralBackspace(TextBlock block) {
    final policy = schema.backspaceAtStartOf(block.blockType);
    final flatIndex = _document.idToFlatIndex[block.id]!;

    if (policy == BackspaceAtStartPolicy.outdentOrConvert) {
      if (_outdentOrConvertBlock(block)) return;
      // Root and already the default type: fall through to merge.
    } else if (policy == BackspaceAtStartPolicy.convertToDefault &&
        block.blockType != schema.defaultBlockType) {
      _applyBatch(
        [ChangeBlockType(block.id, schema.defaultBlockType)],
        selectionAfter: (_) => DocSelection.collapsed(DocPosition(block.id, 0)),
      );
      return;
    }

    // Merge into the previous flat block.
    if (flatIndex == 0) return;
    final prev = _document.allBlocks[flatIndex - 1];

    if (schema.isVoid(prev.blockType)) {
      // An EMPTY block collapses like any backspaced empty line — it is
      // removed and the void becomes selected, so the next backspace
      // deletes the void (checkpoint-2 finding: acting on the void while
      // the empty line survived felt backwards). The per-type voidBackspace
      // policies govern the non-empty case, where the line must survive.
      if (block.plainText.isEmpty) {
        _applyBatch(
          [RemoveBlock(block.id)],
          selectionAfter: (_) => DocSelection(
            base: DocPosition(prev.id, 0),
            extent: DocPosition(prev.id, 1),
          ),
        );
        return;
      }

      final voidPolicy = schema.blockDef(prev.blockType).voidBackspace;
      if (voidPolicy == VoidBackspacePolicy.immediateDelete) {
        _applyBatch(
          [RemoveBlock(prev.id)],
          selectionAfter: (_) =>
              DocSelection.collapsed(DocPosition(block.id, 0)),
        );
      } else {
        // selectFirst: atomic-select the void; the next backspace deletes.
        _selection = DocSelection(
          base: DocPosition(prev.id, 0),
          extent: DocPosition(prev.id, 1),
        );
      }
      return;
    }

    final prevLength = prev.length;
    _applyBatch(
      [MergeBlocks(block.id)],
      selectionAfter: (_) =>
          DocSelection.collapsed(DocPosition(prev.id, prevLength)),
    );
  }

  /// Moves the caret one grapheme cluster left ([direction] < 0) or right
  /// (> 0). Horizontal movement is pure selection-model logic: it steps
  /// within the block, hops to the adjacent flat block at the edges, and
  /// atomic-selects voids on entry (arrowing off a void hops past it). A
  /// non-collapsed text selection collapses to its directional edge.
  /// Vertical movement needs line geometry and lands with the day-10 key
  /// matrix.
  void moveCaret(int direction) {
    _edit(() {
      final sel = _selection;
      if (sel == null) return;
      final doc = _document;

      if (!sel.isCollapsed) {
        final block = doc.blockById(sel.extent.blockId);
        final sameBlock = sel.base.blockId == sel.extent.blockId;
        if (sameBlock && block != null && schema.isVoid(block.blockType)) {
          // Off a void's atomic selection: collapsing onto the void would
          // just re-normalize to the atomic selection.
          _hopToAdjacentBlock(doc.idToFlatIndex[block.id]!, direction);
          return;
        }
        final (start, end) = sel.normalized(doc);
        _selection = DocSelection.collapsed(direction < 0 ? start : end);
        return;
      }

      final caret = sel.extent;
      final block = doc.blockById(caret.blockId);
      final flatIndex = doc.idToFlatIndex[caret.blockId];
      if (block == null || flatIndex == null) return;

      final text = block.plainText;
      if (direction < 0 && caret.offset > 0) {
        final step = _graphemeLengthBefore(text, caret.offset);
        _selection = DocSelection.collapsed(
          DocPosition(caret.blockId, caret.offset - step),
        );
        return;
      }
      if (direction > 0 && caret.offset < block.length) {
        final step = _graphemeLengthAfter(text, caret.offset);
        _selection = DocSelection.collapsed(
          DocPosition(caret.blockId, caret.offset + step),
        );
        return;
      }

      _hopToAdjacentBlock(flatIndex, direction);
    });
  }

  void _hopToAdjacentBlock(int fromFlatIndex, int direction) {
    final doc = _document;
    final targetIndex = fromFlatIndex + (direction < 0 ? -1 : 1);
    if (targetIndex < 0 || targetIndex >= doc.allBlocks.length) return;
    final target = doc.allBlocks[targetIndex];
    final position = schema.isVoid(target.blockType)
        ? DocPosition(target.id, 0) // normalized to the atomic selection
        : DocPosition(target.id, direction < 0 ? target.length : 0);
    _selection = _normalizeSelection(DocSelection.collapsed(position), doc);
  }

  /// Deletes the current selection (no-op when collapsed or absent).
  void deleteSelection() {
    _edit(() {
      final sel = _selection;
      if (sel == null || sel.isCollapsed) return;
      _deleteSelectionNow(sel);
    });
  }

  void _deleteSelectionNow(DocSelection sel) {
    final plan = _rangeDeletionPlan(sel);
    if (plan == null) return;
    _applyBatch(plan.ops, selectionAfter: plan.caretAfter);
  }

  /// Builds the ops that delete [sel], plus where the caret lands.
  ///
  /// Day 3–4 handles the ranges tap-produced selections can reach: within
  /// one text block, the single-void atomic selection (caret lands per G9 —
  /// previous text block's end, else next text block's start, else the
  /// last-block empty-paragraph fallback), and cross-block ranges with text
  /// endpoints. Full void-endpoint range normalization is day-14 work.
  _DeletionPlan? _rangeDeletionPlan(DocSelection sel) {
    final (start, end) = sel.normalized(_document);
    final startBlock = _document.blockById(start.blockId);
    final endBlock = _document.blockById(end.blockId);
    if (startBlock == null || endBlock == null) return null;

    if (start.blockId == end.blockId) {
      if (schema.isVoid(startBlock.blockType)) {
        return _voidRemovalPlan(startBlock);
      }
      final length = end.offset - start.offset;
      if (length <= 0) return null;
      return _TextRangeDeletion(
        ops: [DeleteText(start.blockId, start.offset, length)],
        anchor: DocPosition(start.blockId, start.offset),
      );
    }

    assert(
      !schema.isVoid(startBlock.blockType) &&
          !schema.isVoid(endBlock.blockType),
      'Cross-block ranges with void endpoints need the day-14 range-op '
      'builder normalization; tap-produced selections cannot reach this.',
    );
    return _TextRangeDeletion(
      ops: [DeleteRange(start, end)],
      anchor: DocPosition(start.blockId, start.offset),
    );
  }

  /// Removes a selected void; caret per G9.
  _VoidDeletion _voidRemovalPlan(TextBlock voidBlock) {
    final flatIndex = _document.idToFlatIndex[voidBlock.id]!;
    final flat = _document.allBlocks;

    TextBlock? prevText;
    for (var i = flatIndex - 1; i >= 0; i--) {
      if (!schema.isVoid(flat[i].blockType)) {
        prevText = flat[i];
        break;
      }
    }
    TextBlock? nextText;
    if (prevText == null) {
      for (var i = flatIndex + 1; i < flat.length; i++) {
        if (!schema.isVoid(flat[i].blockType)) {
          nextText = flat[i];
          break;
        }
      }
    }

    return _VoidDeletion(
      voidId: voidBlock.id,
      ops: [RemoveBlock(voidBlock.id)],
      caretAfter: (newDoc) {
        if (prevText != null) {
          return DocSelection.collapsed(
            DocPosition(prevText.id, prevText.length),
          );
        }
        if (nextText != null) {
          return DocSelection.collapsed(DocPosition(nextText.id, 0));
        }
        // Last-block fallback: RemoveBlock swapped in the single empty
        // default-type paragraph.
        return DocSelection.collapsed(
          DocPosition(newDoc.allBlocks.first.id, 0),
        );
      },
    );
  }

  // --- G13 group indent/outdent (architecture §Selection) ---

  /// Indents the selected sibling group, all-or-nothing: each member's
  /// resolved target is its nearest preceding sibling NOT in the group, and
  /// the shared `canIndent` predicate must pass for every member against
  /// that target — otherwise the whole group no-ops (never a partial
  /// re-parent). Gate semantics are defined against the original document;
  /// the ops themselves re-resolve at apply.
  void indent() {
    _edit(() {
      final members = _topLevelSelectedIndices();
      if (members.isEmpty) return;
      final ctx = schema.editContext();
      final doc = _document;
      final groupIds = {for (final i in members) doc.allBlocks[i].id};

      for (final i in members) {
        final parent = doc.parentOf(i);
        final siblings = parent?.children ?? doc.blocks;
        var s = doc.siblingIndex(i) - 1;
        while (s >= 0 && groupIds.contains(siblings[s].id)) {
          s--;
        }
        if (s < 0) return; // No resolved target — whole group no-ops.
        final target = siblings[s];
        if (!ctx.canIndent(doc.allBlocks[i], target, doc.depthOf(i) + 1)) {
          return;
        }
      }

      _applyBatch([for (final i in members) IndentBlock(doc.allBlocks[i].id)]);
    });
  }

  /// Outdents the selected sibling group, all-or-nothing: every top-level
  /// member must be nested (depth > 0), else the whole group no-ops — an
  /// ungated mixed-depth selection would otherwise Shift-Tab partially.
  void outdent() {
    _edit(() {
      final members = _topLevelSelectedIndices();
      if (members.isEmpty) return;
      final doc = _document;

      for (final i in members) {
        if (doc.depthOf(i) == 0) return;
      }

      _applyBatch([for (final i in members) OutdentBlock(doc.allBlocks[i].id)]);
    });
  }

  /// Flat indices of the top-level-within-selection blocks: blocks in the
  /// selected flat range whose parent is outside the range (a selected
  /// ancestor carries its subtree).
  List<int> _topLevelSelectedIndices() {
    final sel = _selection;
    if (sel == null) return const [];
    final (start, end) = sel.normalized(_document);
    final si = _document.idToFlatIndex[start.blockId];
    final ei = _document.idToFlatIndex[end.blockId];
    if (si == null || ei == null) return const [];

    final result = <int>[];
    for (var i = si; i <= ei; i++) {
      final parent = _document.parentOf(i);
      // Ancestors precede their subtree in flat order, so "parent inside
      // the range" is one comparison.
      final covered =
          parent != null && _document.idToFlatIndex[parent.id]! >= si;
      if (!covered) result.add(i);
    }
    return result;
  }
}

/// Deletion ops for a range plus caret placement. The two cases differ in
/// where type-over text lands: a text-range deletion has a surviving
/// [_TextRangeDeletion.anchor]; a void deletion has none — type-over inserts
/// a replacement block at the void's position instead.
sealed class _DeletionPlan {
  _DeletionPlan({required this.ops, required this.caretAfter});

  final List<EditOperation> ops;
  final DocSelection? Function(Document newDoc) caretAfter;
}

class _TextRangeDeletion extends _DeletionPlan {
  _TextRangeDeletion({required super.ops, required this.anchor})
    : super(caretAfter: (_) => DocSelection.collapsed(anchor));

  /// The surviving position where the range began — caret and type-over
  /// text both land here.
  final DocPosition anchor;
}

class _VoidDeletion extends _DeletionPlan {
  _VoidDeletion({
    required super.ops,
    required super.caretAfter,
    required this.voidId,
  });

  /// The removed void's id — type-over chains its replacement block after
  /// this id (before the removal op runs).
  final String voidId;
}
