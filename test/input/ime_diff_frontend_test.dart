import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ime_service_test.dart' show FakeImeConnection;

/// Day 8 — the web non-delta diff fallback (architecture §IME web fallback):
/// a second *frontend* over the same shadow-buffer + resolve-at-apply core.
/// `updateEditingValue` snapshots are diffed against the shadow
/// (`text_diff.dart`), the equivalent delta is synthesized, and it routes
/// through the SAME batch path the delta client uses — stale guard,
/// quarantine, sentinel decomposition (G1), divergence rule, composing
/// mapping (−2 shift, block-local) all apply identically. Exit criterion:
/// the web CJK trace (Safari Japanese compose → convert → commit → "# "
/// rule fire on commit) plus the Safari dead-key shape (the v2 fix's
/// scenario, day-15 drip row).
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
  late List<TextInputConfiguration> configurations;

  ImeService build(
    List<TextBlock> blocks, {
    DocSelection? selection,
    ImeFrontend frontend = ImeFrontend.nonDeltaDiff,
  }) {
    controller = EditorController(
      document: Document(blocks),
      schema: EditorSchema.standard(),
      // Deterministic undo: every push is its own entry, so composition
      // scoping is observable without the 300ms time merge.
      undoGrouping: (previous, current) => false,
    );
    if (selection != null) controller.setSelection(selection);
    connections = [];
    configurations = [];
    service = ImeService(
      controller: controller,
      frontend: frontend,
      connectionFactory: (client, configuration) {
        final connection = FakeImeConnection();
        connections.add(connection);
        configurations.add(configuration);
        return connection;
      },
    );
    service.attach();
    return service;
  }

  FakeImeConnection connection() => connections.last;
  TextEditingValue shadow() => service.currentTextEditingValue!;

  /// The engine's full-value callback — what a web engine sends for every
  /// DOM input/compositionupdate/selectionchange.
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

  group('frontend selection (flippable per-platform, R1/R7)', () {
    test('the diff frontend attaches WITHOUT the delta model', () {
      build([para('a', 'hi')], selection: caret('a', 2));

      expect(service.frontend, ImeFrontend.nonDeltaDiff);
      expect(configurations.single.enableDeltaModel, isFalse);
      expect(
        configurations.single.autocorrect,
        isTrue,
        reason: 'only the delta-model bit differs from the delta config',
      );
    });

    test('the delta frontend keeps enableDeltaModel and treats '
        'updateEditingValue as the documented no-op', () {
      build(
        [para('a', 'hi')],
        selection: caret('a', 2),
        frontend: ImeFrontend.delta,
      );
      expect(configurations.single.enableDeltaModel, isTrue);

      sendValue('. hix', cursor: 5);

      expect(controller.document.blockById('a')!.plainText, 'hi');
      expect(connection().pushed, hasLength(1), reason: 'nothing happened');
    });

    test('an explicit configuration wins over the frontend default', () {
      controller = EditorController(
        document: Document([para('a', 'hi')]),
        schema: EditorSchema.standard(),
      );
      configurations = [];
      service = ImeService(
        controller: controller,
        frontend: ImeFrontend.nonDeltaDiff,
        configuration: const TextInputConfiguration(
          inputType: TextInputType.multiline,
          enableDeltaModel: false,
          autocorrect: false,
        ),
        connectionFactory: (client, configuration) {
          configurations.add(configuration);
          return FakeImeConnection();
        },
      );
      service.attach();

      expect(configurations.single.autocorrect, isFalse);
    });
  });

  group('the diff frontend drives THE SAME core (no forked pipeline)', () {
    test('a full-value snapshot inserting one character applies and is '
        'NEVER echoed back', () {
      build([para('a', 'helo')], selection: caret('a', 3));
      expect(shadow().text, '. helo');

      sendValue('. hello', cursor: 6);

      expect(controller.document.blockById('a')!.plainText, 'hello');
      expect(controller.selection, caret('a', 4));
      expect(
        connection().pushed,
        hasLength(1),
        reason: 'no echo (IME §no-echo) — the snapshot is acknowledged',
      );
      expect(shadow().text, '. hello');
      expect(shadow().selection, const TextSelection.collapsed(offset: 6));
    });

    test('typing letter by letter through snapshots builds the word', () {
      build([para('a', '')], selection: caret('a', 0));
      final word = 'hello';
      for (var i = 1; i <= word.length; i++) {
        sendValue('. ${word.substring(0, i)}', cursor: 2 + i);
      }

      expect(controller.document.blockById('a')!.plainText, 'hello');
      expect(connection().pushed, hasLength(1), reason: 'never echoed');
    });

    test('a snapshot deleting one character maps to a deletion', () {
      build([para('a', 'hello')], selection: caret('a', 5));

      sendValue('. hell', cursor: 6);

      expect(controller.document.blockById('a')!.plainText, 'hell');
      expect(controller.selection, caret('a', 4));
      expect(connection().pushed, hasLength(1));
    });

    test('a snapshot replacing a range maps to a replacement', () {
      build([para('a', 'teh')], selection: caret('a', 3));

      // Browser autocorrect-style fixup: teh → the.
      sendValue('. the', cursor: 5);

      expect(controller.document.blockById('a')!.plainText, 'the');
    });

    test('a value identical to the shadow (the engine echoing our own push) '
        'is acknowledged silently', () {
      build([para('a', 'hi')], selection: caret('a', 2));
      final before = shadow();

      service.updateEditingValue(before);

      expect(connection().pushed, hasLength(1));
      expect(controller.document.blockById('a')!.plainText, 'hi');
      expect(shadow(), before);
    });

    test('a selection-only value moves the model caret without an echo '
        '(the NonTextUpdate analogue)', () {
      build([para('a', 'hello')], selection: caret('a', 5));

      sendValue('. hello', cursor: 2);

      expect(controller.selection, caret('a', 0));
      expect(connection().pushed, hasLength(1));
      expect(
        shadow().selection,
        const TextSelection.collapsed(offset: 2),
        reason: 'acknowledged into the shadow',
      );
    });

    test(r'a snapshot inserting \n splits through the same Enter path and '
        'the new window pushes', () {
      build([para('a', 'onetwo')], selection: caret('a', 3));

      sendValue('. one\ntwo', cursor: 6);

      final blocks = controller.document.allBlocks;
      expect(blocks, hasLength(2));
      expect(blocks[0].plainText, 'one');
      expect(blocks[1].plainText, 'two');
      expect(controller.selection, caret(blocks[1].id, 0));
      expect(connection().pushed.last.text, '. two');
    });

    test('same-block tap-then-type trace behind the diff frontend: type '
        '"hello", tap before h, type x → "xhello"', () {
      build([para('a', '')], selection: caret('a', 0));
      sendValue('. hello', cursor: 7);
      expect(controller.document.blockById('a')!.plainText, 'hello');
      final pushesBeforeTap = connection().pushed.length;

      // The tap: a non-IME selection change → clause (b) re-push.
      controller.setSelection(caret('a', 0));
      expect(connection().pushed.length, pushesBeforeTap + 1);
      expect(shadow().selection, const TextSelection.collapsed(offset: 2));

      // The next snapshot diffs against the re-pushed shadow.
      sendValue('. xhello', cursor: 3);
      expect(controller.document.blockById('a')!.plainText, 'xhello');
    });

    test('G1 through the diff frontend: a snapshot consuming the sentinel '
        'is a structural backspace (merge policy)', () {
      build([para('a', 'prev'), para('b', 'hello')], selection: caret('b', 0));
      expect(shadow().text, '. hello');

      // Backspace at block start: the browser deletes the char before the
      // caret — the sentinel space — and reports the full new value.
      sendValue('.hello', cursor: 1);

      final blocks = controller.document.allBlocks;
      expect(blocks, hasLength(1));
      expect(blocks[0].plainText, 'prevhello');
      expect(controller.selection, caret('a', 4));
      expect(connection().pushed.last.text, '. prevhello');
    });

    test('G1 composite through the diff frontend: a snapshot deleting the '
        'sentinel AND text merges and removes the text (decomposed, never '
        'wholesale)', () {
      build([para('a', 'prev'), para('b', 'hello')], selection: caret('b', 5));

      // Select-to-line-start + delete: the whole ". hello" collapses.
      sendValue('', cursor: 0);

      final blocks = controller.document.allBlocks;
      expect(blocks, hasLength(1));
      expect(blocks[0].plainText, 'prev');
      expect(connection().pushed.last.text, '. prev');
    });

    test('cross-block type-over: a snapshot replacing a selection spanning '
        'the joint merges via replacement', () {
      build([para('a', 'one'), para('b', 'two')]);
      controller.setSelection(
        DocSelection(
          base: const DocPosition('a', 1),
          extent: const DocPosition('b', 3),
        ),
      );
      expect(shadow().text, '. one\ntwo');

      sendValue('. ox', cursor: 4);

      expect(controller.document.allBlocks, hasLength(1));
      expect(controller.document.blockById('a')!.plainText, 'ox');
    });

    test('the post-terminate echo quarantine applies identically: undo '
        'mid-composition, the browser re-asserts the terminated text → '
        'dropped, document equals the undo snapshot', () {
      build([para('a', '')], selection: caret('a', 0));
      sendValue('. か', cursor: 3, composing: const TextRange(start: 2, end: 3));
      expect(controller.composing, isNotNull);

      controller.undo(); // terminate('undo'); quarantine = ('か', 2)
      expect(service.debugQuarantine, (text: 'か', offset: 2));

      // The browser's editable still holds the composed text and echoes a
      // commit-shaped snapshot against the freshly pushed window — the
      // diffed insertion matches the fresh shadow exactly, so the stale
      // guard is structurally blind to it.
      sendValue('. か', cursor: 3);

      expect(
        controller.document.blockById('a')!.plainText,
        '',
        reason: 'the echo is quarantined; undone text is not resurrected',
      );
      expect(service.debugLastDropReason, 'echoQuarantine');
      expect(service.debugQuarantineArmed, isFalse, reason: 'one batch');
    });

    test('a non-IME edit while a snapshot-mapped composition is live '
        'terminates through the choke point', () {
      build([para('a', '')], selection: caret('a', 0));
      sendValue('. か', cursor: 3, composing: const TextRange(start: 2, end: 3));
      expect(controller.composing, isNotNull);

      controller.insertText('!');

      expect(controller.composing, isNull);
      expect(service.debugLastTerminateReason, 'externalEdit');
      expect(connection().pushed.last.composing, TextRange.empty);
    });
  });

  group('composing mapping — the full-peer contract (§web fallback)', () {
    test('TextEditingValue.composing maps to ComposingState: −2 sentinel '
        'shift, block-local; nothing pushed mid-composition', () {
      build([para('a', 'ab')], selection: caret('a', 2));
      final pushesBefore = connection().pushed.length;

      sendValue(
        '. abか',
        cursor: 5,
        composing: const TextRange(start: 4, end: 5),
      );

      expect(
        controller.composing,
        const ComposingState(blockId: 'a', range: TextRange(start: 2, end: 3)),
      );
      expect(
        connection().pushed.length,
        pushesBefore,
        reason: '#1641: a push mid-composition restarts the composition',
      );
      expect(shadow().composing, const TextRange(start: 4, end: 5));
    });

    test('a composing-only value (text unchanged, range changed) is the '
        'NonTextUpdate analogue: acknowledged into the shadow, never '
        'echo-pushed', () {
      build([para('a', '')], selection: caret('a', 0));
      sendValue('. に', cursor: 3, composing: const TextRange(start: 2, end: 3));
      final pushesBefore = connection().pushed.length;

      // compositionupdate without a text change: the range alone moves.
      sendValue('. に', cursor: 2, composing: const TextRange(start: 2, end: 3));

      expect(connection().pushed.length, pushesBefore);
      expect(shadow().selection, const TextSelection.collapsed(offset: 2));
      expect(controller.composing, isNotNull);
    });

    test('a composing region set over pre-existing text (zero text change) '
        'never arms the G3 latch: ending it does not convert', () {
      build([para('a', '---')], selection: caret('a', 3));
      expect(shadow().text, '. ---');

      // The IME marks the existing dashes — text unchanged, composing set.
      sendValue(
        '. ---',
        cursor: 5,
        composing: const TextRange(start: 2, end: 5),
      );
      expect(controller.composing, isNotNull);

      // The composition ends with no edit: nothing to fire on (the
      // zero-edit rule-firing guard, identical to the delta path).
      sendValue('. ---', cursor: 5);

      expect(controller.composing, isNull);
      expect(
        controller.document.blockById('a')!.blockType,
        ParagraphKeys.type,
        reason: 'no spontaneous divider conversion',
      );
      expect(controller.document.blockById('a')!.plainText, '---');
    });

    test('the hardware-key composing gate sees the mapped state (full-peer '
        'check: controller.composing is live behind this frontend)', () {
      build([para('a', '')], selection: caret('a', 0));

      sendValue('. か', cursor: 3, composing: const TextRange(start: 2, end: 3));
      expect(controller.composing, isNotNull, reason: 'gate input is live');

      sendValue('. か', cursor: 3);
      expect(controller.composing, isNull, reason: 'commit clears it');
    });
  });

  group('the web CJK trace (exit criterion, G3-on-web)', () {
    test('Safari Japanese: compose にほん, convert via candidate to 日本, '
        'commit — composition tracked throughout, nothing pushed, one undo '
        'entry', () {
      build([para('a', '')], selection: caret('a', 0));
      final pushesBefore = connection().pushed.length;

      // Compose: full-value updates with composing ranges
      // (compositionstart/update).
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
      expect(controller.document.blockById('a')!.plainText, 'にほん');
      expect(
        controller.composing,
        const ComposingState(blockId: 'a', range: TextRange(start: 0, end: 3)),
      );

      // Convert via candidate: replacement of the composing text.
      sendValue(
        '. 日本',
        cursor: 4,
        composing: const TextRange(start: 2, end: 4),
      );
      expect(controller.document.blockById('a')!.plainText, '日本');
      expect(
        controller.composing,
        const ComposingState(blockId: 'a', range: TextRange(start: 0, end: 2)),
      );

      // Commit: composing cleared, text unchanged.
      sendValue('. 日本', cursor: 4);
      expect(controller.composing, isNull);
      expect(controller.document.blockById('a')!.plainText, '日本');
      expect(
        connection().pushed.length,
        pushesBefore,
        reason: 'the whole trace converged — nothing was ever pushed',
      );

      // Composition-scoped undo: one entry for the whole word.
      controller.undo();
      expect(controller.document.blockById('a')!.plainText, '');
    });

    test('"# " rule fire on commit (G3-on-web): the rule is deferred while '
        'composing and fires when the value clears the composing range', () {
      build([para('a', '')], selection: caret('a', 0));
      final pushesBefore = connection().pushed.length;

      // The IME composes "# " as marked text (full-width ＃ converted).
      sendValue('. #', cursor: 3, composing: const TextRange(start: 2, end: 3));
      sendValue(
        '. # ',
        cursor: 4,
        composing: const TextRange(start: 2, end: 4),
      );
      expect(
        controller.document.blockById('a')!.blockType,
        ParagraphKeys.type,
        reason: 'mid-composition, "# " is just composing text — deferred',
      );
      expect(
        controller.composing,
        const ComposingState(blockId: 'a', range: TextRange(start: 0, end: 2)),
      );
      expect(connection().pushed.length, pushesBefore, reason: 'no push');

      // Commit: the composing-cleared value is the latch-fire trigger.
      sendValue('. # ', cursor: 4);

      expect(controller.document.blockById('a')!.blockType, HeadingKeys.h1);
      expect(controller.document.blockById('a')!.plainText, '');
      expect(controller.selection, caret('a', 0));
      expect(
        connection().pushed.last.text,
        '. ',
        reason:
            'the rule transform re-serializes safely — nothing is composing',
      );
    });

    test('a replacement-commit (conversion and commit in one value: '
        'composing text replaced, composing cleared) fires the rules with '
        'the committed range', () {
      build([para('a', '')], selection: caret('a', 0));
      sendValue('. ＃', cursor: 3, composing: const TextRange(start: 2, end: 3));

      // The candidate commit replaces the marked ＃ with "# ", cleared.
      sendValue('. # ', cursor: 4);

      expect(controller.document.blockById('a')!.blockType, HeadingKeys.h1);
    });

    test('Safari dead-key shape (the v2 Safari fix, day-15 drip row): '
        'marked ´ replaced by é on the next keystroke', () {
      build([para('a', '')], selection: caret('a', 0));
      final pushesBefore = connection().pushed.length;

      // Option+E: Safari marks the accent (compositionstart).
      sendValue('. ´', cursor: 3, composing: const TextRange(start: 2, end: 3));
      expect(controller.document.blockById('a')!.plainText, '´');
      expect(
        controller.composing,
        const ComposingState(blockId: 'a', range: TextRange(start: 0, end: 1)),
        reason: 'the marked accent is composing — underlined, not committed',
      );

      // E: the marked ´ is replaced by the composed é and committed in one
      // value (compositionend).
      sendValue('. é', cursor: 3);

      expect(controller.document.blockById('a')!.plainText, 'é');
      expect(controller.composing, isNull);
      expect(connection().pushed.length, pushesBefore, reason: 'converged');

      // The next plain keystroke lands normally.
      sendValue('. éx', cursor: 4);
      expect(controller.document.blockById('a')!.plainText, 'éx');
    });
  });

  group('inspector surface (pane 3 honesty)', () {
    test('the last diff result is recorded for the inspector', () {
      build([para('a', 'hi')], selection: caret('a', 2));

      sendValue('. hix', cursor: 5);

      final diff = service.debugLastDiff;
      expect(diff, isNotNull);
      expect(diff!.start, 4);
      expect(diff.deletedLength, 0);
      expect(diff.insertedText, 'x');

      // A composing-only value records a null diff (no text change).
      sendValue(
        '. hix',
        cursor: 5,
        composing: const TextRange(start: 2, end: 5),
      );
      expect(service.debugLastDiff, isNull);

      // The synthesized batch feeds the same last-batch debug feed.
      expect(service.debugLastDeltas, hasLength(1));
      expect(
        service.debugLastDeltas!.single,
        isA<TextEditingDeltaNonTextUpdate>(),
      );
    });
  });
}
