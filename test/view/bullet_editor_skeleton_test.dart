import 'dart:math' as math;

import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fixtures/gauntlet_doc.dart';

/// Finds the RichText rendering the block whose text contains [text]
/// (find.text does not match RichText for semantics lookups).
Finder _richTextContaining(String text) => find.byWidgetPredicate(
  (w) => w is RichText && w.text.toPlainText().contains(text),
);

/// A viewport tall enough to lay out the whole gauntlet head (the 16:9
/// image placeholders alone are ~450px each) — for tests that assert on
/// blocks deep in the fixture rather than on laziness.
void tallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Widget _editor(Document document, {EditorSchema? schema}) {
  return MaterialApp(
    home: Scaffold(
      body: BulletEditor(
        document: document,
        schema: schema ?? EditorSchema.standard(),
        textStyle: const TextStyle(fontSize: 16, color: Color(0xFF000000)),
      ),
    ),
  );
}

void main() {
  group('walking skeleton — gauntlet fixture render', () {
    testWidgets('renders every visible launch block kind', (tester) async {
      tallViewport(tester);
      await tester.pumpWidget(_editor(buildGauntletDocument(tailLength: 5)));

      // Headings, paragraphs, lists, quote render their text (block text
      // lives in RichText, so findRichText: true).
      Finder blockText(String t) => find.text(t, findRichText: true);
      expect(blockText('Gauntlet document'), findsOneWidget);
      expect(_richTextContaining('a link in the middle'), findsOneWidget);
      expect(blockText('Bullet depth 0'), findsOneWidget);
      expect(blockText('Bullet depth 1'), findsOneWidget);
      expect(blockText('Bullet depth 2'), findsOneWidget);
      expect(blockText('Numbered one'), findsOneWidget);
      expect(blockText('An unchecked task'), findsOneWidget);
      expect(blockText('A block quote with its bar gutter.'), findsOneWidget);

      // Void components mount (images render placeholders in tests — no
      // network — but the components themselves must be in the tree).
      expect(find.byType(ImageBlockComponent), findsNWidgets(2));
      expect(find.byType(DividerBlockComponent), findsOneWidget);
    });

    testWidgets('numbered list ordinals come from the gutter context', (
      tester,
    ) async {
      tallViewport(tester);
      await tester.pumpWidget(_editor(buildGauntletDocument(tailLength: 0)));
      expect(find.text('1.'), findsOneWidget);
      expect(find.text('2.'), findsOneWidget);
      expect(find.text('3.'), findsOneWidget);
    });

    testWidgets('lazy rendering: the 200-block tail is not built eagerly', (
      tester,
    ) async {
      await tester.pumpWidget(_editor(buildGauntletDocument()));

      // The viewport shows the head of the document; the deep tail must not
      // have been built (D5).
      expect(
        find.text('Lazy tail paragraph 200 of 200.', findRichText: true),
        findsNothing,
      );

      final state = tester.state<BulletEditorState>(find.byType(BulletEditor));
      expect(state.registry.geometryOf('g-tail-199'), isNull);
      // Visible text blocks register geometry (GATE-L skeleton).
      expect(state.registry.geometryOf('g-h1'), isNotNull);
      expect(
        state.registry.layoutCount,
        lessThan(buildGauntletDocument().allBlocks.length),
      );
    });

    testWidgets('geometry contract answers over the RenderParagraph', (
      tester,
    ) async {
      await tester.pumpWidget(_editor(buildGauntletDocument(tailLength: 0)));

      final state = tester.state<BulletEditorState>(find.byType(BulletEditor));
      final geometry = state.registry.geometryOf('g-h1')!;

      final caret = geometry.rectForOffset(0);
      expect(caret, isNotNull);
      expect(caret!.height, greaterThan(0));

      final rects = geometry.rectsForRange(0, 8); // "Gauntlet"
      expect(rects, isNotEmpty);

      // Round-trip: the midpoint of the caret rect at offset 3 resolves
      // back to offset 3.
      final rect3 = geometry.rectForOffset(3)!;
      expect(geometry.offsetForLocalPoint(rect3.center), 3);

      final word = geometry.wordBoundaryAt(2);
      expect(word.start, 0);
      expect(word.end, 8);
    });

    testWidgets('schema validation runs at the editor boundary (GATE-K)', (
      tester,
    ) async {
      final badSchema = EditorSchema(
        defaultBlockType: ParagraphKeys.type,
        blocks: {
          ParagraphKeys.type: const BlockDef(label: 'Paragraph'), // no codec
        },
        inlineStyles: const {},
      );
      await tester.pumpWidget(
        _editor(Document.empty(ParagraphKeys.type), schema: badSchema),
      );
      expect(tester.takeException(), isA<StateError>());
    });
  });

  group('checkpoint-1 findings (regression)', () {
    // Feel-gate findings become tests before fixes (build strategy §edge-
    // case discovery): no inter-block spacing, code block not a real
    // container, image collapsing to line height.

    Document twoBlocks(TextBlock a, TextBlock b) => Document([a, b]);
    TextBlock para(String id, String text) => TextBlock(
      id: id,
      blockType: ParagraphKeys.type,
      segments: [StyledSegment(text)],
    );

    testWidgets(
      'inter-block gap is the v2 max-collapse of after/before, top-side only',
      (tester) async {
        // blockquote (spacingAfter 0.4) → paragraph (spacingBefore 0.5):
        // the gap is max(0.4, 0.5) = 0.5em = 8px, NOT the 14.4px sum.
        final doc = twoBlocks(
          TextBlock(
            id: 'q',
            blockType: BlockQuoteKeys.type,
            segments: [const StyledSegment('quote')],
          ),
          para('p', 'para'),
        );
        await tester.pumpWidget(_editor(doc));

        final quoteBottom = tester
            .getBottomLeft(_richTextContaining('quote'))
            .dy;
        final paraTop = tester.getTopLeft(_richTextContaining('para')).dy;
        expect(paraTop - quoteBottom, moreOrLessEquals(0.5 * 16));
      },
    );

    testWidgets('h1 gets its 1.2em gap below a paragraph', (tester) async {
      final doc = twoBlocks(
        para('p', 'above'),
        TextBlock(
          id: 'h',
          blockType: HeadingKeys.h1,
          segments: [const StyledSegment('Title')],
        ),
      );
      await tester.pumpWidget(_editor(doc));
      final gap =
          tester.getTopLeft(_richTextContaining('Title')).dy -
          tester.getBottomLeft(_richTextContaining('above')).dy;
      expect(gap, moreOrLessEquals(1.2 * 16));
    });

    testWidgets('gap after a nested subtree collapses against its deepest last '
        'descendant, not the root', (tester) async {
      // blockquote (spacingAfter 0.4) with a listItem child (spacingAfter
      // 0), then a root listItem (spacingBefore 0). The flat predecessor
      // of the root listItem is the CHILD, so the gap is max(0, 0) = 0 —
      // using the quote root's 0.4 would open a phantom 6.4px gap.
      final doc = Document([
        TextBlock(
          id: 'q',
          blockType: BlockQuoteKeys.type,
          segments: [const StyledSegment('quote root')],
          children: [
            TextBlock(
              id: 'qc',
              blockType: ListItemKeys.type,
              segments: [const StyledSegment('nested item')],
            ),
          ],
        ),
        TextBlock(
          id: 'l',
          blockType: ListItemKeys.type,
          segments: [const StyledSegment('next root')],
        ),
      ]);
      await tester.pumpWidget(_editor(doc));

      // The child row's bottom is the taller of its bullet glyph
      // (fontSize * 1.2) and its text line box.
      final bullets = find.text('•');
      expect(bullets, findsNWidgets(2));
      final childRowBottom = math.max(
        tester.getBottomLeft(bullets.first).dy,
        tester.getBottomLeft(_richTextContaining('nested item')).dy,
      );
      final nextTop = tester.getTopLeft(_richTextContaining('next root')).dy;
      expect(nextTop - childRowBottom, moreOrLessEquals(0));
    });

    testWidgets('divider gets policy spacing on both sides', (tester) async {
      final doc = Document([
        para('p1', 'above divider'),
        TextBlock(id: 'd', blockType: DividerKeys.type),
        para('p2', 'below divider'),
      ]);
      await tester.pumpWidget(_editor(doc));

      final line = find.byType(DividerBlockComponent);
      final above = tester.getBottomLeft(_richTextContaining('above')).dy;
      final below = tester.getTopLeft(_richTextContaining('below')).dy;
      // 0.5em = 8px each side around the 1px rule.
      expect(tester.getTopLeft(line).dy - above, moreOrLessEquals(8));
      expect(below - tester.getBottomRight(line).dy, moreOrLessEquals(8));
    });

    testWidgets('code block is a real container: full-width fill', (
      tester,
    ) async {
      final doc = twoBlocks(
        TextBlock(
          id: 'code',
          blockType: CodeBlockKeys.type,
          segments: [const StyledSegment('short\nlines')],
        ),
        para('p', 'after'),
      );
      await tester.pumpWidget(_editor(doc));

      // The decorated box spans the editor width regardless of glyph runs
      // (the v2 per-glyph backgroundColor trick stopped at line ends).
      final decorated = find.ancestor(
        of: _richTextContaining('short'),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration! as BoxDecoration).color != null,
        ),
      );
      expect(decorated, findsOneWidget);
      expect(
        tester.getSize(decorated).width,
        tester.getSize(find.byType(BulletEditor)).width,
      );
      // And no per-glyph background remains in the style.
      final richText = tester.widget<RichText>(_richTextContaining('short'));
      expect(richText.text.style?.backgroundColor, isNull);
    });

    testWidgets(
      'image without a loadable source renders an image-shaped slot',
      (tester) async {
        // In tests all network images fail → errorBuilder. The slot must be
        // image-sized (16:9), not text-line-sized.
        final doc = twoBlocks(
          TextBlock(
            id: 'img',
            blockType: ImageKeys.type,
            segments: [const StyledSegment('alt text')],
            metadata: const {ImageKeys.url: 'https://example.com/x.png'},
          ),
          para('p', 'after image'),
        );
        await tester.pumpWidget(_editor(doc));

        final size = tester.getSize(find.byType(ImageBlockComponent));
        expect(size.height, greaterThan(100));
        expect(size.width / size.height, closeTo(16 / 9, 0.2));
      },
    );
  });

  group('walking skeleton — semantics (D4/D3)', () {
    testWidgets(
      'paragraph with a link has a semantics child carrying SemanticsAction.tap',
      (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(_editor(buildGauntletDocument(tailLength: 0)));

        // The booked days-1–2 test (architecture §Accessibility): the link
        // span's TapGestureRecognizer yields a per-link tappable semantics
        // child node assembled by RenderParagraph.
        final semantics = tester.getSemantics(
          _richTextContaining('a link in the middle'),
        );
        var foundTappableLink = false;
        semantics.visitChildren((node) {
          final data = node.getSemanticsData();
          if (data.hasAction(SemanticsAction.tap) &&
              data.label.contains('a link in the middle')) {
            foundTappableLink = true;
          }
          return true;
        });
        expect(
          foundTappableLink,
          isTrue,
          reason: 'link spans must yield tappable semantics child nodes',
        );
        handle.dispose();
      },
    );

    testWidgets('heading blocks are flagged as headers', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_editor(buildGauntletDocument(tailLength: 0)));

      final semantics = tester.getSemantics(
        _richTextContaining('Gauntlet document'),
      );
      expect(semantics.getSemanticsData().flagsCollection.isHeader, isTrue);
      handle.dispose();
    });

    testWidgets('image blocks carry image semantics with the alt label', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_editor(buildGauntletDocument(tailLength: 0)));

      expect(
        find.bySemanticsLabel('A first-in-document banner image'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('link tap fires onLinkTap with the entity snapshot', (
      tester,
    ) async {
      InlineEntitySnapshot? tapped;
      String? tappedBlockId;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BulletEditor(
              document: buildGauntletDocument(tailLength: 0),
              schema: EditorSchema.standard(),
              textStyle: const TextStyle(
                fontSize: 16,
                color: Color(0xFF000000),
              ),
              onLinkTap: (blockId, offset, entity) {
                tappedBlockId = blockId;
                tapped = entity;
              },
            ),
          ),
        ),
      );

      // Tap inside the link's glyphs via its geometry.
      final state = tester.state<BulletEditorState>(find.byType(BulletEditor));
      final geometry = state.registry.geometryOf('g-para-link')!;
      const linkStart = 'A paragraph with '.length;
      final linkRect = geometry.rectForOffset(linkStart + 2)!;
      final global = geometry.renderBox.localToGlobal(linkRect.center);
      await tester.tapAt(global);
      await tester.pump();

      expect(tappedBlockId, 'g-para-link');
      expect(tapped, isNotNull);
      expect(tapped!.key, InlineEntityKeys.link);
      expect(tapped!.text, 'a link in the middle');
      expect(
        tapped!.attributes[InlineEntityKeys.linkUrl],
        'https://example.com/mid',
      );
    });
  });
}
