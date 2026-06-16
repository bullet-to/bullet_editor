import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Day-10 hardware-key MATRIX (architecture §hardware keyboard): vertical
/// ↑/↓ caret movement (geometry-x affinity, cross-block), Cmd/Ctrl line
/// (←/→) and document (↑/↓) boundaries, Shift extension, and Alt+↑/↓
/// `MoveBlock` (with the G13 ordinal-renumber rebuild). All new bindings sit
/// under the composing gate (the gate itself is exercised in the IME suite).
void main() {
  Finder richTextContaining(String text) => find.byWidgetPredicate(
    (w) => w is RichText && w.text.toPlainText().contains(text),
  );

  TextBlock para(String id, String text) => TextBlock(
    id: id,
    blockType: ParagraphKeys.type,
    segments: [StyledSegment(text)],
  );

  TextBlock numbered(String id, String text) => TextBlock(
    id: id,
    blockType: NumberedListKeys.type,
    segments: [StyledSegment(text)],
  );

  late EditorController controller;

  Future<void> pumpEditor(WidgetTester tester, List<TextBlock> blocks) async {
    controller = EditorController(
      document: Document(blocks),
      schema: EditorSchema.standard(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BulletEditor(
            controller: controller,
            autofocus: true,
            textStyle: const TextStyle(fontSize: 16, color: Color(0xFF000000)),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool meta = false,
    bool shift = false,
    bool alt = false,
  }) async {
    if (meta) await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(key);
    if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (meta) await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
  }

  group('vertical caret movement (↑/↓)', () {
    testWidgets('↓ moves to the block below at the same column, ↑ back', (
      tester,
    ) async {
      await pumpEditor(tester, [para('a', 'line one'), para('b', 'line two')]);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 4)));
      await tester.pump();

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(controller.selection!.extent.blockId, 'b');
      expect(controller.selection!.isCollapsed, isTrue);

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(controller.selection!.extent.blockId, 'a');
    });

    testWidgets('Shift+↓ extends the selection into the block below', (
      tester,
    ) async {
      await pumpEditor(tester, [para('a', 'line one'), para('b', 'line two')]);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 4)));
      await tester.pump();

      await press(tester, LogicalKeyboardKey.arrowDown, shift: true);
      expect(controller.selection!.isCollapsed, isFalse);
      expect(controller.selection!.base, DocPosition('a', 4));
      expect(controller.selection!.extent.blockId, 'b');
    });

    testWidgets(
      '↓ holds the goal column across a short intervening line (B2)',
      (tester) async {
        // The middle line is too short to hold the caret's column; the goal
        // column must survive it so the third line lands back at the column,
        // not at the short line's clamped end.
        await pumpEditor(tester, [
          para('a', 'a long first line'),
          para('b', 'x'),
          para('c', 'a long third line'),
        ]);
        controller.setSelection(DocSelection.collapsed(DocPosition('a', 12)));
        await tester.pump();

        await press(tester, LogicalKeyboardKey.arrowDown);
        // 'b' is one char — the column clamps to its end.
        expect(controller.selection!.extent.blockId, 'b');
        expect(controller.selection!.extent.offset, 1);

        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(controller.selection!.extent.blockId, 'c');
        // The remembered column (≈12), NOT 'b''s clamped offset 1.
        expect(controller.selection!.extent.offset, greaterThan(6));
      },
    );

    testWidgets(
      'a horizontal move resets the goal column (B2)',
      (tester) async {
        await pumpEditor(tester, [
          para('a', 'a long first line'),
          para('b', 'x'),
          para('c', 'a long third line'),
        ]);
        controller.setSelection(DocSelection.collapsed(DocPosition('a', 12)));
        await tester.pump();

        await press(tester, LogicalKeyboardKey.arrowDown); // → (b, 1)
        // A horizontal move breaks the vertical run; the next ↓ recomputes the
        // column from 'b''s caret (offset 1), so 'c' lands near the start.
        await press(tester, LogicalKeyboardKey.arrowLeft); // → (b, 0)
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(controller.selection!.extent.blockId, 'c');
        expect(controller.selection!.extent.offset, lessThan(3));
      },
    );
  });

  group('vertical movement across a void (B3)', () {
    TextBlock image(String id) => TextBlock(id: id, blockType: ImageKeys.type);

    testWidgets(
      'Shift+↓ onto an image includes it, then lands on the block below '
      '(no overshoot)',
      (tester) async {
        await pumpEditor(tester, [
          para('a', 'above text'),
          image('img'),
          para('b', 'below text'),
          para('c', 'further down'),
        ]);
        controller.setSelection(DocSelection.collapsed(DocPosition('a', 3)));
        await tester.pump();

        // First Shift+↓ extends ONTO the image — its downstream edge so the
        // void's [0,1) falls inside the selection (it is selected, not skipped).
        await press(tester, LogicalKeyboardKey.arrowDown, shift: true);
        expect(controller.selection!.base, DocPosition('a', 3));
        expect(controller.selection!.extent, DocPosition('img', 1));

        // Second Shift+↓ leaves the (tall) void by a small step → the very
        // next block, not an overshoot past it into 'c'.
        await press(tester, LogicalKeyboardKey.arrowDown, shift: true);
        expect(controller.selection!.extent.blockId, 'b');
      },
    );

    testWidgets('plain ↓ onto an image atomic-selects it, ↑ returns (B2/B3)', (
      tester,
    ) async {
      await pumpEditor(tester, [
        para('a', 'above text here'),
        image('img'),
        para('b', 'below text here'),
      ]);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 8)));
      await tester.pump();

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(
        controller.selection,
        DocSelection(base: DocPosition('img', 0), extent: DocPosition('img', 1)),
      );

      // ↑ off the image returns to the original block at the held column, not
      // the image's left edge (column 0).
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(controller.selection!.extent.blockId, 'a');
      expect(controller.selection!.extent.offset, greaterThan(3));
    });
  });

  group('line boundary (Cmd+←/→)', () {
    testWidgets('Cmd+← goes to line start, Cmd+→ to line end', (tester) async {
      await pumpEditor(tester, [para('a', 'hello world')]);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 5)));
      await tester.pump();

      await press(tester, LogicalKeyboardKey.arrowLeft, meta: true);
      expect(controller.selection!.extent, DocPosition('a', 0));

      await press(tester, LogicalKeyboardKey.arrowRight, meta: true);
      expect(controller.selection!.extent, DocPosition('a', 11));
    });
  });

  group('document boundary (Cmd+↑/↓)', () {
    testWidgets('Cmd+↑ goes to document start, Cmd+↓ to document end', (
      tester,
    ) async {
      await pumpEditor(tester, [
        para('a', 'first'),
        para('b', 'middle'),
        para('c', 'last'),
      ]);
      controller.setSelection(DocSelection.collapsed(DocPosition('b', 2)));
      await tester.pump();

      await press(tester, LogicalKeyboardKey.arrowUp, meta: true);
      expect(controller.selection!.extent, DocPosition('a', 0));

      await press(tester, LogicalKeyboardKey.arrowDown, meta: true);
      expect(controller.selection!.extent, DocPosition('c', 4));
    });
  });

  group('Shift+←/→ extension', () {
    testWidgets('Shift+→ grows the selection one grapheme, holding the base', (
      tester,
    ) async {
      await pumpEditor(tester, [para('a', 'hello')]);
      controller.setSelection(DocSelection.collapsed(DocPosition('a', 1)));
      await tester.pump();

      await press(tester, LogicalKeyboardKey.arrowRight, shift: true);
      await press(tester, LogicalKeyboardKey.arrowRight, shift: true);

      expect(controller.selection!.base, DocPosition('a', 1));
      expect(controller.selection!.extent, DocPosition('a', 3));
    });
  });

  group('scroll caret into view on keyboard movement (B4)', () {
    Future<ScrollController> pumpTall(WidgetTester tester) async {
      controller = EditorController(
        document: Document([
          for (var i = 0; i < 40; i++) para('b$i', 'line number $i'),
        ]),
        schema: EditorSchema.standard(),
      );
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 200,
              child: BulletEditor(
                controller: controller,
                autofocus: true,
                scrollController: scroll,
                textStyle: const TextStyle(
                  fontSize: 16,
                  color: Color(0xFF000000),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return scroll;
    }

    testWidgets('Cmd+↓ to document end scrolls the last block into view', (
      tester,
    ) async {
      final scroll = await pumpTall(tester);
      controller.setSelection(DocSelection.collapsed(DocPosition('b0', 0)));
      await tester.pump();
      expect(scroll.offset, 0);

      await press(tester, LogicalKeyboardKey.arrowDown, meta: true);
      await tester.pumpAndSettle();

      expect(controller.selection!.extent.blockId, 'b39');
      expect(scroll.offset, greaterThan(0));
      // The last block is now laid out and within the viewport.
      final state = tester.state<BulletEditorState>(find.byType(BulletEditor));
      expect(state.registry.geometryOf('b39'), isNotNull);
    });

    testWidgets('repeated ↓ past the viewport edge follows the caret down', (
      tester,
    ) async {
      final scroll = await pumpTall(tester);
      controller.setSelection(DocSelection.collapsed(DocPosition('b0', 0)));
      await tester.pump();

      for (var i = 0; i < 20; i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      expect(scroll.offset, greaterThan(0));
    });
  });

  group('Alt+↑/↓ MoveBlock + ordinal renumber (G13)', () {
    testWidgets('Alt+↑ moves the caret block up among its siblings', (
      tester,
    ) async {
      await pumpEditor(tester, [para('a', 'one'), para('b', 'two'), para('c', 'three')]);
      controller.setSelection(DocSelection.collapsed(DocPosition('b', 0)));
      await tester.pump();

      await press(tester, LogicalKeyboardKey.arrowUp, alt: true);
      expect(controller.document.allBlocks.map((b) => b.id), ['b', 'a', 'c']);
      // Selection rides the reindex (id-based) — still on 'b'.
      expect(controller.selection!.extent.blockId, 'b');
    });

    testWidgets('Alt+↓ at the last sibling is a no-op (boundary policy)', (
      tester,
    ) async {
      await pumpEditor(tester, [para('a', 'one'), para('b', 'two')]);
      controller.setSelection(DocSelection.collapsed(DocPosition('b', 0)));
      await tester.pump();

      await press(tester, LogicalKeyboardKey.arrowDown, alt: true);
      expect(controller.document.allBlocks.map((b) => b.id), ['a', 'b']);
    });

    testWidgets('moving a numbered item renumbers the gutter ordinals', (
      tester,
    ) async {
      await pumpEditor(tester, [
        numbered('n1', 'one'),
        numbered('n2', 'two'),
        numbered('n3', 'three'),
      ]);
      // 'three' starts third → ordinal '3.'.
      final threeRowBefore = find
          .ancestor(
            of: richTextContaining('three'),
            matching: find.byType(Row),
          )
          .first;
      expect(
        find.descendant(of: threeRowBefore, matching: find.text('3.')),
        findsOneWidget,
      );

      controller.setSelection(DocSelection.collapsed(DocPosition('n3', 0)));
      await tester.pump();
      await press(tester, LogicalKeyboardKey.arrowUp, alt: true);

      // Order is now n1, n3, n2 — 'three' is second and must renumber to '2.'
      // even though its block instance is identical (R6 derived-gutter clause).
      expect(controller.document.allBlocks.map((b) => b.id), ['n1', 'n3', 'n2']);
      final threeRowAfter = find
          .ancestor(
            of: richTextContaining('three'),
            matching: find.byType(Row),
          )
          .first;
      expect(
        find.descendant(of: threeRowAfter, matching: find.text('2.')),
        findsOneWidget,
      );
    });
  });
}
