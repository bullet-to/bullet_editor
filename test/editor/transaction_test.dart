import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InsertText', () {
    test('inserts text at offset', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
      ]);
      final result = InsertText(0, 5, ' world').apply(doc);
      expect(result.blocks[0].plainText, 'hello world');
    });

    test('inserts at beginning', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('world')]),
      ]);
      final result = InsertText(0, 0, 'hello ').apply(doc);
      expect(result.blocks[0].plainText, 'hello world');
    });

    test('inherits style when appending to a styled segment', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          segments: [
            const StyledSegment('hello', {InlineStyle.bold}),
          ],
        ),
      ]);
      final result = InsertText(0, 5, ' world').apply(doc);
      expect(result.blocks[0].plainText, 'hello world');
      // The appended text should inherit bold from the segment it continues.
      expect(result.blocks[0].segments.length, 1);
      expect(result.blocks[0].segments[0].styles, {InlineStyle.bold});
    });

    test('inherits style when inserting inside a styled segment', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          segments: [
            const StyledSegment('onetwothree', {InlineStyle.bold}),
          ],
        ),
      ]);
      final result = InsertText(0, 3, 'a').apply(doc);
      expect(result.blocks[0].plainText, 'oneatwothree');
      // All text should remain bold.
      expect(result.blocks[0].segments.length, 1);
      expect(result.blocks[0].segments[0].styles, {InlineStyle.bold});
    });

    test('style persists across multiple sequential inserts', () {
      // Simulate: bold "hello", then type space, then type "world"
      var doc = Document([
        TextBlock(
          id: 'a',
          segments: [
            const StyledSegment('hello', {InlineStyle.bold}),
          ],
        ),
      ]);

      // Type space
      doc = InsertText(0, 5, ' ').apply(doc);
      expect(doc.blocks[0].plainText, 'hello ');
      expect(doc.blocks[0].segments.length, 1);
      expect(doc.blocks[0].segments[0].styles, {InlineStyle.bold});

      // Type 'w'
      doc = InsertText(0, 6, 'w').apply(doc);
      expect(doc.blocks[0].plainText, 'hello w');
      expect(doc.blocks[0].segments.length, 1);
      expect(doc.blocks[0].segments[0].styles, {InlineStyle.bold});

      // Type 'orld'
      doc = InsertText(0, 7, 'o').apply(doc);
      doc = InsertText(0, 8, 'r').apply(doc);
      doc = InsertText(0, 9, 'l').apply(doc);
      doc = InsertText(0, 10, 'd').apply(doc);
      expect(doc.blocks[0].plainText, 'hello world');
      expect(doc.blocks[0].segments.length, 1);
      expect(doc.blocks[0].segments[0].styles, {InlineStyle.bold});
    });
  });

  group('DeleteText', () {
    test('deletes text at offset', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hello world')]),
      ]);
      final result = DeleteText(0, 5, 6).apply(doc);
      expect(result.blocks[0].plainText, 'hello');
    });
  });

  group('ToggleStyle', () {
    test('applies bold to unstyled range', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hello world')]),
      ]);
      final result = ToggleStyle(0, 0, 5, InlineStyle.bold).apply(doc);
      expect(result.blocks[0].segments.length, 2);
      expect(result.blocks[0].segments[0].text, 'hello');
      expect(result.blocks[0].segments[0].styles, {InlineStyle.bold});
      expect(result.blocks[0].segments[1].text, ' world');
      expect(result.blocks[0].segments[1].styles, <InlineStyle>{});
    });

    test('removes bold from fully-styled range', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          segments: [
            const StyledSegment('hello world', {InlineStyle.bold}),
          ],
        ),
      ]);
      final result = ToggleStyle(0, 0, 5, InlineStyle.bold).apply(doc);
      expect(result.blocks[0].segments[0].text, 'hello');
      expect(result.blocks[0].segments[0].styles, <InlineStyle>{});
    });
  });

  group('SplitBlock', () {
    test('splits block at offset', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hello world')]),
      ]);
      final result = SplitBlock(0, 5).apply(doc);
      expect(result.blocks.length, 2);
      expect(result.blocks[0].plainText, 'hello');
      expect(result.blocks[1].plainText, ' world');
    });

    test('split at start creates empty first block', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
      ]);
      final result = SplitBlock(0, 0).apply(doc);
      expect(result.blocks.length, 2);
      expect(result.blocks[0].plainText, '');
      expect(result.blocks[1].plainText, 'hello');
    });
  });

  group('MergeBlocks', () {
    test('merges second block into first', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
        TextBlock(id: 'b', segments: [const StyledSegment(' world')]),
      ]);
      final result = MergeBlocks(1).apply(doc);
      expect(result.blocks.length, 1);
      expect(result.blocks[0].plainText, 'hello world');
    });

    test('merging first block is no-op', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
      ]);
      final result = MergeBlocks(0).apply(doc);
      expect(result.blocks.length, 1);
    });
  });

  group('ChangeBlockType', () {
    test('changes block type', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
      ]);
      final result = ChangeBlockType(0, BlockType.h1).apply(doc);
      expect(result.blocks[0].blockType, BlockType.h1);
      expect(result.blocks[0].plainText, 'hello');
    });
  });

  group('SplitBlock with block types', () {
    test('Enter on heading creates paragraph', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.h1,
          segments: [const StyledSegment('heading')],
        ),
      ]);
      final result = SplitBlock(0, 7).apply(doc);
      expect(result.blocks[0].blockType, BlockType.h1);
      expect(result.blocks[1].blockType, BlockType.paragraph);
    });

    test('Enter on list item creates another list item', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.listItem,
          segments: [const StyledSegment('item')],
        ),
      ]);
      final result = SplitBlock(0, 4).apply(doc);
      expect(result.blocks[0].blockType, BlockType.listItem);
      expect(result.blocks[1].blockType, BlockType.listItem);
    });
  });

  group('IndentBlock', () {
    test('makes block a child of its previous sibling', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.listItem,
          segments: [const StyledSegment('first')],
        ),
        TextBlock(
          id: 'b',
          blockType: BlockType.listItem,
          segments: [const StyledSegment('second')],
        ),
      ]);
      final result = IndentBlock(1).apply(doc);
      // 'b' should now be a child of 'a'.
      expect(result.blocks.length, 1);
      expect(result.blocks[0].id, 'a');
      expect(result.blocks[0].children.length, 1);
      expect(result.blocks[0].children[0].id, 'b');
      // allBlocks still has both.
      expect(result.allBlocks.length, 2);
    });

    test('no-op when block has no previous sibling', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.listItem,
          segments: [const StyledSegment('only')],
        ),
      ]);
      final result = IndentBlock(0).apply(doc);
      expect(result.blocks.length, 1);
      expect(result.blocks[0].children, isEmpty);
    });
  });

  group('OutdentBlock', () {
    test('moves nested block to parent level', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.listItem,
          segments: [const StyledSegment('parent')],
          children: [
            TextBlock(
              id: 'b',
              blockType: BlockType.listItem,
              segments: [const StyledSegment('child')],
            ),
          ],
        ),
      ]);
      final result = OutdentBlock(1).apply(doc);
      // 'b' should now be a sibling after 'a' at root level.
      expect(result.blocks.length, 2);
      expect(result.blocks[0].id, 'a');
      expect(result.blocks[0].children, isEmpty);
      expect(result.blocks[1].id, 'b');
    });

    test('no-op when block is already at root', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.listItem,
          segments: [const StyledSegment('root')],
        ),
      ]);
      final result = OutdentBlock(0).apply(doc);
      expect(result.blocks.length, 1);
    });
  });

  group('DeleteRange', () {
    test('same block behaves like DeleteText', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hello world')]),
      ]);
      final result = DeleteRange(0, 2, 0, 7).apply(doc);
      expect(result.allBlocks[0].plainText, 'heorld');
    });

    test('across 2 blocks merges remaining halves', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
        TextBlock(id: 'b', segments: [const StyledSegment('world')]),
      ]);
      // Delete from offset 3 in block 0 to offset 2 in block 1.
      // Keeps 'hel' + 'rld' = 'helrld'
      final result = DeleteRange(0, 3, 1, 2).apply(doc);
      expect(result.allBlocks.length, 1);
      expect(result.allBlocks[0].plainText, 'helrld');
    });

    test(
      'across 3+ blocks removes middle blocks and merges first and last',
      () {
        final doc = Document([
          TextBlock(id: 'a', segments: [const StyledSegment('aaa')]),
          TextBlock(id: 'b', segments: [const StyledSegment('bbb')]),
          TextBlock(id: 'c', segments: [const StyledSegment('ccc')]),
          TextBlock(id: 'd', segments: [const StyledSegment('ddd')]),
        ]);
        // Delete from offset 1 in block 0 to offset 2 in block 3.
        // Keeps 'a' + 'd' = 'ad', blocks b and c removed.
        final result = DeleteRange(0, 1, 3, 2).apply(doc);
        expect(result.allBlocks.length, 1);
        expect(result.allBlocks[0].plainText, 'ad');
      },
    );

    test('delete entire blocks leaves empty first block', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
        TextBlock(id: 'b', segments: [const StyledSegment('world')]),
      ]);
      // Delete from offset 0 in block 0 to offset 5 in block 1 (everything).
      final result = DeleteRange(0, 0, 1, 5).apply(doc);
      expect(result.allBlocks.length, 1);
      expect(result.allBlocks[0].plainText, '');
    });
  });

  group('Transaction', () {
    test('applies multiple operations in sequence', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
      ]);
      final tx = Transaction(
        operations: [
          InsertText(0, 5, ' world'),
          ToggleStyle(0, 0, 5, InlineStyle.bold),
        ],
      );
      final result = tx.apply(doc);
      expect(result.blocks[0].plainText, 'hello world');
      expect(result.blocks[0].segments[0].styles, {InlineStyle.bold});
    });
  });

  group('SplitBlock with list-like types', () {
    test('Enter on numbered list creates another numbered list', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.numberedList,
          segments: [const StyledSegment('first')],
        ),
      ]);
      final result = SplitBlock(0, 5).apply(doc);
      expect(result.allBlocks.length, 2);
      expect(result.allBlocks[0].blockType, BlockType.numberedList);
      expect(result.allBlocks[1].blockType, BlockType.numberedList);
    });

    test('Enter on task creates unchecked task', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.taskItem,
          segments: [const StyledSegment('done')],
          metadata: {'checked': true},
        ),
      ]);
      final result = SplitBlock(0, 4).apply(doc);
      expect(result.allBlocks.length, 2);
      expect(result.allBlocks[1].blockType, BlockType.taskItem);
      expect(result.allBlocks[1].metadata['checked'], false);
    });
  });

  group('SetBlockMetadata', () {
    test('sets metadata on a block', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.taskItem,
          segments: [const StyledSegment('task')],
          metadata: {'checked': false},
        ),
      ]);
      final result = SetBlockMetadata(0, 'checked', true).apply(doc);
      expect(result.allBlocks[0].metadata['checked'], true);
    });

    test('out of range is no-op', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
      ]);
      final result = SetBlockMetadata(5, 'key', 'value').apply(doc);
      expect(result.allBlocks.length, 1);
    });
  });

  group('ToggleStyle with attributes', () {
    test('applies link style with URL attribute', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('click here')]),
      ]);
      final result = ToggleStyle(
        0,
        0,
        10,
        InlineStyle.link,
        attributes: {'url': 'https://example.com'},
      ).apply(doc);
      final seg = result.allBlocks[0].segments[0];
      expect(seg.styles, contains(InlineStyle.link));
      expect(seg.attributes['url'], 'https://example.com');
    });

    test('removing link style clears URL attribute', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          segments: [
            const StyledSegment(
              'linked',
              {InlineStyle.link},
              {'url': 'https://example.com'},
            ),
          ],
        ),
      ]);
      final result = ToggleStyle(
        0,
        0,
        6,
        InlineStyle.link,
        attributes: {'url': 'https://example.com'},
      ).apply(doc);
      final seg = result.allBlocks[0].segments[0];
      expect(seg.styles, isNot(contains(InlineStyle.link)));
      expect(seg.attributes.containsKey('url'), isFalse);
    });

    test('link on partial range splits segments correctly', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hello world')]),
      ]);
      final result = ToggleStyle(
        0,
        6,
        11,
        InlineStyle.link,
        attributes: {'url': 'https://w.com'},
      ).apply(doc);
      final segs = result.allBlocks[0].segments;
      expect(segs.length, 2);
      expect(segs[0].text, 'hello ');
      expect(segs[0].styles, isEmpty);
      expect(segs[1].text, 'world');
      expect(segs[1].styles, {InlineStyle.link});
      expect(segs[1].attributes['url'], 'https://w.com');
    });
  });

  group('InsertText with attributes', () {
    test('inserts text with link attributes', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('before after')]),
      ]);
      final result = InsertText(
        0,
        7,
        'link',
        styles: {InlineStyle.link},
        attributes: {'url': 'https://x.com'},
      ).apply(doc);
      final segs = result.allBlocks[0].segments;
      // Should have: 'before ' + 'link' (linked) + 'after'
      expect(
        segs.any(
          (s) =>
              s.text == 'link' &&
              s.styles.contains(InlineStyle.link) &&
              s.attributes['url'] == 'https://x.com',
        ),
        isTrue,
      );
    });
  });

  group('DeleteText preserves attributes', () {
    test('deleting part of a link segment keeps URL', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [
          const StyledSegment(
              'link', {InlineStyle.link}, {'url': 'https://flutter.dev'}),
        ]),
      ]);
      final result = DeleteText(0, 3, 1).apply(doc);
      final seg = result.allBlocks[0].segments[0];
      expect(seg.text, 'lin');
      expect(seg.styles, {InlineStyle.link});
      expect(seg.attributes['url'], 'https://flutter.dev');
    });
  });

  group('SplitBlock preserves attributes', () {
    test('splitting inside a link segment keeps URL on both halves', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [
          const StyledSegment(
              'click here', {InlineStyle.link}, {'url': 'https://x.com'}),
        ]),
      ]);
      final result = SplitBlock(0, 5).apply(doc);
      final seg0 = result.allBlocks[0].segments[0];
      final seg1 = result.allBlocks[1].segments[0];
      expect(seg0.text, 'click');
      expect(seg0.attributes['url'], 'https://x.com');
      expect(seg1.text, ' here');
      expect(seg1.attributes['url'], 'https://x.com');
    });
  });
}
