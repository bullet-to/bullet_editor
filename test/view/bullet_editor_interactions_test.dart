import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Day 3–4 interaction surface: tap-to-caret over the geometry registry,
/// the midpoint void hit rule, caret painting, the focus surface, and the
/// hardware-key editing skeleton (checkpoint 2).
void main() {
  Finder richTextContaining(String text) => find.byWidgetPredicate(
    (w) => w is RichText && w.text.toPlainText().contains(text),
  );

  TextBlock para(String id, String text) => TextBlock(
    id: id,
    blockType: ParagraphKeys.type,
    segments: [StyledSegment(text)],
  );

  late EditorController controller;

  Future<void> pumpEditor(
    WidgetTester tester,
    List<TextBlock> blocks, {
    bool readOnly = false,
    bool autofocus = false,
  }) async {
    controller = EditorController(
      document: Document(blocks),
      schema: EditorSchema.standard(),
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
    if (autofocus) await tester.pump();
  }

  group('tap-to-caret', () {
    testWidgets('a tap places a collapsed caret in the hit block and focuses '
        'the editor', (tester) async {
      await pumpEditor(tester, [para('a', 'first'), para('b', 'second')]);
      expect(controller.hasFocus, isFalse);

      final rect = tester.getRect(richTextContaining('second'));
      await tester.tapAt(rect.centerLeft + const Offset(2, 0));
      await tester.pump();

      expect(controller.selection, isNotNull);
      expect(controller.selection!.isCollapsed, isTrue);
      expect(controller.selection!.extent.blockId, 'b');
      expect(controller.hasFocus, isTrue);
    });

    testWidgets('a tap in empty space clamps into the nearest block', (
      tester,
    ) async {
      await pumpEditor(tester, [para('a', 'hi')]);
      final rect = tester.getRect(richTextContaining('hi'));
      // Far right of the glyphs (within the row) and well below the content:
      // both clamp to the line/block end rather than missing.
      await tester.tapAt(Offset(rect.center.dx + 300, rect.bottom + 120));
      await tester.pump();

      expect(controller.selection, isNotNull);
      expect(controller.selection!.extent.blockId, 'a');
      expect(controller.selection!.extent.offset, 2);
    });

    testWidgets('a tap on a void block atomic-selects it', (tester) async {
      await pumpEditor(tester, [
        para('a', 'above'),
        TextBlock(id: 'img', blockType: ImageKeys.type),
        para('b', 'below'),
      ]);
      await tester.tapAt(tester.getCenter(find.byType(ImageBlockComponent)));
      await tester.pump();

      expect(
        controller.selection,
        DocSelection(
          base: DocPosition('img', 0),
          extent: DocPosition('img', 1),
        ),
      );
      // The atomic selection renders the tint affordance.
      expect(
        find.byWidgetPredicate(
          (w) => w is Container && w.foregroundDecoration != null,
        ),
        findsOneWidget,
      );
    });
  });

  group('void selection affordances (checkpoint-2 findings)', () {
    testWidgets(
      'the divider has a tappable band and a visible selected state',
      (tester) async {
        await pumpEditor(tester, [
          para('a', 'above'),
          TextBlock(id: 'd', blockType: DividerKeys.type),
          para('b', 'below'),
        ]);
        // A 1px rule is an unusable midpoint-rule target and an invisible
        // tint; the component provides a band around the rule.
        final band = tester.getSize(find.byType(DividerBlockComponent));
        expect(band.height, greaterThanOrEqualTo(8));

        await tester.tapAt(
          tester.getCenter(find.byType(DividerBlockComponent)),
        );
        await tester.pump();
        expect(controller.selection!.base.blockId, 'd');
        expect(
          find.byWidgetPredicate(
            (w) => w is Container && w.foregroundDecoration != null,
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('image corners are clipped to match the selection tint', (
      tester,
    ) async {
      await pumpEditor(tester, [
        TextBlock(id: 'img', blockType: ImageKeys.type),
        para('a', 'after'),
      ]);
      expect(
        find.descendant(
          of: find.byType(ImageBlockComponent),
          matching: find.byType(ClipRRect),
        ),
        findsOneWidget,
      );
    });
  });

  group('void geometry (midpoint hit rule, G5)', () {
    testWidgets('top half resolves upstream (0), bottom half downstream (1)', (
      tester,
    ) async {
      await pumpEditor(tester, [
        para('a', 'above'),
        TextBlock(id: 'img', blockType: ImageKeys.type),
      ]);
      final state = tester.state<BulletEditorState>(find.byType(BulletEditor));
      final geometry = state.registry.geometryOf('img');
      expect(geometry, isNotNull, reason: 'voids register geometry (GATE-L)');

      final height = geometry!.renderBox.size.height;
      expect(geometry.offsetForLocalPoint(Offset(10, height * 0.25)), 0);
      expect(geometry.offsetForLocalPoint(Offset(10, height * 0.75)), 1);
      expect(geometry.rectsForRange(0, 1), isNotEmpty);
      expect(geometry.wordBoundaryAt(0), const TextRange(start: 0, end: 1));
    });
  });

  group('caret painting', () {
    // The caret layer is a CustomPaint with a foregroundPainter directly
    // over the block's RichText (the debug Banner is also a foregroundPainter
    // CustomPaint, so the child constraint matters).
    final caretLayer = find.byWidgetPredicate(
      (w) =>
          w is CustomPaint &&
          w.foregroundPainter != null &&
          w.child is RichText,
    );

    testWidgets('the focused caret block paints a caret layer', (tester) async {
      await pumpEditor(tester, [para('a', 'text')]);

      // No caret before focus+selection.
      expect(caretLayer, findsNothing);

      await tester.tapAt(tester.getCenter(richTextContaining('text')));
      await tester.pump();

      expect(caretLayer, findsOneWidget);
      expect(
        find.descendant(of: caretLayer, matching: richTextContaining('text')),
        findsOneWidget,
      );
    });

    testWidgets('clearing focus removes the caret layer', (tester) async {
      await pumpEditor(tester, [para('a', 'text')]);
      await tester.tapAt(tester.getCenter(richTextContaining('text')));
      await tester.pump();
      expect(caretLayer, findsOneWidget);

      controller.clearFocus();
      // Focus changes apply in a microtask; the listener's setState lands
      // a frame later.
      await tester.pump();
      await tester.pump();

      expect(caretLayer, findsNothing);
    });
  });

  group('focus surface', () {
    testWidgets('hasFocus / requestFocus / clearFocus route to the editor '
        'focus node', (tester) async {
      await pumpEditor(tester, [para('a', 'text')]);
      expect(controller.hasFocus, isFalse);

      controller.requestFocus();
      await tester.pump();
      expect(controller.hasFocus, isTrue);

      controller.clearFocus();
      await tester.pump();
      expect(controller.hasFocus, isFalse);
    });

    testWidgets('an app-supplied focusNode is used and not disposed', (
      tester,
    ) async {
      final node = FocusNode(debugLabel: 'app');
      addTearDown(node.dispose);
      controller = EditorController(
        document: Document([para('a', 'text')]),
        schema: EditorSchema.standard(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BulletEditor(controller: controller, focusNode: node),
          ),
        ),
      );

      controller.requestFocus();
      await tester.pump();
      expect(node.hasFocus, isTrue);
    });
  });

  group('hardware-key skeleton (checkpoint 2)', () {
    testWidgets('typing a character inserts at the caret', (tester) async {
      await pumpEditor(tester, [para('a', 'helo')], autofocus: true);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 3)));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();

      expect(controller.document.blockById('a')!.plainText, 'hello');
    });

    testWidgets('Enter splits, Backspace merges back', (tester) async {
      await pumpEditor(tester, [para('a', 'onetwo')], autofocus: true);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 3)));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(controller.document.allBlocks.length, 2);
      expect(controller.document.allBlocks[0].plainText, 'one');
      expect(controller.document.allBlocks[1].plainText, 'two');

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(controller.document.allBlocks.length, 1);
      expect(controller.document.allBlocks[0].plainText, 'onetwo');
    });

    testWidgets('Tab indents the caret block under its previous sibling', (
      tester,
    ) async {
      await pumpEditor(tester, [
        TextBlock(
          id: 'l1',
          blockType: ListItemKeys.type,
          segments: [const StyledSegment('one')],
        ),
        TextBlock(
          id: 'l2',
          blockType: ListItemKeys.type,
          segments: [const StyledSegment('two')],
        ),
      ], autofocus: true);
      controller.setSelection(DocSelection.collapsed(DocPosition('l2', 0)));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      expect(controller.document.blockById('l1')!.children.map((b) => b.id), [
        'l2',
      ]);
    });

    testWidgets('arrow keys move the caret and hop blocks', (tester) async {
      await pumpEditor(tester, [
        para('a', 'ab'),
        para('b', 'cd'),
      ], autofocus: true);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 2)));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(controller.selection!.extent, DocPosition('b', 0));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(controller.selection!.extent, DocPosition('a', 2));
    });

    testWidgets('arrowing onto a void atomic-selects it; arrowing on moves '
        'past it', (tester) async {
      await pumpEditor(tester, [
        para('a', 'x'),
        TextBlock(id: 'img', blockType: ImageKeys.type),
        para('b', 'y'),
      ], autofocus: true);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 1)));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        controller.selection,
        DocSelection(
          base: DocPosition('img', 0),
          extent: DocPosition('img', 1),
        ),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(controller.selection!.extent, DocPosition('b', 0));
    });

    testWidgets('Cmd/Ctrl+Z undoes, Shift adds redo', (tester) async {
      await pumpEditor(tester, [para('a', '')], autofocus: true);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 0)));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.pump();
      expect(controller.document.blockById('a')!.plainText, 'h');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(controller.document.blockById('a')!.plainText, '');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(controller.document.blockById('a')!.plainText, 'h');
    });

    testWidgets('readOnly: taps place the caret but keys are inert', (
      tester,
    ) async {
      await pumpEditor(tester, [para('a', 'text')], readOnly: true);
      await tester.tapAt(tester.getCenter(richTextContaining('text')));
      await tester.pump();
      expect(controller.selection, isNotNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
      await tester.pump();
      expect(controller.document.blockById('a')!.plainText, 'text');
    });
  });
}
