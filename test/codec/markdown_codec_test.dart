import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MarkdownCodec', () {
    final codec = MarkdownCodec();

    test('encode plain paragraphs', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.paragraph,
          segments: [const StyledSegment('Hello')],
        ),
        TextBlock(
          id: 'b',
          blockType: BlockType.paragraph,
          segments: [const StyledSegment('World')],
        ),
      ]);
      expect(codec.encode(doc), 'Hello\n\nWorld');
    });

    test('encode bold segments', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.paragraph,
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
          blockType: BlockType.paragraph,
          segments: [
            const StyledSegment('Some '),
            const StyledSegment('bold', {InlineStyle.bold}),
            const StyledSegment(' and normal'),
          ],
        ),
        TextBlock(
          id: 'b',
          blockType: BlockType.paragraph,
          segments: [const StyledSegment('Second paragraph')],
        ),
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
          blockType: BlockType.paragraph,
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
          blockType: BlockType.paragraph,
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
        TextBlock(
          id: 'a',
          blockType: BlockType.paragraph,
          segments: [const StyledSegment('Above')],
        ),
        TextBlock(id: 'b', blockType: BlockType.divider),
        TextBlock(
          id: 'c',
          blockType: BlockType.paragraph,
          segments: [const StyledSegment('Below')],
        ),
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
          blockType: BlockType.paragraph,
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
          blockType: BlockType.paragraph,
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
          blockType: BlockType.paragraph,
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

    test('encode overlapping bold+italic uses nested delimiters', () {
      // "1 " bold, "2" bold+italic, " 3" bold → **1 *2* 3**
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.paragraph,
          segments: [
            const StyledSegment('1 ', {InlineStyle.bold}),
            const StyledSegment('2', {InlineStyle.bold, InlineStyle.italic}),
            const StyledSegment(' 3', {InlineStyle.bold}),
          ],
        ),
      ]);
      expect(codec.encode(doc), '**1 *2* 3**');
    });

    test('decode nested bold+italic **1 *2* 3**', () {
      final doc = codec.decode('**1 *2* 3**');
      final segs = doc.blocks[0].segments;
      // Should produce 3 segments: bold, bold+italic, bold.
      expect(segs.length, 3);
      expect(segs[0].text, '1 ');
      expect(segs[0].styles, {InlineStyle.bold});
      expect(segs[1].text, '2');
      expect(segs[1].styles, {InlineStyle.bold, InlineStyle.italic});
      expect(segs[2].text, ' 3');
      expect(segs[2].styles, {InlineStyle.bold});
    });

    test('round-trip bold span with italic subset', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.paragraph,
          segments: [
            const StyledSegment('1 ', {InlineStyle.bold}),
            const StyledSegment('2', {InlineStyle.bold, InlineStyle.italic}),
            const StyledSegment(' 3', {InlineStyle.bold}),
          ],
        ),
      ]);
      final md = codec.encode(doc);
      final decoded = codec.decode(md);
      final segs = decoded.blocks[0].segments;
      expect(segs.length, 3);
      expect(segs[0].styles, {InlineStyle.bold});
      expect(segs[1].styles, {InlineStyle.bold, InlineStyle.italic});
      expect(segs[2].styles, {InlineStyle.bold});
    });

    test('encode bold link uses nested delimiters', () {
      // bold + link → **[text](url)**
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.paragraph,
          segments: [
            const StyledSegment('plain '),
            const StyledSegment(
              'click',
              {InlineStyle.bold, InlineStyle.link},
              {'url': 'https://x.com'},
            ),
            const StyledSegment(' more'),
          ],
        ),
      ]);
      expect(codec.encode(doc), 'plain **[click](https://x.com)** more');
    });

    test('decode ***text*** as bold+italic', () {
      final doc = codec.decode('***text***');
      final segs = doc.blocks[0].segments;
      expect(segs.length, 1);
      expect(segs[0].text, 'text');
      expect(segs[0].styles, {InlineStyle.bold, InlineStyle.italic});
    });

    test('encode empty paragraph adds one extra blank line', () {
      // Without empty para: "above\n\n## Heading" (one blank line).
      // With empty para: "above\n\n\n## Heading" (two blank lines visible).
      // The empty para contributes one extra \n.
      final withEmpty = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.paragraph,
          segments: [const StyledSegment('above')],
        ),
        TextBlock(id: 'b', blockType: BlockType.paragraph, segments: const []),
        TextBlock(
          id: 'c',
          blockType: BlockType.h2,
          segments: [const StyledSegment('Heading')],
        ),
      ]);
      final without = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.paragraph,
          segments: [const StyledSegment('above')],
        ),
        TextBlock(
          id: 'c',
          blockType: BlockType.h2,
          segments: [const StyledSegment('Heading')],
        ),
      ]);
      final resultWith = codec.encode(withEmpty);
      final resultWithout = codec.encode(without);

      expect(resultWithout, 'above\n\n## Heading');
      // The empty paragraph should add exactly one extra newline.
      expect(resultWith, 'above\n\n\n## Heading');
    });

    test('full document round-trip preserves structure', () {
      final md =
          '# Welcome\n\n'
          'Paragraph\n\n'
          '- Parent\n\n'
          '  - Child\n\n'
          '- Sibling\n\n'
          '---\n\n'
          '1. First\n\n'
          '2. Second';
      final decoded = codec.decode(md);
      // Parent should have Child as nested.
      expect(
        decoded.blocks.length,
        7,
      ); // h1, para, list(+child), list, divider, num, num
      final parentBlock = decoded.blocks.firstWhere(
        (b) => b.plainText == 'Parent',
      );
      expect(parentBlock.children.length, 1);
      expect(parentBlock.children[0].plainText, 'Child');
    });

    // --- Tier 1: Trailing # on headings ---

    test('decode H1 with trailing #', () {
      final doc = codec.decode('# foo #');
      expect(doc.blocks[0].blockType, BlockType.h1);
      expect(doc.blocks[0].plainText, 'foo');
    });

    test('decode H2 with multiple trailing ##', () {
      final doc = codec.decode('## foo ##');
      expect(doc.blocks[0].blockType, BlockType.h2);
      expect(doc.blocks[0].plainText, 'foo');
    });

    test('decode H3 trailing ### with extra spaces', () {
      final doc = codec.decode('### bar    ###');
      expect(doc.blocks[0].blockType, BlockType.h3);
      expect(doc.blocks[0].plainText, 'bar');
    });

    test('trailing # without preceding space is kept', () {
      final doc = codec.decode('# foo#');
      expect(doc.blocks[0].plainText, 'foo#');
    });

    test('trailing ### b is not a closing sequence', () {
      final doc = codec.decode('### foo ### b');
      expect(doc.blocks[0].plainText, 'foo ### b');
    });

    // --- Tier 1: Empty headings ---

    test('decode empty H2 (## alone)', () {
      final doc = codec.decode('##');
      expect(doc.blocks[0].blockType, BlockType.h2);
      expect(doc.blocks[0].plainText, '');
    });

    test('decode empty H1 (# alone)', () {
      final doc = codec.decode('#');
      expect(doc.blocks[0].blockType, BlockType.h1);
      expect(doc.blocks[0].plainText, '');
    });

    test('decode ### ### as empty H3', () {
      final doc = codec.decode('### ###');
      expect(doc.blocks[0].blockType, BlockType.h3);
      expect(doc.blocks[0].plainText, '');
    });

    // --- Tier 1: Leading spaces on headings ---

    test('decode heading with 1-3 leading spaces', () {
      final doc = codec.decode(' # foo');
      expect(doc.blocks[0].blockType, BlockType.h1);
      expect(doc.blocks[0].plainText, 'foo');

      final doc2 = codec.decode('  ## bar');
      expect(doc2.blocks[0].blockType, BlockType.h2);
      expect(doc2.blocks[0].plainText, 'bar');

      final doc3 = codec.decode('   ### baz');
      expect(doc3.blocks[0].blockType, BlockType.h3);
      expect(doc3.blocks[0].plainText, 'baz');
    });

    // --- Tier 1: Thematic break variants ---

    test('decode *** as divider', () {
      final doc = codec.decode('***');
      expect(doc.blocks[0].blockType, BlockType.divider);
    });

    test('decode ___ as divider', () {
      final doc = codec.decode('___');
      expect(doc.blocks[0].blockType, BlockType.divider);
    });

    test('decode spaced thematic breaks', () {
      final doc = codec.decode('- - -');
      expect(doc.blocks[0].blockType, BlockType.divider);

      final doc2 = codec.decode('*  *  *  *  *');
      expect(doc2.blocks[0].blockType, BlockType.divider);
    });

    test('decode long thematic break', () {
      final doc = codec.decode('_____________________________________');
      expect(doc.blocks[0].blockType, BlockType.divider);
    });

    test('encode divider always produces ---', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.divider,
          segments: [const StyledSegment('')],
        ),
      ]);
      expect(codec.encode(doc), '---');
    });

    // --- Tier 1: Backslash escapes ---

    test('decode backslash-escaped * in plain text', () {
      final doc = codec.decode(r'foo \*bar\* baz');
      expect(doc.blocks[0].plainText, 'foo *bar* baz');
      // Should NOT be italic.
      expect(doc.blocks[0].segments.length, 1);
      expect(doc.blocks[0].segments[0].styles, isEmpty);
    });

    test('decode backslash-escaped [ is literal', () {
      final doc = codec.decode(r'not a \[link](url)');
      expect(doc.blocks[0].plainText, 'not a [link](url)');
    });

    test('decode escaped # in heading content', () {
      final doc = codec.decode(r'# foo \#');
      expect(doc.blocks[0].blockType, BlockType.h1);
      expect(doc.blocks[0].plainText, 'foo #');
    });

    test('escaped ## does not create heading', () {
      final doc = codec.decode(r'\## foo');
      expect(doc.blocks[0].blockType, BlockType.paragraph);
      expect(doc.blocks[0].plainText, '## foo');
    });

    test('encode plain text escapes markdown chars', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.paragraph,
          segments: [const StyledSegment('foo *bar* baz')],
        ),
      ]);
      expect(codec.encode(doc), r'foo \*bar\* baz');
    });

    test('encode does not escape inside styled spans', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.paragraph,
          segments: [
            const StyledSegment('hello *world*', {InlineStyle.bold}),
          ],
        ),
      ]);
      // The * inside bold span should NOT be escaped.
      expect(codec.encode(doc), '**hello *world***');
    });

    test('round-trip heading with trailing # preserved', () {
      final doc = codec.decode('# foo #');
      final encoded = codec.encode(doc);
      final reDecoded = codec.decode(encoded);
      expect(reDecoded.blocks[0].blockType, BlockType.h1);
      expect(reDecoded.blocks[0].plainText, 'foo');
    });

    test('round-trip paragraph starting with ## preserved', () {
      final doc = codec.decode(r'\## foo');
      final encoded = codec.encode(doc);
      final reDecoded = codec.decode(encoded);
      expect(reDecoded.blocks[0].blockType, BlockType.paragraph);
      expect(reDecoded.blocks[0].plainText, '## foo');
    });

    // --- H4-H6 ---

    test('decode H4', () {
      final doc = codec.decode('#### foo');
      expect(doc.blocks[0].blockType, BlockType.h4);
      expect(doc.blocks[0].plainText, 'foo');
    });

    test('decode H5', () {
      final doc = codec.decode('##### foo');
      expect(doc.blocks[0].blockType, BlockType.h5);
      expect(doc.blocks[0].plainText, 'foo');
    });

    test('decode H6', () {
      final doc = codec.decode('###### foo');
      expect(doc.blocks[0].blockType, BlockType.h6);
      expect(doc.blocks[0].plainText, 'foo');
    });

    test('encode H4-H6 round-trip', () {
      final md = '#### H4\n\n##### H5\n\n###### H6';
      final doc = codec.decode(md);
      expect(doc.blocks[0].blockType, BlockType.h4);
      expect(doc.blocks[1].blockType, BlockType.h5);
      expect(doc.blocks[2].blockType, BlockType.h6);
      final reEncoded = codec.encode(doc);
      expect(reEncoded, md);
    });

    test('empty H4-H6', () {
      expect(codec.decode('####').blocks[0].blockType, BlockType.h4);
      expect(codec.decode('####').blocks[0].plainText, '');
      expect(codec.decode('#####').blocks[0].blockType, BlockType.h5);
      expect(codec.decode('######').blocks[0].blockType, BlockType.h6);
    });

    test('H4 trailing # stripping', () {
      final doc = codec.decode('#### foo ####');
      expect(doc.blocks[0].blockType, BlockType.h4);
      expect(doc.blocks[0].plainText, 'foo');
    });

    test('H4 with leading spaces', () {
      final doc = codec.decode('  #### foo');
      expect(doc.blocks[0].blockType, BlockType.h4);
      expect(doc.blocks[0].plainText, 'foo');
    });

    // --- Inline code ---

    test('decode inline code', () {
      final doc = codec.decode('foo `bar` baz');
      expect(doc.blocks[0].segments.length, 3);
      expect(doc.blocks[0].segments[1].text, 'bar');
      expect(doc.blocks[0].segments[1].styles, {InlineStyle.code});
    });

    test('inline code content is literal (no italic)', () {
      final doc = codec.decode('`*foo*`');
      expect(doc.blocks[0].segments.length, 1);
      expect(doc.blocks[0].segments[0].text, '*foo*');
      expect(doc.blocks[0].segments[0].styles, {InlineStyle.code});
    });

    test('encode inline code round-trip', () {
      final doc = codec.decode('foo `code` bar');
      final encoded = codec.encode(doc);
      expect(encoded, 'foo `code` bar');
    });

    test('literal backtick in plain text is escaped', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.paragraph,
          segments: [const StyledSegment('foo ` bar')],
        ),
      ]);
      expect(codec.encode(doc), r'foo \` bar');
    });

    test('inline code round-trip preserves content', () {
      final doc = codec.decode('`hello world`');
      final encoded = codec.encode(doc);
      final reDecoded = codec.decode(encoded);
      expect(reDecoded.blocks[0].segments[0].text, 'hello world');
      expect(reDecoded.blocks[0].segments[0].styles, {InlineStyle.code});
    });

    // --- Autolinks ---

    test('decode angle-bracket autolink', () {
      final doc = codec.decode('see <https://example.com> here');
      expect(doc.blocks[0].segments.length, 3);
      expect(doc.blocks[0].segments[1].text, 'https://example.com');
      expect(doc.blocks[0].segments[1].styles, {InlineStyle.link});
      expect(
        doc.blocks[0].segments[1].attributes['url'],
        'https://example.com',
      );
    });

    test('decode bare URL', () {
      final doc = codec.decode('visit https://flutter.dev today');
      expect(doc.blocks[0].segments.length, 3);
      expect(doc.blocks[0].segments[1].text, 'https://flutter.dev');
      expect(doc.blocks[0].segments[1].styles, {InlineStyle.link});
      expect(
        doc.blocks[0].segments[1].attributes['url'],
        'https://flutter.dev',
      );
    });

    test('standard link still works with autolinks', () {
      final doc = codec.decode('[text](https://example.com)');
      expect(doc.blocks[0].segments[0].text, 'text');
      expect(
        doc.blocks[0].segments[0].attributes['url'],
        'https://example.com',
      );
    });

    test('autolink round-trip normalizes to standard link', () {
      final doc = codec.decode('<https://example.com>');
      final encoded = codec.encode(doc);
      expect(encoded, '[https://example.com](https://example.com)');
    });

    // --- Images ---

    test('decode image block', () {
      final doc = codec.decode('![alt text](image.png)');
      expect(doc.blocks[0].blockType, BlockType.image);
      expect(doc.blocks[0].plainText, 'alt text');
      expect(doc.blocks[0].metadata['url'], 'image.png');
    });

    test('encode image round-trip', () {
      final doc = codec.decode('![photo](https://example.com/img.jpg)');
      final encoded = codec.encode(doc);
      expect(encoded, '![photo](https://example.com/img.jpg)');
    });

    test('image with empty alt text', () {
      final doc = codec.decode('![](url.png)');
      expect(doc.blocks[0].blockType, BlockType.image);
      expect(doc.blocks[0].plainText, '');
      expect(doc.blocks[0].metadata['url'], 'url.png');
    });

    test('mixed text with image syntax stays paragraph', () {
      final doc = codec.decode('before ![img](url) after');
      expect(doc.blocks[0].blockType, BlockType.paragraph);
    });

    // --- Block quotes ---

    test('decode block quote', () {
      final doc = codec.decode('> Hello world');
      expect(doc.blocks[0].blockType, BlockType.blockQuote);
      expect(doc.blocks[0].plainText, 'Hello world');
    });

    test('encode block quote round-trip', () {
      final doc = codec.decode('> Some quote');
      final encoded = codec.encode(doc);
      expect(encoded, '> Some quote');
    });

    test('block quote with indented children', () {
      final md = '> Parent quote\n  - Child item';
      final doc = codec.decode(md);
      expect(doc.blocks[0].blockType, BlockType.blockQuote);
      expect(doc.blocks[0].plainText, 'Parent quote');
      expect(doc.blocks[0].children.length, 1);
      expect(doc.blocks[0].children[0].blockType, BlockType.listItem);
      expect(doc.blocks[0].children[0].plainText, 'Child item');
    });

    test('consecutive block quotes use tight separator', () {
      final doc = codec.decode('> First\n> Second');
      expect(doc.blocks.length, 2);
      expect(doc.blocks[0].blockType, BlockType.blockQuote);
      expect(doc.blocks[1].blockType, BlockType.blockQuote);
    });

    test('block quote round-trip with children', () {
      final md = '> Quote\n\n  - Item';
      final doc = codec.decode(md);
      final encoded = codec.encode(doc);
      final reDecoded = codec.decode(encoded);
      expect(reDecoded.blocks[0].blockType, BlockType.blockQuote);
      expect(reDecoded.blocks[0].children.length, 1);
    });

    // --- Fenced code blocks ---

    test('decode fenced code block', () {
      final md = '```\nfoo\nbar\n```';
      final doc = codec.decode(md);
      expect(doc.blocks[0].blockType, BlockType.codeBlock);
      expect(doc.blocks[0].plainText, 'foo\nbar');
    });

    test('decode fenced code block with language', () {
      final md = '```dart\nvoid main() {}\n```';
      final doc = codec.decode(md);
      expect(doc.blocks[0].blockType, BlockType.codeBlock);
      expect(doc.blocks[0].metadata['language'], 'dart');
      expect(doc.blocks[0].plainText, 'void main() {}');
    });

    test('fenced code block preserves blank lines inside', () {
      final md = '```\nline1\n\nline3\n```';
      final doc = codec.decode(md);
      expect(doc.blocks[0].blockType, BlockType.codeBlock);
      expect(doc.blocks[0].plainText, 'line1\n\nline3');
    });

    test('fenced code block no inline decode', () {
      final md = '```\n*bold* and `code`\n```';
      final doc = codec.decode(md);
      expect(doc.blocks[0].segments.length, 1);
      expect(doc.blocks[0].plainText, '*bold* and `code`');
      expect(doc.blocks[0].segments[0].styles, isEmpty);
    });

    test('encode fenced code block round-trip', () {
      final md = '```python\nprint("hi")\n```';
      final doc = codec.decode(md);
      final encoded = codec.encode(doc);
      expect(encoded, md);
    });

    test('tilde fenced code block', () {
      final md = '~~~\nfoo\n~~~';
      final doc = codec.decode(md);
      expect(doc.blocks[0].blockType, BlockType.codeBlock);
      expect(doc.blocks[0].plainText, 'foo');
    });

    test('unclosed fence includes rest as content', () {
      final md = '```\nfoo\nbar';
      final doc = codec.decode(md);
      expect(doc.blocks[0].blockType, BlockType.codeBlock);
      expect(doc.blocks[0].plainText, 'foo\nbar');
    });

    test('fenced code block between paragraphs', () {
      final md = 'before\n\n```\ncode\n```\n\nafter';
      final doc = codec.decode(md);
      expect(doc.blocks.length, 3);
      expect(doc.blocks[0].blockType, BlockType.paragraph);
      expect(doc.blocks[1].blockType, BlockType.codeBlock);
      expect(doc.blocks[2].blockType, BlockType.paragraph);
    });
  });
}
