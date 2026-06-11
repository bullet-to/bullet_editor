import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Document', () {
    test('empty creates single block with given type', () {
      final doc = Document.empty(ParagraphKeys.type);
      expect(doc.allBlocks.length, 1);
      expect(doc.allBlocks.first.blockType, ParagraphKeys.type);
      expect(doc.allBlocks.first.plainText, '');
    });

    test('empty works with custom block type key', () {
      final doc = Document.empty('myCustomBlock');
      expect(doc.allBlocks.length, 1);
      expect(doc.allBlocks.first.blockType, 'myCustomBlock');
    });

    // The global plain-text surface (Document.plainText, blockAt,
    // globalOffset) died with the single-TextField architecture; the
    // replacement addressing surface is id-based.

    test('indexOfBlock resolves ids to flat indices', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('A')],
          children: [
            TextBlock(
              id: 'a1',
              blockType: ParagraphKeys.type,
              segments: [const StyledSegment('A1')],
            ),
          ],
        ),
        TextBlock(
          id: 'b',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('B')],
        ),
      ]);
      expect(doc.indexOfBlock('a'), 0);
      expect(doc.indexOfBlock('a1'), 1);
      expect(doc.indexOfBlock('b'), 2);
      expect(doc.indexOfBlock('gone'), -1);
      expect(doc.idToFlatIndex['a1'], 1);
    });

    test('blockById returns the block or null', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('A')],
        ),
      ]);
      expect(doc.blockById('a')!.plainText, 'A');
      expect(doc.blockById('gone'), isNull);
    });

    test('generateBlockId produces unique UUID-shaped ids', () {
      final ids = {for (var i = 0; i < 1000; i++) generateBlockId()};
      expect(ids.length, 1000);
      final uuid = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      expect(ids.every(uuid.hasMatch), isTrue);
    });
  });

  group('StyledSegment', () {
    test('equality', () {
      const a = StyledSegment('hi', {InlineStyleKeys.bold});
      const b = StyledSegment('hi', {InlineStyleKeys.bold});
      expect(a, equals(b));
    });
  });

  group('Document tree / allBlocks', () {
    test('allBlocks flattens tree depth-first', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('A')],
        ),
        TextBlock(
          id: 'b',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('B')],
          children: [
            TextBlock(
              id: 'b1',
              blockType: ParagraphKeys.type,
              segments: [const StyledSegment('B1')],
            ),
            TextBlock(
              id: 'b2',
              blockType: ParagraphKeys.type,
              segments: [const StyledSegment('B2')],
            ),
          ],
        ),
        TextBlock(
          id: 'c',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('C')],
        ),
      ]);
      final ids = doc.allBlocks.map((b) => b.id).toList();
      expect(ids, ['a', 'b', 'b1', 'b2', 'c']);
    });

    test('per-block text flattens tree correctly', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('A')],
          children: [
            TextBlock(
              id: 'a1',
              blockType: ParagraphKeys.type,
              segments: [const StyledSegment('A1')],
            ),
          ],
        ),
        TextBlock(
          id: 'b',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('B')],
        ),
      ]);
      expect(doc.allBlocks.map((b) => b.plainText).toList(), ['A', 'A1', 'B']);
    });

    test('depthOf returns correct nesting level', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: const [],
          children: [
            TextBlock(
              id: 'a1',
              blockType: ParagraphKeys.type,
              segments: const [],
              children: [
                TextBlock(
                  id: 'a1a',
                  blockType: ParagraphKeys.type,
                  segments: const [],
                ),
              ],
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
    test('returns styles from segment at block-local offset', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [
            const StyledSegment('abc '),
            const StyledSegment('bold', {InlineStyleKeys.bold}),
            const StyledSegment(' xyz'),
          ],
        ),
      ]);
      // Inside unstyled "abc "
      expect(doc.stylesAt(0, 0), <Object>{});
      expect(doc.stylesAt(0, 2), <Object>{});
      // Inside bold "bold"
      expect(doc.stylesAt(0, 5), {InlineStyleKeys.bold});
      expect(doc.stylesAt(0, 7), {InlineStyleKeys.bold});
      // At boundary (offset 8 = end of bold / start of " xyz").
      // Backward boundary → bold (typing continues the style you just left).
      expect(doc.stylesAt(0, 8), {InlineStyleKeys.bold});
      // Inside unstyled " xyz"
      expect(doc.stylesAt(0, 9), <Object>{});
    });

    test('returns empty for empty block', () {
      final doc = Document([
        TextBlock(id: 'a', blockType: ParagraphKeys.type, segments: const []),
      ]);
      expect(doc.stylesAt(0, 0), <Object>{});
    });
  });

  group('mergeSegments', () {
    test('merges adjacent same-style segments', () {
      final result = mergeSegments([
        const StyledSegment('hel', {InlineStyleKeys.bold}),
        const StyledSegment('lo', {InlineStyleKeys.bold}),
        const StyledSegment(' world'),
      ]);
      expect(result.length, 2);
      expect(result[0].text, 'hello');
      expect(result[0].styles, {InlineStyleKeys.bold});
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
        const StyledSegment(
          'a',
          {InlineEntityKeys.link},
          {'url': 'https://a.com'},
        ),
        const StyledSegment(
          'b',
          {InlineEntityKeys.link},
          {'url': 'https://b.com'},
        ),
      ]);
      expect(result.length, 2);
      expect(result[0].attributes['url'], 'https://a.com');
      expect(result[1].attributes['url'], 'https://b.com');
    });

    test('merges segments with same styles AND attributes', () {
      final result = mergeSegments([
        const StyledSegment(
          'click',
          {InlineEntityKeys.link},
          {'url': 'https://x.com'},
        ),
        const StyledSegment(
          ' here',
          {InlineEntityKeys.link},
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
      const a = StyledSegment('x', {InlineEntityKeys.link}, {'url': 'a'});
      const b = StyledSegment('x', {InlineEntityKeys.link}, {'url': 'a'});
      const c = StyledSegment('x', {InlineEntityKeys.link}, {'url': 'b'});
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });

    test('copyWith preserves attributes', () {
      const seg = StyledSegment('hi', {InlineEntityKeys.link}, {'url': 'x'});
      final copy = seg.copyWith(text: 'bye');
      expect(copy.text, 'bye');
      expect(copy.attributes, {'url': 'x'});
    });

    test('default attributes is empty', () {
      const seg = StyledSegment('hi', {InlineStyleKeys.bold});
      expect(seg.attributes, isEmpty);
    });
  });

  group('extractRange', () {
    test('single block partial extraction', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [
            const StyledSegment('Hello '),
            const StyledSegment('world', {InlineStyleKeys.bold}),
          ],
        ),
      ]);
      // Extract "lo wo" (local offsets 3..8)
      final blocks = doc.extractRange(0, 3, 0, 8);
      expect(blocks.length, 1);
      expect(blocks[0].plainText, 'lo wo');
      // Should have 2 segments: "lo " (plain) + "wo" (bold)
      expect(blocks[0].segments.length, 2);
      expect(blocks[0].segments[1].styles, {InlineStyleKeys.bold});
    });

    test('cross-block extraction preserves block types', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: HeadingKeys.h1,
          segments: [const StyledSegment('Title')],
        ),
        TextBlock(
          id: 'b',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('Body text')],
        ),
      ]);
      // Extract "tle" + "Body " — crosses the block boundary.
      final blocks = doc.extractRange(0, 2, 1, 5);
      expect(blocks.length, 2);
      expect(blocks[0].blockType, HeadingKeys.h1);
      expect(blocks[0].plainText, 'tle');
      expect(blocks[1].blockType, ParagraphKeys.type);
      expect(blocks[1].plainText, 'Body ');
    });

    test('full block extraction', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('first')],
        ),
        TextBlock(
          id: 'b',
          blockType: ListItemKeys.type,
          segments: [const StyledSegment('second')],
        ),
        TextBlock(
          id: 'c',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('third')],
        ),
      ]);
      // Extract the entire second block.
      final blocks = doc.extractRange(1, 0, 1, 6);
      expect(blocks.length, 1);
      expect(blocks[0].blockType, ListItemKeys.type);
      expect(blocks[0].plainText, 'second');
    });

    test('extracts link attributes', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [
            const StyledSegment(
              'click',
              {InlineEntityKeys.link},
              {'url': 'https://x.com'},
            ),
          ],
        ),
      ]);
      final blocks = doc.extractRange(0, 0, 0, 5);
      expect(blocks[0].segments[0].attributes['url'], 'https://x.com');
    });

    test('preserves nesting (parent with child)', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ListItemKeys.type,
          segments: [const StyledSegment('Parent')],
          children: [
            TextBlock(
              id: 'b',
              blockType: ListItemKeys.type,
              segments: [const StyledSegment('Child')],
            ),
          ],
        ),
      ]);
      // Select all: "Parent" through "Child".
      final blocks = doc.extractRange(0, 0, 1, 5);
      expect(blocks.length, 1, reason: 'Should be 1 root with 1 child');
      expect(blocks[0].plainText, 'Parent');
      expect(blocks[0].children.length, 1);
      expect(blocks[0].children[0].plainText, 'Child');
    });

    test('nested extraction round-trips through markdown codec', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ListItemKeys.type,
          segments: [const StyledSegment('Parent')],
          children: [
            TextBlock(
              id: 'b',
              blockType: ListItemKeys.type,
              segments: [const StyledSegment('Nested')],
            ),
          ],
        ),
      ]);
      final extracted = doc.extractRange(0, 0, 1, 6); // "Parent" + "Nested"
      final tempDoc = Document(extracted);
      final codec = MarkdownCodec();
      final md = codec.encode(tempDoc);
      expect(md, contains('- Parent'));
      expect(md, contains('  - Nested'));

      // Decode it back and verify nesting is preserved.
      final decoded = codec.decode(md);
      expect(decoded.blocks.length, 1);
      expect(decoded.blocks[0].children.length, 1);
      expect(decoded.blocks[0].children[0].plainText, 'Nested');
    });
  });
}
