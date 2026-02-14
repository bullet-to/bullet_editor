import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BulletEditor link tap', () {
    testWidgets('onTap fires with segment info when tapping',
        (tester) async {
      final tappedDetails = <EditorTapDetails>[];

      final controller = EditorController(
        document: Document([
          TextBlock(id: 'a', segments: [
            const StyledSegment('Visit '),
            const StyledSegment(
              'Google',
              {InlineStyle.link},
              {'url': 'https://google.com'},
            ),
            const StyledSegment(' today'),
          ]),
        ]),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 200,
              child: BulletEditor(
                controller: controller,
                onTap: (details) => tappedDetails.add(details),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final textFieldFinder = find.byType(TextField);
      expect(textFieldFinder, findsOneWidget);

      // Tap near the left of the text field — should hit 'Visit ' or 'Google'.
      final box = tester.getRect(textFieldFinder);
      // Tap at ~40% from left, near where 'Google' starts.
      await tester.tapAt(Offset(box.left + box.width * 0.25, box.top + 20));
      await tester.pumpAndSettle();

      expect(tappedDetails, isNotEmpty,
          reason: 'onTap should fire on any tap');
      // We got a segment — the pipeline works.
      expect(tappedDetails.first.segment, isNotNull);
    });

    testWidgets('onLinkTap fires with URL when tapping link text',
        (tester) async {
      String? tappedUrl;

      final controller = EditorController(
        document: Document([
          TextBlock(id: 'a', segments: [
            const StyledSegment(
              'click here',
              {InlineStyle.link},
              {'url': 'https://example.com'},
            ),
          ]),
        ]),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 200,
              child: BulletEditor(
                controller: controller,
                onLinkTap: (url) => tappedUrl = url,
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

    testWidgets('segmentAtOffset returns correct segment for each block',
        (tester) async {
      // Unit-level test that the segment lookup works for different offsets
      // across multiple blocks, without relying on simulated taps.
      final controller = EditorController(
        document: Document([
          TextBlock(id: 'a', segments: [
            const StyledSegment('first block'),
          ]),
          TextBlock(id: 'b', segments: [
            const StyledSegment('second block'),
          ]),
          TextBlock(id: 'c', segments: [
            const StyledSegment('third block'),
          ]),
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

    testWidgets('onTap fires with null linkUrl on plain text',
        (tester) async {
      EditorTapDetails? lastTap;

      final controller = EditorController(
        document: Document([
          TextBlock(id: 'a', segments: [
            const StyledSegment('just plain text here nothing special'),
          ]),
        ]),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 200,
              child: BulletEditor(
                controller: controller,
                onTap: (details) => lastTap = details,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final textFieldFinder = find.byType(TextField);
      await tester.tapAt(tester.getCenter(textFieldFinder));
      await tester.pumpAndSettle();

      expect(lastTap, isNotNull, reason: 'onTap should have fired');
      expect(lastTap!.segment, isNotNull);
      expect(lastTap!.segment!.styles, isNot(contains(InlineStyle.link)));
    });
  });
}
