import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MarkdownCodec', () {
    final codec = MarkdownCodec();

    test('encode plain paragraphs', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('Hello')]),
        TextBlock(id: 'b', segments: [const StyledSegment('World')]),
      ]);
      expect(codec.encode(doc), 'Hello\n\nWorld');
    });

    test('encode bold segments', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          segments: [
            const StyledSegment('Hello '),
            const StyledSegment('bold', {InlineStyle.bold}),
            const StyledSegment(' text'),
          ],
        ),
      ]);
      expect(codec.encode(doc), 'Hello **bold** text');
    });

    test('decode plain paragraphs', () {
      final doc = codec.decode('Hello\n\nWorld');
      expect(doc.blocks.length, 2);
      expect(doc.blocks[0].plainText, 'Hello');
      expect(doc.blocks[1].plainText, 'World');
    });

    test('decode bold text', () {
      final doc = codec.decode('Hello **bold** text');
      expect(doc.blocks.length, 1);
      final segments = doc.blocks[0].segments;
      expect(segments.length, 3);
      expect(segments[0].text, 'Hello ');
      expect(segments[0].styles, <InlineStyle>{});
      expect(segments[1].text, 'bold');
      expect(segments[1].styles, {InlineStyle.bold});
      expect(segments[2].text, ' text');
    });

    test('encode H1 block', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.h1,
          segments: [const StyledSegment('Hello')],
        ),
      ]);
      expect(codec.encode(doc), '# Hello');
    });

    test('encode list item', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.listItem,
          segments: [const StyledSegment('Item')],
        ),
      ]);
      expect(codec.encode(doc), '- Item');
    });

    test('decode H1', () {
      final doc = codec.decode('# Hello');
      expect(doc.blocks.length, 1);
      expect(doc.blocks[0].blockType, BlockType.h1);
      expect(doc.blocks[0].plainText, 'Hello');
    });

    test('decode list item', () {
      final doc = codec.decode('- Item');
      expect(doc.blocks.length, 1);
      expect(doc.blocks[0].blockType, BlockType.listItem);
      expect(doc.blocks[0].plainText, 'Item');
    });

    test('round-trip H1 with bold', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.h1,
          segments: [
            const StyledSegment('Hello '),
            const StyledSegment('bold', {InlineStyle.bold}),
          ],
        ),
      ]);
      final decoded = codec.decode(codec.encode(doc));
      expect(decoded.blocks[0].blockType, BlockType.h1);
      expect(decoded.blocks[0].plainText, 'Hello bold');
      expect(
        decoded.blocks[0].segments.any(
          (s) => s.text == 'bold' && s.styles.contains(InlineStyle.bold),
        ),
        isTrue,
      );
    });

    test('encode nested list items with indentation', () {
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
      expect(codec.encode(doc), '- parent\n\n  - child');
    });

    test('decode nested list items', () {
      final doc = codec.decode('- parent\n\n  - child');
      expect(doc.blocks.length, 1);
      expect(doc.blocks[0].blockType, BlockType.listItem);
      expect(doc.blocks[0].plainText, 'parent');
      expect(doc.blocks[0].children.length, 1);
      expect(doc.blocks[0].children[0].blockType, BlockType.listItem);
      expect(doc.blocks[0].children[0].plainText, 'child');
    });

    test('round-trip: encode then decode preserves content', () {
      final original = Document([
        TextBlock(
          id: 'a',
          segments: [
            const StyledSegment('Some '),
            const StyledSegment('bold', {InlineStyle.bold}),
            const StyledSegment(' and normal'),
          ],
        ),
        TextBlock(id: 'b', segments: [const StyledSegment('Second paragraph')]),
      ]);

      final markdown = codec.encode(original);
      final decoded = codec.decode(markdown);

      expect(decoded.blocks.length, 2);
      expect(decoded.blocks[0].plainText, 'Some bold and normal');
      expect(decoded.blocks[1].plainText, 'Second paragraph');
      expect(
        decoded.blocks[0].segments.any(
          (s) => s.text == 'bold' && s.styles.contains(InlineStyle.bold),
        ),
        isTrue,
      );
    });
  });
}
