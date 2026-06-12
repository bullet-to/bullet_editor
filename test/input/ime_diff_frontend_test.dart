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

    test('the diff frontend ignores a delta batch (the mirror of the delta '
        "frontend's updateEditingValue no-op)", () {
      build([para('a', 'hi')], selection: caret('a', 2));

      service.updateEditingValueWithDeltas([
        const TextEditingDeltaInsertion(
          oldText: '. hi',
          textInserted: 'x',
          insertionOffset: 4,
          selection: TextSelection.collapsed(offset: 5),
          composing: TextRange.empty,
        ),
      ]);

      expect(controller.document.blockById('a')!.plainText, 'hi');
      expect(connection().pushed, hasLength(1), reason: 'nothing happened');
    });

    test('a configuration whose delta declaration disagrees with the '
        'frontend asserts (the attach shape must match the callback the '
        'frontend listens on)', () {
      controller = EditorController(
        document: Document([para('a', 'hi')]),
        schema: EditorSchema.standard(),
      );
      expect(
        () => ImeService(
          controller: controller,
          frontend: ImeFrontend.nonDeltaDiff,
          // enableDeltaModel: true — the delta frontend's declaration.
          configuration: ImeService.defaultConfiguration,
          connectionFactory: (client, configuration) => FakeImeConnection(),
        ),
        throwsAssertionError,
      );
      expect(
        () => ImeService(
          controller: controller,
          frontend: ImeFrontend.delta,
          // enableDeltaModel: false — the diff frontend's declaration.
          configuration: ImeService.nonDeltaConfiguration,
          connectionFactory: (client, configuration) => FakeImeConnection(),
        ),
        throwsAssertionError,
      );
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

    test('selection-only snapshots do not consume the echo quarantine: the '
        'held-syllable recommit after two selectionchange batches is still '
        'dropped', () {
      build([para('a', 'ab')], selection: caret('a', 2));
      sendValue(
        '. abか',
        cursor: 5,
        composing: const TextRange(start: 4, end: 5),
      );
      expect(controller.composing, isNotNull);

      controller.undo(); // terminate('undo'); quarantine = ('か', 4)
      expect(service.debugQuarantine, (text: 'か', offset: 4));

      // Two DOM selectionchange snapshots (one batch each on web): pushless
      // NonTextUpdate analogues, not the user retyping — they must not burn
      // the one-batch quarantine budget before the echo arrives.
      sendValue('. ab', cursor: 3);
      sendValue('. ab', cursor: 4);
      expect(service.debugQuarantineArmed, isTrue);

      // The browser editable still holds the composed text and re-asserts
      // it commit-shaped against the freshly pushed window.
      sendValue('. abか', cursor: 5);

      expect(
        controller.document.blockById('a')!.plainText,
        'ab',
        reason: 'the recommit is quarantined; undone text never resurrects',
      );
      expect(service.debugLastDropReason, 'echoQuarantine');
      expect(service.debugQuarantineArmed, isFalse, reason: 'consumed');
    });

    test('pre-push race (the stale-guard analogue): a snapshot computed '
        'against the window a host-app edit just replaced is dropped and '
        'the authoritative window re-pushed, never applied as an edit', () {
      build([para('a', 'hello')], selection: caret('a', 5));
      expect(shadow().text, '. hello');

      // Host-app edit: clause (a) pushes the new window W2.
      controller.insertText('!');
      expect(shadow().text, '. hello!');
      final pushesAfterEdit = connection().pushed.length;

      // The browser's W1-shaped snapshot (computed before our push reached
      // the DOM) arrives. Diffed against W2 it would read as the user
      // deleting the host edit's '!'.
      sendValue('. hello', cursor: 7);

      expect(
        controller.document.blockById('a')!.plainText,
        'hello!',
        reason: 'the stale snapshot must not be applied as a deletion',
      );
      expect(service.debugLastDropReason, 'staleSnapshot');
      expect(
        connection().pushed.length,
        pushesAfterEdit + 1,
        reason: 'the authoritative window re-pushes (the guard recovery)',
      );
      expect(connection().pushed.last.text, '. hello!');

      // Legitimate input against the re-pushed window still lands.
      sendValue('. hello!x', cursor: 9);
      expect(controller.document.blockById('a')!.plainText, 'hello!x');
    });

    test('retype-what-you-just-deleted is NOT the pre-push race: once a '
        'post-push snapshot has been accepted the race window is closed, '
        'and a commit matching the replaced text lands as input', () {
      build([para('a', '')], selection: caret('a', 0));

      // Cycle 1: Option+E marks the accent, E commits é (the dead-key
      // shape — the easiest way to produce the signature, not the cause).
      sendValue('. ´', cursor: 3, composing: const TextRange(start: 2, end: 3));
      sendValue('. é', cursor: 3);
      expect(controller.document.blockById('a')!.plainText, 'é');

      // Hardware backspace: an external edit, clause (a) push of '. ' —
      // the replaced text '. é' arms the previous-shadow drop.
      controller.backspace();
      expect(shadow().text, '. ');

      // Option+E: the marked accent is accepted against the pushed window.
      // An accepted post-push snapshot proves the engine is working from
      // the fresh window — the pre-push race window is now closed.
      sendValue('. ´', cursor: 3, composing: const TextRange(start: 2, end: 3));
      expect(controller.composing, isNotNull);

      // E: the commit's text equals the pre-backspace '. é' — the drop's
      // false-positive signature. It is the user retyping what they just
      // deleted, never the stale race.
      sendValue('. é', cursor: 3);

      expect(
        controller.document.blockById('a')!.plainText,
        'é',
        reason: 'the recommit of just-deleted text is input, not the race',
      );
      expect(controller.composing, isNull);
      expect(service.debugLastDropReason, isNot('staleSnapshot'));
    });

    test('a stale-shaped snapshot carrying a live composing region is fresh '
        'marked text, never the race: a non-terminate push only happens '
        'with no live composition, so the replaced window was '
        'composing-free', () {
      build([para('a', '´')], selection: caret('a', 1));
      expect(shadow().text, '. ´');

      // External backspace deletes the stray ´: push of '. ', replaced
      // text '. ´' arms the drop.
      controller.backspace();
      expect(shadow().text, '. ');

      // Option+E immediately: the FIRST post-push snapshot matches the
      // replaced text exactly but carries a fresh composition — an
      // in-flight stale snapshot cannot, so it must not be dropped
      // (dropping it severs the browser's live composition).
      sendValue('. ´', cursor: 3, composing: const TextRange(start: 2, end: 3));

      expect(controller.document.blockById('a')!.plainText, '´');
      expect(
        controller.composing,
        const ComposingState(blockId: 'a', range: TextRange(start: 0, end: 1)),
      );
      expect(service.debugLastDropReason, isNot('staleSnapshot'));

      // The commit completes the dead-key cycle.
      sendValue('. é', cursor: 3);
      expect(controller.document.blockById('a')!.plainText, 'é');
      expect(controller.composing, isNull);
    });

    test('an out-of-range engine composing region is sanitized to empty — '
        'never a RangeError out of the shadow (the synthesis boundary is '
        'the trust boundary)', () {
      build([para('a', 'ab')], selection: caret('a', 2));

      // A malformed snapshot: the composing region runs past the text end.
      sendValue(
        '. abか',
        cursor: 5,
        composing: const TextRange(start: 4, end: 99),
      );

      expect(controller.document.blockById('a')!.plainText, 'abか');
      expect(
        controller.composing,
        isNull,
        reason:
            'a region the engine mis-reports is treated as no '
            'composition, not clamped into one',
      );
      expect(shadow().composing, TextRange.empty);

      // The next terminate-shaped path reads composing.textInside(shadow
      // .text) — the line a poisoned shadow would blow up.
      controller.insertText('!');
      expect(controller.document.blockById('a')!.plainText, 'abか!');
    });

    test('an emoji-variant swap snapshot (shared high surrogate) diffs as '
        'the whole pair — the document ends with 😁 intact, no mid-pair '
        'offsets', () {
      build([para('a', '😀')], selection: caret('a', 2));
      expect(shadow().text, '. 😀');

      // Same-length replacement sharing the high surrogate U+D83D:
      // 😀 (U+D83D,U+DE00) → 😁 (U+D83D,U+DE01).
      sendValue('. 😁', cursor: 4);

      expect(controller.document.blockById('a')!.plainText, '😁');
      final diff = service.debugLastDiff!;
      expect(diff.start, 2, reason: 'widened to the surrogate boundary');
      expect(diff.deletedLength, 2);
      expect(diff.insertedText, '😁');
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

    test("Safari's append-shaped dead-key commit (the v2 Safari fix, "
        'v0.1.7 / day-15 drip row): the commit snapshot APPENDS the '
        'resolved char after the still-marked ´ with composing unchanged — '
        'rewritten to the replace shape, composing cleared, engine '
        'resynced', () {
      build([para('a', '')], selection: caret('a', 0));

      // Option+E: Safari marks the accent (compositionstart).
      sendValue('. ´', cursor: 3, composing: const TextRange(start: 2, end: 3));
      expect(controller.document.blockById('a')!.plainText, '´');
      expect(
        controller.composing,
        const ComposingState(blockId: 'a', range: TextRange(start: 0, end: 1)),
      );

      // E: WebKit's append shape (the v2 fix's recorded trace — v0.1.7).
      // The DOM input event fires BEFORE compositionend, so the engine's
      // latched composingBase still reports (2,3) over the stale ´ while
      // the resolved é sits appended AFTER it.
      sendValue(
        '. ´é',
        cursor: 4,
        composing: const TextRange(start: 2, end: 3),
      );

      expect(
        controller.document.blockById('a')!.plainText,
        'é',
        reason:
            'the dead key must be replaced, not kept alongside the '
            'resolved char (the user-visible v2/Safari symptom)',
      );
      expect(
        controller.composing,
        isNull,
        reason: 'the appended char IS the commit — the underline clears',
      );
      expect(
        connection().pushed.last.text,
        '. é',
        reason:
            "the browser's DOM still holds the append-shaped text — "
            'the corrected window must be synced back (v2: '
            '_finalizeComposing)',
      );

      // Whether or not Safari follows up, the result converges (channel
      // order: anything computed before the resync push arrives first):
      // (a) a late append-shaped snapshot (computed before the resync push
      // reached the DOM, composing now cleared at compositionend) is the
      // stale race shape — dropped, never re-applied as an insertion of
      // the stale ´;
      sendValue('. ´é', cursor: 4);
      expect(
        controller.document.blockById('a')!.plainText,
        'é',
        reason:
            'idempotent under the corrective: the stale append shape '
            'must not resurrect the dead key',
      );
      expect(controller.composing, isNull);
      expect(service.debugLastDropReason, 'staleSnapshot');
      // (b) an echo of OUR corrected push is acknowledged silently.
      sendValue('. é', cursor: 3);
      expect(controller.document.blockById('a')!.plainText, 'é');

      // Follow-up typing lands clean.
      sendValue('. éx', cursor: 4);
      expect(controller.document.blockById('a')!.plainText, 'éx');
      sendValue('. éxy', cursor: 5);
      expect(controller.document.blockById('a')!.plainText, 'éxy');
    });

    test('kana growth is NOT the append-shaped commit: a composing region '
        'that grows to cover the appended character stays a composition '
        '(the CJK non-misfire edge)', () {
      build([para('a', '')], selection: caret('a', 0));
      sendValue('. に', cursor: 3, composing: const TextRange(start: 2, end: 3));
      final pushesBefore = connection().pushed.length;

      // The next kana appends AT the old composing end — the same insert
      // offset as the dead-key shape — but the engine's composing region
      // grew to (2,4) to cover it: the engine itself says the new char is
      // part of the composition, so it must NOT collapse into a commit.
      sendValue(
        '. にほ',
        cursor: 4,
        composing: const TextRange(start: 2, end: 4),
      );

      expect(controller.document.blockById('a')!.plainText, 'にほ');
      expect(
        controller.composing,
        const ComposingState(blockId: 'a', range: TextRange(start: 0, end: 2)),
        reason: 'the composition continues — both kana stay marked',
      );
      expect(
        connection().pushed.length,
        pushesBefore,
        reason: 'no commit ⇒ no resync push — nothing mid-composition',
      );

      // The composition still commits normally afterwards.
      sendValue('. にほ', cursor: 4);
      expect(controller.composing, isNull);
      expect(controller.document.blockById('a')!.plainText, 'にほ');
    });

    test("the rewrite's follow-up (the stuck-IME Safari bug): the engine's "
        'composition latch outlives the commit, so post-commit snapshots '
        'still carry the dead range — refused, never re-armed: the '
        'underline stays cleared and the next keystrokes land as plain '
        'inserts, not the é→e replacement', () {
      build([para('a', '')], selection: caret('a', 0));

      // The dead-key commit (the append-shaped fixture's first half).
      sendValue('. ´', cursor: 3, composing: const TextRange(start: 2, end: 3));
      sendValue(
        '. ´é',
        cursor: 4,
        composing: const TextRange(start: 2, end: 3),
      );
      expect(controller.document.blockById('a')!.plainText, 'é');
      expect(controller.composing, isNull);
      expect(connection().pushed.last.text, '. é');

      // What Safari sends next (engine source:
      // composition_aware_mixin.dart): composingText/composingBase reset
      // ONLY at compositionstart/end, and nothing we push fires a
      // composition event — so until a real compositionend every
      // handleChange-driven snapshot still reports the dead (2,3).
      //
      // (1) The late append-shaped snapshot (computed before the resync
      // push reached the DOM) — STILL composing-latched: the stale race
      // shape. With the dead latch refused it falls to the previous-shadow
      // drop instead of being applied as fresh marked text.
      sendValue(
        '. ´é',
        cursor: 4,
        composing: const TextRange(start: 2, end: 3),
      );
      expect(
        controller.document.blockById('a')!.plainText,
        'é',
        reason:
            'the stale append shape must not resurrect the dead key — '
            'with or without the latched composing region riding along',
      );
      expect(controller.composing, isNull);
      expect(service.debugLastDropReason, 'staleSnapshot');

      // (2) The resync push's own selectionchange echo: text and selection
      // match the pushed window exactly, composing still the dead (2,3).
      // This must NOT synthesize a NonTextUpdate that re-arms
      // ComposingState over the committed é — the stuck underline.
      sendValue('. é', cursor: 3, composing: const TextRange(start: 2, end: 3));
      expect(
        controller.composing,
        isNull,
        reason: 'the composing-only re-arm of a terminated range is refused',
      );
      expect(controller.document.blockById('a')!.plainText, 'é');

      // (3) E: a plain insert at the caret, composing STILL latched at the
      // dead (2,3) — the rewrite must not fire again (the observed é→e
      // replacement: the user "pressing E replaces the é with a plain e").
      sendValue(
        '. ée',
        cursor: 4,
        composing: const TextRange(start: 2, end: 3),
      );
      expect(
        controller.document.blockById('a')!.plainText,
        'ée',
        reason: 'a plain insert, never a second dead-key rewrite',
      );
      expect(controller.composing, isNull);

      // (4) Continued typing under the still-latched range keeps working.
      sendValue(
        '. ées',
        cursor: 5,
        composing: const TextRange(start: 2, end: 3),
      );
      expect(controller.document.blockById('a')!.plainText, 'ées');
      expect(controller.composing, isNull);

      // (5) Safari's compositionend corrective (composing finally cleared)
      // converges silently — and the flow above already converged without
      // it.
      final pushesBefore = connection().pushed.length;
      sendValue('. ées', cursor: 5);
      expect(controller.document.blockById('a')!.plainText, 'ées');
      expect(controller.composing, isNull);
      expect(connection().pushed.length, pushesBefore, reason: 'silent');
    });

    test('a genuine immediate re-composition is NOT suppressed: Option+E '
        'right after the commit re-latches the engine base at the caret — '
        'fresh numbers, a live composition that commits normally', () {
      build([para('a', '')], selection: caret('a', 0));
      sendValue('. ´', cursor: 3, composing: const TextRange(start: 2, end: 3));
      sendValue(
        '. ´é',
        cursor: 4,
        composing: const TextRange(start: 2, end: 3),
      );
      expect(controller.document.blockById('a')!.plainText, 'é');
      // The post-commit stale echo (the refusal armed and exercised).
      sendValue('. é', cursor: 3, composing: const TextRange(start: 2, end: 3));
      expect(controller.composing, isNull);

      // Option+E again at the caret: compositionstart reset the engine
      // latch and the new ´ re-latched at base = extent − 1 = 3
      // (composition_aware_mixin.dart) — a different range, live by
      // construction.
      sendValue(
        '. é´',
        cursor: 4,
        composing: const TextRange(start: 3, end: 4),
      );
      expect(controller.document.blockById('a')!.plainText, 'é´');
      expect(
        controller.composing,
        const ComposingState(blockId: 'a', range: TextRange(start: 1, end: 2)),
        reason: 'the fresh composition composes — the refusal must not eat it',
      );

      // The new composition commits through the same append-shaped rewrite.
      sendValue(
        '. é´é',
        cursor: 5,
        composing: const TextRange(start: 3, end: 4),
      );
      expect(controller.document.blockById('a')!.plainText, 'éé');
      expect(controller.composing, isNull);
    });

    test('a fresh composition re-latched over the SAME numbers is honored: '
        'caret placed before the é, Option+E marks a new ´ at (2,3) — a '
        'text change ending at the caret is a live compositionupdate, not '
        'the dead latch', () {
      build([para('a', '')], selection: caret('a', 0));
      sendValue('. ´', cursor: 3, composing: const TextRange(start: 2, end: 3));
      sendValue(
        '. ´é',
        cursor: 4,
        composing: const TextRange(start: 2, end: 3),
      );
      expect(controller.document.blockById('a')!.plainText, 'é');

      // Click before the é while the engine latch persists: a
      // selectionchange snapshot, composing still the dead (2,3) —
      // refused, the caret still applies.
      sendValue('. é', cursor: 2, composing: const TextRange(start: 2, end: 3));
      expect(controller.composing, isNull);
      expect(controller.selection, caret('a', 0));

      // Option+E at offset 2: compositionstart reset the engine latch and
      // the new ´ re-latched at base = extent − 1 = 2 — the dead range's
      // exact numbers, but over a NEW ´ (text changed, region ends at the
      // caret: the live-compositionupdate shape).
      sendValue(
        '. ´é',
        cursor: 3,
        composing: const TextRange(start: 2, end: 3),
      );
      expect(controller.document.blockById('a')!.plainText, '´é');
      expect(
        controller.composing,
        const ComposingState(blockId: 'a', range: TextRange(start: 0, end: 1)),
        reason: 'same numbers, genuinely fresh — must compose, not suppress',
      );

      // The new composition commits (the append shape again).
      sendValue(
        '. ´éé',
        cursor: 4,
        composing: const TextRange(start: 2, end: 3),
      );
      expect(controller.document.blockById('a')!.plainText, 'éé');
      expect(controller.composing, isNull);
    });

    test("Safari's late compositionend corrective (composing cleared, text "
        'unchanged) converges silently and disarms the refusal', () {
      build([para('a', '')], selection: caret('a', 0));
      sendValue('. ´', cursor: 3, composing: const TextRange(start: 2, end: 3));
      sendValue(
        '. ´é',
        cursor: 4,
        composing: const TextRange(start: 2, end: 3),
      );
      // The stale echo first (the refusal is live).
      sendValue('. é', cursor: 3, composing: const TextRange(start: 2, end: 3));
      expect(controller.composing, isNull);
      final pushesBefore = connection().pushed.length;

      // compositionend finally reflects: the composing-cleared echo.
      sendValue('. é', cursor: 3);
      expect(controller.document.blockById('a')!.plainText, 'é');
      expect(controller.composing, isNull);
      expect(connection().pushed.length, pushesBefore, reason: 'silent');

      // Plain typing continues clean.
      sendValue('. éx', cursor: 4);
      expect(controller.document.blockById('a')!.plainText, 'éx');
    });

    test('dead-key double cycle (the day-8 web bug): compose+commit é, '
        'hardware backspace, compose+commit é again — the second commit '
        'lands and plain typing afterwards still works', () {
      build([para('a', '')], selection: caret('a', 0));

      // Cycle 1.
      sendValue('. ´', cursor: 3, composing: const TextRange(start: 2, end: 3));
      sendValue('. é', cursor: 3);
      expect(controller.document.blockById('a')!.plainText, 'é');
      expect(controller.composing, isNull);

      // Hardware backspace removes the é (an external edit + push).
      controller.backspace();
      expect(controller.document.blockById('a')!.plainText, '');
      expect(shadow().text, '. ');

      // Cycle 2: identical keystrokes — the commit snapshot's text equals
      // the text the backspace push replaced, the drop's false-positive
      // signature.
      sendValue('. ´', cursor: 3, composing: const TextRange(start: 2, end: 3));
      expect(
        controller.composing,
        const ComposingState(blockId: 'a', range: TextRange(start: 0, end: 1)),
        reason: 'the marked accent is composing — underlined, not committed',
      );
      sendValue('. é', cursor: 3);

      expect(controller.document.blockById('a')!.plainText, 'é');
      expect(controller.composing, isNull);

      // Typing afterwards must not "get funky": the shadow and the engine
      // agree, so plain keystrokes land as ordinary insertions.
      sendValue('. éx', cursor: 4);
      expect(controller.document.blockById('a')!.plainText, 'éx');
      sendValue('. éxy', cursor: 5);
      expect(controller.document.blockById('a')!.plainText, 'éxy');
    });
  });

  group("WebKit's range-selection-over-composing snapshots (the Safari "
      'Japanese capture)', () {
    test('a composing snapshot whose selection is the composing RANGE '
        'survives: no terminate, nothing pushed, the engine selection '
        'honored as a model range', () {
      build([para('a', '')], selection: caret('a', 0));
      final pushesBefore = connection().pushed.length;

      // The captured seq-6 shape (Safari, Japanese romaji 'n'): the first
      // composing snapshot transiently reports the marked text as SELECTED
      // — selection == composing, a non-collapsed range. The applied
      // insertion leaves a collapsed model caret, so the batch-end
      // selection comparison diverges — but nothing structural happened:
      // terminating here de-marks Safari's live composition and every
      // later compositionupdate INSERTS instead of replacing (the
      // "nににhにほ…" accumulation).
      sendValue(
        '. n',
        cursor: 3,
        cursorBase: 2,
        composing: const TextRange(start: 2, end: 3),
      );

      expect(controller.document.blockById('a')!.plainText, 'n');
      expect(service.debugLastTerminateReason, isNull);
      expect(
        controller.composing,
        const ComposingState(blockId: 'a', range: TextRange(start: 0, end: 1)),
        reason: 'the composition survives the transient range selection',
      );
      expect(
        connection().pushed.length,
        pushesBefore,
        reason: '#1641: a push mid-composition restarts the composition',
      );
      // The engine's selection is adopted verbatim (a range within the
      // marked text is a legal model selection — see _finishBatch's
      // adoption rule for why range-over-collapse keeps the no-echo triple
      // genuinely convergent).
      expect(
        controller.selection,
        DocSelection(
          base: const DocPosition('a', 0),
          extent: const DocPosition('a', 1),
        ),
      );

      // The composition continues as marked-text replacement (what Safari
      // sends once the composition was never de-marked) and converges.
      sendValue('. に', cursor: 3, composing: const TextRange(start: 2, end: 3));
      expect(controller.document.blockById('a')!.plainText, 'に');
      expect(controller.composing, isNotNull);
      expect(connection().pushed.length, pushesBefore);
    });

    test('the structural rule still fires when the selection ESCAPES the '
        'composing region (text converged, selection outside the marked '
        'text is NOT the WebKit transient)', () {
      build([para('a', 'abc')], selection: caret('a', 3));
      expect(shadow().text, '. abc');

      // A composing insertion whose snapshot selection lands outside the
      // marked range — unexplained mid-composition, the G10 shape.
      service.updateEditingValue(
        const TextEditingValue(
          text: '. abcか',
          selection: TextSelection(baseOffset: 2, extentOffset: 4),
          composing: TextRange(start: 5, end: 6),
        ),
      );

      expect(controller.document.blockById('a')!.plainText, 'abcか');
      expect(service.debugLastTerminateReason, 'structuralDelta');
      expect(controller.composing, isNull);
      expect(connection().pushed.last.composing, TextRange.empty);
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
