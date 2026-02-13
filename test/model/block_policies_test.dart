import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Reset ID counter before each test for deterministic IDs.
  setUp(() {
    // We can't reset _idCounter directly, but tests don't depend on specific IDs.
  });

  group('IndentBlock policies', () {
    test('indent heading is a no-op (canBeChild: false)', () {
      // Two root-level blocks: paragraph then heading.
      final doc = Document([
        TextBlock(
          id: 'p1',
          blockType: BlockType.paragraph,
          segments: [const StyledSegment('hello')],
        ),
        TextBlock(
          id: 'h1',
          blockType: BlockType.h1,
          segments: [const StyledSegment('title')],
        ),
      ]);

      // Heading is flat index 1, previous sibling is paragraph at index 0.
      final result = IndentBlock(1).apply(doc);

      // Should be unchanged — heading can't be a child.
      expect(result.allBlocks.length, 2);
      expect(result.allBlocks[0].id, 'p1');
      expect(result.allBlocks[1].id, 'h1');
      expect(result.depthOf(1), 0);
    });

    test(
      'indent list item under paragraph is a no-op (canHaveChildren: false)',
      () {
        final doc = Document([
          TextBlock(
            id: 'p1',
            blockType: BlockType.paragraph,
            segments: [const StyledSegment('hello')],
          ),
          TextBlock(
            id: 'li1',
            blockType: BlockType.listItem,
            segments: [const StyledSegment('item')],
          ),
        ]);

        final result = IndentBlock(1).apply(doc);

        // Should be unchanged — paragraph can't have children.
        expect(result.allBlocks.length, 2);
        expect(result.depthOf(1), 0);
      },
    );

    test('indent list item beyond maxDepth is a no-op', () {
      // Build a chain of 6 nested list items (depth 0..5), then try to indent the last one deeper.
      TextBlock deepChain(int depth) {
        if (depth == 6) {
          return TextBlock(
            id: 'li_$depth',
            blockType: BlockType.listItem,
            segments: [StyledSegment('item $depth')],
          );
        }
        return TextBlock(
          id: 'li_$depth',
          blockType: BlockType.listItem,
          segments: [StyledSegment('item $depth')],
          children: [deepChain(depth + 1)],
        );
      }

      // Root has one chain: li_0 > li_1 > ... > li_6 (li_6 is at depth 6).
      // Then add a sibling to li_6 so we can try indenting it.
      final chain = deepChain(0);
      // li_6 is at depth 6. Add a sibling li_7 at depth 6 (under li_5).
      // We need to find li_5 and add a second child.
      TextBlock addSiblingAtDepth5(TextBlock node, int depth) {
        if (depth == 5) {
          return node.copyWith(
            children: [
              ...node.children,
              TextBlock(
                id: 'li_sibling',
                blockType: BlockType.listItem,
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
      final flat = doc.allBlocks;
      final siblingIdx = flat.indexWhere((b) => b.id == 'li_sibling');
      expect(siblingIdx, greaterThan(0));
      expect(doc.depthOf(siblingIdx), 6);

      final result = IndentBlock(siblingIdx).apply(doc);

      // Should be unchanged — maxDepth exceeded.
      expect(result.allBlocks.length, flat.length);
      expect(
        result.depthOf(
          result.allBlocks.indexWhere((b) => b.id == 'li_sibling'),
        ),
        6,
      );
    });

    test('indent list item under list item works (happy path)', () {
      final doc = Document([
        TextBlock(
          id: 'li1',
          blockType: BlockType.listItem,
          segments: [const StyledSegment('first')],
        ),
        TextBlock(
          id: 'li2',
          blockType: BlockType.listItem,
          segments: [const StyledSegment('second')],
        ),
      ]);

      final result = IndentBlock(1).apply(doc);

      // li2 should now be a child of li1.
      expect(result.allBlocks.length, 2);
      expect(result.depthOf(1), 1);
      expect(result.allBlocks[0].children.length, 1);
      expect(result.allBlocks[0].children[0].id, 'li2');
    });
  });

  group('ChangeBlockType policies', () {
    test(
      'change nested list item to H1 is a no-op (canBeChild: false + nested)',
      () {
        final doc = Document([
          TextBlock(
            id: 'li1',
            blockType: BlockType.listItem,
            segments: [const StyledSegment('parent')],
            children: [
              TextBlock(
                id: 'li2',
                blockType: BlockType.listItem,
                segments: [const StyledSegment('child')],
              ),
            ],
          ),
        ]);

        // li2 is flat index 1, nested at depth 1.
        final result = ChangeBlockType(1, BlockType.h1).apply(doc);

        // Should be unchanged — h1 can't be a child.
        expect(result.allBlocks[1].blockType, BlockType.listItem);
      },
    );

    test('change root paragraph to H1 works (not nested)', () {
      final doc = Document([
        TextBlock(
          id: 'p1',
          blockType: BlockType.paragraph,
          segments: [const StyledSegment('hello')],
        ),
      ]);

      final result = ChangeBlockType(0, BlockType.h1).apply(doc);

      expect(result.allBlocks[0].blockType, BlockType.h1);
    });
  });
}
