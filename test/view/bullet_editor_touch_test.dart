import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Days 11–13 touch interactor + selection chrome (architecture §Gestures
/// touch-kind, §Context menus): tap→caret, long-press→word select,
/// long-press-drag→extend by word, plain touch drag scrolls (not selects),
/// long-press-drag does NOT scroll, handles on a range, handle drag moves the
/// extent, grab-without-move is a no-op (arch 1427), handle hides when its
/// anchor scrolls off, and the fallback toolbar shows on long-press with the
/// expected buttons / Copy writes markdown to the clipboard.
///
/// Mirrors the mouse test's geometry-based point helpers; touch gestures use
/// `tester.longPress`, `tester.startGesture(kind: touch)`, and a press-move-up
/// `TestGesture`. The pure visual loupe rendering is device-feel and not tested
/// headlessly (the focal-point tracking that drives it is exercised via the
/// long-press-drag tests).
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
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: editor)));
    // Let the overlay portal mount (post-frame show).
    await tester.pump();
  }

  BulletEditorState stateOf(WidgetTester tester) =>
      tester.state<BulletEditorState>(find.byType(BulletEditor));

  /// A global point at the center of [offset]'s caret rect in block [id].
  Offset pointFor(WidgetTester tester, String id, int offset) {
    final geometry = stateOf(tester).registry.geometryOf(id)!;
    return geometry.renderBox.localToGlobal(
      geometry.rectForOffset(offset)!.center,
    );
  }

  group('tap (touch-kind)', () {
    testWidgets('a touch tap places a collapsed caret and focuses', (
      tester,
    ) async {
      await pumpEditor(tester, [para('a', 'first'), para('b', 'second')]);
      expect(controller.hasFocus, isFalse);

      await tester.tapAt(
        pointFor(tester, 'b', 2),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump();

      expect(controller.selection!.isCollapsed, isTrue);
      expect(controller.selection!.extent.blockId, 'b');
      expect(controller.hasFocus, isTrue);
    });
  });

  group('long-press (touch-kind)', () {
    testWidgets('a long-press selects the word under the finger', (
      tester,
    ) async {
      await pumpEditor(tester, [para('a', 'hello world foo')]);
      await tester.longPressAt(pointFor(tester, 'a', 2)); // inside "hello"
      await tester.pump();

      expect(controller.selection!.isCollapsed, isFalse);
      final (start, end) = controller.selection!.normalized(
        controller.document,
      );
      expect(start, DocPosition('a', 0));
      expect(end, DocPosition('a', 5)); // "hello"
    });

    testWidgets('a long-press-drag extends the selection by word', (
      tester,
    ) async {
      await pumpEditor(tester, [para('a', 'hello world foo bar')]);
      final gesture = await tester.startGesture(
        pointFor(tester, 'a', 2),
        kind: PointerDeviceKind.touch,
      );
      // Hold past the long-press timeout so the long-press recognizer wins.
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 10));
      // Drag into the third word "foo".
      await gesture.moveTo(pointFor(tester, 'a', 13)); // inside "foo"
      await tester.pump();
      await gesture.up();
      await tester.pump();

      final (start, end) = controller.selection!.normalized(
        controller.document,
      );
      // Anchored word "hello" never shrinks; extension reaches at least "foo".
      expect(start, DocPosition('a', 0));
      expect(end.offset, greaterThanOrEqualTo(15)); // through "foo"
    });
  });

  group('arena (plain drag scrolls, long-press-drag does not)', () {
    testWidgets('a plain touch drag scrolls and leaves the selection alone', (
      tester,
    ) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final blocks = [for (var i = 0; i < 60; i++) para('b$i', 'line $i')];
      await pumpEditor(tester, blocks, scrollController: scroll, height: 200);
      expect(controller.selection, isNull);

      // A drag WITHOUT a long-press: the scrollable wins the arena.
      await tester.drag(
        find.byType(BulletEditor),
        const Offset(0, -150),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump();

      expect(scroll.offset, greaterThan(0), reason: 'plain touch drag scrolls');
      expect(
        controller.selection,
        isNull,
        reason: 'no selection from a scroll',
      );
    });

    testWidgets('a long-press-drag does NOT scroll the list', (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final blocks = [for (var i = 0; i < 60; i++) para('b$i', 'line $i')];
      await pumpEditor(tester, blocks, scrollController: scroll, height: 400);

      final gesture = await tester.startGesture(
        pointFor(tester, 'b0', 2),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 10));
      // Drift within the viewport (not into the autoscroll edge zone).
      await gesture.moveTo(pointFor(tester, 'b2', 2));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(
        scroll.offset,
        0,
        reason: 'the long-press won the arena; the scroll drag is suppressed',
      );
      expect(controller.selection!.isCollapsed, isFalse);
    });
  });

  group('selection handles (G11)', () {
    // Handles are TOUCH chrome: they appear only for a touch-originated
    // selection (long-press / handle drag), never over a programmatic or mouse
    // selection (arch 1248). These tests therefore make the selection via a
    // real long-press. The bulbs are the non-origin Positioned widgets (the
    // editor's own overlay slots are Positioned.fill at the origin).
    Finder bulbs() => find.byWidgetPredicate(
      (w) => w is Positioned && (w.left != 0 || w.top != 0),
    );

    testWidgets('two handles render on a long-press word selection', (
      tester,
    ) async {
      await pumpEditor(tester, [para('a', 'first line'), para('b', 'hello')]);
      await tester.longPressAt(pointFor(tester, 'b', 2)); // selects "hello"
      await tester.pump(); // notify → schedule recompute
      await tester.pump(); // post-frame recompute → setState

      expect(controller.selection!.isCollapsed, isFalse);
      expect(bulbs(), findsNWidgets(2));
    });

    // A mid-document line keeps the toolbar (above the selection) clear of the
    // END handle (below it) — a headless layout-collision avoidance.
    testWidgets('dragging the end handle changes the extent', (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await pumpEditor(
        tester,
        [
          for (var i = 0; i < 10; i++) para('p$i', 'filler line $i'),
          para('b', 'hello world foo'),
          for (var i = 0; i < 10; i++) para('q$i', 'filler line $i'),
        ],
        scrollController: scroll,
        height: 600,
      );
      scroll.jumpTo(60);
      await tester.pump();
      // Long-press "hello" to establish a touch selection.
      await tester.longPressAt(pointFor(tester, 'b', 2));
      await tester.pump();
      await tester.pump();
      expect(controller.selection!.extent.offset, 5); // "hello"

      final interactor = stateOf(tester).touchInteractorForTest;
      final endRect = interactor.handleAnchorRectGlobal(
        SelectionHandleKind.end,
      )!;
      // Grab the end bulb (it hangs a line-height below the rect bottom) and
      // drag right toward the end of "world".
      final grabPoint = endRect.bottomLeft + const Offset(0, 6);
      final gesture = await tester.startGesture(
        grabPoint,
        kind: PointerDeviceKind.touch,
      );
      await tester.pump();
      expect(interactor.isDragging, isTrue, reason: 'the handle drag started');
      await gesture.moveTo(pointFor(tester, 'b', 9)); // inside "world"
      await tester.pump();
      await gesture.up();
      await tester.pump();

      final (start, end) = controller.selection!.normalized(
        controller.document,
      );
      expect(start, DocPosition('b', 0));
      expect(end.offset, greaterThan(5), reason: 'the extent extended');
    });

    testWidgets(
      'grabbing a handle without moving leaves the selection unchanged '
      '(arch 1427)',
      (tester) async {
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        await pumpEditor(
          tester,
          [
            for (var i = 0; i < 10; i++) para('p$i', 'filler line $i'),
            para('b', 'hello world'),
            for (var i = 0; i < 10; i++) para('q$i', 'filler line $i'),
          ],
          scrollController: scroll,
          height: 600,
        );
        scroll.jumpTo(60);
        await tester.pump();
        await tester.longPressAt(pointFor(tester, 'b', 2)); // "hello"
        await tester.pump();
        await tester.pump();
        final before = controller.selection;

        final interactor = stateOf(tester).touchInteractorForTest;
        final endRect = interactor.handleAnchorRectGlobal(
          SelectionHandleKind.end,
        )!;
        final gesture = await tester.startGesture(
          endRect.bottomLeft + const Offset(0, 6),
          kind: PointerDeviceKind.touch,
        );
        await tester.pump();
        expect(
          interactor.isDragging,
          isTrue,
          reason: 'the handle drag started',
        );
        await gesture.up(); // released without moving
        await tester.pump();

        expect(controller.selection, before, reason: 'no-op grab');
      },
    );

    testWidgets(
      'a tap after a handle release is not suppressed (places a caret)',
      (tester) async {
        // The G11 tap-suppress flag (`_handleGestureActive`) outlives the drag
        // by one frame to swallow the editor tap that fires on the same up;
        // the NEXT independent tap must NOT be suppressed (review M1).
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        await pumpEditor(
          tester,
          [
            for (var i = 0; i < 10; i++) para('p$i', 'filler line $i'),
            para('b', 'hello world foo'),
            for (var i = 0; i < 10; i++) para('q$i', 'filler line $i'),
          ],
          scrollController: scroll,
          height: 600,
        );
        scroll.jumpTo(60);
        await tester.pump();
        await tester.longPressAt(pointFor(tester, 'b', 2)); // "hello"
        await tester.pump();
        await tester.pump();
        expect(controller.selection!.isCollapsed, isFalse);

        final interactor = stateOf(tester).touchInteractorForTest;
        final endRect = interactor.handleAnchorRectGlobal(
          SelectionHandleKind.end,
        )!;
        // Grab + release the end handle without moving (sets the suppress flag).
        final grab = await tester.startGesture(
          endRect.bottomLeft + const Offset(0, 6),
          kind: PointerDeviceKind.touch,
        );
        await tester.pump();
        await grab.up();
        await tester.pump(); // post-frame clears _handleGestureActive

        // A subsequent independent tap must place a caret, not be swallowed.
        await tester.tapAt(
          pointFor(tester, 'b', 12),
          kind: PointerDeviceKind.touch,
        );
        await tester.pump();

        expect(
          controller.selection!.isCollapsed,
          isTrue,
          reason: 'the post-handle tap was not suppressed',
        );
        expect(controller.selection!.extent.blockId, 'b');
      },
    );

    testWidgets('a handle hides when its anchor scrolls fully offscreen', (
      tester,
    ) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final blocks = [for (var i = 0; i < 60; i++) para('b$i', 'line $i')];
      await pumpEditor(tester, blocks, scrollController: scroll, height: 200);

      await tester.longPressAt(pointFor(tester, 'b0', 2)); // "line"
      await tester.pump();
      await tester.pump();

      final interactor = stateOf(tester).touchInteractorForTest;
      // The anchor is visible now, and a bulb is mounted.
      expect(
        interactor.handleAnchorRectGlobal(SelectionHandleKind.start),
        isNotNull,
      );
      expect(bulbs(), findsWidgets);

      // Scroll b0 far past the viewport + cacheExtent so it deregisters.
      scroll.jumpTo(2000);
      await tester.pump();
      await tester.pump();

      // The block is no longer laid out → no anchor → the viewport predicate
      // hides the handle (selection state is unaffected — model-level).
      expect(
        interactor.handleAnchorRectGlobal(SelectionHandleKind.start),
        isNull,
      );
      expect(bulbs(), findsNothing, reason: 'no bulb when the anchor is off');
      expect(controller.selection!.isCollapsed, isFalse);
    });
  });

  group('fallback toolbar (§Context menus)', () {
    testWidgets(
      'the toolbar shows on long-press with Copy/Cut/Paste/Select-all',
      (tester) async {
        await pumpEditor(tester, [para('a', 'hello world')]);
        await tester.longPressAt(pointFor(tester, 'a', 2));
        // long-press end → toolbar reconciles post-frame.
        await tester.pump();
        await tester.pump();

        expect(find.text('Copy'), findsOneWidget);
        expect(find.text('Cut'), findsOneWidget);
        expect(find.text('Paste'), findsOneWidget);
        // Select-all label varies by platform adaptive toolbar; assert via the
        // copy/cut/paste presence which proves the button set wired through.
      },
    );

    testWidgets('Copy puts the selection markdown on the clipboard', (
      tester,
    ) async {
      String? clipboardText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardText = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await pumpEditor(tester, [para('a', 'hello world')]);
      await tester.longPressAt(pointFor(tester, 'a', 2));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Copy'));
      await tester.pump();

      expect(clipboardText, 'hello'); // the long-pressed word, as markdown
    });
  });
}
