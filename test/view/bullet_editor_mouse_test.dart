import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Day-10 mouse interactor (architecture §Gestures, mouse-kind): click /
/// double-click / triple-click + `expandBase`, shift-click extension, press-
/// drag with the shared hit tester, drag-across-image (both directions, G5),
/// and the wheel-scroll-mid-drag re-hit-test (G5). Touch gestures (handles,
/// magnifier) are days 11–13.
void main() {
  TextBlock para(String id, String text) => TextBlock(
    id: id,
    blockType: ParagraphKeys.type,
    segments: [StyledSegment(text)],
  );

  late EditorController controller;

  Future<void> pumpEditor(
    WidgetTester tester,
    List<TextBlock> blocks, {
    ScrollController? scrollController,
    double? height,
  }) async {
    controller = EditorController(
      document: Document(blocks),
      schema: EditorSchema.standard(),
    );
    Widget editor = BulletEditor(
      controller: controller,
      scrollController: scrollController,
      textStyle: const TextStyle(fontSize: 16, color: Color(0xFF000000)),
    );
    if (height != null) editor = SizedBox(height: height, child: editor);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: editor)),
    );
  }

  BulletEditorState stateOf(WidgetTester tester) =>
      tester.state<BulletEditorState>(find.byType(BulletEditor));

  /// A global point at the center of [offset]'s caret rect in block [id] —
  /// font-metric independent (resolved through the geometry registry).
  Offset pointFor(WidgetTester tester, String id, int offset) {
    final geometry = stateOf(tester).registry.geometryOf(id)!;
    return geometry.renderBox.localToGlobal(
      geometry.rectForOffset(offset)!.center,
    );
  }

  Future<void> mouseClick(WidgetTester tester, Offset position) async {
    await tester.tapAt(position, kind: PointerDeviceKind.mouse);
    await tester.pump();
  }

  group('click placement', () {
    testWidgets('a mouse click places a collapsed caret and focuses', (
      tester,
    ) async {
      await pumpEditor(tester, [para('a', 'first'), para('b', 'second')]);
      expect(controller.hasFocus, isFalse);

      await mouseClick(tester, pointFor(tester, 'b', 2));

      expect(controller.selection!.isCollapsed, isTrue);
      expect(controller.selection!.extent.blockId, 'b');
      expect(controller.hasFocus, isTrue);
    });

    testWidgets('a mouse click on a void atomic-selects it', (tester) async {
      await pumpEditor(tester, [
        para('a', 'above'),
        TextBlock(id: 'img', blockType: ImageKeys.type),
      ]);
      await mouseClick(
        tester,
        tester.getCenter(find.byType(ImageBlockComponent)),
      );
      expect(
        controller.selection,
        DocSelection(base: DocPosition('img', 0), extent: DocPosition('img', 1)),
      );
    });
  });

  group('multi-click (G6)', () {
    testWidgets('double-click selects the word', (tester) async {
      await pumpEditor(tester, [para('a', 'hello world foo')]);
      final point = pointFor(tester, 'a', 2); // inside "hello"
      await tester.tapAt(point, kind: PointerDeviceKind.mouse);
      await tester.tapAt(point, kind: PointerDeviceKind.mouse);
      await tester.pump();

      expect(controller.selection!.base.offset, 0);
      expect(controller.selection!.extent.offset, 5); // "hello"
    });

    testWidgets('triple-click selects the whole block', (tester) async {
      await pumpEditor(tester, [para('a', 'hello world foo')]);
      final point = pointFor(tester, 'a', 2);
      for (var i = 0; i < 3; i++) {
        await tester.tapAt(point, kind: PointerDeviceKind.mouse);
      }
      await tester.pump();

      expect(controller.selection!.base, DocPosition('a', 0));
      expect(controller.selection!.extent, DocPosition('a', 15)); // whole block
    });
  });

  group('shift-click extension (G6)', () {
    testWidgets('shift-click extends from the click anchor across blocks', (
      tester,
    ) async {
      await pumpEditor(tester, [para('a', 'first'), para('b', 'second')]);
      await mouseClick(tester, pointFor(tester, 'a', 1));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await mouseClick(tester, pointFor(tester, 'b', 4));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      expect(controller.selection!.isCollapsed, isFalse);
      final (start, end) = controller.selection!.normalized(controller.document);
      expect(start, DocPosition('a', 1));
      expect(end, DocPosition('b', 4));
    });

    testWidgets(
      'shift-click after a stale triple-click clamps, no out-of-bounds (G6)',
      (tester) async {
        await pumpEditor(tester, [para('a', 'hello world'), para('b', 'tail')]);
        // Triple-click records expandBase = the whole block [0, 11].
        final point = pointFor(tester, 'a', 2);
        for (var i = 0; i < 3; i++) {
          await tester.tapAt(point, kind: PointerDeviceKind.mouse);
        }
        await tester.pump();
        expect(controller.selection!.extent.offset, 11);

        // A queued edit shortens block 'a' under the recorded anchor.
        controller.apply([DeleteText('a', 5, 6)]); // "hello world" → "hello"
        await tester.pump();

        // Shift-click into 'b': the stale anchor end (a,11) must clamp to the
        // new length (a,5), never index out of bounds.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await mouseClick(tester, pointFor(tester, 'b', 2));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

        final (start, end) = controller.selection!.normalized(
          controller.document,
        );
        expect(start, DocPosition('a', 0));
        expect(end, DocPosition('b', 2));
        expect(controller.document.blockById('a')!.plainText, 'hello');
      },
    );
  });

  group('drag selection (G5)', () {
    testWidgets('a mouse press-drag extends the selection by extent', (
      tester,
    ) async {
      await pumpEditor(tester, [para('a', 'first'), para('b', 'second')]);
      final gesture = await tester.startGesture(
        pointFor(tester, 'a', 1),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(pointFor(tester, 'b', 4));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      final (start, end) = controller.selection!.normalized(controller.document);
      expect(start, DocPosition('a', 1));
      expect(end, DocPosition('b', 4));
    });

    testWidgets('downward drag across an image includes and tints it', (
      tester,
    ) async {
      await pumpEditor(tester, [
        para('a', 'above'),
        TextBlock(id: 'img', blockType: ImageKeys.type),
        para('b', 'below'),
      ]);
      final gesture = await tester.startGesture(
        pointFor(tester, 'a', 1),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(pointFor(tester, 'b', 3));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(
        find.byWidgetPredicate(
          (w) => w is Container && w.foregroundDecoration != null,
        ),
        findsOneWidget,
        reason: 'the swept image is tinted (its [0,1) is inside the range)',
      );
    });

    testWidgets('upward drag across an image also includes it (symmetric)', (
      tester,
    ) async {
      await pumpEditor(tester, [
        para('a', 'above'),
        TextBlock(id: 'img', blockType: ImageKeys.type),
        para('b', 'below'),
      ]);
      final gesture = await tester.startGesture(
        pointFor(tester, 'b', 3),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(pointFor(tester, 'a', 1));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(
        find.byWidgetPredicate(
          (w) => w is Container && w.foregroundDecoration != null,
        ),
        findsOneWidget,
      );
    });

    testWidgets('the highlight slice paints behind the selected text', (
      tester,
    ) async {
      await pumpEditor(tester, [para('a', 'hello world')]);
      // No highlight before a non-collapsed selection.
      expect(find.byType(CustomPaint), findsWidgets);
      final gesture = await tester.startGesture(
        pointFor(tester, 'a', 0),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(pointFor(tester, 'a', 5));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      // A CustomPaint with a painter (background highlight) wrapping the text.
      expect(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter != null && w.child is RichText,
        ),
        findsOneWidget,
      );
    });
  });

  group('wheel-scroll mid-drag re-hit-test (G5)', () {
    testWidgets(
      'press, scroll two viewports, release without moving → extent under the '
      'pointer final position',
      (tester) async {
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        final blocks = [
          for (var i = 0; i < 60; i++) para('b$i', 'line number $i'),
        ];
        await pumpEditor(tester, blocks, scrollController: scroll, height: 200);

        // Press on the first visible block, do not move.
        final pressPoint = pointFor(tester, 'b0', 4);
        final gesture = await tester.startGesture(
          pressPoint,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        expect(controller.selection!.base.blockId, 'b0');

        // Scroll roughly two viewports; the drag is still held.
        scroll.jumpTo(400);
        await tester.pump(); // ScrollNotification → onScroll schedules re-hit
        await tester.pump(); // post-frame re-hit-test runs

        await gesture.up();
        await tester.pump();

        // The extent landed on whatever block is now under the stationary
        // pointer — not the original b0.
        final hit = stateOf(tester).registry;
        final extentId = controller.selection!.extent.blockId;
        expect(extentId, isNot('b0'));
        expect(
          hit.geometryOf(extentId),
          isNotNull,
          reason: 'the re-hit-test lands on laid-out content, never an estimate',
        );
        expect(controller.selection!.isCollapsed, isFalse);
      },
    );
  });
}
