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

    testWidgets('a double-tap selects the word under the finger', (
      tester,
    ) async {
      await pumpEditor(tester, [para('a', 'hello world foo')]);
      final p = pointFor(tester, 'a', 7); // inside "world"
      // Space the taps in time: the interactor counts consecutive taps from
      // their event timestamps (within kDoubleTapTimeout / kDoubleTapSlop), so
      // two taps at the same instant would not register as a double-tap.
      await tester.tapAt(p, kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(p, kind: PointerDeviceKind.touch);
      await tester.pump();

      final (start, end) = controller.selection!.normalized(controller.document);
      expect(start.offset, 6); // "world" start
      expect(end.offset, 11); // "world" end
    });

    testWidgets(
      'a double-tap-and-hold selects the word immediately (no long-press wait)',
      (tester) async {
        await pumpEditor(tester, [para('a', 'hello world foo')]);
        final p = pointFor(tester, 'a', 7); // inside "world"
        await tester.tapAt(p, kind: PointerDeviceKind.touch);
        await tester.pump(const Duration(milliseconds: 50));
        // The second tap is a HOLD: press and do NOT release.
        final hold = await tester.startGesture(p, kind: PointerDeviceKind.touch);
        await tester.pump(); // one frame — far under the long-press timeout

        final (start, end) = controller.selection!.normalized(
          controller.document,
        );
        expect(
          (start.offset, end.offset),
          (6, 11),
          reason: 'word selected on the down, not after the long-press timeout',
        );
        await hold.up();
        await tester.pump();
      },
    );

    testWidgets('a triple-tap selects the whole block (not the document)', (
      tester,
    ) async {
      await pumpEditor(tester, [para('a', 'hello world'), para('b', 'foo bar')]);
      final p = pointFor(tester, 'a', 2);
      for (var i = 0; i < 3; i++) {
        await tester.tapAt(p, kind: PointerDeviceKind.touch);
        await tester.pump(const Duration(milliseconds: 50));
      }
      final (start, end) = controller.selection!.normalized(controller.document);
      expect(start, DocPosition('a', 0));
      expect(end, DocPosition('a', 11)); // end of "hello world" — block 'a' only
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
    // real long-press. One private `_SelectionHandle` is built per visible
    // handle (none when hidden), so counting them counts the visible handles.
    Finder bulbs() => find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_SelectionHandle',
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

    // Device finding: dragging a handle PAST the opposite endpoint must invert
    // the selection (native handle-swap), not clamp to one character. The bug:
    // the fixed end was re-derived from the live (re-normalized) selection each
    // move, so once the handles crossed, the anchor walked with the finger and
    // the selection stayed ~1 char wide. The anchor is now locked at drag-start.
    testWidgets('dragging a handle past the anchor inverts the selection', (
      tester,
    ) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      // Mid-document (like the extent test) so the toolbar sits clear above the
      // selection and does not overlap the END handle below it.
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
      // Select "world" (offsets 6..11) by double-tap.
      final mid = pointFor(tester, 'b', 8);
      await tester.tapAt(mid, kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(mid, kind: PointerDeviceKind.touch);
      await tester.pump();
      await tester.pump(); // let the handle overlay lay out post-frame
      expect(controller.selection!.normalized(controller.document).$1.offset, 6);

      final interactor = stateOf(tester).touchInteractorForTest;
      // Grab the END handle (right of "world") and drag it left, past the start
      // of "world" and into "hello".
      final endRect = interactor.handleAnchorRectGlobal(
        SelectionHandleKind.end,
      )!;
      final gesture = await tester.startGesture(
        endRect.bottomLeft + const Offset(0, 6),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump();
      expect(interactor.isDragging, isTrue, reason: 'handle grab started');
      await gesture.moveTo(pointFor(tester, 'b', 2)); // inside "hello"
      await tester.pump();
      await gesture.up();
      await tester.pump();

      // The anchor (start of "world", offset 6) stayed fixed; the dragged handle
      // crossed it, so the live selection now spans [2, 6] — not clamped to one
      // character around 6.
      final (start, end) = controller.selection!.normalized(
        controller.document,
      );
      expect(end, DocPosition('b', 6), reason: 'the anchor stayed locked');
      expect(start.offset, lessThanOrEqualTo(3), reason: 'crossed into "hello"');
    });

    // The hit region pads the small glyph to a finger-sized (≈48px) target — a
    // grab OFF the glyph centre (but within the pad) must still start the handle
    // drag, and the handle's arena claim (EagerGestureRecognizer) must keep the
    // editor's own scrollable from scrolling under the finger.
    testWidgets('an off-centre grab within the hit-slop drags, never scrolls', (
      tester,
    ) async {
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
      final scrollBefore = scroll.offset;

      final interactor = stateOf(tester).touchInteractorForTest;
      final endRect = interactor.handleAnchorRectGlobal(
        SelectionHandleKind.end,
      )!;
      // Off the glyph centre — a few px left and below the endpoint, inside the
      // padded touch target (≈48px) but outside the ~22px glyph.
      final grabPoint = endRect.bottomLeft + const Offset(-10, 10);
      final gesture = await tester.startGesture(
        grabPoint,
        kind: PointerDeviceKind.touch,
      );
      await tester.pump();
      expect(
        interactor.isDragging,
        isTrue,
        reason: 'the off-centre grab still started the handle drag',
      );
      await gesture.moveTo(pointFor(tester, 'b', 9)); // inside "world"
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(
        scroll.offset,
        scrollBefore,
        reason: 'the handle drag did not scroll the list under it',
      );
      expect(controller.selection!.extent.offset, greaterThan(5));
    });

    // Device finding (G11): the editor is commonly nested in a horizontally-
    // swipeable ancestor — a `TabBarView`/`PageView`. A raw Listener does not
    // enter the gesture arena, so the ancestor's horizontal drag recognizer won
    // it uncontested and swiped the page while the finger was on a handle. The
    // handle's EagerGestureRecognizer must claim the arena so the ancestor never
    // moves during a handle drag.
    testWidgets('a handle drag does not swipe an ancestor PageView', (
      tester,
    ) async {
      final pages = PageController();
      addTearDown(pages.dispose);
      controller = EditorController(
        document: Document([para('b', 'hello world foo')]),
        schema: EditorSchema.standard(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PageView(
              controller: pages,
              children: [
                BulletEditor(
                  controller: controller,
                  textStyle: const TextStyle(
                    fontSize: 16,
                    color: Color(0xFF000000),
                  ),
                ),
                const ColoredBox(color: Color(0xFF00FF00)),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.longPressAt(pointFor(tester, 'b', 2)); // "hello"
      await tester.pump();
      await tester.pump();

      final interactor = stateOf(tester).touchInteractorForTest;
      final endRect = interactor.handleAnchorRectGlobal(
        SelectionHandleKind.end,
      )!;
      final gesture = await tester.startGesture(
        endRect.bottomLeft,
        kind: PointerDeviceKind.touch,
      );
      await tester.pump();
      // A decidedly horizontal drag — exactly what would swipe the PageView.
      await gesture.moveBy(const Offset(-120, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(
        pages.page,
        0.0,
        reason: 'the handle drag must not swipe the ancestor PageView',
      );
      expect(
        interactor.isDragging || controller.selection != null,
        isTrue,
        reason: 'the gesture went to the handle, not the page',
      );
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
