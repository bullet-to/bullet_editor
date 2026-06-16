import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ime_replay.dart';
import 'ime_service_test.dart' show FakeImeConnection;

/// Two REAL inspector captures (Chrome, the diff frontend) of the engine's
/// composition latch surviving blur: `composition_aware_mixin` holds
/// `composingText` + `composingBase ??=`, reset ONLY by compositionstart/
/// compositionend DOM events — so the dead range outlives
/// `connectionClosed`, re-attach, and even complete window replacement,
/// decorating later snapshots whose text never changed.
///
/// - **Capture 1** (the wedge): compose に → blur → return → snapshot
///   `{". に", sel:[3,3], composing:[2,3]}` with text UNCHANGED. Honored as
///   the NonTextUpdate analogue it re-armed shadow composing, the
///   hardware-key gate closed on a phantom composition, and Backspace was
///   deferred into the void.
/// - **Capture 2** (the cascade): the same re-arm at seq 26, then the dead
///   range carried onto a DIFFERENT block's freshly pushed window (seq 31),
///   a deferred Enter reaching the DOM textarea as `performAction(newline)`
///   (seq 35) whose model edit armed the passive window (seq 36), which
///   then absorbed the user's next REAL composition into the void
///   (seq 42–47: the d/だ keystrokes never reached the document).
///
/// The fix is the composing-birth invariant: composing state can only be
/// BORN from a text-CHANGING snapshot (every genuine compositionstart/
/// update inserts or replaces — even a dead key inserts its `´`), so the
/// dead decoration on a text-unchanged snapshot is filtered to empty
/// (`composingBirthSuppressed`) and the phantom never arms; plus the
/// passive window's exit-on-region-replacement (seq 42's [2,5] → [45,46]:
/// the absorbed composition objectively ended) and the `performAction`
/// guard (no model edit while the engine owns a composition).
///
/// Replay subtlety (the Safari capture replay test's doctrine): the
/// captured snapshot TEXTS embed the buggy session's DOM — its pipeline
/// stopped pushing once the cascade armed passive, so the engine textarea
/// accumulated state a fixed session would have been re-pushed out of. The
/// capture-2 tail (seq 37–47) is therefore unreachable mid-stream state
/// under the fix; the test asserts the strongest invariants that DO hold:
/// no phantom arm, no spurious terminate, the region replacement
/// reconciles, and the user's real input lands instead of vanishing.
void main() {
  TextBlock para(String id, String text) => TextBlock(
    id: id,
    blockType: ParagraphKeys.type,
    segments: [StyledSegment(text)],
  );

  DocSelection caret(String blockId, int offset) =>
      DocSelection.collapsed(DocPosition(blockId, offset));

  late EditorController controller;
  late ImeService service;
  late List<FakeImeConnection> connections;

  ImeService build(List<TextBlock> blocks, {DocSelection? selection}) {
    controller = EditorController(
      document: Document(blocks),
      schema: EditorSchema.standard(),
      undoGrouping: (previous, current) => false,
    );
    if (selection != null) controller.setSelection(selection);
    connections = [];
    service = ImeService(
      controller: controller,
      frontend: ImeFrontend.nonDeltaDiff,
      connectionFactory: (client, configuration) {
        final connection = FakeImeConnection();
        connections.add(connection);
        return connection;
      },
    );
    service.attach();
    return service;
  }

  FakeImeConnection connection() => connections.last;

  List<Object?> terminateReasons() => [
    for (final e in service.journal.events)
      if (e.kind == 'terminate') e.payload['reason'],
  ];

  List<Object?> birthSuppressions() => [
    for (final e in service.journal.events)
      if (e.kind == 'composingBirthSuppressed') e.payload['range'],
  ];

  void replay(String dump) =>
      replayImeJournal(service, parseImeJournalDump(dump));

  test('capture 1 (Chrome blur-return): the stale text-unchanged '
      'decoration is birth-suppressed — gate open, Backspace not '
      'deferred, deletes に', () {
    build([para('a', '')], selection: caret('a', 0));

    // The pre-blur composition (compositionstart/update — a text change,
    // as every genuine composition's first snapshot is).
    replay(r'''
{"seq":1,"kind":"snapshot","payload":{"text":". に","sel":[3,3],"composing":[2,3]}}
''');
    expect(controller.composing, isNotNull);

    // Browser-chrome blur: Chrome closes the connection (flutter#155265's
    // handleBlur → connectionClosed). Our state resets through the choke
    // point — but the ENGINE's composition latch survives in the page.
    service.connectionClosed();
    expect(terminateReasons(), ['connectionClosed']);

    // Return to the tab: the attachment re-syncs and pushes the window.
    service.attach();
    expect(connection().pushed.last.text, '. に');

    // The captured poison: the dead latch decorates the fresh window's
    // text-UNCHANGED echo. Honored, this re-armed shadow composing and
    // closed the gate on a phantom composition (the captured wedge).
    replay(r'''
{"seq":2,"kind":"snapshot","payload":{"text":". に","sel":[3,3],"composing":[2,3]}}
''');

    expect(birthSuppressions(), [
      [2, 3],
    ]);
    expect(controller.composing, isNull);
    expect(service.currentTextEditingValue!.composing, TextRange.empty);
    expect(
      service.engineComposing,
      isFalse,
      reason:
          'the gate inputs (controller.composing OR engineComposing) are '
          'open — the captured Backspace would be HANDLED, not deferred',
    );

    // What the widget's open gate dispatches for Backspace — in the
    // capture this keydown was deferred into the void.
    controller.backspace();
    expect(controller.document.blockById('a')!.plainText, '');
    expect(terminateReasons(), ['connectionClosed'], reason: 'no new ones');
  });

  test('capture 2 (the cascade): no phantom arm at seq 26/31, the click is '
      'a plain push (no externalEdit terminate), the deferred-Enter '
      'performAction lands as the user\'s Enter, the seq-42 region '
      'replacement reconciles, and the d/だ composition reaches the '
      'document instead of the void', () {
    build([
      para('a', ''),
      para('b', 'A paragraph directly above an image block.'),
    ], selection: caret('a', 0));

    // Pre-blur: the composition the seq-23 terminate reports as composed
    // "にほn", including WebKit's marked-text-selected echo (sel == the
    // composing range) — that adopted range selection is why the captured
    // seq-25 re-attach push carries sel [2,5].
    replay(r'''
{"seq":20,"kind":"snapshot","payload":{"text":". に","sel":[3,3],"composing":[2,3]}}
{"seq":21,"kind":"snapshot","payload":{"text":". にほ","sel":[4,4],"composing":[2,4]}}
{"seq":22,"kind":"snapshot","payload":{"text":". にほn","sel":[5,5],"composing":[2,5]}}
{"seq":23,"kind":"snapshot","payload":{"text":". にほn","sel":[2,5],"composing":[2,5]}}
''');
    expect(controller.composing, isNotNull);

    // seq 23–25: blur closes the connection; return re-attaches and
    // pushes the window — text unchanged from the engine's point of view.
    service.connectionClosed();
    service.attach();
    expect(connection().pushed.last.text, '. にほn');
    expect(
      connection().pushed.last.selection,
      const TextSelection(baseOffset: 2, extentOffset: 5),
    );

    // seq 26: the stale decoration on the text-unchanged echo. In the
    // capture this re-armed shadow composing; under the invariant it
    // cannot be a birth.
    replay(r'''
{"seq":26,"kind":"snapshot","payload":{"text":". にほn","sel":[2,5],"composing":[2,5]}}
''');
    expect(birthSuppressions(), [
      [2, 5],
    ]);
    expect(controller.composing, isNull);
    expect(service.engineComposing, isFalse);

    // seq 29–30's cause: the user clicks the other block. With no phantom
    // composition this is clause (b)'s PLAIN selection push — the capture
    // terminated 'externalEdit' here and pushed viaTerminate.
    controller.setSelection(caret('b', 42));
    expect(terminateReasons(), ['connectionClosed'], reason: 'no externalEdit');
    expect(
      connection().pushed.last.text,
      '. A paragraph directly above an image block.',
    );

    // seq 31: the SAME dead range decorating a DIFFERENT block's freshly
    // pushed window — text unchanged again, suppressed again.
    replay(r'''
{"seq":31,"kind":"snapshot","payload":{"text":". A paragraph directly above an image block.","sel":[44,44],"composing":[2,5]}}
''');
    expect(birthSuppressions(), [
      [2, 5],
      [2, 5],
    ]);
    expect(controller.composing, isNull);

    // seq 34: in the capture the Enter was deferred on the phantom
    // composition ("deferred":true,"handler":"ignored" — a no-op in
    // replay). The fixed gate inputs are OPEN: the keydown would be
    // handled by the widget and never reach the DOM textarea.
    expect(controller.composing, isNull);
    expect(service.engineComposing, isFalse, reason: 'seq-34 gate verdict');

    // seq 35: the captured deferred Enter that DID reach the DOM comes
    // back as performAction(newline). No engine-owned composition exists
    // under the fix, so the guard stands down and the action applies as
    // the user's Enter — a clean split, not the captured mid-"composition"
    // edit that armed the passive absorption (seq 36).
    replay(r'''
{"seq":35,"kind":"performAction","payload":{"action":"newline"}}
''');
    service.flushPendingNewline();
    expect(
      service.journal.events.any((e) => e.kind == 'performActionSuppressed'),
      isFalse,
      reason: 'the guard is scoped to engine-owned compositions',
    );
    expect(controller.document.allBlocks, hasLength(3));
    expect(controller.document.allBlocks[2].plainText, '');

    // seq 37: the captured DOM state — the buggy session's textarea still
    // held the full block text plus the deferred Enter's literal \n,
    // decorated with the dead [2,5]. Against the fixed pipeline's
    // post-split shadow this is a TEXT-CHANGING snapshot, deliberately
    // outside the birth invariant (the latch's territory — and the latch
    // died with the connection), so it arms and its structural shape
    // defers: the passive window arms. Unreachable mid-stream state in a
    // real fixed session (see the replay subtlety above); the pipeline
    // must stay safe under it regardless.
    replay(r'''
{"seq":37,"kind":"snapshot","payload":{"text":". A paragraph directly above an image block.\n","sel":[45,45],"composing":[2,5]}}
''');
    expect(
      service.journal.events.any((e) => e.kind == 'passiveDivergence'),
      isTrue,
    );
    expect(service.engineComposing, isTrue);

    // seq 42: THE region replacement — the absorbed [2,5] replaced by
    // [45,46] (a new compositionstart re-latched the engine base; within
    // one composition the start is fixed). The absorbed composition
    // objectively ended: reconcile, exactly like live→empty. The captured
    // session stayed passive here and absorbed the user's typing into the
    // void.
    replay(r'''
{"seq":42,"kind":"snapshot","payload":{"text":". A paragraph directly above an image block.\nd","sel":[46,46],"composing":[45,46]}}
''');
    final reconcile = service.journal.events.lastWhere(
      (e) => e.kind == 'passiveReconcile',
    );
    expect(reconcile.payload['trigger'], 'regionReplaced');
    expect(reconcile.payload['discardedComposing'], [2, 5]);
    expect(service.engineComposing, isFalse, reason: 'passive resolved');

    // seq 47: the user's REAL composition re-arrives (text-changing, live
    // region — a genuine birth) and APPLIES: the だ reaches the document.
    // In the captured session these keystrokes were absorbed one-way and
    // lost.
    replay(r'''
{"seq":47,"kind":"snapshot","payload":{"text":". A paragraph directly above an image block.\nだ","sel":[46,46],"composing":[45,46]}}
''');
    expect(
      controller.document.allBlocks.last.plainText,
      'だ',
      reason: "the user's d/だ composition lands instead of vanishing",
    );
    expect(
      service.engineComposing,
      isTrue,
      reason:
          'the gate is closed for the RIGHT reason now — a genuine '
          'composition is live',
    );

    // The whole cascade produced exactly one terminate: the blur's own.
    expect(terminateReasons(), ['connectionClosed']);
  });
}
