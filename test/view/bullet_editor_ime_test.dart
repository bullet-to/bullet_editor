import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../input/ime_replay.dart';

/// Day 5–7 widget wiring: the IME connection follows focus, engine deltas
/// reach the document through the editor's [ImeService], the composing
/// underline renders (G3 visibility), and geometry (editable transform +
/// caret/composing rects) reaches the engine.
void main() {
  TextBlock para(String id, String text) => TextBlock(
    id: id,
    blockType: ParagraphKeys.type,
    segments: [StyledSegment(text)],
  );

  Finder richTextContaining(String text) => find.byWidgetPredicate(
    (w) => w is RichText && w.text.toPlainText().contains(text),
  );

  late EditorController controller;

  Future<void> pumpEditor(
    WidgetTester tester,
    List<TextBlock> blocks, {
    bool readOnly = false,
    bool autofocus = true,
    ImeFrontend? imeFrontend,
  }) async {
    controller = EditorController(
      document: Document(blocks),
      schema: EditorSchema.standard(),
      undoGrouping: (previous, current) => false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BulletEditor(
            controller: controller,
            readOnly: readOnly,
            autofocus: autofocus,
            imeFrontend: imeFrontend,
            textStyle: const TextStyle(fontSize: 16, color: Color(0xFF000000)),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  ImeService imeOf(WidgetTester tester) =>
      tester.state<BulletEditorState>(find.byType(BulletEditor)).imeService;

  void sendInsertion(
    WidgetTester tester,
    String text, {
    int? at,
    TextRange composing = TextRange.empty,
  }) {
    final ime = imeOf(tester);
    final shadow = ime.currentTextEditingValue!;
    final offset = at ?? shadow.selection.extentOffset;
    ime.updateEditingValueWithDeltas([
      TextEditingDeltaInsertion(
        oldText: shadow.text,
        textInserted: text,
        insertionOffset: offset,
        selection: TextSelection.collapsed(offset: offset + text.length),
        composing: composing,
      ),
    ]);
  }

  group('connection lifecycle follows focus', () {
    testWidgets('focus attaches a delta-model connection and pushes the '
        'sentinel window', (tester) async {
      await pumpEditor(tester, [para('a', 'hi')], autofocus: false);
      tester.testTextInput.log.clear();
      expect(imeOf(tester).isAttached, isFalse);

      controller.setSelection(DocSelection.collapsed(DocPosition('a', 2)));
      controller.requestFocus();
      await tester.pump();

      expect(imeOf(tester).isAttached, isTrue);
      final setClient = tester.testTextInput.log.firstWhere(
        (call) => call.method == 'TextInput.setClient',
      );
      final config =
          (setClient.arguments as List<dynamic>)[1] as Map<String, dynamic>;
      expect(config['enableDeltaModel'], isTrue);
      expect(config['autocorrect'], isTrue);
      expect(imeOf(tester).currentTextEditingValue!.text, '. hi');
    });

    testWidgets('losing focus detaches the connection', (tester) async {
      await pumpEditor(tester, [para('a', 'hi')]);
      expect(imeOf(tester).isAttached, isTrue);

      controller.clearFocus();
      await tester.pump();
      await tester.pump();

      expect(imeOf(tester).isAttached, isFalse);
    });

    testWidgets('readOnly editors never attach', (tester) async {
      await pumpEditor(tester, [para('a', 'hi')], readOnly: true);
      await tester.tapAt(tester.getCenter(richTextContaining('hi')));
      await tester.pump();

      expect(imeOf(tester).isAttached, isFalse);
    });

    testWidgets('toggling readOnly while focused syncs the connection both '
        'directions', (tester) async {
      Widget editor({required bool readOnly}) => MaterialApp(
        home: Scaffold(
          body: BulletEditor(
            controller: controller,
            readOnly: readOnly,
            autofocus: true,
            textStyle: const TextStyle(fontSize: 16, color: Color(0xFF000000)),
          ),
        ),
      );
      await pumpEditor(tester, [para('a', 'hi')]);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 2)));
      await tester.pump();
      expect(imeOf(tester).isAttached, isTrue);

      // readOnly → true with focus held: the live connection must drop —
      // deltas would otherwise keep mutating the document against the
      // widget's readOnly contract.
      await tester.pumpWidget(editor(readOnly: true));
      await tester.pump();
      expect(imeOf(tester).isAttached, isFalse);

      // readOnly → false with focus still held: the connection re-attaches
      // and the current window is pushed.
      await tester.pumpWidget(editor(readOnly: false));
      await tester.pump();
      expect(imeOf(tester).isAttached, isTrue);
      expect(imeOf(tester).currentTextEditingValue!.text, '. hi');
    });

    testWidgets('a tap with the selection on a void block keeps an attached '
        'connection (buffer = sentinel + ~)', (tester) async {
      await pumpEditor(tester, [
        para('a', 'above'),
        TextBlock(id: 'img', blockType: ImageKeys.type),
      ]);
      await tester.tapAt(tester.getCenter(find.byType(ImageBlockComponent)));
      await tester.pump();

      expect(imeOf(tester).isAttached, isTrue);
      expect(imeOf(tester).currentTextEditingValue!.text, '. ~');
    });
  });

  group('delta typing through the widget', () {
    testWidgets('engine insertion deltas update the document and rebuild', (
      tester,
    ) async {
      await pumpEditor(tester, [para('a', '')]);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 0)));
      await tester.pump();

      sendInsertion(tester, 'hi');
      await tester.pump();

      expect(controller.document.blockById('a')!.plainText, 'hi');
      expect(richTextContaining('hi'), findsOneWidget);
    });

    testWidgets('same-block tap-then-type trace (widget): type "hello", tap '
        'before h, type x → "xhello"', (tester) async {
      await pumpEditor(tester, [para('a', '')]);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 0)));
      await tester.pump();
      sendInsertion(tester, 'hello');
      await tester.pump();

      // A real tap before 'h' — the engine-side cursor must follow
      // (clause (b) of the no-echo invariant), or 'x' lands at the old
      // caret and the document reads "hellox".
      final rect = tester.getRect(richTextContaining('hello'));
      await tester.tapAt(rect.centerLeft + const Offset(1, 0));
      await tester.pump();
      expect(
        imeOf(tester).currentTextEditingValue!.selection,
        const TextSelection.collapsed(offset: 2),
      );

      sendInsertion(tester, 'x');
      await tester.pump();

      expect(controller.document.blockById('a')!.plainText, 'xhello');
    });
  });

  group('macOS dead-key trace (hardware keys racing the composition)', () {
    // macOS key dispatch contract this trace models: the framework receives
    // the hardware KeyDownEvent FIRST, and FlutterTextInputPlugin is a
    // SECONDARY responder — NSTextInputContext (the IME) only processes a
    // key the framework reports unhandled, and only then emits deltas. The
    // test honors that contract literally: the marked-text-removal delta is
    // delivered iff the framework did NOT handle the backspace key.
    testWidgets('compose ´ (Option+E) → backspace → compose ´ again → E '
        'commits é: the second accent must not vanish', (tester) async {
      await pumpEditor(tester, [para('a', '')]);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 0)));
      await tester.pump();
      final ime = imeOf(tester);

      // Option+E: keyE is ignored by _onKeyEvent; the IME marks ´.
      sendInsertion(tester, '´', composing: const TextRange(start: 2, end: 3));
      await tester.pump();
      expect(controller.composing, isNotNull);

      // Backspace while marked text exists. If the framework handles it,
      // the IME is starved (no delta); if it ignores it, macOS consumes the
      // key and reports the marked-text removal as a deletion delta.
      final handled = await simulateKeyDownEvent(LogicalKeyboardKey.backspace);
      await simulateKeyUpEvent(LogicalKeyboardKey.backspace);
      if (!handled) {
        final shadow = ime.currentTextEditingValue!;
        ime.updateEditingValueWithDeltas([
          TextEditingDeltaDeletion(
            oldText: shadow.text,
            deletedRange: const TextRange(start: 2, end: 3),
            selection: const TextSelection.collapsed(offset: 2),
            composing: TextRange.empty,
          ),
        ]);
      }
      await tester.pump();
      expect(controller.document.blockById('a')!.plainText, '');
      expect(controller.composing, isNull);

      // Second Option+E: fresh marked ´ at the same buffer offset.
      sendInsertion(
        tester,
        '´',
        at: 2,
        composing: const TextRange(start: 2, end: 3),
      );
      await tester.pump();
      expect(
        controller.document.blockById('a')!.plainText,
        '´',
        reason: 'the re-typed dead-key accent must not be swallowed',
      );

      // E: the IME replaces the marked range with é and commits.
      final shadow = ime.currentTextEditingValue!;
      ime.updateEditingValueWithDeltas([
        TextEditingDeltaReplacement(
          oldText: shadow.text,
          replacedRange: const TextRange(start: 2, end: 3),
          replacementText: 'é',
          selection: const TextSelection.collapsed(offset: 3),
          composing: TextRange.empty,
        ),
      ]);
      await tester.pump();
      expect(controller.document.blockById('a')!.plainText, 'é');
      expect(richTextContaining('é'), findsOneWidget);
      expect(controller.composing, isNull);
    });

    testWidgets('backspace during a dead-key marked state: the gate defers '
        'the key, the engine unmarks and forwards deleteBackward: — the '
        'pending accent is removed entirely', (tester) async {
      await pumpEditor(tester, [para('a', '')]);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 0)));
      await tester.pump();
      final ime = imeOf(tester);

      // Option+E: the IME marks ´.
      sendInsertion(tester, '´', composing: const TextRange(start: 2, end: 3));
      await tester.pump();
      expect(controller.composing, isNotNull);

      // The composing gate defers backspace to the platform IME ...
      expect(await simulateKeyDownEvent(LogicalKeyboardKey.backspace), isFalse);
      await simulateKeyUpEvent(LogicalKeyboardKey.backspace);

      // ... and macOS ends the dead-key state: unmark first (deltas are
      // sent synchronously), then the editing command (selectors are
      // batched to the next run-loop turn) — the verified engine ordering.
      final shadow = ime.currentTextEditingValue!;
      ime.updateEditingValueWithDeltas([
        TextEditingDeltaNonTextUpdate(
          oldText: shadow.text,
          selection: shadow.selection,
          composing: TextRange.empty,
        ),
      ]);
      ime.performSelector('deleteBackward:');
      await tester.pump();

      expect(
        controller.document.blockById('a')!.plainText,
        '',
        reason: 'native dead-key backspace removes the pending accent',
      );
      expect(controller.composing, isNull);

      // Recovery: a fresh Option+E marks and E commits é.
      sendInsertion(
        tester,
        '´',
        at: 2,
        composing: const TextRange(start: 2, end: 3),
      );
      await tester.pump();
      expect(controller.document.blockById('a')!.plainText, '´');
      final shadow2 = ime.currentTextEditingValue!;
      ime.updateEditingValueWithDeltas([
        TextEditingDeltaReplacement(
          oldText: shadow2.text,
          replacedRange: const TextRange(start: 2, end: 3),
          replacementText: 'é',
          selection: const TextSelection.collapsed(offset: 3),
          composing: TextRange.empty,
        ),
      ]);
      await tester.pump();
      expect(controller.document.blockById('a')!.plainText, 'é');
      expect(controller.composing, isNull);
    });

    testWidgets('the composing gate defers Enter and Tab to the IME while '
        'marked text exists, and releases them when it clears', (tester) async {
      await pumpEditor(tester, [para('a', 'ab')]);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 2)));
      await tester.pump();

      sendInsertion(tester, 'か', composing: const TextRange(start: 4, end: 5));
      await tester.pump();
      expect(controller.composing, isNotNull);

      expect(await simulateKeyDownEvent(LogicalKeyboardKey.enter), isFalse);
      await simulateKeyUpEvent(LogicalKeyboardKey.enter);
      expect(
        controller.document.allBlocks,
        hasLength(1),
        reason: 'no hardware split mid-composition — the IME owns Enter',
      );
      expect(await simulateKeyDownEvent(LogicalKeyboardKey.tab), isFalse);
      await simulateKeyUpEvent(LogicalKeyboardKey.tab);

      // Commit clears the composition; the hardware handlers re-engage.
      final ime = imeOf(tester);
      final shadow = ime.currentTextEditingValue!;
      ime.updateEditingValueWithDeltas([
        TextEditingDeltaNonTextUpdate(
          oldText: shadow.text,
          selection: shadow.selection,
          composing: TextRange.empty,
        ),
      ]);
      await tester.pump();
      expect(controller.composing, isNull);

      expect(await simulateKeyDownEvent(LogicalKeyboardKey.backspace), isTrue);
      await simulateKeyUpEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(controller.document.blockById('a')!.plainText, 'ab');
    });
  });

  group('composing underline (G3 visibility)', () {
    final overlayLayer = find.byWidgetPredicate(
      (w) =>
          w is CustomPaint &&
          w.foregroundPainter != null &&
          w.child is RichText,
    );

    testWidgets('the composing block paints a solid underline under the '
        'range', (tester) async {
      await pumpEditor(tester, [para('a', '')]);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 0)));
      await tester.pump();

      sendInsertion(tester, 'かな', composing: const TextRange(start: 2, end: 4));
      await tester.pump();

      expect(
        controller.composing,
        const ComposingState(blockId: 'a', range: TextRange(start: 0, end: 2)),
      );
      // Two filled rects: the composing underline, then the caret.
      expect(
        tester.renderObject(overlayLayer),
        paints
          ..rect()
          ..rect(),
      );
    });

    testWidgets('without a composition only the caret rect paints', (
      tester,
    ) async {
      await pumpEditor(tester, [para('a', '')]);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 0)));
      await tester.pump();
      sendInsertion(tester, 'abc');
      await tester.pump();

      expect(controller.composing, isNull);
      expect(
        tester.renderObject(overlayLayer),
        isNot(
          paints
            ..rect()
            ..rect(),
        ),
      );
      expect(tester.renderObject(overlayLayer), paints..rect());
    });

    testWidgets('terminating the composition removes the underline', (
      tester,
    ) async {
      await pumpEditor(tester, [para('a', '')]);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 0)));
      await tester.pump();
      sendInsertion(tester, 'か', composing: const TextRange(start: 2, end: 3));
      await tester.pump();
      expect(controller.composing, isNotNull);

      controller.undo(); // terminateComposition('undo')
      await tester.pump();

      expect(controller.composing, isNull);
    });
  });

  group('geometry reporting (composing-rect rule, G15 separation)', () {
    testWidgets('after a delta batch the engine receives the editable '
        'transform and the caret rect', (tester) async {
      await pumpEditor(tester, [para('a', '')]);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 0)));
      await tester.pump();

      // The attach-time report carried the editable size/transform (the
      // connection caches it engine-side and re-sends only on change).
      expect(
        tester.testTextInput.log.map((c) => c.method),
        contains('TextInput.setEditableSizeAndTransform'),
      );
      tester.testTextInput.log.clear();

      sendInsertion(tester, 'abc');
      await tester.pump(); // the post-frame geometry report

      final methods = tester.testTextInput.log.map((c) => c.method).toList();
      expect(methods, contains('TextInput.setCaretRect'));
      expect(
        methods,
        isNot(contains('TextInput.setEditingState')),
        reason:
            'geometry reporting never touches text state (G15) — and a '
            'convergent batch is never echoed',
      );
    });

    testWidgets('a composing batch additionally reports the composing rect '
        '(iOS anchors its candidate bar from it)', (tester) async {
      await pumpEditor(tester, [para('a', '')]);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 0)));
      await tester.pump();
      tester.testTextInput.log.clear();

      sendInsertion(tester, 'かな', composing: const TextRange(start: 2, end: 4));
      await tester.pump();

      final methods = tester.testTextInput.log.map((c) => c.method).toList();
      // setComposingRect's wire name is TextInput.setMarkedTextRect.
      expect(methods, contains('TextInput.setMarkedTextRect'));
    });
  });

  group('web diff fallback wiring (day 8)', () {
    testWidgets('imeFrontend: nonDeltaDiff attaches WITHOUT the delta model '
        'and full-value updates from the platform drive the document', (
      tester,
    ) async {
      await pumpEditor(tester, [
        para('a', ''),
      ], imeFrontend: ImeFrontend.nonDeltaDiff);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 0)));
      await tester.pump();

      expect(imeOf(tester).frontend, ImeFrontend.nonDeltaDiff);
      final setClient = tester.testTextInput.log.firstWhere(
        (call) => call.method == 'TextInput.setClient',
      );
      final config =
          (setClient.arguments as List<dynamic>)[1] as Map<String, dynamic>;
      expect(config['enableDeltaModel'], isFalse);

      // The engine's full-value callback, end to end over the channel —
      // what a web engine sends for every DOM input event.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '. hi',
          selection: TextSelection.collapsed(offset: 4),
        ),
      );
      await tester.pump();

      expect(controller.document.blockById('a')!.plainText, 'hi');
      expect(richTextContaining('hi'), findsOneWidget);
    });

    testWidgets('a composing snapshot maps to ComposingState and paints the '
        'underline (the full-peer contract: composing is never invisible '
        'on web)', (tester) async {
      await pumpEditor(tester, [
        para('a', ''),
      ], imeFrontend: ImeFrontend.nonDeltaDiff);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 0)));
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '. かな',
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange(start: 2, end: 4),
        ),
      );
      await tester.pump();

      expect(
        controller.composing,
        const ComposingState(blockId: 'a', range: TextRange(start: 0, end: 2)),
      );
      // Two filled rects: the composing underline, then the caret.
      expect(
        tester.renderObject(
          find.byWidgetPredicate(
            (w) =>
                w is CustomPaint &&
                w.foregroundPainter != null &&
                w.child is RichText,
          ),
        ),
        paints
          ..rect()
          ..rect(),
      );
    });

    testWidgets('flipping imeFrontend rebuilds the IME service with the new '
        'frontend (a connection cannot change its delta declaration in '
        'place)', (tester) async {
      await pumpEditor(tester, [para('a', 'hi')]);
      final deltaService = imeOf(tester);
      expect(deltaService.frontend, ImeFrontend.delta);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BulletEditor(
              controller: controller,
              autofocus: true,
              imeFrontend: ImeFrontend.nonDeltaDiff,
              textStyle: const TextStyle(
                fontSize: 16,
                color: Color(0xFF000000),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final diffService = imeOf(tester);
      expect(identical(diffService, deltaService), isFalse);
      expect(diffService.frontend, ImeFrontend.nonDeltaDiff);
      expect(diffService.isAttached, isTrue);
    });

    testWidgets('a no-op imeFrontend change (null → the explicit platform '
        'default) keeps the live service and connection — effective '
        'frontends are compared, not raw nullables', (tester) async {
      await pumpEditor(tester, [para('a', 'hi')]);
      final before = imeOf(tester);
      expect(before.frontend, ImeFrontend.platformDefault);
      expect(before.isAttached, isTrue);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BulletEditor(
              controller: controller,
              autofocus: true,
              imeFrontend: ImeFrontend.platformDefault,
              textStyle: const TextStyle(
                fontSize: 16,
                color: Color(0xFF000000),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        identical(imeOf(tester), before),
        isTrue,
        reason:
            'resolving null to the platform default is not a flip — a '
            'rebuild here would tear down a live connection (and any '
            'composition) for a no-op',
      );
      expect(imeOf(tester).isAttached, isTrue);
    });
  });

  group("Safari's post-compositionend commit Enter (web diff fallback)", () {
    // The tail of a REAL journal capture (Safari, Japanese): にほんご was
    // converted to 日本語 (seq 60), Safari echoed the caret move (seq 69),
    // and compositionend was reflected as the composing-clear snapshot
    // (seq 72). 29 ms later the Enter that COMMITTED the conversion reached
    // the framework as an ordinary keydown — Safari fires compositionend
    // BEFORE the committing key's keydown (Chrome/Firefox do the opposite,
    // keyCode 229), so by then `controller.composing` is null and the
    // composing gate cannot defer it.
    const captureTail = r'''
{"seq":60,"ms":9450,"kind":"snapshot","payload":{"text":". 日本語","sel":[2,5],"composing":[2,5]}}
{"seq":69,"ms":10379,"kind":"snapshot","payload":{"text":". 日本語","sel":[5,5],"composing":[2,5]}}
{"seq":72,"ms":10379,"kind":"snapshot","payload":{"text":". 日本語","sel":[5,5],"composing":null}}
''';

    testWidgets('the Enter that commits a conversion is swallowed once — '
        'no spurious paragraph; the next Enter splits normally', (
      tester,
    ) async {
      await pumpEditor(tester, [
        para('a', ''),
      ], imeFrontend: ImeFrontend.nonDeltaDiff);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 0)));
      await tester.pump();

      replayImeJournal(imeOf(tester), parseImeJournalDump(captureTail));
      await tester.pump();
      expect(controller.document.blockById('a')!.plainText, '日本語');
      expect(controller.composing, isNull, reason: 'compositionend reflected');

      // The commit Enter (the capture's seq 75, 29 ms after the clear):
      // handled, but NO newline — it already did its job engine-side.
      expect(await simulateKeyDownEvent(LogicalKeyboardKey.enter), isTrue);
      await simulateKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(
        controller.document.allBlocks,
        hasLength(1),
        reason: 'the commit Enter must not also insert a paragraph',
      );
      expect(controller.document.blockById('a')!.plainText, '日本語');
      expect(
        [
          for (final e in imeOf(tester).journal.toJson())
            if (e['kind'] == 'key')
              ((e['payload']! as Map).cast<String, Object?>())['handler'],
        ],
        contains('commitEnterSuppressed'),
        reason: 'the decision is journaled for future captures',
      );

      // One-shot: the suppression disarmed on consumption, so the very next
      // Enter is a genuine split.
      expect(await simulateKeyDownEvent(LogicalKeyboardKey.enter), isTrue);
      await simulateKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(controller.document.allBlocks, hasLength(2));
      expect(controller.document.allBlocks.first.plainText, '日本語');
    });

    testWidgets("Chrome's ordering (commit keydown deferred by the gate "
        'BEFORE compositionend) never arms — the next Enter splits', (
      tester,
    ) async {
      await pumpEditor(tester, [
        para('a', ''),
      ], imeFrontend: ImeFrontend.nonDeltaDiff);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 0)));
      await tester.pump();
      final ime = imeOf(tester);

      // Compose か, then the commit Enter: on Chrome the keydown reaches
      // the framework while the composition is still live, so the gate
      // defers it to the browser ...
      ime.updateEditingValue(
        const TextEditingValue(
          text: '. か',
          selection: TextSelection.collapsed(offset: 3),
          composing: TextRange(start: 2, end: 3),
        ),
      );
      await tester.pump();
      expect(controller.composing, isNotNull);
      expect(await simulateKeyDownEvent(LogicalKeyboardKey.enter), isFalse);
      await simulateKeyUpEvent(LogicalKeyboardKey.enter);

      // ... which commits the composition and reflects compositionend.
      ime.updateEditingValue(
        const TextEditingValue(
          text: '. か',
          selection: TextSelection.collapsed(offset: 3),
        ),
      );
      await tester.pump();
      expect(controller.composing, isNull);

      // The user's quick follow-up Enter (commit-then-new-line, the
      // standard Japanese flow) is a genuine split — the gate-deferred
      // commit key already proved the keydown-first ordering, so the
      // suppression never armed.
      expect(await simulateKeyDownEvent(LogicalKeyboardKey.enter), isTrue);
      await simulateKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(controller.document.allBlocks, hasLength(2));
    });
  });

  group('controller swap', () {
    testWidgets('swapping controllers re-homes the IME service', (
      tester,
    ) async {
      await pumpEditor(tester, [para('a', 'one')]);
      final firstService = imeOf(tester);
      final second = EditorController(
        document: Document([para('b', 'two')]),
        schema: EditorSchema.standard(),
      );
      addTearDown(second.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BulletEditor(controller: second, autofocus: true),
          ),
        ),
      );
      await tester.pump();

      final swapped = imeOf(tester);
      expect(identical(swapped, firstService), isFalse);
      expect(swapped.controller, second);
      expect(
        controller.imeExternalChangeHandler,
        isNull,
        reason: 'the old service unhooked on dispose',
      );

      second.setSelection(DocSelection.collapsed(DocPosition('b', 3)));
      await tester.pump();
      expect(swapped.currentTextEditingValue!.text, '. two');
    });
  });
}
