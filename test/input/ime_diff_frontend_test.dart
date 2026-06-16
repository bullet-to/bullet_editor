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

  /// The most recent `staleComposingLatchDisarmed` journal payload — the
  /// disarm-decision record a live capture keys on (fresh vs corrective vs
  /// different-range); null when no disarm was journaled.
  Map<String, Object?>? lastLatchDisarm() {
    for (final e in service.journal.events.reversed) {
      if (e.kind == 'staleComposingLatchDisarmed') return e.payload;
    }
    return null;
  }

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
        'is birth-suppressed — it never arms, so ending it can never '
        'convert (the G3 zero-edit guard, now structural)', () {
      // Adjudication note: this fixture previously honored the
      // text-unchanged decoration as a composition (asserting only that
      // the G3 latch never armed from it). Under the composing-birth
      // invariant a composition cannot be BORN from a no-text-change
      // snapshot while shadow composing is empty: on web the only source
      // of this shape is the engine's stale composition latch (the
      // captured Chrome blur-return re-arm) — every genuine
      // compositionstart/update changes text. The protection the test
      // existed for (no spontaneous rule fire on a zero-edit "commit")
      // holds a fortiori: the region never enters the model at all.
      build([para('a', '---')], selection: caret('a', 3));
      expect(shadow().text, '. ---');

      // The engine decorates an unchanged window — text unchanged,
      // composing set, shadow composing empty: the dead-latch shape.
      sendValue(
        '. ---',
        cursor: 5,
        composing: const TextRange(start: 2, end: 5),
      );
      expect(
        controller.composing,
        isNull,
        reason: 'composing is only born from a text-changing snapshot',
      );
      expect(shadow().composing, TextRange.empty);
      final suppression = service.journal.events.lastWhere(
        (e) => e.kind == 'composingBirthSuppressed',
      );
      expect(suppression.payload, {
        'range': [2, 5],
      });

      // The decoration clearing again is a silent no-op.
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

  group('the composing-birth invariant (§web fallback: composing is only '
      'born from a text-changing snapshot)', () {
    test('a text-unchanged snapshot cannot arm composing from an empty '
        'shadow (the Chrome blur-return stale decoration): filtered, '
        'journaled, pure echo — the gate inputs stay open', () {
      // The engine's composition latch (composition_aware_mixin) survives
      // blur/connectionClosed/re-attach and decorates the re-pushed
      // window's echo with the dead range; honoring it re-armed shadow
      // composing and closed the hardware-key gate on a phantom
      // composition (the captured journal). Every GENUINE composition's
      // first snapshot changes text, so this shape can never be a birth.
      build([para('a', 'に')], selection: caret('a', 1));
      expect(shadow().text, '. に');
      final pushesBefore = connection().pushed.length;

      sendValue('. に', cursor: 3, composing: const TextRange(start: 2, end: 3));

      expect(controller.composing, isNull);
      expect(shadow().composing, TextRange.empty);
      expect(service.engineComposing, isFalse, reason: 'the gate stays open');
      expect(connection().pushed.length, pushesBefore, reason: 'no echo push');
      final suppression = service.journal.events.lastWhere(
        (e) => e.kind == 'composingBirthSuppressed',
      );
      expect(suppression.payload, {
        'range': [2, 3],
      });
    });

    test('a text-unchanged decorated snapshot that MOVES the selection '
        'still applies the move — only the composing decoration is '
        'filtered (the NonTextUpdate keeps its selection half)', () {
      build([para('a', 'ab')], selection: caret('a', 2));

      sendValue(
        '. ab',
        cursor: 3,
        composing: const TextRange(start: 2, end: 4),
      );

      expect(controller.composing, isNull);
      expect(controller.selection, caret('a', 1));
      expect(shadow().selection, const TextSelection.collapsed(offset: 3));
      expect(shadow().composing, TextRange.empty);
    });

    test('negative control: a text-CHANGING snapshot with a live region '
        'arms composing normally — a real compositionstart/update '
        '(the full-peer CJK shapes are unaffected)', () {
      // The broader negative-control coverage is the existing CJK suite:
      // 'TextEditingValue.composing maps to ComposingState', the web CJK
      // trace (compose にほん → convert → commit), and the dead-key shapes.
      build([para('a', '')], selection: caret('a', 0));

      sendValue('. か', cursor: 3, composing: const TextRange(start: 2, end: 3));

      expect(
        controller.composing,
        const ComposingState(blockId: 'a', range: TextRange(start: 0, end: 1)),
      );
      expect(
        service.journal.events.any((e) => e.kind == 'composingBirthSuppressed'),
        isFalse,
      );
    });

    test('composing-only updates during a LIVE composition keep working '
        '(candidate navigation / the NonTextUpdate analogue): the '
        'invariant only gates BIRTH, never a live region move', () {
      build([para('a', '')], selection: caret('a', 0));
      sendValue('. に', cursor: 3, composing: const TextRange(start: 2, end: 3));
      expect(controller.composing, isNotNull);

      // The region moves with no text change — live, must pass.
      sendValue('. に', cursor: 2, composing: const TextRange(start: 2, end: 3));

      expect(controller.composing, isNotNull);
      expect(shadow().composing, const TextRange(start: 2, end: 3));
      expect(
        service.journal.events.any((e) => e.kind == 'composingBirthSuppressed'),
        isFalse,
      );

      // And the live→empty commit still clears it.
      sendValue('. に', cursor: 3);
      expect(controller.composing, isNull);
    });
  });

  group('the sub-sentinel selection invariant (the Safari blur reset: a '
      'snapshot selection starting inside [0, 2) is browser bookkeeping, '
      'never input)', () {
    List<Object?> suppressions() => [
      for (final e in service.journal.events)
        if (e.kind == 'sentinelSelectionSuppressed') e.payload['sel'],
    ];

    test('a collapsed [0,0] on a text-unchanged snapshot is ignored — the '
        'model caret stays put — while the composing live→empty clear '
        'still processes (the captured Safari blur shape)', () {
      build([para('a', 'hi')], selection: caret('a', 2));
      sendValue(
        '. hiら',
        cursor: 5,
        composing: const TextRange(start: 4, end: 5),
      );
      expect(controller.composing, isNotNull);
      final pushesBefore = connection().pushed.length;

      // Safari blur: compositionend reflected + the DOM selection reset.
      sendValue('. hiら', cursor: 0);

      expect(suppressions(), [
        [0, 0],
      ]);
      expect(controller.selection, caret('a', 3), reason: 'caret preserved');
      expect(controller.composing, isNull, reason: 'the clear still lands');
      expect(shadow().composing, TextRange.empty);
      expect(service.debugCommitKeySuppressionArmed, isTrue);
      // The corrective push re-teaches the DOM the PRESERVED caret — the
      // bug was this push carrying the sentinel-clamped [2,2].
      expect(connection().pushed.length, pushesBefore + 1);
      expect(
        connection().pushed.last.selection,
        const TextSelection.collapsed(offset: 5),
      );
    });

    test('a RANGE whose start is in-zone but extent beyond ([0,3]) is the '
        'same artifact family: ignored, journaled, and the preserved '
        'window re-pushed', () {
      // No pushed window ever anchors inside the sentinel, so honoring a
      // clamped half would fabricate a selection the user never made.
      build([para('a', 'hello')], selection: caret('a', 5));
      final pushesBefore = connection().pushed.length;

      sendValue('. hello', cursor: 3, cursorBase: 0);

      expect(suppressions(), [
        [0, 3],
      ]);
      expect(controller.selection, caret('a', 5), reason: 'caret preserved');
      expect(connection().pushed.length, pushesBefore + 1);
      expect(
        connection().pushed.last.selection,
        const TextSelection.collapsed(offset: 7),
      );
      expect(shadow().selection, const TextSelection.collapsed(offset: 7));
    });

    test('negative control: a selection at [2,2] (the true block start) is '
        'honored normally — the NonTextUpdate analogue', () {
      build([para('a', 'hello')], selection: caret('a', 5));
      final pushesBefore = connection().pushed.length;

      sendValue('. hello', cursor: 2);

      expect(suppressions(), isEmpty);
      expect(controller.selection, caret('a', 0));
      expect(shadow().selection, const TextSelection.collapsed(offset: 2));
      expect(connection().pushed.length, pushesBefore, reason: 'no echo');
    });

    test('text-CHANGING snapshots are exempt: a sub-sentinel selection on '
        'an edit rides into the shadow untouched (G1 sentinel-consuming '
        "shapes — backspace at block start's [1,1], the composite "
        "delete's [0,0] — are genuine), a text delta's selection never "
        'drives the model, and the batch-end reconcile re-pushes the '
        'post-edit caret', () {
      build([para('a', 'hello')], selection: caret('a', 5));

      sendValue('. helloX', cursor: 0);

      expect(suppressions(), isEmpty);
      expect(controller.document.blockById('a')!.plainText, 'helloX');
      expect(controller.selection, caret('a', 6));
      expect(
        connection().pushed.last.selection,
        const TextSelection.collapsed(offset: 8),
      );
      expect(shadow().selection, const TextSelection.collapsed(offset: 8));
    });
  });

  group('the performAction guard (engine-owned compositions)', () {
    test("performAction(newline) is ignored while the shadow reports a "
        'live composition: no model edit, no push, journaled — the '
        'genuine commit newline arrives via snapshot (G10)', () {
      build([para('a', 'ab')], selection: caret('a', 2));
      sendValue(
        '. abか',
        cursor: 5,
        composing: const TextRange(start: 4, end: 5),
      );
      expect(controller.composing, isNotNull);
      final pushesBefore = connection().pushed.length;

      service.performAction(TextInputAction.newline);

      expect(controller.document.allBlocks, hasLength(1), reason: 'no split');
      expect(controller.document.blockById('a')!.plainText, 'abか');
      expect(controller.composing, isNotNull, reason: 'composition intact');
      expect(connection().pushed.length, pushesBefore, reason: 'no push');
      final suppression = service.journal.events.lastWhere(
        (e) => e.kind == 'performActionSuppressed',
      );
      expect(suppression.payload, {'action': 'newline'});
    });

    test('performAction(newline) is ignored while the passive window is '
        'armed (the captured deferred-Enter-reaching-the-DOM fallout: '
        'seq 35 edited the model mid-divergence)', () {
      build([para('a', 'one')], selection: caret('a', 3));
      sendValue(
        '. oneか',
        cursor: 6,
        composing: const TextRange(start: 5, end: 6),
      );
      // The unmappable structural shape arms the deferred reconciliation.
      sendValue(
        '. oneか\nx',
        cursor: 8,
        composing: const TextRange(start: 5, end: 8),
      );
      expect(service.engineComposing, isTrue);
      final blocksBefore = [
        for (final b in controller.document.allBlocks) b.plainText,
      ];
      final pushesBefore = connection().pushed.length;

      service.performAction(TextInputAction.newline);

      expect(
        [for (final b in controller.document.allBlocks) b.plainText],
        blocksBefore,
        reason: 'no model edit while the engine owns the composition',
      );
      expect(connection().pushed.length, pushesBefore);
      expect(
        service.journal.events.any((e) => e.kind == 'performActionSuppressed'),
        isTrue,
      );
    });

    test('performAction(newline) with no composition still splits (the '
        'guard is scoped to engine-owned compositions only)', () {
      build([para('a', 'onetwo')], selection: caret('a', 3));

      service.performAction(TextInputAction.newline);
      service.flushPendingNewline();

      expect(controller.document.allBlocks, hasLength(2));
      expect(
        service.journal.events.any((e) => e.kind == 'performActionSuppressed'),
        isFalse,
      );
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
      expect(
        lastLatchDisarm(),
        {
          'reason': 'differentRange',
          'range': [3, 4],
        },
        reason: 'the disarm decision is journaled for live captures',
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
      expect(
        lastLatchDisarm(),
        {'reason': 'fresh'},
        reason:
            'the ambiguous same-range disarm is journaled (see '
            '_filterStaleComposing: this shape is indistinguishable from a '
            'plain char typed just before the dead range)',
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
      expect(
        lastLatchDisarm(),
        {'reason': 'corrective'},
        reason: 'the disarm decision is journaled for live captures',
      );

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

    test('a selection ESCAPING the composing region (text converged) is '
        'absorbed, not terminated: the engine selection is adopted one-way '
        'and the composition survives — the diff frontend is passive while '
        'the browser owns a live composition (§web fallback)', () {
      // Adjudication note: this fixture previously asserted
      // terminateComposition('structuralDelta') — the delta frontend's G10
      // divergence rule applied reactively to a snapshot. Under the
      // passive-while-composing invariant a snapshot-shaped surprise must
      // never write to the browser mid-composition (the engine cannot
      // re-mark text; the viaTerminate push IS the #1641 corruption), so
      // the shape is absorbed instead. The delta frontend keeps the
      // terminating rule (ime_service_test §structural-while-composing).
      build([para('a', 'abc')], selection: caret('a', 3));
      expect(shadow().text, '. abc');
      final pushesBefore = connection().pushed.length;

      // A composing insertion whose snapshot selection lands outside the
      // marked range — unexplained mid-composition.
      service.updateEditingValue(
        const TextEditingValue(
          text: '. abcか',
          selection: TextSelection(baseOffset: 2, extentOffset: 4),
          composing: TextRange(start: 5, end: 6),
        ),
      );

      expect(controller.document.blockById('a')!.plainText, 'abcか');
      expect(service.debugLastTerminateReason, isNull);
      expect(
        controller.composing,
        const ComposingState(blockId: 'a', range: TextRange(start: 3, end: 4)),
        reason: 'the composition is kept — nothing may de-mark the browser',
      );
      expect(
        controller.selection,
        DocSelection(
          base: const DocPosition('a', 0),
          extent: const DocPosition('a', 2),
        ),
        reason: 'the engine selection is honored one-way into the model',
      );
      expect(
        connection().pushed.length,
        pushesBefore,
        reason: 'no push of any kind while the composition is live',
      );

      // The composition still commits normally afterwards.
      sendValue('. abcか', cursor: 6);
      expect(controller.composing, isNull);
      expect(controller.document.blockById('a')!.plainText, 'abcか');
    });
  });

  group('passive-while-composing — deferred reconciliation '
      '(§web fallback)', () {
    test('an unmappable mid-composition snapshot (structural shape) defers: '
        'no push, no terminate while the composition lives; the snapshot '
        'ending the composition runs the ONE authoritative push', () {
      build([para('a', 'one')], selection: caret('a', 3));
      sendValue(
        '. oneか',
        cursor: 6,
        composing: const TextRange(start: 5, end: 6),
      );
      expect(controller.composing, isNotNull);
      final pushesBefore = connection().pushed.length;

      // A \n lands mid-composition with the composing region GROWING over
      // it (should be impossible from a browser composition — guarded
      // anyway): the split moves the window away from the engine's buffer
      // and the composing range stops mapping into one block. The old rule
      // fired terminateComposition('structuralDelta') — a mid-flight push.
      // (The region must differ from the shadow's: an unchanged region with
      // an insert at its end is the dead-key append-commit shape, which the
      // rewrite deliberately owns.)
      sendValue(
        '. oneか\nx',
        cursor: 8,
        composing: const TextRange(start: 5, end: 8),
      );

      expect(service.debugLastTerminateReason, isNull);
      expect(
        connection().pushed.length,
        pushesBefore,
        reason: 'no push while the browser composition is live',
      );
      expect(
        controller.composing,
        isNotNull,
        reason: 'the composition is kept — the gate stays closed',
      );
      // The snapshot's text applied one-way into the model.
      final blocks = controller.document.allBlocks;
      expect(blocks, hasLength(2));
      expect(blocks[0].plainText, 'oneか');
      expect(blocks[1].plainText, 'x');

      // While diverged, further composing snapshots acknowledge one-way
      // into the shadow WITHOUT model application: the window mapping no
      // longer matches the engine buffer, and mapping through it would
      // corrupt.
      sendValue(
        '. oneか\nxや',
        cursor: 9,
        composing: const TextRange(start: 5, end: 9),
      );
      expect(connection().pushed.length, pushesBefore);
      expect(shadow().text, '. oneか\nxや');
      expect(controller.document.allBlocks[1].plainText, 'x');
      expect(service.debugLastTerminateReason, isNull);

      // The composition-ending snapshot (live→empty) reconciles: the model
      // is the authority and the ONE push happens now — after the
      // composition is over, when pushing is safe.
      sendValue('. oneか\nxや', cursor: 9);

      expect(controller.composing, isNull);
      expect(connection().pushed.length, pushesBefore + 1);
      expect(connection().pushed.last.text, '. x');
      expect(connection().pushed.last.composing, TextRange.empty);
      expect(
        service.debugLastTerminateReason,
        isNull,
        reason: 'a reconciliation push, not a termination',
      );
    });

    test('the passive reconcile is journaled with what was discarded vs '
        'pushed, and the push is protected against in-flight snapshots '
        'still decorated with the absorbed engine composing range: refused '
        'via the stale-composing latch, dropped as the pre-push race — '
        'never applied, never re-arming the underline', () {
      build([para('a', 'one')], selection: caret('a', 3));
      sendValue(
        '. oneか',
        cursor: 6,
        composing: const TextRange(start: 5, end: 6),
      );
      // Arm the deferred divergence, then let the composition end.
      sendValue(
        '. oneか\nx',
        cursor: 8,
        composing: const TextRange(start: 5, end: 8),
      );
      sendValue(
        '. oneか\nxや',
        cursor: 9,
        composing: const TextRange(start: 5, end: 9),
      );
      sendValue('. oneか\nxや', cursor: 9); // live→empty: the reconcile push

      // Finding the discard in a live capture requires the payload: the
      // absorbed engine window vs the authoritative one that replaced it.
      final reconcile = service.journal.events.lastWhere(
        (e) => e.kind == 'passiveReconcile',
      );
      expect(reconcile.payload['discardedText'], '. oneか\nxや');
      expect(reconcile.payload['discardedComposing'], [5, 9]);
      expect(reconcile.payload['pushedText'], '. x');
      expect(reconcile.payload['pushedSelection'], [3, 3]);

      // The reconcile push replaced a mid-composition engine window, so it
      // arms the same in-flight protection the dead-key rewrite gets: the
      // absorbed range is a dead engine latch until proven otherwise.
      expect(
        service.debugStaleComposingLatch,
        const TextRange(start: 5, end: 9),
      );
      final blocksBefore = [
        for (final b in controller.document.allBlocks) b.plainText,
      ];

      // A late snapshot computed against the replaced engine buffer, still
      // decorated with the absorbed range (the engine's composition
      // bookkeeping raced the push): the latch strips the dead region, and
      // the stripped snapshot is the pre-push race shape exactly.
      sendValue(
        '. oneか\nxや',
        cursor: 5,
        composing: const TextRange(start: 5, end: 9),
      );

      expect(service.debugLastDropReason, 'staleSnapshot');
      expect(
        [for (final b in controller.document.allBlocks) b.plainText],
        blocksBefore,
        reason: 'the stale decorated snapshot must never be applied',
      );
      expect(
        controller.composing,
        isNull,
        reason: 'the dead range must not re-arm the underline',
      );
    });

    test('passive-exit-on-region-replacement (the captured Chrome cascade, '
        'seq 42): the absorbed region replaced by one with a different '
        'start reconciles like live→empty — the new composition proceeds '
        'against the fresh window instead of being absorbed into the '
        'void', () {
      build([para('a', 'one')], selection: caret('a', 3));
      sendValue(
        '. oneか',
        cursor: 6,
        composing: const TextRange(start: 5, end: 6),
      );
      // Arm the deferred divergence (the unmappable structural shape).
      sendValue(
        '. oneか\nx',
        cursor: 8,
        composing: const TextRange(start: 5, end: 8),
      );
      expect(service.engineComposing, isTrue);
      final pushesBefore = connection().pushed.length;

      // The engine reports a NEW composition: a live region whose START
      // moved off the absorbed one (composingBase is reset only by
      // compositionstart — within one composition the start is fixed).
      // The absorbed composition objectively ended; the old behavior kept
      // absorbing one-way and the new composition's keystrokes vanished
      // (the capture's lost d/だ).
      sendValue(
        '. oneか\nxd',
        cursor: 9,
        composing: const TextRange(start: 8, end: 9),
      );

      expect(service.engineComposing, isFalse, reason: 'passive resolved');
      expect(controller.composing, isNull);
      expect(connection().pushed.length, pushesBefore + 1);
      expect(connection().pushed.last.composing, TextRange.empty);
      final reconcile = service.journal.events.lastWhere(
        (e) => e.kind == 'passiveReconcile',
      );
      expect(reconcile.payload['trigger'], 'regionReplaced');
      expect(reconcile.payload['discardedText'], '. oneか\nxd');
      expect(reconcile.payload['discardedComposing'], [5, 8]);
      // The replacing region's already-absorbed keystroke is the accepted
      // loss the payload records; the in-flight protection arms with the
      // ABSORBED range, and the commit-key one-shot must NOT arm — the
      // replacing region proves the user's next composition intervened.
      expect(
        service.debugStaleComposingLatch,
        const TextRange(start: 5, end: 8),
      );
      expect(service.debugCommitKeySuppressionArmed, isFalse);

      // The new composition re-arrives against the fresh window and
      // composes normally: the user's input is not lost going forward.
      final fresh = shadow().text;
      sendValue(
        '$freshだ',
        cursor: fresh.length + 1,
        composing: TextRange(start: fresh.length, end: fresh.length + 1),
      );
      expect(controller.composing, isNotNull);
      expect(
        controller.document.allBlocks.map((b) => b.plainText),
        contains(contains('だ')),
      );

      // And it commits.
      sendValue('$freshだ', cursor: fresh.length + 1);
      expect(controller.composing, isNull);
    });

    test('deliberate terminations survive the passive window: undo during '
        'deferred divergence still terminates and pushes', () {
      build([para('a', 'one')], selection: caret('a', 3));
      sendValue(
        '. oneか',
        cursor: 6,
        composing: const TextRange(start: 5, end: 6),
      );
      // Arm the deferred divergence (the structural shape above).
      sendValue(
        '. oneか\nx',
        cursor: 8,
        composing: const TextRange(start: 5, end: 8),
      );
      expect(service.debugLastTerminateReason, isNull);
      expect(controller.composing, isNotNull);

      controller.undo();

      expect(service.debugLastTerminateReason, 'undo');
      expect(controller.composing, isNull);
      expect(connection().pushed.last.composing, TextRange.empty);

      // The divergence is resolved by the terminate's authoritative push:
      // the next composition starts clean (no stale deferral eats it).
      sendValue(
        '${shadow().text}に',
        cursor: shadow().text.length + 1,
        composing: TextRange(
          start: shadow().text.length,
          end: shadow().text.length + 1,
        ),
      );
      expect(controller.composing, isNotNull);
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

      // A composing-decorated value with no text change records a null
      // diff — and, with shadow composing empty, the decoration is
      // birth-suppressed (the value then matches the shadow exactly: a
      // pure echo, no synthesized delta).
      sendValue(
        '. hix',
        cursor: 5,
        composing: const TextRange(start: 2, end: 5),
      );
      expect(service.debugLastDiff, isNull);
      expect(
        service.journal.events.any((e) => e.kind == 'composingBirthSuppressed'),
        isTrue,
      );

      // A selection-only value synthesizes the NonTextUpdate analogue and
      // feeds the same last-batch debug feed.
      sendValue('. hix', cursor: 4);
      expect(service.debugLastDiff, isNull);
      expect(service.debugLastDeltas, hasLength(1));
      expect(
        service.debugLastDeltas!.single,
        isA<TextEditingDeltaNonTextUpdate>(),
      );
    });
  });
}
