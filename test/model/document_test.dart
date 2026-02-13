import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Document', () {
    test('plainText joins blocks with newline', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
        TextBlock(id: 'b', segments: [const StyledSegment('world')]),
      ]);
      expect(doc.plainText, 'hello\nworld');
    });

    test('blockAt maps global offset to correct block', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('abc')]), // 0-2
        TextBlock(
          id: 'b',
          segments: [const StyledSegment('de')],
        ), // 4-5 (3 is \n)
      ]);

      // Inside first block
      expect(doc.blockAt(0).blockIndex, 0);
      expect(doc.blockAt(0).localOffset, 0);
      expect(doc.blockAt(2).blockIndex, 0);
      expect(doc.blockAt(2).localOffset, 2);
      expect(doc.blockAt(3).blockIndex, 0);
      expect(doc.blockAt(3).localOffset, 3);

      // Inside second block
      expect(doc.blockAt(4).blockIndex, 1);
      expect(doc.blockAt(4).localOffset, 0);
      expect(doc.blockAt(5).blockIndex, 1);
      expect(doc.blockAt(5).localOffset, 1);
    });

    test('globalOffset reverses blockAt', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('abc')]),
        TextBlock(id: 'b', segments: [const StyledSegment('de')]),
      ]);

      expect(doc.globalOffset(0, 0), 0);
      expect(doc.globalOffset(0, 3), 3);
      expect(doc.globalOffset(1, 0), 4);
      expect(doc.globalOffset(1, 2), 6);
    });
  });

  group('StyledSegment', () {
    test('equality', () {
      const a = StyledSegment('hi', {InlineStyle.bold});
      const b = StyledSegment('hi', {InlineStyle.bold});
      expect(a, equals(b));
    });
  });

  group('Document tree / allBlocks', () {
    test('allBlocks flattens tree depth-first', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('A')]),
        TextBlock(
          id: 'b',
          segments: [const StyledSegment('B')],
          children: [
            TextBlock(id: 'b1', segments: [const StyledSegment('B1')]),
            TextBlock(id: 'b2', segments: [const StyledSegment('B2')]),
          ],
        ),
        TextBlock(id: 'c', segments: [const StyledSegment('C')]),
      ]);
      final ids = doc.allBlocks.map((b) => b.id).toList();
      expect(ids, ['a', 'b', 'b1', 'b2', 'c']);
    });

    test('plainText flattens tree correctly', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          segments: [const StyledSegment('A')],
          children: [
            TextBlock(id: 'a1', segments: [const StyledSegment('A1')]),
          ],
        ),
        TextBlock(id: 'b', segments: [const StyledSegment('B')]),
      ]);
      expect(doc.plainText, 'A\nA1\nB');
    });

    test('blockAt works with nested blocks', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          segments: [const StyledSegment('AB')],
          children: [
            TextBlock(id: 'a1', segments: [const StyledSegment('CD')]),
          ],
        ),
        TextBlock(id: 'b', segments: [const StyledSegment('EF')]),
      ]);
      // "AB\nCD\nEF" — offsets: A=0, B=1, \n=2, C=3, D=4, \n=5, E=6, F=7
      expect(doc.blockAt(0).blockIndex, 0); // 'a'
      expect(doc.blockAt(3).blockIndex, 1); // 'a1'
      expect(doc.blockAt(6).blockIndex, 2); // 'b'
    });

    test('depthOf returns correct nesting level', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          segments: const [],
          children: [
            TextBlock(
              id: 'a1',
              segments: const [],
              children: [TextBlock(id: 'a1a', segments: const [])],
            ),
          ],
        ),
      ]);
      expect(doc.depthOf(0), 0); // 'a'
      expect(doc.depthOf(1), 1); // 'a1'
      expect(doc.depthOf(2), 2); // 'a1a'
    });
  });

  group('Document.stylesAt', () {
    test('returns styles from segment at offset', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          segments: [
            const StyledSegment('abc '),
            const StyledSegment('bold', {InlineStyle.bold}),
            const StyledSegment(' xyz'),
          ],
        ),
      ]);
      // Inside unstyled "abc "
      expect(doc.stylesAt(0), <InlineStyle>{});
      expect(doc.stylesAt(2), <InlineStyle>{});
      // Inside bold "bold"
      expect(doc.stylesAt(5), {InlineStyle.bold});
      expect(doc.stylesAt(7), {InlineStyle.bold});
      // At end of bold segment (offset 8 = boundary)
      expect(doc.stylesAt(8), {InlineStyle.bold});
      // Inside unstyled " xyz"
      expect(doc.stylesAt(9), <InlineStyle>{});
    });

    test('returns empty for empty block', () {
      final doc = Document([TextBlock(id: 'a', segments: const [])]);
      expect(doc.stylesAt(0), <InlineStyle>{});
    });
  });

  group('mergeSegments', () {
    test('merges adjacent same-style segments', () {
      final result = mergeSegments([
        const StyledSegment('hel', {InlineStyle.bold}),
        const StyledSegment('lo', {InlineStyle.bold}),
        const StyledSegment(' world'),
      ]);
      expect(result.length, 2);
      expect(result[0].text, 'hello');
      expect(result[0].styles, {InlineStyle.bold});
      expect(result[1].text, ' world');
    });

    test('drops empty segments', () {
      final result = mergeSegments([
        const StyledSegment(''),
        const StyledSegment('hi'),
        const StyledSegment(''),
      ]);
      expect(result.length, 1);
      expect(result[0].text, 'hi');
    });

    test('does NOT merge segments with different attributes', () {
      final result = mergeSegments([
        const StyledSegment('a', {InlineStyle.link}, {'url': 'https://a.com'}),
        const StyledSegment('b', {InlineStyle.link}, {'url': 'https://b.com'}),
      ]);
      expect(result.length, 2);
      expect(result[0].attributes['url'], 'https://a.com');
      expect(result[1].attributes['url'], 'https://b.com');
    });

    test('merges segments with same styles AND attributes', () {
      final result = mergeSegments([
        const StyledSegment(
          'click',
          {InlineStyle.link},
          {'url': 'https://x.com'},
        ),
        const StyledSegment(
          ' here',
          {InlineStyle.link},
          {'url': 'https://x.com'},
        ),
      ]);
      expect(result.length, 1);
      expect(result[0].text, 'click here');
      expect(result[0].attributes['url'], 'https://x.com');
    });
  });

  group('StyledSegment attributes', () {
    test('equality includes attributes', () {
      const a = StyledSegment('x', {InlineStyle.link}, {'url': 'a'});
      const b = StyledSegment('x', {InlineStyle.link}, {'url': 'a'});
      const c = StyledSegment('x', {InlineStyle.link}, {'url': 'b'});
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });

    test('copyWith preserves attributes', () {
      const seg = StyledSegment('hi', {InlineStyle.link}, {'url': 'x'});
      final copy = seg.copyWith(text: 'bye');
      expect(copy.text, 'bye');
      expect(copy.attributes, {'url': 'x'});
    });

    test('default attributes is empty', () {
      const seg = StyledSegment('hi', {InlineStyle.bold});
      expect(seg.attributes, isEmpty);
    });
  });

  group('extractRange', () {
    test('single block partial extraction', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [
          const StyledSegment('Hello '),
          const StyledSegment('world', {InlineStyle.bold}),
        ]),
      ]);
      // Extract "lo wo" (offset 3..8)
      final blocks = doc.extractRange(3, 8);
      expect(blocks.length, 1);
      expect(blocks[0].plainText, 'lo wo');
      // Should have 2 segments: "lo " (plain) + "wo" (bold)
      expect(blocks[0].segments.length, 2);
      expect(blocks[0].segments[1].styles, {InlineStyle.bold});
    });

    test('cross-block extraction preserves block types', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.h1,
          segments: [const StyledSegment('Title')],
        ),
        TextBlock(
          id: 'b',
          segments: [const StyledSegment('Body text')],
        ),
      ]);
      // Extract "tle\nBody " (offset 2..11) — crosses block boundary
      // Title(5) + \n(1) + "Body "(5) = 11
      final blocks = doc.extractRange(2, 11);
      expect(blocks.length, 2);
      expect(blocks[0].blockType, BlockType.h1);
      expect(blocks[0].plainText, 'tle');
      expect(blocks[1].blockType, BlockType.paragraph);
      expect(blocks[1].plainText, 'Body ');
    });

    test('full block extraction', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('first')]),
        TextBlock(
          id: 'b',
          blockType: BlockType.listItem,
          segments: [const StyledSegment('second')],
        ),
        TextBlock(id: 'c', segments: [const StyledSegment('third')]),
      ]);
      // Extract entire second block: "first\n" = 6 chars, second = 6..12
      final blocks = doc.extractRange(6, 12);
      expect(blocks.length, 1);
      expect(blocks[0].blockType, BlockType.listItem);
      expect(blocks[0].plainText, 'second');
    });

    test('extracts link attributes', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [
          const StyledSegment(
              'click', {InlineStyle.link}, {'url': 'https://x.com'}),
        ]),
      ]);
      final blocks = doc.extractRange(0, 5);
      expect(blocks[0].segments[0].attributes['url'], 'https://x.com');
    });
  });
}
