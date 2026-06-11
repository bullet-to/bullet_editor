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
        find.bySemanticsLabel('A first-in-document image'),
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
