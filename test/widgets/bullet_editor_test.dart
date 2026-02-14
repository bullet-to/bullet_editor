import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BulletEditor link tap', () {
    testWidgets('tapping text allows segment lookup via controller', (tester) async {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: [
              const StyledSegment('Visit '),
              const StyledSegment(
                'Google',
                {InlineStyle.link},
                {'url': 'https://google.com'},
              ),
              const StyledSegment(' today'),
            ],
          ),
        ]),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 200,
              child: BulletEditor(
                controller: controller,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final textFieldFinder = find.byType(TextField);
      expect(textFieldFinder, findsOneWidget);

      // Tap near the left of the text field.
      final box = tester.getRect(textFieldFinder);
      await tester.tapAt(Offset(box.left + box.width * 0.25, box.top + 20));
      await tester.pumpAndSettle();

      // After tapping, the selection should be valid and we can look up the segment.
      expect(controller.value.selection.isValid, isTrue);
      final segment = controller.segmentAtOffset(
        controller.value.selection.baseOffset,
      );
      expect(segment, isNotNull);
    });

    testWidgets('onLinkTap fires with URL when tapping link text', (
      tester,
    ) async {
      String? tappedUrl;

      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: [
              const StyledSegment(
                'click here',
                {InlineStyle.link},
                {'url': 'https://example.com'},
              ),
            ],
          ),
        ]),
        onLinkTap: (url) => tappedUrl = url,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 200,
              child: BulletEditor(
                controller: controller,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final textFieldFinder = find.byType(TextField);
      await tester.tapAt(tester.getCenter(textFieldFinder));
      await tester.pumpAndSettle();

      expect(tappedUrl, 'https://example.com');
    });

    testWidgets('segmentAtOffset returns correct segment for each block', (
      tester,
    ) async {
      // Unit-level test that the segment lookup works for different offsets
      // across multiple blocks, without relying on simulated taps.
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('first block')]),
          TextBlock(id: 'b', blockType: BlockType.paragraph, segments: [const StyledSegment('second block')]),
          TextBlock(id: 'c', blockType: BlockType.paragraph, segments: [const StyledSegment('third block')]),
        ]),
      );

      // 'first block' = offsets 0..10, \n at 11,
      // 'second block' = offsets 12..23, \n at 24,
      // 'third block' = offsets 25..35.
      expect(controller.segmentAtOffset(0)?.text, 'first block');
      expect(controller.segmentAtOffset(5)?.text, 'first block');
      expect(controller.segmentAtOffset(12)?.text, 'second block');
      expect(controller.segmentAtOffset(18)?.text, 'second block');
      expect(controller.segmentAtOffset(25)?.text, 'third block');
      expect(controller.segmentAtOffset(30)?.text, 'third block');

      controller.dispose();
    });

    testWidgets('tapping plain text does not trigger onLinkTap', (tester) async {
      String? tappedUrl;

      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: [
              const StyledSegment('just plain text here nothing special'),
            ],
          ),
        ]),
        onLinkTap: (url) => tappedUrl = url,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 200,
              child: BulletEditor(
                controller: controller,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final textFieldFinder = find.byType(TextField);
      await tester.tapAt(tester.getCenter(textFieldFinder));
      await tester.pumpAndSettle();

      // Plain text should not trigger onLinkTap.
      expect(tappedUrl, isNull);

      // But the segment at the cursor should be valid plain text.
      expect(controller.value.selection.isValid, isTrue);
      final segment = controller.segmentAtOffset(
        controller.value.selection.baseOffset,
      );
      expect(segment, isNotNull);
      expect(segment!.styles, isNot(contains(InlineStyle.link)));
    });
  });

  group('BulletEditor undo/redo via Actions', () {
    testWidgets('UndoTextIntent routes to controller.undo()', (tester) async {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('hello')]),
        ]),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 200,
              child: BulletEditor(controller: controller),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Focus the text field and type something.
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      controller.value = controller.value.copyWith(
        selection: const TextSelection.collapsed(offset: 5),
      );
      // Simulate a typed character so there's something to undo.
      controller.value = controller.value.copyWith(
        text: controller.value.text.replaceRange(5, 5, 'X'),
        selection: const TextSelection.collapsed(offset: 6),
      );
      await tester.pump();
      expect(controller.document.allBlocks.first.plainText, contains('X'));

      // Dispatch UndoTextIntent via the Actions widget.
      final context = tester.element(find.byType(TextField));
      Actions.invoke(context, const UndoTextIntent(SelectionChangedCause.keyboard));
      await tester.pump();

      // After undo, the 'X' should be gone.
      expect(controller.document.allBlocks.first.plainText, 'hello');
    });

    testWidgets('RedoTextIntent routes to controller.redo()', (tester) async {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('hello')]),
        ]),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 200,
              child: BulletEditor(controller: controller),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Focus and type.
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      controller.value = controller.value.copyWith(
        selection: const TextSelection.collapsed(offset: 5),
      );
      controller.value = controller.value.copyWith(
        text: controller.value.text.replaceRange(5, 5, 'X'),
        selection: const TextSelection.collapsed(offset: 6),
      );
      await tester.pump();

      // Undo first.
      final context = tester.element(find.byType(TextField));
      Actions.invoke(context, const UndoTextIntent(SelectionChangedCause.keyboard));
      await tester.pump();
      expect(controller.document.allBlocks.first.plainText, 'hello');

      // Now redo.
      Actions.invoke(context, const RedoTextIntent(SelectionChangedCause.keyboard));
      await tester.pump();
      expect(controller.document.allBlocks.first.plainText, contains('X'));
    });
  });
}
