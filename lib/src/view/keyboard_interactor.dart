import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../editor/edit_operation.dart' show MoveDirection;
import '../editor/editor_controller.dart';
import '../input/ime_service.dart';
import '../model/doc_selection.dart';
import 'block_layout_registry.dart';
import 'caret_movement.dart';

/// The outcome of classifying one key event: the framework [result], the IME
/// journal [handler] label, whether the composing gate [deferred] the key to
/// the IME, and the [action] (the controller verb / side effect) to run.
typedef KeyOutcome = ({
  KeyEventResult result,
  String handler,
  bool deferred,
  VoidCallback? action,
});

/// A handled key: stops propagation, runs [action] (the controller verb), and
/// is recorded in the IME journal under [handler].
KeyOutcome _handled(String handler, [VoidCallback? action]) => (
  result: KeyEventResult.handled,
  handler: handler,
  deferred: false,
  action: action,
);

/// A key the composing gate defers to the platform IME: skipRemainingHandlers
/// (NOT ignored — see the gate comment) so it reaches the IME without
/// preventDefault, journaled as deferred. [action] is an optional note hook.
KeyOutcome _deferred([VoidCallback? action]) => (
  result: KeyEventResult.skipRemainingHandlers,
  handler: 'ignored',
  deferred: true,
  action: action,
);

/// An unhandled key. [action] runs a side effect (e.g. spending a one-shot)
/// while leaving the event unhandled.
KeyOutcome _ignored([VoidCallback? action]) => (
  result: KeyEventResult.ignored,
  handler: 'ignored',
  deferred: false,
  action: action,
);

/// The hardware-key matrix the IME doesn't own, behind the full composing gate
/// (architecture §hardware keyboard) — symmetric with [MouseInteractor] for the
/// keyboard: Enter/Backspace/Tab, undo/redo, ←/→ grapheme movement, ↑/↓
/// vertical movement (geometry-x affinity, goal-column), Cmd/Ctrl line (←/→)
/// and document (↑/↓) boundaries, Shift extension, and Alt+↑/↓ `MoveBlock`,
/// plus the post-movement ensure-caret-visible scroll (B4).
///
/// Character input is NEVER here — it arrives through the IME delta path, so a
/// hardware character-insert would double-type against the engine connection.
/// The composing gate covers EVERY handler: while a composition is live every
/// editing/navigation key belongs to the IME (the whitelist is Cmd/Ctrl+Z).
///
/// The interactor owns no widgets — `BulletEditorState` feeds it key events and
/// supplies the controller/IME/scroll/viewport surfaces as callbacks (read
/// through getters so a controller swap is transparent), keeping it
/// render-agnostic and unit-reachable. It carries the goal-column state
/// ([_verticalGoalX]/[_verticalAnchorExtent]) because that is a
/// keyboard-movement concern, not a widget one.
class KeyboardInteractor {
  KeyboardInteractor({
    required this.controllerOf,
    required this.imeServiceOf,
    required this.registry,
    required this.scrollPositionOf,
    required this.editorRectOf,
    required this.isReadOnly,
    required this.isMounted,
  });

  /// The live controller (re-read each call — it can be swapped via
  /// `didUpdateWidget`, and the IME service is rebuilt with it).
  final EditorController Function() controllerOf;

  /// The live IME service (rebuilt on a controller swap).
  final ImeService Function() imeServiceOf;

  final BlockLayoutRegistry registry;

  /// The editor's scroll position, or null before the viewport is laid out.
  final ScrollPosition? Function() scrollPositionOf;

  /// The editor viewport's global rect, for the ensure-caret-visible margin.
  final Rect? Function() editorRectOf;

  /// Whether the editor is read-only (editing/movement keys go inert).
  final bool Function() isReadOnly;

  /// Whether the host widget is still mounted (guards post-frame work).
  final bool Function() isMounted;

  EditorController get _controller => controllerOf();
  ImeService get _ime => imeServiceOf();

  /// Goal-column state for ↑/↓ (architecture §hardware keyboard: geometry-x
  /// affinity). [_verticalGoalX] is the global x a consecutive vertical run
  /// holds; [_verticalAnchorExtent] is where the last vertical move left the
  /// extent. A run continues only while the live extent still equals it —
  /// any click, edit, horizontal move, or boundary jump changes the extent
  /// and so recomputes the column from the caret afresh (no per-path reset
  /// plumbing needed).
  double? _verticalGoalX;
  DocPosition? _verticalAnchorExtent;

