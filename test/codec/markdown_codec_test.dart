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
      expect(codec.encode(doc), '- parent\n  - child');
    });

    test('decode nested list items', () {
      final doc = codec.decode('- parent\n  - child');
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

    test('encode italic segments', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          segments: [
            const StyledSegment('normal '),
            const StyledSegment('italic', {InlineStyle.italic}),
            const StyledSegment(' text'),
          ],
        ),
      ]);
      expect(codec.encode(doc), 'normal *italic* text');
    });

    test('decode italic text', () {
      final doc = codec.decode('normal *italic* text');
      expect(
        doc.blocks[0].segments.any(
          (s) => s.text == 'italic' && s.styles.contains(InlineStyle.italic),
        ),
        isTrue,
      );
    });

    test('encode strikethrough segments', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          segments: [
            const StyledSegment('normal '),
            const StyledSegment('strike', {InlineStyle.strikethrough}),
            const StyledSegment(' text'),
          ],
        ),
      ]);
      expect(codec.encode(doc), 'normal ~~strike~~ text');
    });

    test('decode strikethrough text', () {
      final doc = codec.decode('normal ~~strike~~ text');
      expect(
        doc.blocks[0].segments.any(
          (s) =>
              s.text == 'strike' &&
              s.styles.contains(InlineStyle.strikethrough),
        ),
        isTrue,
      );
    });

    test('encode numbered list', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.numberedList,
          segments: [const StyledSegment('first')],
        ),
        TextBlock(
          id: 'b',
          blockType: BlockType.numberedList,
          segments: [const StyledSegment('second')],
        ),
      ]);
      expect(codec.encode(doc), '1. first\n2. second');
    });

    test('decode numbered list', () {
      final doc = codec.decode('1. first\n2. second');
      expect(doc.blocks.length, 2);
      expect(doc.blocks[0].blockType, BlockType.numberedList);
      expect(doc.blocks[0].plainText, 'first');
      expect(doc.blocks[1].blockType, BlockType.numberedList);
      expect(doc.blocks[1].plainText, 'second');
    });

    test('encode task items', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.taskItem,
          segments: [const StyledSegment('undone')],
          metadata: {'checked': false},
        ),
        TextBlock(
          id: 'b',
          blockType: BlockType.taskItem,
          segments: [const StyledSegment('done')],
          metadata: {'checked': true},
        ),
      ]);
      expect(codec.encode(doc), '- [ ] undone\n- [x] done');
    });

    test('decode task items', () {
      final doc = codec.decode('- [ ] undone\n- [x] done');
      expect(doc.blocks.length, 2);
      expect(doc.blocks[0].blockType, BlockType.taskItem);
      expect(doc.blocks[0].plainText, 'undone');
      expect(doc.blocks[0].metadata['checked'], false);
      expect(doc.blocks[1].blockType, BlockType.taskItem);
      expect(doc.blocks[1].plainText, 'done');
      expect(doc.blocks[1].metadata['checked'], true);
    });

    test('encode divider', () {
      final doc = Document([TextBlock(id: 'a', blockType: BlockType.divider)]);
      expect(codec.encode(doc), '---');
    });

    test('decode divider', () {
      final doc = codec.decode('---');
      expect(doc.blocks.length, 1);
      expect(doc.blocks[0].blockType, BlockType.divider);
      expect(doc.blocks[0].plainText, '');
    });

    test('round-trip divider between paragraphs', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('Above')]),
        TextBlock(id: 'b', blockType: BlockType.divider),
        TextBlock(id: 'c', segments: [const StyledSegment('Below')]),
      ]);
      final md = codec.encode(doc);
      expect(md, 'Above\n\n---\n\nBelow');
      final decoded = codec.decode(md);
      expect(decoded.blocks.length, 3);
      expect(decoded.blocks[0].blockType, BlockType.paragraph);
      expect(decoded.blocks[0].plainText, 'Above');
      expect(decoded.blocks[1].blockType, BlockType.divider);
      expect(decoded.blocks[1].plainText, '');
      expect(decoded.blocks[2].blockType, BlockType.paragraph);
      expect(decoded.blocks[2].plainText, 'Below');
    });

    test('--- with extra text is not a divider', () {
      final doc = codec.decode('--- extra');
      expect(doc.blocks[0].blockType, BlockType.paragraph);
    });

    test('encode link segment', () {
      final doc = Document([
        TextBlock(
          id: 'a',
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
      ]);
      expect(codec.encode(doc), 'Visit [Google](https://google.com) today');
    });

    test('decode link', () {
      final doc = codec.decode('Visit [Google](https://google.com) today');
      final segs = doc.blocks[0].segments;
      expect(segs.length, 3);
      expect(segs[0].text, 'Visit ');
      expect(segs[0].styles, isEmpty);
      expect(segs[1].text, 'Google');
      expect(segs[1].styles, {InlineStyle.link});
      expect(segs[1].attributes['url'], 'https://google.com');
      expect(segs[2].text, ' today');
    });

    test('round-trip link with bold', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          segments: [
            const StyledSegment('Click ', {InlineStyle.bold}),
            const StyledSegment(
              'here',
              {InlineStyle.link},
              {'url': 'https://example.com'},
            ),
          ],
        ),
      ]);
      final md = codec.encode(doc);
      expect(md, '**Click **[here](https://example.com)');
      final decoded = codec.decode(md);
      expect(
        decoded.blocks[0].segments.any(
          (s) =>
              s.text == 'here' &&
              s.styles.contains(InlineStyle.link) &&
              s.attributes['url'] == 'https://example.com',
        ),
        isTrue,
      );
    });

    test('decode multiple links in one paragraph', () {
      final doc = codec.decode('[A](url1) and [B](url2)');
      final segs = doc.blocks[0].segments;
      expect(segs.length, 3);
      expect(segs[0].text, 'A');
      expect(segs[0].attributes['url'], 'url1');
      expect(segs[1].text, ' and ');
      expect(segs[2].text, 'B');
      expect(segs[2].attributes['url'], 'url2');
    });

    test('encode consecutive list items without blank lines between', () {
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
        TextBlock(
          id: 'c',
          segments: [const StyledSegment('paragraph after')],
        ),
      ]);
      final md = codec.encode(doc);
      // List siblings should be separated by \n, not \n\n.
      expect(md, contains('- first\n- second'));
      // But paragraph after the list should have \n\n.
      expect(md, contains('second\n\nparagraph after'));
    });

    test('encode consecutive numbered list items without blank lines', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.numberedList,
          segments: [const StyledSegment('first')],
        ),
        TextBlock(
          id: 'b',
          blockType: BlockType.numberedList,
          segments: [const StyledSegment('second')],
        ),
      ]);
      expect(codec.encode(doc), '1. first\n2. second');
    });

    test('full document round-trip preserves structure', () {
      final md = '# Welcome\n\n'
          'Paragraph\n\n'
          '- Parent\n\n'
          '  - Child\n\n'
          '- Sibling\n\n'
          '---\n\n'
          '1. First\n\n'
          '2. Second';
      final decoded = codec.decode(md);
      // Parent should have Child as nested.
      expect(decoded.blocks.length, 7); // h1, para, list(+child), list, divider, num, num
      final parentBlock = decoded.blocks.firstWhere(
          (b) => b.plainText == 'Parent');
      expect(parentBlock.children.length, 1);
      expect(parentBlock.children[0].plainText, 'Child');
    });
  });
}
