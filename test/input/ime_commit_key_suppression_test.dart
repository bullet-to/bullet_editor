import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ime_replay.dart';
import 'ime_service_test.dart' show FakeImeConnection;

/// The Safari post-compositionend commit Enter (the captured Japanese
/// session): WebKit fires compositionend BEFORE the keydown of the key that
/// ended the composition, so the Enter that commits a conversion reaches
/// the framework with composing already null — past the composing gate —
/// and inserted a spurious paragraph. The service-side fix is the one-shot
/// commit-key suppression (ProseMirror's `compositionEndedAt` + 500 ms
/// precedent): armed when an engine snapshot ends a live shadow
/// composition, consumed once by the widget's Enter consult, expired after
/// [ImeService.commitKeySuppressionWindow]. These tests drive the window
/// with an injected monotonic clock; the widget-level half (the actual
/// swallowed keydown) lives in `test/view/bullet_editor_ime_test.dart`.
void main() {
  TextBlock para(String id, String text) => TextBlock(
    id: id,
    blockType: ParagraphKeys.type,
    segments: [StyledSegment(text)],
  );

  DocSelection caret(String blockId, int offset) =>
      DocSelection.collapsed(DocPosition(blockId, offset));

  late int nowMs;
  late EditorController controller;
  late ImeService service;
  late List<FakeImeConnection> connections;

  ImeService build(
    List<TextBlock> blocks, {
    DocSelection? selection,
    ImeFrontend frontend = ImeFrontend.nonDeltaDiff,
  }) {
    nowMs = 0;
    controller = EditorController(
      document: Document(blocks),
      schema: EditorSchema.standard(),
      undoGrouping: (previous, current) => false,
    );
    if (selection != null) controller.setSelection(selection);
    connections = [];
    service = ImeService(
      controller: controller,
      frontend: frontend,
      monotonicNowMs: () => nowMs,
      connectionFactory: (client, configuration) {
        final connection = FakeImeConnection();
        connections.add(connection);
        return connection;
      },
    );
    service.attach();
    return service;
  }

  void sendValue(
    String text, {
    required int cursor,
    int? cursorBase,
    TextRange composing = TextRange.empty,
  }) {
    service.updateEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection(
          baseOffset: cursorBase ?? cursor,
          extentOffset: cursor,
        ),
        composing: composing,
      ),
    );
  }

  List<Object?> journalKinds() => [
    for (final e in service.journal.toJson()) e['kind'],
  ];

  /// The real capture's tail (sentinel `". "` visible): the conversion
  /// display (seq 60, WebKit's marked-text-selected shape), the caret echo
  /// (seq 69), and compositionend reflected as the composing-clear
  /// snapshot (seq 72). The commit Enter's keydown followed 29 ms later.
  const captureTail = r'''
{"seq":60,"ms":9450,"kind":"snapshot","payload":{"text":". 日本語","sel":[2,5],"composing":[2,5]}}
{"seq":69,"ms":10379,"kind":"snapshot","payload":{"text":". 日本語","sel":[5,5],"composing":[2,5]}}
{"seq":72,"ms":10379,"kind":"snapshot","payload":{"text":". 日本語","sel":[5,5],"composing":null}}
''';

  group(
    'the Safari capture tail (compositionend before the commit keydown)',
    () {
      test('the composing-clear snapshot arms; the commit Enter 29 ms later '
          'consumes — once', () {
        build([para('a', '')], selection: caret('a', 0));

        replayImeJournal(service, parseImeJournalDump(captureTail));

        expect(controller.document.blockById('a')!.plainText, '日本語');
        expect(controller.composing, isNull);
        expect(service.debugCommitKeySuppressionArmed, isTrue);
        expect(journalKinds(), contains('commitKeySuppressionArmed'));

        nowMs += 29; // the captured gap to the commit Enter's keydown
        expect(service.consumeCommitKeySuppression(), isTrue);
        expect(journalKinds(), contains('commitKeySuppressionConsumed'));

        // One-shot: consumed means disarmed — the next Enter is genuine.
        expect(service.debugCommitKeySuppressionArmed, isFalse);
        expect(service.consumeCommitKeySuppression(), isFalse);
      });

      test('an Enter after the window expired is genuine — the consult '
          'returns false (and disarms the dead arm)', () {
        build([para('a', '')], selection: caret('a', 0));
        replayImeJournal(service, parseImeJournalDump(captureTail));
        expect(service.debugCommitKeySuppressionArmed, isTrue);

        nowMs += 600; // past commitKeySuppressionWindow (500 ms)
        expect(service.consumeCommitKeySuppression(), isFalse);
        expect(service.debugCommitKeySuppressionArmed, isFalse);
        expect(journalKinds(), contains('commitKeySuppressionExpired'));
        expect(journalKinds(), isNot(contains('commitKeySuppressionConsumed')));
      });
    },
  );

  group('arming rules (engine-reported ends only)', () {
    test('our own terminate does NOT arm — and disarms an earlier arm', () {
      build([para('a', '')], selection: caret('a', 0));

      // A live composition ended by OUR terminate (the externalEdit /
      // structural paths): the engine never reported an end, so no commit
      // keydown is in flight — Enter right after must split.
      sendValue('. か', cursor: 3, composing: const TextRange(start: 2, end: 3));
      expect(controller.composing, isNotNull);
      service.terminateComposition('externalEdit');
      expect(controller.composing, isNull);
      expect(service.debugCommitKeySuppressionArmed, isFalse);
      expect(service.consumeCommitKeySuppression(), isFalse);
      expect(journalKinds(), isNot(contains('commitKeySuppressionArmed')));
    });

    test('a terminate between arm and consult disarms the stale arm', () {
      build([para('a', '')], selection: caret('a', 0));
      replayImeJournal(service, parseImeJournalDump(captureTail));
      expect(service.debugCommitKeySuppressionArmed, isTrue);

      service.terminateComposition('externalEdit');

      expect(service.debugCommitKeySuppressionArmed, isFalse);
      expect(service.consumeCommitKeySuppression(), isFalse);
    });

    test("the dead-key rewrite (Safari's append-shaped commit) does not arm "
        '— Enter right after a committed é still splits', () {
      build([para('a', 'hello')], selection: caret('a', 5));

      // Option+E marks ´, then E commits: WebKit's input-before-
      // compositionend shape — the snapshot still carries the stale live
      // region, so the live→empty transition never matches and the
      // committing key was a character key, not Enter.
      sendValue(
        '. hello´',
        cursor: 8,
        composing: const TextRange(start: 7, end: 8),
      );
      expect(controller.composing, isNotNull);
      sendValue(
        '. hello´é',
        cursor: 9,
        composing: const TextRange(start: 7, end: 8),
      );

      expect(controller.document.blockById('a')!.plainText, 'helloé');
      expect(controller.composing, isNull);
      expect(service.debugCommitKeySuppressionArmed, isFalse);
      expect(service.consumeCommitKeySuppression(), isFalse);
    });

    test("Chrome's ordering — a gate-deferred Enter precedes the "
        'composing-clear — skips the arm (the gate already consumed the '
        'commit key)', () {
      build([para('a', '')], selection: caret('a', 0));

      sendValue('. か', cursor: 3, composing: const TextRange(start: 2, end: 3));
      expect(controller.composing, isNotNull);

      // What the widget's composing gate records when it defers the commit
      // Enter to the browser (keyCode 229, composition still live) ...
      service.noteCommitKeyDeferred();
      nowMs += 5;
      // ... and the browser's commit: compositionend reflected.
      sendValue('. か', cursor: 3);

      expect(controller.composing, isNull);
      expect(service.debugCommitKeySuppressionArmed, isFalse);
      expect(service.consumeCommitKeySuppression(), isFalse);
      expect(journalKinds(), contains('commitKeySuppressionSkipped'));
      expect(journalKinds(), isNot(contains('commitKeySuppressionArmed')));
    });

    test('a subsequently ACCEPTED snapshot disarms (the click-commit / '
        'punctuation auto-commit scope): the arm only covers a keydown '
        'already in flight directly behind the arming snapshot', () {
      build([para('a', '')], selection: caret('a', 0));

      // The composition ends engine-side (a click-commit — no keydown in
      // flight) ...
      sendValue('. か', cursor: 3, composing: const TextRange(start: 2, end: 3));
      sendValue('. か', cursor: 3);
      expect(service.debugCommitKeySuppressionArmed, isTrue);

      // ... and the click's own selectionchange snapshot lands: an
      // accepted snapshot proves other traffic intervened, so the arm
      // cannot be Safari's compositionend→keydown gap (nothing intervenes
      // there) — the user's near-future Enter is genuine.
      sendValue('. か', cursor: 2);

      expect(service.debugCommitKeySuppressionArmed, isFalse);
      nowMs += 29;
      expect(service.consumeCommitKeySuppression(), isFalse);
      expect(journalKinds(), contains('commitKeySuppressionDisarmed'));
    });

    test('the arming snapshot does NOT disarm itself — the original Safari '
        'capture (arm → 29 ms → Enter, nothing between) stays suppressed', () {
      build([para('a', '')], selection: caret('a', 0));

      replayImeJournal(service, parseImeJournalDump(captureTail));

      expect(service.debugCommitKeySuppressionArmed, isTrue);
      nowMs += 29;
      expect(service.consumeCommitKeySuppression(), isTrue);
    });

    test('an external (non-IME) selection change disarms: by the time a '
        'tap-then-Enter sequence reaches the consult, the arm is gone', () {
      build([para('a', '')], selection: caret('a', 0));
      replayImeJournal(service, parseImeJournalDump(captureTail));
      expect(service.debugCommitKeySuppressionArmed, isTrue);

      // The user taps elsewhere — clause (b)'s non-IME selection change.
      controller.setSelection(caret('a', 1));

      expect(service.debugCommitKeySuppressionArmed, isFalse);
      nowMs += 29;
      expect(service.consumeCommitKeySuppression(), isFalse);
      expect(journalKinds(), contains('commitKeySuppressionDisarmed'));
    });

    test('the delta frontend never arms (desktop: the committing keydown '
        'precedes the composing-clear; the composing gate owns it)', () {
      build(
        [para('a', '')],
        selection: caret('a', 0),
        frontend: ImeFrontend.delta,
      );

      service.updateEditingValueWithDeltas([
        const TextEditingDeltaInsertion(
          oldText: '. ',
          textInserted: 'か',
          insertionOffset: 2,
          selection: TextSelection.collapsed(offset: 3),
          composing: TextRange(start: 2, end: 3),
        ),
      ]);
      expect(controller.composing, isNotNull);
      service.updateEditingValueWithDeltas([
        const TextEditingDeltaNonTextUpdate(
          oldText: '. か',
          selection: TextSelection.collapsed(offset: 3),
          composing: TextRange.empty,
        ),
      ]);

      expect(controller.composing, isNull);
      expect(service.debugCommitKeySuppressionArmed, isFalse);
      expect(service.consumeCommitKeySuppression(), isFalse);
      expect(journalKinds(), isNot(contains('commitKeySuppressionArmed')));
    });
  });
}
