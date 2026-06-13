import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ime_replay.dart';
import 'ime_service_test.dart' show FakeImeConnection;

/// A REAL inspector capture (Safari, Japanese romaji input): the user types
/// `n i h o n g o`, the IME composes にほんご, converts to 日本語, commits.
/// Expected block text: `日本語`. The captured session instead accumulated
/// every intermediate composition state — `nににhにほにほnにほんg日本語`.
///
/// The poison is the capture's seq-6 snapshot: Safari's FIRST composing
/// snapshot reports the marked text as SELECTED — `sel == composing`, a
/// non-collapsed range. The applied insertion leaves a collapsed model
/// caret, so `_finishBatch`'s selection comparison diverged and fired
/// `terminateComposition('structuralDelta')`; the viaTerminate push
/// de-marked Safari's live composition while the IME kept its internal
/// buffer, so every subsequent compositionupdate INSERTED its full text at
/// the caret instead of replacing the no-longer-marked range (seq 16's
/// `". nに"`: the `n` survives and に appends; seq 26: `". nににh"`; …).
/// The fix (`_finishBatch`'s within-composing selection adoption) keeps the
/// composition alive through that shape.
///
/// IMPORTANT replay subtlety, and what this test can therefore assert: the
/// captured snapshot TEXTS embed the buggy accumulation — Safari's DOM
/// contained the garbage because the bug was live DURING capture. Under the
/// fixed pipeline the early snapshots are unreachable mid-stream states (a
/// never-de-marked Safari would have sent `". に"` replacing the marked
/// `n`, not `". nに"` appending), so the replay cannot end at `日本語`
/// verbatim — the pipeline's job is to mirror the engine, and the engine's
/// captured stream carries the garbage. The test asserts the strongest
/// invariants that DO hold under the fix, each red against the buggy code:
///
/// - no terminate ever fires — the composition survives every snapshot
///   (buggy: 'structuralDelta' on every composing text snapshot);
/// - the composition is LIVE in the model after every composing snapshot up
///   to the conversion commit (buggy: de-marked after each one);
/// - the pipeline adds no accumulation of its own: after every snapshot the
///   model mirrors the engine text minus the sentinel, verbatim — except
///   seq 76, where the dead-key rewrite deliberately collapses the
///   append-shaped double-commit;
/// - the tail commit sequence (seq 66 → 80) ends with exactly ONE `日本語`
///   (seq 76's `…日本語日本語` is the append-shaped commit, rewritten;
///   seq 80's stale composing re-arm is latch-suppressed), composing
///   cleared, selection collapsed after it;
/// - nothing was ever pushed mid-composition: the only pushes are the
///   attach window and the dead-key rewrite's resync, neither viaTerminate.
void main() {
  /// The capture, verbatim (inspector journal pane, Copy JSON). Inbound
  /// kinds replay; the `push`/`terminate` lines are what the BUGGY code did
  /// during the session and are deliberately NOT asserted as expected
  /// outputs — the assertions below are on the FIXED behavior.
  const capture = r'''
{"seq":0,"ms":100,"kind":"attach","payload":{"frontend":"nonDeltaDiff"}}
{"seq":1,"ms":104,"kind":"push","payload":{"text":". ","sel":[2,2],"composing":null,"viaTerminate":false}}
{"seq":3,"ms":5281,"kind":"key","payload":{"kind":"down","key":"Enter","character":null,"deferred":false,"handler":"insertNewline"}}
{"seq":4,"ms":5285,"kind":"push","payload":{"text":". ","sel":[2,2],"composing":null,"viaTerminate":false}}
{"seq":6,"ms":6415,"kind":"snapshot","payload":{"text":". n","sel":[2,3],"composing":[2,3]}}
{"seq":12,"ms":6468,"kind":"snapshot","payload":{"text":". n","sel":[3,3],"composing":[2,3]}}
{"seq":16,"ms":6849,"kind":"snapshot","payload":{"text":". nに","sel":[3,4],"composing":[3,4]}}
{"seq":22,"ms":6893,"kind":"snapshot","payload":{"text":". nに","sel":[4,4],"composing":[3,4]}}
{"seq":26,"ms":7587,"kind":"snapshot","payload":{"text":". nににh","sel":[4,6],"composing":[4,6]}}
{"seq":32,"ms":7639,"kind":"snapshot","payload":{"text":". nににh","sel":[6,6],"composing":[4,6]}}
{"seq":36,"ms":8007,"kind":"snapshot","payload":{"text":". nににhにほ","sel":[6,8],"composing":[6,8]}}
{"seq":42,"ms":8056,"kind":"snapshot","payload":{"text":". nににhにほ","sel":[8,8],"composing":[6,8]}}
{"seq":46,"ms":8417,"kind":"snapshot","payload":{"text":". nににhにほにほn","sel":[8,11],"composing":[8,11]}}
{"seq":52,"ms":8469,"kind":"snapshot","payload":{"text":". nににhにほにほn","sel":[11,11],"composing":[8,11]}}
{"seq":56,"ms":8681,"kind":"snapshot","payload":{"text":". nににhにほにほnにほんg","sel":[11,15],"composing":[11,15]}}
{"seq":62,"ms":8724,"kind":"snapshot","payload":{"text":". nににhにほにほnにほんg","sel":[15,15],"composing":[11,15]}}
{"seq":66,"ms":9746,"kind":"snapshot","payload":{"text":". nににhにほにほnにほんg日本語","sel":[15,18],"composing":[15,18]}}
{"seq":71,"ms":9756,"kind":"snapshot","payload":{"text":". nににhにほにほnにほんg日本語","sel":[18,18],"composing":[15,18]}}
{"seq":76,"ms":11291,"kind":"snapshot","payload":{"text":". nににhにほにほnにほんg日本語日本語","sel":[21,21],"composing":[15,18]}}
{"seq":80,"ms":11316,"kind":"snapshot","payload":{"text":". nににhにほにほnにほんg日本語","sel":[18,18],"composing":[15,18]}}
''';

  test('Safari Japanese capture replay: the composition survives the '
      'range-selection snapshots — no terminate, no mid-composition push, '
      'exactly one 日本語 after the commit tail', () {
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

    String blockText() => controller.document.allBlocks.last.plainText;

    // Replay event by event so the invariants can be checked at every
    // inbound snapshot, not just at the end.
    for (final event in parseImeJournalDump(capture)) {
      replayImeJournal(service, [event]);
      if (event['kind'] != 'snapshot') continue;
      final seq = event['seq']! as int;
      final payload = (event['payload']! as Map).cast<String, Object?>();
      final text = payload['text']! as String;

      // The fix's core claim: the range-selection-over-composing snapshot
      // is NOT structural divergence. Buggy code terminates here from
      // seq 6 onward.
      expect(
        service.debugLastTerminateReason,
        isNull,
        reason: 'seq $seq must not terminate the live composition',
      );

      // The composition stays live in the model until the conversion
      // commit (seq 76 is the append-shaped commit — the dead-key rewrite
      // clears composing; seq 80 is the engine's stale re-arm, suppressed
      // by the latch the rewrite leaves behind).
      expect(
        controller.composing,
        seq <= 71 ? isNotNull : isNull,
        reason: 'composition liveness after seq $seq',
      );

      // Acknowledge-verbatim: the model mirrors the engine's text minus
      // the sentinel — the pipeline adds NO accumulation of its own (the
      // garbage inside the captured texts is Safari's DOM as the live bug
      // left it, not the replay's doing). Seq 76 is the one deliberate
      // divergence: the append-shaped `…日本語日本語` is rewritten as the
      // commit (replace the marked 日本語, not append a second one).
      expect(
        blockText(),
        seq == 76
            ? text.substring(2).replaceFirst('日本語日本語', '日本語')
            : text.substring(2),
        reason: 'model mirrors the engine after seq $seq',
      );
    }

    // The tail (seq 66 → 80): exactly one 日本語, composing cleared on
    // both sides, selection collapsed after the committed word.
    final text = blockText();
    expect('日本語'.allMatches(text), hasLength(1));
    expect(text, endsWith('日本語'));
    expect(controller.composing, isNull);
    expect(service.currentTextEditingValue!.composing, TextRange.empty);
    expect(controller.selection!.isCollapsed, isTrue);
    expect(controller.selection!.extent.offset, text.length);

    // No push ever carried viaTerminate, and none happened mid-composition:
    // the journal records exactly the attach window and the dead-key
    // rewrite's resync (the Enter at seq 3 leaves the window byte-identical
    // — `'. '` to `'. '` — so clause (b) sends nothing).
    final journal = service.journal.toJson();
    expect(
      journal.where((e) => e['kind'] == 'terminate'),
      isEmpty,
      reason: 'the composition was never terminated',
    );
    final pushes = [
      for (final e in journal)
        if (e['kind'] == 'push') (e['payload']! as Map).cast<String, Object?>(),
    ];
    expect([for (final p in pushes) p['viaTerminate']], everyElement(isFalse));
    expect([for (final p in pushes) p['text']], ['. ', '. nににhにほにほnにほんg日本語']);
  });
}
