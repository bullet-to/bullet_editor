import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Format', () {
    test('equality by name', () {
      expect(Format.markdown, equals(const Format('markdown')));
    });

    test('different names are not equal', () {
      expect(Format.markdown, isNot(equals(const Format('html'))));
    });

    test('hashCode consistent with equality', () {
      expect(
        Format.markdown.hashCode,
        equals(const Format('markdown').hashCode),
      );
    });
  });

  group('BlockCodec', () {
    test('encode uses EncodeContext', () {
      final codec = BlockCodec(
        encode: (block, ctx) => '${ctx.indent}# ${ctx.content}',
      );
      final block = TextBlock(
        id: 'a',
        blockType: BlockType.h1,
        segments: [const StyledSegment('Hello')],
      );
      final ctx = const EncodeContext(
        depth: 1,
        indent: '  ',
        ordinal: 0,
        content: 'Hello',
      );
      expect(codec.encode(block, ctx), '  # Hello');
    });

    test('encode with ordinal', () {
      final codec = BlockCodec(
        encode: (block, ctx) => '${ctx.indent}${ctx.ordinal}. ${ctx.content}',
      );
      final block = TextBlock(
        id: 'a',
        blockType: BlockType.numberedList,
        segments: [const StyledSegment('Item')],
      );
      final ctx = const EncodeContext(
        depth: 0,
        indent: '',
        ordinal: 3,
        content: 'Item',
      );
      expect(codec.encode(block, ctx), '3. Item');
    });

    test('decode returns match when pattern matches', () {
      final codec = BlockCodec(
        encode: (block, ctx) => '',
        decode: (line) {
          if (!line.startsWith('# ')) return null;
          return DecodeMatch(line.substring(2));
        },
      );
      final match = codec.decode!('# Hello');
      expect(match, isNotNull);
      expect(match!.content, 'Hello');
      expect(match.metadata, isEmpty);
    });

    test('decode returns null when pattern does not match', () {
      final codec = BlockCodec(
        encode: (block, ctx) => '',
        decode: (line) {
          if (!line.startsWith('# ')) return null;
          return DecodeMatch(line.substring(2));
        },
      );
      expect(codec.decode!('- Item'), isNull);
    });

    test('decode with metadata', () {
      final codec = BlockCodec(
        encode: (block, ctx) => '',
        decode: (line) {
          if (line.startsWith('- [x] ')) {
            return DecodeMatch(line.substring(6), metadata: {'checked': true});
          }
          return null;
        },
      );
      final match = codec.decode!('- [x] Done');
      expect(match, isNotNull);
      expect(match!.content, 'Done');
      expect(match.metadata['checked'], true);
    });
  });

  group('InlineCodec', () {
    test('wrap stores delimiter', () {
      const codec = InlineCodec(wrap: '**');
      expect(codec.wrap, '**');
    });

    test('wrap can be null', () {
      const codec = InlineCodec();
      expect(codec.wrap, isNull);
    });
  });

  group('DecodeMatch', () {
    test('default metadata is empty', () {
      const match = DecodeMatch('content');
      expect(match.content, 'content');
      expect(match.metadata, isEmpty);
    });
  });

  group('Schema-driven MarkdownCodec', () {
    test('decode picks most specific match (h3 over h1)', () {
      final codec = MarkdownCodec();
      final doc = codec.decode('### Sub-heading');
      expect(doc.blocks[0].blockType, BlockType.h3);
      expect(doc.blocks[0].plainText, 'Sub-heading');
    });

    test('decode picks most specific match (task over list)', () {
      final codec = MarkdownCodec();
      final doc = codec.decode('- [ ] My task');
      expect(doc.blocks[0].blockType, BlockType.taskItem);
      expect(doc.blocks[0].plainText, 'My task');
      expect(doc.blocks[0].metadata['checked'], false);
    });

    test('schema inline codecs are used for encode', () {
      final codec = MarkdownCodec();
      final doc = Document([
        TextBlock(id: 'a', segments: [
          const StyledSegment('normal '),
          const StyledSegment('bold', {InlineStyle.bold}),
          const StyledSegment(' '),
          const StyledSegment('italic', {InlineStyle.italic}),
        ]),
      ]);
      expect(codec.encode(doc), 'normal **bold** *italic*');
    });

    test('schema inline codecs are used for decode', () {
      final codec = MarkdownCodec();
      final doc = codec.decode('normal **bold** *italic*');
      final segs = doc.blocks[0].segments;
      expect(segs.length, 4);
      expect(segs[0].text, 'normal ');
      expect(segs[1].text, 'bold');
      expect(segs[1].styles, {InlineStyle.bold});
      expect(segs[2].text, ' ');
      expect(segs[3].text, 'italic');
      expect(segs[3].styles, {InlineStyle.italic});
    });

    test('block def without codec falls back to plain content', () {
      final schema = EditorSchema(
        blocks: {
          BlockType.paragraph: const BlockDef(label: 'Paragraph'),
        },
        inlineStyles: {},
      );
      final codec = MarkdownCodec(schema: schema);
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('Hello')]),
      ]);
      // Fallback: indent + content
      expect(codec.encode(doc), 'Hello');
    });
  });
}