  KeyEventResult handleKeyEvent(KeyEvent event) {
    final (:result, :handler, :deferred, :action) = _classify(event);
    // Every key event lands in the IME journal so hardware keys interleave
    // with the engine traffic in one capturable stream — `handler` names
    // the controller verb that consumed it (or `ignored`), `deferred`
    // whether the composing gate left it to the IME. Recorded BEFORE the
    // verb runs so the key precedes the pushes it causes.
    _ime.journal.record(
      'key',
      () => {
        'kind': switch (event) {
          KeyDownEvent() => 'down',
          KeyRepeatEvent() => 'repeat',
          KeyUpEvent() => 'up',
          _ => event.runtimeType.toString(),
        },
        'key': event.logicalKey.keyLabel,
        'character': event.character,
        'deferred': deferred,
        'handler': handler,
      },
    );
    action?.call();
    // Keep the caret on-screen after any handled key (B4): movement past the
    // viewport edge, a Cmd-boundary jump, or an edit that pushed the caret out.
    // Post-frame, so it measures the geometry this key's edit/move produced.
    if (result == KeyEventResult.handled) _scheduleEnsureCaretVisible();
    return result;
  }

  /// The key dispatch decision, split from [handleKeyEvent] so the journal can
  /// record the outcome alongside the event before the verb runs.
  KeyOutcome _classify(KeyEvent event) {
    if (isReadOnly()) return _ignored();
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return _ignored();

    final controller = _controller;
    final pressed = HardwareKeyboard.instance;
    final isShortcut = pressed.isMetaPressed || pressed.isControlPressed;

    if (isShortcut) {
      // The composing gate's explicit whitelist (architecture §hardware
      // keyboard: "a whitelist over an ignore-all default, not a per-key
      // blacklist"): Cmd/Ctrl+Z and Shift+Cmd/Ctrl+Z stay handled even while
      // a composition is live — undo is a first-class composition terminator
      // (G7): the controller restores the pre-composition snapshot and the
      // IME push routes through terminateComposition('undo'), quarantine
      // armed.
      if (event.logicalKey == LogicalKeyboardKey.keyZ) {
        return pressed.isShiftPressed
            ? _handled('redo', controller.redo)
            : _handled('undo', controller.undo);
      }
      // Every OTHER shortcut is gated too — a Cmd+arrow during Japanese
      // hardware-keyboard conversion must reach the IME (it navigates clause
      // segments / candidates), not fire a movement that external-edit
      // terminates the composition. The whitelist above is the only exception.
      if (controller.composing != null || _ime.engineComposing) {
        return _deferred();
      }
      // Cmd/Ctrl + arrows: line-boundary (←/→) and document-boundary (↑/↓)
      // movement, Shift-extendable. Part of the day-10 key MATRIX.
      final extend = pressed.isShiftPressed;
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowLeft:
          return _handled('moveLineStart', () {
            final sel = controller.selection;
            if (sel != null) {
              _moveTo(
                lineBoundaryTarget(registry, sel, false),
                extend: extend,
              );
            }
          });
        case LogicalKeyboardKey.arrowRight:
          return _handled('moveLineEnd', () {
            final sel = controller.selection;
            if (sel != null) {
              _moveTo(
                lineBoundaryTarget(registry, sel, true),
                extend: extend,
              );
            }
          });
        case LogicalKeyboardKey.arrowUp:
          return _handled(
            'moveDocStart',
            () => _moveTo(
              documentBoundaryTarget(controller.document, false),
              extend: extend,
            ),
          );
        case LogicalKeyboardKey.arrowDown:
          return _handled(
            'moveDocEnd',
            () => _moveTo(
              documentBoundaryTarget(controller.document, true),
              extend: extend,
            ),
          );
      }
      return _ignored();
    }

