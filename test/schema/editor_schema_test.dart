import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EditorSchema', () {
    test('standard() contains all built-in block types', () {
      final schema = EditorSchema.standard();
      for (final type in BlockType.values) {
        expect(
          schema.blocks.containsKey(type),
          isTrue,
          reason: '$type missing from standard schema',
        );
      }
    });

    test('standard() contains all built-in inline styles', () {
      final schema = EditorSchema.standard();
      for (final style in InlineStyle.values) {
        expect(
          schema.inlineStyles.containsKey(style),
          isTrue,
          reason: '$style missing from standard schema',
        );
      }
    });

    test('blockDef returns fallback for unknown key', () {
      final schema = EditorSchema.standard();
      final def = schema.blockDef('nonexistent');
      expect(def.label, 'Unknown');
    });

    test('inlineStyleDef returns fallback for unknown key', () {
      final schema = EditorSchema.standard();
      final def = schema.inlineStyleDef('nonexistent');
      expect(def.label, 'Unknown');
      // Fallback applyStyle is identity.
      const base = TextStyle(fontSize: 14);
      expect(def.applyStyle(base), base);
    });

    test('isListLike returns true for list-like types', () {
      final schema = EditorSchema.standard();
      expect(schema.isListLike(BlockType.listItem), isTrue);
      expect(schema.isListLike(BlockType.numberedList), isTrue);
      expect(schema.isListLike(BlockType.taskItem), isTrue);
    });

    test('isListLike returns false for non-list types', () {
      final schema = EditorSchema.standard();
      expect(schema.isListLike(BlockType.paragraph), isFalse);
      expect(schema.isListLike(BlockType.h1), isFalse);
      expect(schema.isListLike(BlockType.h2), isFalse);
      expect(schema.isListLike(BlockType.h3), isFalse);
    });

    test('policies aggregates from block defs', () {
      final schema = EditorSchema.standard();
      final policies = schema.policies;
      expect(policies[BlockType.h1]!.canBeChild, isFalse);
      expect(policies[BlockType.listItem]!.canHaveChildren, isTrue);
      expect(policies[BlockType.listItem]!.maxDepth, 6);
    });

    test('block labels match expected values', () {
      final schema = EditorSchema.standard();
      expect(schema.blockDef(BlockType.paragraph).label, 'Paragraph');
      expect(schema.blockDef(BlockType.h1).label, 'Heading 1');
      expect(schema.blockDef(BlockType.h2).label, 'Heading 2');
      expect(schema.blockDef(BlockType.h3).label, 'Heading 3');
      expect(schema.blockDef(BlockType.listItem).label, 'Bullet List');
      expect(schema.blockDef(BlockType.numberedList).label, 'Numbered List');
      expect(schema.blockDef(BlockType.taskItem).label, 'Task');
      expect(schema.blockDef(BlockType.divider).label, 'Divider');
    });

    test('h1 baseStyle returns larger bold font', () {
      final schema = EditorSchema.standard();
      const base = TextStyle(fontSize: 14);
      final h1Style = schema.blockDef(BlockType.h1).baseStyle!(base);
      expect(h1Style!.fontSize, 24);
      expect(h1Style.fontWeight, FontWeight.bold);
    });

    test('h2 baseStyle returns medium bold font', () {
      final schema = EditorSchema.standard();
      const base = TextStyle(fontSize: 14);
      final h2Style = schema.blockDef(BlockType.h2).baseStyle!(base);
      expect(h2Style!.fontSize, 20);
      expect(h2Style.fontWeight, FontWeight.bold);
    });

    test('h3 baseStyle returns semibold font', () {
      final schema = EditorSchema.standard();
      const base = TextStyle(fontSize: 14);
      final h3Style = schema.blockDef(BlockType.h3).baseStyle!(base);
      expect(h3Style!.fontSize, 17);
      expect(h3Style.fontWeight, FontWeight.w600);
    });

    test('paragraph has no baseStyle override', () {
      final schema = EditorSchema.standard();
      expect(schema.blockDef(BlockType.paragraph).baseStyle, isNull);
    });

    test('bold applyStyle adds FontWeight.bold', () {
      final schema = EditorSchema.standard();
      const base = TextStyle(fontSize: 14);
      final result = schema.inlineStyleDef(InlineStyle.bold).applyStyle(base);
      expect(result.fontWeight, FontWeight.bold);
    });

    test('italic applyStyle adds FontStyle.italic', () {
      final schema = EditorSchema.standard();
      const base = TextStyle(fontSize: 14);
      final result = schema.inlineStyleDef(InlineStyle.italic).applyStyle(base);
      expect(result.fontStyle, FontStyle.italic);
    });

    test('strikethrough applyStyle adds lineThrough', () {
      final schema = EditorSchema.standard();
      const base = TextStyle(fontSize: 14);
      final result = schema
          .inlineStyleDef(InlineStyle.strikethrough)
          .applyStyle(base);
      expect(result.decoration, TextDecoration.lineThrough);
    });

    test('custom schema with third-party block type', () {
      final schema = EditorSchema(
        blocks: {
          ...EditorSchema.standard().blocks,
          'callout': const BlockDef(label: 'Callout'),
        },
        inlineStyles: EditorSchema.standard().inlineStyles,
      );
      expect(schema.blockDef('callout').label, 'Callout');
      // Built-in types still work.
      expect(schema.blockDef(BlockType.paragraph).label, 'Paragraph');
    });
  });

  group('H2/H3 codec', () {
    final codec = MarkdownCodec();

    test('encode h2 block', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.h2,
          segments: [const StyledSegment('Section')],
        ),
      ]);
      expect(codec.encode(doc), '## Section');
    });

    test('encode h3 block', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.h3,
          segments: [const StyledSegment('Subsection')],
        ),
      ]);
      expect(codec.encode(doc), '### Subsection');
    });

    test('decode h2', () {
      final doc = codec.decode('## Section');
      expect(doc.blocks.length, 1);
      expect(doc.blocks[0].blockType, BlockType.h2);
      expect(doc.blocks[0].plainText, 'Section');
    });

    test('decode h3', () {
      final doc = codec.decode('### Subsection');
      expect(doc.blocks.length, 1);
      expect(doc.blocks[0].blockType, BlockType.h3);
      expect(doc.blocks[0].plainText, 'Subsection');
    });

    test('round-trip h2 with bold', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.h2,
          segments: [
            const StyledSegment('plain '),
            const StyledSegment('bold', {InlineStyle.bold}),
          ],
        ),
      ]);
      final markdown = codec.encode(doc);
      expect(markdown, '## plain **bold**');
      final decoded = codec.decode(markdown);
      expect(decoded.blocks[0].blockType, BlockType.h2);
      expect(decoded.blocks[0].segments.length, 2);
      expect(decoded.blocks[0].segments[1].styles, contains(InlineStyle.bold));
    });
  });

  group('H2/H3 input rules', () {
    test('## space converts to H2', () {
      final rule = PrefixBlockRule('##', BlockType.h2);
      // Doc has "##" typed so far; user types space.
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('##')]),
      ]);
      final tx = Transaction(
        operations: [InsertText(0, 2, ' ')],
        selectionAfter: const TextSelection.collapsed(offset: 3),
      );
      final result = rule.tryTransform(tx, doc);
      expect(result, isNotNull);
      final applied = result!.apply(doc);
      expect(applied.allBlocks[0].blockType, BlockType.h2);
      expect(applied.allBlocks[0].plainText, '');
    });

    test('### space converts to H3', () {
      final rule = PrefixBlockRule('###', BlockType.h3);
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('###')]),
      ]);
      final tx = Transaction(
        operations: [InsertText(0, 3, ' ')],
        selectionAfter: const TextSelection.collapsed(offset: 4),
      );
      final result = rule.tryTransform(tx, doc);
      expect(result, isNotNull);
      final applied = result!.apply(doc);
      expect(applied.allBlocks[0].blockType, BlockType.h3);
      expect(applied.allBlocks[0].plainText, '');
    });

    test('## space on paragraph with existing text', () {
      final rule = PrefixBlockRule('##', BlockType.h2);
      // Doc has "##hello" typed; user inserts space at offset 2.
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('##hello')]),
      ]);
      final tx = Transaction(
        operations: [InsertText(0, 2, ' ')],
        selectionAfter: const TextSelection.collapsed(offset: 3),
      );
      final result = rule.tryTransform(tx, doc);
      expect(result, isNotNull);
      final applied = result!.apply(doc);
      expect(applied.allBlocks[0].blockType, BlockType.h2);
      expect(applied.allBlocks[0].plainText, 'hello');
    });
  });

  group('H2/H3 policies', () {
    test('h2 cannot be indented (canBeChild: false)', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.listItem,
          segments: [const StyledSegment('parent')],
        ),
        TextBlock(
          id: 'b',
          blockType: BlockType.h2,
          segments: [const StyledSegment('heading')],
        ),
      ]);
      final result = IndentBlock(1).apply(doc);
      // Should be no-op — h2 stays at root.
      expect(result.blocks.length, 2);
      expect(result.blocks[1].blockType, BlockType.h2);
    });

    test('nested block cannot be changed to h3 (canBeChild: false)', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.listItem,
          segments: [const StyledSegment('parent')],
          children: [
            TextBlock(
              id: 'b',
              blockType: BlockType.paragraph,
              segments: [const StyledSegment('child')],
            ),
          ],
        ),
      ]);
      final result = ChangeBlockType(1, BlockType.h3).apply(doc);
      // Should be no-op — nested block can't become h3.
      expect(result.allBlocks[1].blockType, BlockType.paragraph);
    });
  });
}
