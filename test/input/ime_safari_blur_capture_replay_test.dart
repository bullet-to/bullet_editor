import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ime_replay.dart';
import 'ime_service_test.dart' show FakeImeConnection;

/// A REAL inspector capture (Safari, the diff frontend): compose に, blur
/// to the URL bar, return. Safari's blur fires compositionend AND resets
/// the DOM selection to zero — the captured seq-27 snapshot
/// `{". に", sel:[0,0], composing:null}` over unchanged text. The
/// composing-clear half is correct (it is the compositionend that disarms
/// everything); the selection half is browser bookkeeping: every window we
/// push starts with the 2-char `". "` sentinel and carries a selection
/// ≥ 2, and the hidden editable is a 1px sliver nothing can click, so a
/// selection STARTING inside `[0, 2)` cannot be a user action.
///
/// The captured failure: honored as the NonTextUpdate analogue, the [0,0]
/// selection was sentinel-clamped to the block start (seq 29's model jump
/// — visible caret flicker at blur), and the follow-up push (seq 31)
/// carried the clamped `[2,2]` — so the re-attach push on return (seq 34)
/// re-taught Safari the wrong caret and the user came back stuck at the
/// block start.
///
/// The fix is the sub-sentinel selection invariant
/// (`sentinelSelectionSuppressed`): the selection component is ignored —
/// the model caret stays at the に end — while the composing live→empty
/// clear, the commit-key arm, and the follow-up push all proceed; the push
/// now carries the PRESERVED caret, and the return re-attach pushes it
/// again.
void main() {
  test('Safari blur capture replay: the seq-27 selection reset is '
      'suppressed — model caret preserved at the に end, composing '
      'cleared, commit-suppression armed, and the follow-up + re-attach '
      'pushes carry the preserved caret', () {
    final controller = EditorController(
      document: Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('')],
        ),
      ]),
      schema: EditorSchema.standard(),
      undoGrouping: (previous, current) => false,
    );
    controller.setSelection(DocSelection.collapsed(const DocPosition('a', 0)));
    final connections = <FakeImeConnection>[];
    final service = ImeService(
      controller: controller,
      frontend: ImeFrontend.nonDeltaDiff,
      connectionFactory: (client, configuration) {
        final connection = FakeImeConnection();
        connections.add(connection);
        return connection;
      },
    );
    service.attach();

    DocSelection caret(int offset) =>
        DocSelection.collapsed(DocPosition('a', offset));

    // The pre-blur composition (compositionstart/update — text-changing,
    // so composing is legitimately born), then the capture's seq-24 echo.
    replayImeJournal(
      service,
      parseImeJournalDump(r'''
{"seq":20,"ms":5600,"kind":"snapshot","payload":{"text":". に","sel":[3,3],"composing":[2,3]}}
{"seq":24,"ms":5676,"kind":"snapshot","payload":{"text":". に","sel":[3,3],"composing":[2,3]}}
'''),
    );
    expect(controller.composing, isNotNull);
    expect(controller.selection, caret(1));
    final pushesBeforeBlur = connections.last.pushed.length;

    // seq 27: Safari blur — compositionend reflected (composing null,
    // CORRECT and load-bearing) plus the DOM selection reset to zero (the
    // artifact).
    replayImeJournal(
      service,
      parseImeJournalDump(r'''
{"seq":27,"ms":5677,"kind":"snapshot","payload":{"text":". に","sel":[0,0],"composing":null}}
'''),
    );

    // The selection component was suppressed and journaled; the model
    // caret REMAINS at the に end (the capture's seq-29 nonText delta
    // walked it to the block start).
    final suppressed = service.journal.events
        .where((e) => e.kind == 'sentinelSelectionSuppressed')
        .toList();
    expect(suppressed, hasLength(1));
    expect(suppressed.single.payload['sel'], [0, 0]);
    expect(controller.selection, caret(1));

    // The composing-clear half still processed (the compositionend that
    // disarms everything)...
    expect(controller.composing, isNull);
    expect(service.currentTextEditingValue!.composing, TextRange.empty);
    expect(service.engineComposing, isFalse);
    // ...including the commit-key one-shot (the capture's seq 30 —
    // live→empty, correct and harmless).
    expect(service.debugCommitKeySuppressionArmed, isTrue);

    // The follow-up push (the capture's seq 31) carries the PRESERVED
    // caret — the buggy session pushed the sentinel-clamped [2,2] because
    // the model had already moved.
    expect(connections.last.pushed.length, pushesBeforeBlur + 1);
    expect(connections.last.pushed.last.text, '. に');
    expect(
      connections.last.pushed.last.selection,
      const TextSelection.collapsed(offset: 3),
    );

    // The user returns (the capture's seq 33/34): the lifecycle recovery
    // re-attaches and pushes the window — still the preserved caret.
    service.detach();
    service.attach();
    expect(connections.last.pushed.last.text, '. に');
    expect(
      connections.last.pushed.last.selection,
      const TextSelection.collapsed(offset: 3),
    );
    expect(controller.selection, caret(1));
  });
}
