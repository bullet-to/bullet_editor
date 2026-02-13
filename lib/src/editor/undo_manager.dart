import 'package:flutter/widgets.dart';

import '../model/document.dart';

/// A snapshot of the editor state at a point in time.
class UndoEntry {
  const UndoEntry({
    required this.document,
    required this.selection,
    required this.timestamp,
  });

  final Document document;
  final TextSelection selection;
  final DateTime timestamp;
}

/// Decides whether a new edit should merge with the previous undo entry
/// (i.e. consecutive fast typing becomes one undo step).
///
/// Return true to merge, false to push a new entry.
typedef ShouldGroupUndo = bool Function(UndoEntry previous, UndoEntry current);

/// Default grouping: merge if the new edit is within 300ms of the previous.
bool defaultUndoGrouping(UndoEntry previous, UndoEntry current) =>
    current.timestamp.difference(previous.timestamp).inMilliseconds < 300;

/// Manages undo/redo stacks using document snapshots.
///
/// The grouping strategy is swappable via [ShouldGroupUndo].
/// Stack size is bounded by [maxStackSize] — oldest entries are dropped.
class UndoManager {
  UndoManager({
    ShouldGroupUndo? grouping,
    this.maxStackSize = 100,
  }) : _grouping = grouping ?? defaultUndoGrouping;

  final ShouldGroupUndo _grouping;
  final int maxStackSize;

  final List<UndoEntry> _undoStack = [];
  final List<UndoEntry> _redoStack = [];

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  /// Push a snapshot of the state *before* an edit.
  ///
  /// If the new entry groups with the previous one, the previous entry is
  /// kept (it already holds the pre-group state). Otherwise a new entry is
  /// pushed. Redo stack is always cleared on new edits.
  void push(UndoEntry entry) {
    _redoStack.clear();

    if (_undoStack.isNotEmpty && _grouping(_undoStack.last, entry)) {
      // Group with previous — don't push. The existing top entry already
      // holds the document state from before this group of edits started.
      return;
    }

    _undoStack.add(entry);

    // Enforce max stack size.
    if (_undoStack.length > maxStackSize) {
      _undoStack.removeAt(0);
    }
  }

  /// Pop the most recent undo entry. Returns null if nothing to undo.
  ///
  /// The caller is responsible for pushing the *current* state to redo
  /// before restoring this snapshot.
  UndoEntry? undo() {
    if (_undoStack.isEmpty) return null;
    return _undoStack.removeLast();
  }

  /// Pop the most recent redo entry. Returns null if nothing to redo.
  ///
  /// The caller is responsible for pushing the *current* state to undo
  /// before restoring this snapshot.
  UndoEntry? redo() {
    if (_redoStack.isEmpty) return null;
    return _redoStack.removeLast();
  }

  /// Push an entry directly onto the redo stack. Used by the controller
  /// when performing an undo (the current state goes to redo).
  void pushRedo(UndoEntry entry) {
    _redoStack.add(entry);
  }

  /// Push an entry directly onto the undo stack without clearing redo.
  /// Used by the controller when performing a redo (the current state goes
  /// back to undo).
  void pushUndoRaw(UndoEntry entry) {
    _undoStack.add(entry);
    if (_undoStack.length > maxStackSize) {
      _undoStack.removeAt(0);
    }
  }

  /// Clear both stacks.
  void clear() {
    _undoStack.clear();
    _redoStack.clear();
  }
}
