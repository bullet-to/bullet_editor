import 'dart:convert';

import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ime_replay.dart';
import 'ime_service_test.dart' show FakeImeConnection;

/// The IME journal (v3-build-strategy §record-and-replay): bounded
/// structured recording at every `ImeService` decision point, the dump
/// format the inspector's Copy JSON produces, the widget's hardware-key
/// interleave, and the replay self-test — a captured Safari-shaped session
/// replayed into a fresh service converges to the same document and shadow.
void main() {
  TextBlock para(String id, String text) => TextBlock(
    id: id,
    blockType: ParagraphKeys.type,
    segments: [StyledSegment(text)],
  );

  DocSelection caret(String blockId, int offset) =>
      DocSelection.collapsed(DocPosition(blockId, offset));

  group('ImeJournal (the ring buffer and the dump)', () {
    test('records events with monotonic sequence numbers and elapsed-ms '
        'timestamps', () {
      final journal = ImeJournal();
      journal.record('one', () => {'a': 1});
      journal.record('two', () => {'b': 'x'});

      expect(journal.events, hasLength(2));
      expect(journal.events[0].seq, 0);
      expect(journal.events[1].seq, 1);
      expect(journal.events[0].kind, 'one');
      expect(journal.events[0].payload, {'a': 1});
      expect(
        journal.events[1].elapsedMs,
        greaterThanOrEqualTo(journal.events[0].elapsedMs),
        reason: 'the stopwatch clock is monotonic',
      );
    });

    test('the buffer is bounded: the oldest events evict, the sequence '
        'keeps counting', () {
      final journal = ImeJournal(capacity: 5);
      for (var i = 0; i < 8; i++) {
        journal.record('e$i', () => const {});
      }

      expect(journal.events, hasLength(5));
      expect(journal.events.first.seq, 3, reason: 'seq gaps reveal eviction');
      expect(journal.events.last.seq, 7);
      expect(journal.events.first.kind, 'e3');
    });

    test('dump() is one JSON object per line, decodable back into the '
        'event maps', () {
      final journal = ImeJournal();
      journal.record('push', () => {'text': '. に', 'viaTerminate': false});
      journal.record('drop', () => {'reason': 'staleSnapshot'});

      final dump = journal.dump();
      final lines = dump.split('\n');
      expect(lines, hasLength(2));
      for (final line in lines) {
        final decoded = json.decode(line) as Map;
        expect(decoded.keys, containsAll(['seq', 'ms', 'kind', 'payload']));
      }
      expect(
        (json.decode(lines.first) as Map)['payload'],
        {'text': '. に', 'viaTerminate': false},
        reason: 'unicode and raw payloads survive the round trip',
      );
      expect(parseImeJournalDump(dump), journal.toJson());
    });

    test('a disabled journal records nothing and never builds the payload '
        '(the release-mode cost discipline)', () {
      final journal = ImeJournal(enabled: false);
      var built = 0;
      journal.record('e', () {
        built++;
        return const {};
      });

      expect(journal.events, isEmpty);
      expect(built, 0, reason: 'the payload closure is behind the flag');
      expect(journal.dump(), isEmpty);
    });

    test('clear() empties the buffer; later events are recognizably later '
        '(the sequence does not reset)', () {
      final journal = ImeJournal();
      journal.record('a', () => const {});
      journal.record('b', () => const {});
      journal.clear();
      expect(journal.events, isEmpty);

      journal.record('c', () => const {});
      expect(journal.events.single.seq, 2);
    });
  });

  group('ImeService records at every decision point', () {
    late EditorController controller;
    late ImeService service;
    late List<FakeImeConnection> connections;

    ImeService build(
      List<TextBlock> blocks, {
      DocSelection? selection,
      ImeFrontend frontend = ImeFrontend.nonDeltaDiff,
    }) {
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
      TextRange composing = TextRange.empty,
    }) {
      service.updateEditingValue(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: cursor),
          composing: composing,
        ),
      );
    }

    List<ImeJournalEvent> events(String kind) =>
        service.journal.events.where((e) => e.kind == kind).toList();

    test('attach records the frontend mode, then the authoritative push '
        '(raw window text, sentinel visible)', () {
      build([para('a', 'hi')], selection: caret('a', 2));

      final kinds = [for (final e in service.journal.events) e.kind];
      expect(kinds, ['attach', 'push']);
      expect(events('attach').single.payload, {'frontend': 'nonDeltaDiff'});
      expect(events('push').single.payload, {
        'text': '. hi',
        'sel': [4, 4],
        'composing': null,
        'viaTerminate': false,
      });
    });

    test('a snapshot records raw (before any filtering), its diff, and the '
        'synthesized delta', () {
      build([para('a', 'hi')], selection: caret('a', 2));

      sendValue('. hix', cursor: 5);

      expect(events('snapshot').single.payload, {
        'text': '. hix',
        'sel': [5, 5],
        'composing': null,
      });
      expect(events('diff').single.payload, {
        'start': 4,
        'deleted': 0,
        'inserted': 'x',
      });
      expect(events('synthesized').single.payload, {
        'delta': {
          'type': 'insertion',
          'oldText': '. hi',
          'inserted': 'x',
          'at': 4,
          'sel': [5, 5],
          'composing': null,
        },
      });
    });

    test('a pure echo of our own push synthesizes null', () {
      build([para('a', 'hi')], selection: caret('a', 2));

      service.updateEditingValue(service.currentTextEditingValue!);

      expect(events('diff').single.payload, {'result': null});
      expect(events('synthesized').single.payload, {'delta': null});
    });

    test('the stale-snapshot drop and its recovery push are recorded', () {
      build([para('a', 'hello')], selection: caret('a', 5));
      controller.insertText('!'); // clause (a) push arms the drop
      service.journal.clear();

      sendValue('. hello', cursor: 7); // the in-flight stale shape

      final kinds = [for (final e in service.journal.events) e.kind];
      expect(kinds, ['snapshot', 'diff', 'drop', 'push']);
      expect(events('drop').single.payload, {'reason': 'staleSnapshot'});
      expect(events('push').single.payload['text'], '. hello!');
    });

    test('terminateComposition records the reason and the quarantined '
        'composed text; its push carries viaTerminate', () {
      build([para('a', '')], selection: caret('a', 0));
      sendValue('. か', cursor: 3, composing: const TextRange(start: 2, end: 3));
      service.journal.clear();

      controller.undo();

      expect(events('terminate').single.payload, {
        'reason': 'undo',
        'composed': 'か',
      });
      expect(events('push').single.payload['viaTerminate'], isTrue);
    });

    test('a mis-reported composing region records the sanitization', () {
      build([para('a', 'ab')], selection: caret('a', 2));

      sendValue(
        '. abか',
        cursor: 5,
        composing: const TextRange(start: 4, end: 99),
      );

      expect(events('composingSanitized').single.payload, {
        'from': [4, 99],
        'to': null,
      });
    });

    test("the dead-key rewrite and the stale-latch refusal's suppression "
        'are recorded (the Safari stuck-IME shape)', () {
      build([para('a', '')], selection: caret('a', 0));
      sendValue('. ´', cursor: 3, composing: const TextRange(start: 2, end: 3));
      service.journal.clear();

      // WebKit's append-shaped commit: é appended after the still-marked ´.
      sendValue(
        '. ´é',
        cursor: 4,
        composing: const TextRange(start: 2, end: 3),
      );
      expect(
        events('synthesized').single.payload['deadKeyRewrite'],
        isTrue,
        reason: 'the rewrite decision is in the stream',
      );
      service.journal.clear();

      // The push-induced echo still latched at the dead range: suppressed.
      sendValue('. é', cursor: 3, composing: const TextRange(start: 2, end: 3));
      expect(events('staleComposingSuppressed').single.payload, {
        'range': [2, 3],
      });
    });

    test('an inbound delta batch is recorded verbatim with type tags '
        '(the delta frontend)', () {
      build(
        [para('a', 'hi')],
        selection: caret('a', 2),
        frontend: ImeFrontend.delta,
      );

      service.updateEditingValueWithDeltas([
        const TextEditingDeltaInsertion(
          oldText: '. hi',
          textInserted: 'x',
          insertionOffset: 4,
          selection: TextSelection.collapsed(offset: 5),
          composing: TextRange.empty,
        ),
      ]);

      expect(events('deltas').single.payload, {
        'deltas': [
          {
            'type': 'insertion',
            'oldText': '. hi',
            'inserted': 'x',
            'at': 4,
            'sel': [5, 5],
            'composing': null,
          },
        ],
      });
    });

    test('performSelector and an unhandled selector are recorded', () {
      build([para('a', 'hi')], selection: caret('a', 2));

      service.performSelector('moveToBeginningOfDocument:');

      expect(events('performSelector').single.payload, {
        'selector': 'moveToBeginningOfDocument:',
      });
      expect(events('selectorUnhandled').single.payload, {
        'selector': 'moveToBeginningOfDocument:',
      });
    });
  });

  group('hardware keypress history (the widget interleave)', () {
    testWidgets('every key event lands in the journal with the consuming '
        'handler — and the composing gate records the deferral', (
      tester,
    ) async {
      final controller = EditorController(
        document: Document([para('a', 'hi')]),
        schema: EditorSchema.standard(),
        undoGrouping: (previous, current) => false,
      );
      controller.setSelection(caret('a', 2));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BulletEditor(controller: controller, autofocus: true),
          ),
        ),
      );
      await tester.pump();
      final ime = tester
          .state<BulletEditorState>(find.byType(BulletEditor))
          .imeService;
      ime.journal.clear();

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);

      final keys = ime.journal.events.where((e) => e.kind == 'key').toList();
      expect(keys, hasLength(2), reason: 'key-down and key-up both record');
      expect(keys[0].payload['kind'], 'down');
      expect(keys[0].payload['key'], 'Backspace');
      expect(keys[0].payload['handler'], 'backspace');
      expect(keys[0].payload['deferred'], isFalse);
      expect(keys[1].payload['kind'], 'up');
      expect(keys[1].payload['handler'], 'ignored');
      expect(controller.document.blockById('a')!.plainText, 'h');

      // The key precedes the push it causes (record-then-run order).
      final all = ime.journal.events;
      final keySeq = all.firstWhere((e) => e.kind == 'key').seq;
      final pushSeq = all.firstWhere((e) => e.kind == 'push').seq;
      expect(keySeq, lessThan(pushSeq));

      // The composing gate: backspace during a live composition defers.
      ime.updateEditingValueWithDeltas([
        TextEditingDeltaInsertion(
          oldText: ime.currentTextEditingValue!.text,
          textInserted: 'か',
          insertionOffset: 3,
          selection: const TextSelection.collapsed(offset: 4),
          composing: const TextRange(start: 3, end: 4),
        ),
      ]);
      expect(controller.composing, isNotNull);
      ime.journal.clear();

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);

      final deferred = ime.journal.events
          .where((e) => e.kind == 'key')
          .first
          .payload;
      expect(deferred['deferred'], isTrue);
      expect(deferred['handler'], 'ignored');
      expect(
        controller.document.blockById('a')!.plainText,
        'hか',
        reason: 'the gate left the key to the IME — nothing was edited',
      );
    });
  });

  group('replay (the record-and-replay seam)', () {
    test('a captured Safari-shaped session (Japanese compose → convert → '
        'commit, hardware backspace, plain typing) replays through the JSON '
        'dump into a fresh service and converges to the same document and '
        'shadow', () {
      List<TextBlock> fixture() => [para('a', '')];
      ({
        EditorController controller,
        ImeService service,
        FakeImeConnection connection,
      })
      harness() {
        final controller = EditorController(
          document: Document(fixture()),
          schema: EditorSchema.standard(),
          undoGrouping: (previous, current) => false,
        );
        controller.setSelection(caret('a', 0));
        final connection = FakeImeConnection();
        final service = ImeService(
          controller: controller,
          frontend: ImeFrontend.nonDeltaDiff,
          connectionFactory: (client, configuration) => connection,
        )..attach();
        return (
          controller: controller,
          service: service,
          connection: connection,
        );
      }

      // --- Capture: the manual Safari session ---
      final capture = harness();
      void sendValue(
        String text, {
        required int cursor,
        TextRange composing = TextRange.empty,
      }) {
        capture.service.updateEditingValue(
          TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: cursor),
            composing: composing,
          ),
        );
      }

      // Compose にほん, convert to 日本, commit (the web CJK exit-criterion
      // shapes).
      sendValue('. に', cursor: 3, composing: const TextRange(start: 2, end: 3));
      sendValue(
        '. にほ',
        cursor: 4,
        composing: const TextRange(start: 2, end: 4),
      );
      sendValue(
        '. にほん',
        cursor: 5,
        composing: const TextRange(start: 2, end: 5),
      );
      sendValue(
        '. 日本',
        cursor: 4,
        composing: const TextRange(start: 2, end: 4),
      );
      sendValue('. 日本', cursor: 4);
      // Hardware backspace — the widget's record-then-run order.
      capture.service.journal.record(
        'key',
        () => {
          'kind': 'down',
          'key': 'Backspace',
          'character': null,
          'deferred': false,
          'handler': 'backspace',
        },
      );
      capture.controller.backspace();
      // Plain typing against the re-pushed window.
      sendValue('. 日x', cursor: 4);

      expect(capture.controller.document.blockById('a')!.plainText, '日x');

      // --- The capture round-trips through the paste-into-chat dump ---
      final events = parseImeJournalDump(capture.service.journal.dump());

      // --- Replay into a fresh service over the same starting state ---
      final replay = harness();
      replayImeJournal(replay.service, events);

      expect(
        replay.controller.document.blockById('a')!.plainText,
        '日x',
        reason: 'the replayed inbound stream rebuilds the same document',
      );
      expect(replay.controller.selection, capture.controller.selection);
      expect(
        replay.service.currentTextEditingValue,
        capture.service.currentTextEditingValue,
        reason: 'the shadow (text + selection + composing) converges',
      );
      // The capture's outbound `push` events are the EXPECTED outputs: the
      // fresh connection received the same pushes the device session did.
      expect(
        [for (final v in replay.connection.pushed) v.text],
        [for (final v in capture.connection.pushed) v.text],
      );
    });
  });
}