    // The full composing gate (architecture §hardware keyboard: "the
    // composing gate covers ALL of keyboard_service, not just Enter/Backspace
    // — ignore-everything-while-composing with an explicit whitelist"; the
    // whitelist is the shortcut block above). The day-10 movement matrix (↑/↓
    // vertical, Cmd+arrows, Alt+↑/↓ MoveBlock) lands under this same gate.
    // While a composition is live EVERY editing/navigation key belongs to
    // the IME: on macOS the text input plugin is a SECONDARY key responder,
    // so a key event the framework marks handled never reaches
    // NSTextInputContext — handling backspace here while marked text exists
    // both starves the IME of the keystroke it must consume (a dead key's
    // marked-text removal) and edits the document out from under the live
    // composition (terminateComposition → quarantine armed → the re-typed
    // accent's signature). Arrows are NOT exempt: Japanese conversion uses
    // ←/→ for clause segments and ↑/↓ for candidates — an ungated arrow
    // fires setSelection → terminateComposition('externalEdit'), committing
    // the marked text on the first navigation keystroke (the live
    // Safari/Chrome symptoms: → mid-composition walks the caret through the
    // text and copies it to the start of the next line; ↑/↓ while cycling
    // the candidate menu push the cursor through the document).
    //
    // Every key uses skipRemainingHandlers — NOT ignored. On web, ignored
    // lets Flutter's focus tree consume the key before the browser IME
    // sees it: FocusTraversalGroup intercepts Tab (and Shift+Tab),
    // DirectionalFocusTraversalPolicyMixin intercepts arrows, ModalRoute
    // intercepts Escape. Each calls preventDefault() on the native
    // keydown, killing the IME's use of that key. skipRemainingHandlers
    // stops focus-tree propagation WITHOUT preventDefault(), so every key
    // reaches the platform IME. On desktop this is harmless: the platform
    // result is "not handled" — same as ignored — and the key continues
    // up the macOS responder chain to NSTextInputContext.
    //
    // The gate keys on the MODEL's composing state OR the service's
    // engine-side condition ([ImeService.engineComposing]): on the diff
    // frontend a composition whose FIRST snapshot is unmappable arms the
    // passive-divergence window without ever installing a ComposingState
    // — the browser genuinely still composes, and an editing key reaching
    // the model there would external-edit terminate → mid-composition
    // push, the corruption class this gate exists to prevent.
    if (controller.composing != null || _ime.engineComposing) {
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter ||
          key == LogicalKeyboardKey.backspace ||
          key == LogicalKeyboardKey.tab) {
        // A gate-deferred commit-capable key — Enter, Backspace, Tab: the
        // editing keys an IME consumes to end a composition AND our
        // handlers act on destructively — is noted with the service: it
        // proves the keydown-first ordering (Chrome/Firefox — keyCode 229
        // while the composition is live), so the composing-clear this key
        // produces must not arm the commit-key suppression below.
        return _deferred(_ime.noteCommitKeyDeferred);
      }
      return _deferred();
    }

    // Safari fires compositionend BEFORE the keydown of the key that ended the
    // composition, so the commit/cancel key (Enter/Backspace/Tab) arrives past
    // the gate above with composing already null. The service's one-shot
    // identifies it: swallow it once, handled, with no effect; the next press is
    // genuine. (Escape spends the same one-shot in its own case below; arrows
    // deliberately never consult it.)
    final committedKey = event.logicalKey;
    if ((committedKey == LogicalKeyboardKey.enter ||
            committedKey == LogicalKeyboardKey.numpadEnter ||
            committedKey == LogicalKeyboardKey.backspace ||
            committedKey == LogicalKeyboardKey.tab) &&
        _ime.consumeCommitKeySuppression()) {
      return _handled('commitKeySuppressed');
    }

    switch (event.logicalKey) {
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter:
        return _handled('insertNewline', controller.insertNewline);
      case LogicalKeyboardKey.escape:
        // ProseMirror's other suppressed key: an Escape arriving inside
        // the window is the keydown of the CANCEL that ended the
        // composition (WebKit's compositionend-before-keydown ordering),
        // and it must spend the one-shot so the user's next Enter splits.
        // Nothing here handles Escape, so it stays ignored either way —
        // only the arm is consumed (the consult journals the decision).
        return _ignored(_ime.consumeCommitKeySuppression);
      case LogicalKeyboardKey.backspace:
        return _handled('backspace', controller.backspace);
      case LogicalKeyboardKey.tab:
        return pressed.isShiftPressed
            ? _handled('outdent', controller.outdent)
            : _handled('indent', controller.indent);
      // Arrows (and the unhandled Home/End) deliberately do NOT consult
      // the one-shot: a trailing post-compositionend arrow only moves the
      // caret — nothing destructive happens — and the selection change it
      // causes disarms a pending arm through the external-change path
      // anyway. Only keys our handlers act on destructively consult
      // (Enter/Backspace/Tab above; Escape spends the arm without
      // handling).
      case LogicalKeyboardKey.arrowLeft:
        return _handled(
          'moveCaretBack',
          () => controller.moveCaret(-1, extend: pressed.isShiftPressed),
        );
      case LogicalKeyboardKey.arrowRight:
        return _handled(
          'moveCaretForward',
          () => controller.moveCaret(1, extend: pressed.isShiftPressed),
        );
      case LogicalKeyboardKey.arrowUp:
        // Alt+↑ moves the block (MoveBlock); a plain ↑ moves the caret up a
        // line (geometry-x affinity), Shift-extendable.
        if (pressed.isAltPressed) {
          return _handled(
            'moveBlockUp',
            () => controller.moveBlock(MoveDirection.up),
          );
        }
        return _handled(
          'moveCaretUp',
          () => _moveVertically(-1, extend: pressed.isShiftPressed),
        );
      case LogicalKeyboardKey.arrowDown:
        if (pressed.isAltPressed) {
          return _handled(
            'moveBlockDown',
            () => controller.moveBlock(MoveDirection.down),
          );
        }
        return _handled(
          'moveCaretDown',
          () => _moveVertically(1, extend: pressed.isShiftPressed),
        );
    }

    return _ignored();
  }

  /// Applies a computed movement [target] (caret_movement.dart) as a collapsed
  /// caret, or — under Shift ([extend]) — as a base-anchored extension. Null
  /// targets (no geometry yet, empty doc) no-op. setSelection clamps offsets
  /// and atomic-normalizes a void target.
  void _moveTo(DocPosition? target, {required bool extend}) {
    if (target == null) return;
    final controller = _controller;
    final sel = controller.selection;
    controller.setSelection(
      extend && sel != null
          ? DocSelection(base: sel.base, extent: target)
          : DocSelection.collapsed(target),
    );
  }

  /// ↑/↓ caret movement with goal-column affinity (B2/B3). Reuses the carried
  /// [_verticalGoalX] only while this is a consecutive vertical run (the live
  /// extent still where the last vertical move left it); otherwise it starts a
  /// fresh column from the current caret. The remembered extent is read back
  /// AFTER `setSelection` so it matches the void `[0,1)` atomic normalization.
  void _moveVertically(int direction, {required bool extend}) {
    final controller = _controller;
    final sel = controller.selection;
    if (sel == null) return;
    final goalX = sel.extent == _verticalAnchorExtent ? _verticalGoalX : null;
    final move = verticalCaretTarget(
      registry,
      controller.schema,
      controller.document,
      sel,
      direction,
      goalX: goalX,
    );
    if (move == null) return;
    _verticalGoalX = move.goalX;
    _moveTo(move.target, extend: extend);
    _verticalAnchorExtent = controller.selection?.extent;
  }

  /// Brings the caret/extent into view after a keyboard movement (B4). Driven
  /// post-frame from [handleKeyEvent] for every handled key so a move past the
  /// viewport edge (↑/↓), or a line/document boundary jump (Cmd+arrows),
  /// scrolls the caret back on-screen. Geometry-based and lazy-viewport safe:
  /// when the extent block isn't laid out (a document-boundary jump landing
  /// far off-screen) it scrolls to the matching scroll extreme so the next
  /// frame lays the block out, then the following pass fine-tunes the margin.
  void _scheduleEnsureCaretVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (isMounted()) _ensureCaretVisible();
    });
  }

  void _ensureCaretVisible() {
    final position = scrollPositionOf();
    if (position == null) return;
    final sel = _controller.selection;
    if (sel == null) return;
    final editorRect = editorRectOf();
    if (editorRect == null) return;

    final geometry = registry.geometryOf(sel.extent.blockId);
    final caret = geometry?.rectForOffset(sel.extent.offset);
    if (geometry == null || caret == null) {
      // The extent landed on a block the lazy viewport hasn't built (a
      // document-boundary jump). Scroll toward the block: ahead of the
      // current band scrolls down, behind it scrolls up. The post-frame
      // re-schedule below lays it out and re-runs to settle the margin.
      final index = _controller.document.indexOfBlock(sel.extent.blockId);
      if (index < 0) return;
      final laidOut = registry.laidOutBlockIds
          .map(_controller.document.indexOfBlock)
          .where((i) => i >= 0);
      if (laidOut.isEmpty) return;
      final ahead = index > laidOut.reduce((a, b) => a > b ? a : b);
      final target = ahead ? position.maxScrollExtent : position.minScrollExtent;
      if (target != position.pixels) {
        position.jumpTo(target);
        _scheduleEnsureCaretVisible();
      }
      return;
    }

    const margin = 12.0;
    final box = geometry.renderBox;
    final caretTop = box.localToGlobal(caret.topLeft).dy;
    final caretBottom = box.localToGlobal(caret.bottomLeft).dy;
    double delta = 0;
    if (caretTop < editorRect.top + margin) {
      delta = caretTop - (editorRect.top + margin);
    } else if (caretBottom > editorRect.bottom - margin) {
      delta = caretBottom - (editorRect.bottom - margin);
    }
    if (delta == 0) return;
    final target = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target != position.pixels) position.jumpTo(target);
  }
}
