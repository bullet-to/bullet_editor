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

    testWidgets('the full composing gate (day-10 pull-forward): ←/→ '
        'mid-composition defer to the IME — the caret must not walk through '
        'the document text (the manual Safari/Chrome symptom: → mid-'
        'composition copies the text to the start of the next line)', (
      tester,
    ) async {
      await pumpEditor(tester, [para('a', 'hello'), para('b', 'world')]);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 5)));
      await tester.pump();

      sendInsertion(tester, 'か', composing: const TextRange(start: 7, end: 8));
      await tester.pump();
      expect(controller.composing, isNotNull);
      final selectionBefore = controller.selection;
      final ime = imeOf(tester);
      ime.journal.clear();

      // An ungated arrow fires moveCaret → setSelection →
      // terminateComposition('externalEdit'): the marked text commits as-is
      // on the first candidate/segment-navigation keystroke and the IME's
      // internal buffer diverges from the document (§hardware keyboard).
      // The raw key result is NOT asserted: once the editor defers, ambient
      // app-level shortcuts (focus traversal) may still mark the event
      // handled upstream — the invariant is the model state and the gate's
      // journaled decision.
      await simulateKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await simulateKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await simulateKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      await simulateKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();

      expect(
        controller.composing,
        isNotNull,
        reason: 'arrows must not terminate the composition',
      );
      expect(controller.selection, selectionBefore);
      expect(ime.debugLastTerminateReason, isNull);
      expect(controller.document.blockById('a')!.plainText, 'helloか');
      expect(controller.document.blockById('b')!.plainText, 'world');
      final downs = [
        for (final e in ime.journal.events)
          if (e.kind == 'key' && e.payload['kind'] == 'down')
            (e.payload['key'], e.payload['deferred']),
      ];
      expect(downs, [
        ('Arrow Right', true),
        ('Arrow Left', true),
      ], reason: 'both arrows deferred via the composing gate');
    });

    testWidgets('the full composing gate: ↑/↓ (candidate-menu cycling) and '
        'Home/End/PageUp/PageDown defer while composing — the cursor must '
        'not be pushed through the document text', (tester) async {
      await pumpEditor(tester, [para('a', 'hello')]);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 5)));
      await tester.pump();

      sendInsertion(tester, 'か', composing: const TextRange(start: 7, end: 8));
      await tester.pump();
      expect(controller.composing, isNotNull);
      final ime = imeOf(tester);
      ime.journal.clear();

      const gated = [
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.home,
        LogicalKeyboardKey.end,
        LogicalKeyboardKey.pageUp,
        LogicalKeyboardKey.pageDown,
      ];
      // The raw key result is not asserted (ambient app-level shortcuts —
      // scroll, focus traversal — may handle the deferred event upstream);
      // the invariant is the journaled gate decision plus untouched state.
      for (final key in gated) {
        await simulateKeyDownEvent(key);
        await simulateKeyUpEvent(key);
      }
      await tester.pump();

      expect(controller.composing, isNotNull);
      expect(ime.debugLastTerminateReason, isNull);
      // The gate's decision is journaled: every key-down above was deferred
      // to the IME, not merely unhandled.
      final downs = [
        for (final e in ime.journal.events)
          if (e.kind == 'key' && e.payload['kind'] == 'down')
            (e.payload['key'], e.payload['deferred']),
      ];
      expect(downs, hasLength(gated.length));
      for (final (key, deferred) in downs) {
        expect(deferred, isTrue, reason: '$key must defer via the gate');
      }
    });

    testWidgets('the composing gate whitelist: Cmd/Ctrl+Z mid-composition '
        'stays handled — undo is a first-class composition terminator (G7)', (
      tester,
    ) async {
      await pumpEditor(tester, [para('a', '')]);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 0)));
      await tester.pump();

      sendInsertion(tester, 'か', composing: const TextRange(start: 2, end: 3));
      await tester.pump();
      expect(controller.composing, isNotNull);

      await simulateKeyDownEvent(LogicalKeyboardKey.metaLeft);
      expect(
        await simulateKeyDownEvent(LogicalKeyboardKey.keyZ),
        isTrue,
        reason: 'undo passes the gate — the one whitelisted terminator',
      );
      await simulateKeyUpEvent(LogicalKeyboardKey.keyZ);
      await simulateKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();

      expect(controller.composing, isNull);
      expect(imeOf(tester).debugLastTerminateReason, 'undo');
      expect(controller.document.blockById('a')!.plainText, '');
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

  group('candidate-window geometry (the web engine consumes ONLY '
      'setEditableSizeAndTransform — the hidden input must sit at the '
      'caret/composing region, or the candidate window opens at the '
      "editor's top-left)", () {
    Map<String, dynamic> lastSizeAndTransform(WidgetTester tester) {
      final call = tester.testTextInput.log.lastWhere(
        (c) => c.method == 'TextInput.setEditableSizeAndTransform',
      );
      return (call.arguments as Map).cast<String, dynamic>();
    }

    Future<ScrollController> pumpScrolledEditor(WidgetTester tester) async {
      controller = EditorController(
        document: Document([
          for (var i = 0; i < 30; i++) para('b$i', 'block $i'),
        ]),
        schema: EditorSchema.standard(),
        undoGrouping: (previous, current) => false,
      );
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BulletEditor(
              controller: controller,
              scrollController: scrollController,
              autofocus: true,
              textStyle: const TextStyle(
                fontSize: 16,
                color: Color(0xFF000000),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return scrollController;
    }

    testWidgets('composing on a block far from the origin reports the '
        "editable transform at the composing region's on-screen position", (
      tester,
    ) async {
      final scrollController = await pumpScrolledEditor(tester);
      scrollController.jumpTo(120);
      await tester.pump();
      controller.setSelection(
        DocSelection.collapsed(const DocPosition('b15', 8)),
      );
      await tester.pump();

      // Compose かな at the end of 'block 15' (buffer offset 10, sentinel
      // +8), caret AFTER the marked text. The composing anchor stays at the
      // region's left edge (8 glyphs in) while the caret sits 2 glyphs
      // further — and the framework's TextInputConnection suppresses
      // identical size+transform re-sends, so the LAST placement on the
      // channel proves the anchor: a caret-anchored implementation would
      // have emitted a fresh call at the caret's x.
      sendInsertion(
        tester,
        'かな',
        composing: const TextRange(start: 10, end: 12),
      );
      await tester.pump(); // the post-frame geometry report

      final blockRect = tester.getRect(richTextContaining('block 15'));
      expect(
        blockRect.top,
        greaterThan(100),
        reason: 'the fixture block must sit far from the editor origin',
      );
      final args = lastSizeAndTransform(tester);
      final transform = (args['transform'] as List).cast<double>();
      // The composing かな starts after the 8 glyphs of 'block 15'.
      expect(
        transform[12],
        closeTo(blockRect.left + 8 * 16, 1.0),
        reason:
            'x: the hidden input must sit at the composing region, not '
            'the caret (2 glyphs further) and not the editor origin',
      );
      expect(
        transform[13],
        closeTo(blockRect.top, 1.0),
        reason: 'y: the block position, not the editor top-left',
      );
      // The Monaco/CodeMirror hidden-input shape: position = the composing
      // region (that places the candidate window), size = nothing visible —
      // 1 logical px wide, one line tall. WebKit paints its marked-text
      // underline INSIDE the hidden element, and no font/size matching
      // keeps the browser's own line layout glued to our rendered text
      // (the manual Safari finding: the native blue line wandered as the
      // composition grew), so the element gets no area to draw it in.
      expect(
        args['width'] as double,
        1.0,
        reason:
            'a 1px-wide editable leaves WebKit nowhere to paint its '
            'native marked-text underline',
      );
      expect(
        args['height'] as double,
        closeTo(16.0, 1.0),
        reason:
            'one line tall: the browser drops the candidate window '
            "below the element's bottom edge — below the composed line",
      );
    });

    testWidgets('scrolling re-reports: the anchor follows the content '
        '(ScrollNotification-driven re-send, the day-15 re-send note)', (
      tester,
    ) async {
      final scrollController = await pumpScrolledEditor(tester);
      scrollController.jumpTo(120);
      await tester.pump();
      controller.setSelection(
        DocSelection.collapsed(const DocPosition('b15', 8)),
      );
      await tester.pump();
      sendInsertion(
        tester,
        'か',
        composing: const TextRange(start: 10, end: 11),
      );
      await tester.pump();
      final before = lastSizeAndTransform(tester);
      final beforeY = ((before['transform'] as List).cast<double>())[13];
      tester.testTextInput.log.clear();

      scrollController.jumpTo(170); // scroll 50 further
      await tester.pump(); // notification → scheduled post-frame report
      await tester.pump();

      final after = lastSizeAndTransform(tester);
      final afterY = ((after['transform'] as List).cast<double>())[13];
      expect(
        afterY,
        closeTo(beforeY - 50, 1.0),
        reason: 'the reported anchor must track the scrolled content',
      );
    });
  });

  group("hidden-input metrics (TextInput.setStyle — the engine's editing "
      'element carries OUR font metrics so its DOM caret box, the anchor '
      "browsers hang the IME candidate window off, matches our line)", () {
    Map<String, dynamic> lastSetStyle(WidgetTester tester) {
      final call = tester.testTextInput.log.lastWhere(
        (c) => c.method == 'TextInput.setStyle',
      );
      return (call.arguments as Map).cast<String, dynamic>();
    }

    testWidgets('attach sends setStyle with the focused block\'s resolved '
        'style', (tester) async {
      await pumpEditor(tester, [para('a', 'hi')], autofocus: false);
      tester.testTextInput.log.clear();

      controller.setSelection(DocSelection.collapsed(DocPosition('a', 2)));
      controller.requestFocus();
      await tester.pump(); // attach
      await tester.pump(); // the post-frame report carries the style

      final style = lastSetStyle(tester);
      expect(style['fontSize'], 16.0);
      expect(style['textAlignIndex'], TextAlign.start.index);
      expect(style['textDirectionIndex'], TextDirection.ltr.index);
    });

    testWidgets('moving the caret into a block with a different resolved '
        'style re-sends setStyle (the heading\'s metrics, not the '
        'paragraph\'s)', (tester) async {
      await pumpEditor(tester, [
        TextBlock(
          id: 'h',
          blockType: HeadingKeys.h1,
          segments: [StyledSegment('Title')],
        ),
        para('a', 'hi'),
      ], autofocus: false);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 2)));
      controller.requestFocus();
      await tester.pump();
      await tester.pump();
      expect(lastSetStyle(tester)['fontSize'], 16.0);
      tester.testTextInput.log.clear();

      controller.setSelection(DocSelection.collapsed(DocPosition('h', 5)));
      await tester.pump(); // selection push schedules a report
      await tester.pump(); // the post-frame report

      final style = lastSetStyle(tester);
      expect(style['fontSize'], 16.0 * 1.75, reason: 'h1 scales the base');
      expect(
        style['fontWeightIndex'],
        FontWeight.values.indexOf(FontWeight.bold),
      );
    });

    testWidgets('an ambient text-scale change re-sends setStyle with the '
        'rescaled metrics — the hidden input must not keep stale metrics '
        'across MediaQuery changes (didChangeDependencies → coalesced '
        'geometry report)', (tester) async {
      controller = EditorController(
        document: Document([para('a', 'hi')]),
        schema: EditorSchema.standard(),
        undoGrouping: (previous, current) => false,
      );
      Widget app(double scale) => MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: BulletEditor(
              controller: controller,
              autofocus: true,
              textStyle: const TextStyle(
                fontSize: 16,
                color: Color(0xFF000000),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(app(1.0));
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 2)));
      await tester.pump();
      await tester.pump(); // the post-frame report carries the style
      expect(lastSetStyle(tester)['fontSize'], 16.0);
      tester.testTextInput.log.clear();

      // The ambient scale changes — no widget field changed, so only a
      // dependency-driven re-report can refresh the engine's DOM font, and
      // a stale font mis-sizes the DOM caret box the candidate window
      // anchors to.
      await tester.pumpWidget(app(2.0));
      await tester.pump(); // the scheduled post-frame report

      expect(
        lastSetStyle(tester)['fontSize'],
        32.0,
        reason: 'the hidden input must re-style with the rescaled metrics',
      );
    });

    testWidgets('an unchanged style is not re-sent on every geometry '
        'report — setStyle is cached per connection', (tester) async {
      await pumpEditor(tester, [para('a', 'hi')], autofocus: false);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 2)));
      controller.requestFocus();
      await tester.pump();
      await tester.pump();
      tester.testTextInput.log.clear();

      controller.setSelection(DocSelection.collapsed(DocPosition('a', 0)));
      await tester.pump();
      await tester.pump();

      final methods = tester.testTextInput.log.map((c) => c.method).toList();
      expect(
        methods,
        contains('TextInput.setEditableSizeAndTransform'),
        reason: 'the caret move re-reports geometry',
      );
      expect(
        methods,
        isNot(contains('TextInput.setStyle')),
        reason: 'same block, same resolved style — nothing to re-send',
      );
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

    testWidgets('the composing gate stays closed when the FIRST snapshot of '
        'a browser composition is unmappable (passive divergence with no '
        'ComposingState): editing keys defer to the IME — no model edit, no '
        'terminate, no push', (tester) async {
      await pumpEditor(tester, [
        para('a', 'one'),
      ], imeFrontend: ImeFrontend.nonDeltaDiff);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 3)));
      await tester.pump();
      final ime = imeOf(tester);

      // The composition's FIRST snapshot carries a composing region
      // spanning a \n (unmappable into one block): the defer branch arms
      // passive divergence, but no ComposingState was ever installed — the
      // widget gate must key on the service-side condition, not only on
      // controller.composing.
      ime.updateEditingValue(
        const TextEditingValue(
          text: '. one\nx',
          selection: TextSelection.collapsed(offset: 7),
          composing: TextRange(start: 5, end: 7),
        ),
      );
      await tester.pump();
      expect(
        controller.composing,
        isNull,
        reason: 'the unmappable region never installed a ComposingState',
      );
      final blocksBefore = [
        for (final b in controller.document.allBlocks) b.plainText,
      ];
      final pushesBefore = tester.testTextInput.log
          .where((c) => c.method == 'TextInput.setEditingState')
          .length;
      ime.journal.clear();

      // An editing key mid-browser-composition: it must defer to the IME —
      // handled here it edits the model, external-edit terminates, and
      // pushes mid-composition (the corruption class the gate prevents).
      await simulateKeyDownEvent(LogicalKeyboardKey.backspace);
      await simulateKeyUpEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      expect(
        [for (final b in controller.document.allBlocks) b.plainText],
        blocksBefore,
        reason: 'no model edit while the browser owns the composition',
      );
      expect(ime.debugLastTerminateReason, isNull);
      expect(
        tester.testTextInput.log
            .where((c) => c.method == 'TextInput.setEditingState')
            .length,
        pushesBefore,
        reason: 'no push of any kind mid-browser-composition',
      );
      final downs = [
        for (final e in ime.journal.events)
          if (e.kind == 'key' && e.payload['kind'] == 'down')
            (e.payload['key'], e.payload['deferred']),
      ];
      expect(downs, [('Backspace', true)]);

      // The composition-ending snapshot reconciles; the gate reopens.
      ime.updateEditingValue(
        const TextEditingValue(
          text: '. one\nx',
          selection: TextSelection.collapsed(offset: 7),
        ),
      );
      await tester.pump();
      expect(await simulateKeyDownEvent(LogicalKeyboardKey.backspace), isTrue);
      await simulateKeyUpEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
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
        contains('commitKeySuppressed'),
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

    testWidgets('a click-commit does not poison the next Enter: the commit '
        "snapshot arms, but the click's follow-up snapshot disarms — an "
        'Enter within the window is a genuine split', (tester) async {
      await pumpEditor(tester, [
        para('a', ''),
      ], imeFrontend: ImeFrontend.nonDeltaDiff);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 0)));
      await tester.pump();
      final ime = imeOf(tester);

      // Compose か, then the user clicks elsewhere in the marked text:
      // the browser commits the composition — compositionend reflected as
      // the composing-clear snapshot (this arms; no keydown follows a
      // click) ...
      ime.updateEditingValue(
        const TextEditingValue(
          text: '. か',
          selection: TextSelection.collapsed(offset: 3),
          composing: TextRange(start: 2, end: 3),
        ),
      );
      await tester.pump();
      expect(controller.composing, isNotNull);
      ime.updateEditingValue(
        const TextEditingValue(
          text: '. か',
          selection: TextSelection.collapsed(offset: 3),
        ),
      );
      await tester.pump();
      expect(controller.composing, isNull);

      // ... followed by the click's own selectionchange snapshot — an
      // ACCEPTED snapshot proves other traffic landed behind the arm, so
      // it disarms (the Safari Enter-commit capture has NOTHING between
      // the arming snapshot and the keydown).
      ime.updateEditingValue(
        const TextEditingValue(
          text: '. か',
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      await tester.pump();

      // The user's Enter right after the click-commit is genuine.
      expect(await simulateKeyDownEvent(LogicalKeyboardKey.enter), isTrue);
      await simulateKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(
        controller.document.allBlocks,
        hasLength(2),
        reason: 'a genuine Enter after a click-commit must split',
      );
    });

    testWidgets("Escape consumes the one-shot too (ProseMirror's other "
        'suppressed key): an Escape-cancel ends the composition '
        'engine-side, the Escape keydown behind it spends the arm, and the '
        'next Enter splits', (tester) async {
      await pumpEditor(tester, [
        para('a', ''),
      ], imeFrontend: ImeFrontend.nonDeltaDiff);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 0)));
      await tester.pump();
      final ime = imeOf(tester);

      // Compose か, then Escape cancels: WebKit reflects compositionend
      // BEFORE the keydown — the marked text is removed and composing
      // clears (this snapshot arms the one-shot) ...
      ime.updateEditingValue(
        const TextEditingValue(
          text: '. か',
          selection: TextSelection.collapsed(offset: 3),
          composing: TextRange(start: 2, end: 3),
        ),
      );
      await tester.pump();
      expect(controller.composing, isNotNull);
      ime.updateEditingValue(
        const TextEditingValue(
          text: '. ',
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      await tester.pump();
      expect(controller.composing, isNull);
      expect(controller.document.blockById('a')!.plainText, '');

      // ... and the Escape keydown arrives behind the snapshot: nothing
      // here handles Escape (it stays ignored), but it IS the keydown of
      // the key that ended the composition, so it spends the one-shot.
      await simulateKeyDownEvent(LogicalKeyboardKey.escape);
      await simulateKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      // The user's next Enter is genuine.
      expect(await simulateKeyDownEvent(LogicalKeyboardKey.enter), isTrue);
      await simulateKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(
        controller.document.allBlocks,
        hasLength(2),
        reason: 'the Escape already consumed the arm — Enter must split',
      );
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

  group("Safari's post-compositionend cancel Backspace / Tab "
      '(web diff fallback)', () {
    // The tail of a REAL journal capture (Safari): a lone `n` composed at
    // the end of "image block." was canceled with one Backspace. The IME
    // consumed the key — the composing-clear snapshot lands FIRST with the
    // n already deleted (seq 12) — and the trailing Backspace keydown then
    // reached the framework with composing null, gate open, and ate the
    // block's period: WebKit's compositionend-before-keydown ordering
    // applies to EVERY key the IME consumes to end a composition, not just
    // the commit Enter.
    const backspaceCaptureTail = r'''
{"seq":8,"kind":"snapshot","payload":{"text":". image block.n","sel":[15,15],"composing":[14,15]}}
{"seq":12,"kind":"snapshot","payload":{"text":". image block.","sel":[14,14],"composing":null}}
''';

    testWidgets('the Backspace that cancels a composition is swallowed once '
        '— the period stays; the next Backspace deletes it', (tester) async {
      await pumpEditor(tester, [
        para('a', 'image block.'),
      ], imeFrontend: ImeFrontend.nonDeltaDiff);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 12)));
      await tester.pump();

      replayImeJournal(
        imeOf(tester),
        parseImeJournalDump(backspaceCaptureTail),
      );
      await tester.pump();
      expect(controller.document.blockById('a')!.plainText, 'image block.');
      expect(controller.composing, isNull, reason: 'compositionend reflected');

      // The trailing Backspace keydown (the capture's seq 16): handled,
      // but NO deletion — the IME already applied it engine-side.
      expect(await simulateKeyDownEvent(LogicalKeyboardKey.backspace), isTrue);
      await simulateKeyUpEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(
        controller.document.blockById('a')!.plainText,
        'image block.',
        reason: 'the cancel Backspace must not also eat the period',
      );
      expect(
        [
          for (final e in imeOf(tester).journal.toJson())
            if (e['kind'] == 'key')
              ((e['payload']! as Map).cast<String, Object?>())['handler'],
        ],
        contains('commitKeySuppressed'),
        reason: 'the decision is journaled for future captures',
      );

      // One-shot: the suppression disarmed on consumption, so the very
      // next Backspace is a genuine deletion.
      expect(await simulateKeyDownEvent(LogicalKeyboardKey.backspace), isTrue);
      await simulateKeyUpEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(controller.document.blockById('a')!.plainText, 'image block');
    });

    testWidgets('a Tab ending a composition is swallowed once — no indent; '
        'the next Tab indents normally', (tester) async {
      TextBlock listItem(String id, String text) => TextBlock(
        id: id,
        blockType: ListItemKeys.type,
        segments: [StyledSegment(text)],
      );
      await pumpEditor(tester, [
        listItem('a', 'one'),
        listItem('b', 'two'),
      ], imeFrontend: ImeFrontend.nonDeltaDiff);
      controller.setSelection(DocSelection.collapsed(DocPosition('b', 3)));
      await tester.pump();
      final ime = imeOf(tester);

      // Compose n at the end of "two", then the IME consumes a Tab to end
      // the composition: compositionend reflects FIRST (the same WebKit
      // ordering as the Backspace cancel) ...
      ime.updateEditingValue(
        const TextEditingValue(
          text: '. twon',
          selection: TextSelection.collapsed(offset: 6),
          composing: TextRange(start: 5, end: 6),
        ),
      );
      await tester.pump();
      expect(controller.composing, isNotNull);
      ime.updateEditingValue(
        const TextEditingValue(
          text: '. two',
          selection: TextSelection.collapsed(offset: 5),
        ),
      );
      await tester.pump();
      expect(controller.composing, isNull);

      // ... and the trailing Tab keydown must not indent the block.
      expect(await simulateKeyDownEvent(LogicalKeyboardKey.tab), isTrue);
      await simulateKeyUpEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        controller.document.depthOf(1),
        0,
        reason: 'the composition-ending Tab must not also indent',
      );

      // One-shot: the next Tab is a genuine indent.
      expect(await simulateKeyDownEvent(LogicalKeyboardKey.tab), isTrue);
      await simulateKeyUpEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(controller.document.depthOf(1), 1);
    });

    testWidgets("Chrome's ordering (cancel Backspace deferred by the gate "
        'BEFORE compositionend) never arms — the next Backspace deletes', (
      tester,
    ) async {
      await pumpEditor(tester, [
        para('a', 'hi'),
      ], imeFrontend: ImeFrontend.nonDeltaDiff);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 2)));
      await tester.pump();
      final ime = imeOf(tester);

      // Compose か, then Backspace cancels: on Chrome the keydown reaches
      // the framework while the composition is still live, so the gate
      // defers it to the browser (and notes the deferral) ...
      ime.updateEditingValue(
        const TextEditingValue(
          text: '. hiか',
          selection: TextSelection.collapsed(offset: 5),
          composing: TextRange(start: 4, end: 5),
        ),
      );
      await tester.pump();
      expect(controller.composing, isNotNull);
      expect(await simulateKeyDownEvent(LogicalKeyboardKey.backspace), isFalse);
      await simulateKeyUpEvent(LogicalKeyboardKey.backspace);

      // ... which deletes the composed char and reflects compositionend.
      // The gate-deferred Backspace proved the keydown-first ordering, so
      // the composing-clear must SKIP the arm — a stale arm here would
      // swallow the user's next genuine Backspace for 500 ms.
      ime.updateEditingValue(
        const TextEditingValue(
          text: '. hi',
          selection: TextSelection.collapsed(offset: 4),
        ),
      );
      await tester.pump();
      expect(controller.composing, isNull);
      expect(ime.debugCommitKeySuppressionArmed, isFalse);
      expect([
        for (final e in ime.journal.toJson()) e['kind'],
      ], contains('commitKeySuppressionSkipped'));

      // The user's quick follow-up Backspace is a genuine deletion.
      expect(await simulateKeyDownEvent(LogicalKeyboardKey.backspace), isTrue);
      await simulateKeyUpEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(controller.document.blockById('a')!.plainText, 'h');
    });
  });

  group('browser-chrome blur mid-composition (windowBlur recovery)', () {
    // The wedge this group covers (manual Safari repro): compose にほんご,
    // click the URL bar — browser focus leaves the page WITHOUT blurring
    // Flutter's FocusNode (no detach), and on Safari desktop the engine
    // attaches NO blur listener to its hidden input (engine
    // text_editing.dart, addEventHandlers: `this is!
    // SafariDesktopTextEditingStrategy`), so no connectionClosed arrives
    // either. No composition-ending snapshot ever comes: the composing
    // gate stays closed, typing wedges. Page-level focus loss IS
    // observable as AppLifecycleState.inactive/hidden — the recovery seam.
    Future<void> setLifecycleState(
      WidgetTester tester,
      AppLifecycleState state,
    ) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/lifecycle',
        const StringCodec().encodeMessage(state.toString()),
        (_) {},
      );
    }

    List<Object?> terminateReasons(ImeService ime) => [
      for (final e in ime.journal.events)
        if (e.kind == 'terminate') e.payload['reason'],
    ];

    testWidgets('lifecycle inactive terminates a live diff-frontend '
        'composition (windowBlur): composing cleared, gate open, journaled; '
        'after resumed typing and a fresh composition work', (tester) async {
      await pumpEditor(tester, [
        para('a', ''),
      ], imeFrontend: ImeFrontend.nonDeltaDiff);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 0)));
      await tester.pump();
      final ime = imeOf(tester);
      addTearDown(() => setLifecycleState(tester, AppLifecycleState.resumed));

      ime.updateEditingValue(
        const TextEditingValue(
          text: '. にほんご',
          selection: TextSelection.collapsed(offset: 6),
          composing: TextRange(start: 2, end: 6),
        ),
      );
      await tester.pump();
      expect(controller.composing, isNotNull);
      expect(ime.engineComposing, isTrue);

      // The URL-bar click: window focus leaves, the FocusNode keeps focus,
      // no engine traffic of any kind follows (Safari).
      await setLifecycleState(tester, AppLifecycleState.inactive);
      await tester.pump();

      expect(
        controller.composing,
        isNull,
        reason: 'deactivation commits the composition (native macOS shape)',
      );
      expect(
        ime.engineComposing,
        isFalse,
        reason: 'the hardware-key gate must reopen',
      );
      expect(
        controller.document.blockById('a')!.plainText,
        'にほんご',
        reason: 'commit, not discard',
      );
      expect(terminateReasons(ime), contains('windowBlur'));

      await setLifecycleState(tester, AppLifecycleState.resumed);
      await tester.pump();
      expect(
        ime.isAttached,
        isTrue,
        reason:
            'no detach happened — and no '
            'double-attach either (attach is idempotent)',
      );

      // Typing works against the re-pushed window.
      final shadow = ime.currentTextEditingValue!;
      ime.updateEditingValue(
        TextEditingValue(
          text: '${shadow.text}x',
          selection: TextSelection.collapsed(offset: shadow.text.length + 1),
        ),
      );
      await tester.pump();
      expect(controller.document.blockById('a')!.plainText, 'にほんごx');

      // A fresh composition works: the underline state is live again.
      final shadow2 = ime.currentTextEditingValue!;
      ime.updateEditingValue(
        TextEditingValue(
          text: '${shadow2.text}か',
          selection: TextSelection.collapsed(offset: shadow2.text.length + 1),
          composing: TextRange(
            start: shadow2.text.length,
            end: shadow2.text.length + 1,
          ),
        ),
      );
      await tester.pump();
      expect(controller.composing, isNotNull);
      expect(ime.engineComposing, isTrue);
    });

    testWidgets('the passive-divergence variant: lifecycle inactive resolves '
        'a deferred reconciliation that never installed a ComposingState — '
        'engineComposing reopens the gate and editing keys work after '
        'resumed', (tester) async {
      await pumpEditor(tester, [
        para('a', 'one'),
      ], imeFrontend: ImeFrontend.nonDeltaDiff);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 3)));
      await tester.pump();
      final ime = imeOf(tester);
      addTearDown(() => setLifecycleState(tester, AppLifecycleState.resumed));

      // The composition's FIRST snapshot is unmappable (composing spans a
      // \n): passive divergence arms with NO ComposingState — the gate is
      // held closed by ImeService.engineComposing alone, and no ending
      // snapshot will ever come once the window blurs.
      ime.updateEditingValue(
        const TextEditingValue(
          text: '. one\nx',
          selection: TextSelection.collapsed(offset: 7),
          composing: TextRange(start: 5, end: 7),
        ),
      );
      await tester.pump();
      expect(controller.composing, isNull);
      expect(ime.engineComposing, isTrue);
      // The \n half of the snapshot applied structurally (the split is
      // real; only the composing mapping deferred): ['one', 'x'], caret in
      // the new tail block.
      List<String> blockTexts() => [
        for (final b in controller.document.allBlocks) b.plainText,
      ];
      expect(blockTexts(), ['one', 'x']);
      await simulateKeyDownEvent(LogicalKeyboardKey.backspace);
      await simulateKeyUpEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(blockTexts(), [
        'one',
        'x',
      ], reason: 'gate closed: the key deferred to the IME');

      await setLifecycleState(tester, AppLifecycleState.inactive);
      await tester.pump();

      expect(ime.engineComposing, isFalse, reason: 'the gate must reopen');
      expect(terminateReasons(ime), contains('windowBlur'));

      await setLifecycleState(tester, AppLifecycleState.resumed);
      await tester.pump();

      // The gate is open: backspace reaches the model again (the caret sits
      // after the 'x' the split landed in the tail block).
      expect(await simulateKeyDownEvent(LogicalKeyboardKey.backspace), isTrue);
      await simulateKeyUpEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(blockTexts(), ['one', '']);

      // And a fresh composition still maps and installs ComposingState.
      final shadow = ime.currentTextEditingValue!;
      ime.updateEditingValue(
        TextEditingValue(
          text: '${shadow.text}か',
          selection: TextSelection.collapsed(offset: shadow.text.length + 1),
          composing: TextRange(
            start: shadow.text.length,
            end: shadow.text.length + 1,
          ),
        ),
      );
      await tester.pump();
      expect(controller.composing, isNotNull);
    });

    testWidgets('no live composition: lifecycle inactive terminates nothing '
        '(no spurious terminate push, no quarantine arm)', (tester) async {
      await pumpEditor(tester, [
        para('a', 'hi'),
      ], imeFrontend: ImeFrontend.nonDeltaDiff);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 2)));
      await tester.pump();
      final ime = imeOf(tester);
      addTearDown(() => setLifecycleState(tester, AppLifecycleState.resumed));
      ime.journal.clear();

      await setLifecycleState(tester, AppLifecycleState.inactive);
      await setLifecycleState(tester, AppLifecycleState.resumed);
      await tester.pump();

      expect(terminateReasons(ime), isEmpty);
      expect(ime.debugQuarantineArmed, isFalse);
      expect(ime.isAttached, isTrue);
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
