import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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
