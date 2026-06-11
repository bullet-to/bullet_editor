import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final ctx = EditorSchema.standard().editContext();

  group('IndentBlock policies', () {
    test('indent heading rejects (canBeChild: false)', () {
      // Two root-level blocks: paragraph then heading.
      final doc = Document([
        TextBlock(
          id: 'p1',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('hello')],
        ),
        TextBlock(
          id: 'h1',
          blockType: HeadingKeys.h1,
          segments: [const StyledSegment('title')],
        ),
      ]);

      // Gate failures reject (null) instead of silently no-oping — the
      // batch loop aborts the whole batch.
      final result = IndentBlock('h1').apply(doc, ctx);
      expect(result, isNull);
    });

    test(
      'indent list item under paragraph rejects (canHaveChildren: false)',
      () {
        final doc = Document([
          TextBlock(
            id: 'p1',
            blockType: ParagraphKeys.type,
            segments: [const StyledSegment('hello')],
          ),
          TextBlock(
            id: 'li1',
            blockType: ListItemKeys.type,
            segments: [const StyledSegment('item')],
          ),
        ]);

        final result = IndentBlock('li1').apply(doc, ctx);
        expect(result, isNull);
      },
    );

    test('indent list item beyond maxDepth rejects', () {
      // Build a chain of 6 nested list items (depth 0..5), then try to indent the last one deeper.
      TextBlock deepChain(int depth) {
        if (depth == 6) {
          return TextBlock(
            id: 'li_$depth',
            blockType: ListItemKeys.type,
            segments: [StyledSegment('item $depth')],
          );
        }
        return TextBlock(
          id: 'li_$depth',
          blockType: ListItemKeys.type,
          segments: [StyledSegment('item $depth')],
          children: [deepChain(depth + 1)],
        );
      }

      // Root has one chain: li_0 > li_1 > ... > li_6 (li_6 is at depth 6).
      // Then add a sibling to li_6 so we can try indenting it.
      final chain = deepChain(0);
      TextBlock addSiblingAtDepth5(TextBlock node, int depth) {
        if (depth == 5) {
          return node.copyWith(
            children: [
              ...node.children,
              TextBlock(
                id: 'li_sibling',
                blockType: ListItemKeys.type,
                segments: [const StyledSegment('sibling')],
              ),
            ],
          );
        }
        return node.copyWith(
          children: node.children
              .map((c) => addSiblingAtDepth5(c, depth + 1))
              .toList(),
        );
      }

      final root = addSiblingAtDepth5(chain, 0);
      final doc = Document([root]);

      // li_sibling is at depth 6. Its previous sibling is li_6.
      // Indenting would make it depth 7, which exceeds maxDepth: 6.
      expect(doc.depthOf(doc.indexOfBlock('li_sibling')), 6);

      final result = IndentBlock('li_sibling').apply(doc, ctx);
      expect(result, isNull);
    });

    test('indent list item under list item works (happy path)', () {
      final doc = Document([
        TextBlock(
          id: 'li1',
          blockType: ListItemKeys.type,
          segments: [const StyledSegment('first')],
        ),
        TextBlock(
          id: 'li2',
          blockType: ListItemKeys.type,
          segments: [const StyledSegment('second')],
        ),
      ]);

      final result = IndentBlock('li2').apply(doc, ctx);

      // li2 should now be a child of li1.
      expect(result, isNotNull);
      expect(result!.allBlocks.length, 2);
      expect(result.depthOf(1), 1);
      expect(result.allBlocks[0].children.length, 1);
      expect(result.allBlocks[0].children[0].id, 'li2');
    });
  });

  group('ChangeBlockType policies', () {
    test(
      'change nested list item to H1 rejects (canBeChild: false + nested)',
      () {
        final doc = Document([
          TextBlock(
            id: 'li1',
            blockType: ListItemKeys.type,
            segments: [const StyledSegment('parent')],
            children: [
              TextBlock(
                id: 'li2',
                blockType: ListItemKeys.type,
                segments: [const StyledSegment('child')],
              ),
            ],
          ),
        ]);

        final result = ChangeBlockType('li2', HeadingKeys.h1).apply(doc, ctx);
        expect(result, isNull);
      },
    );

    test('change root paragraph to H1 works (not nested)', () {
      final doc = Document([
        TextBlock(
          id: 'p1',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('hello')],
        ),
      ]);

      final result = ChangeBlockType('p1', HeadingKeys.h1).apply(doc, ctx);

      expect(result, isNotNull);
      expect(result!.allBlocks[0].blockType, HeadingKeys.h1);
    });
  });
}
