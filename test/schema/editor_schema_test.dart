import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EditorSchema', () {
    test('standard() contains all built-in block types', () {
      final schema = EditorSchema.standard();
      // image is disabled pending multi-widget architecture.
      const disabled = {BlockType.image};
      for (final type in BlockType.values) {
        if (disabled.contains(type)) continue;
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

    test('defaultBlockType is paragraph', () {
      final schema = EditorSchema.standard();
      expect(schema.defaultBlockType, BlockType.paragraph);
    });

    test('isHeading returns true for headings, false for others', () {
      final schema = EditorSchema.standard();
      expect(schema.isHeading(BlockType.h1), isTrue);
      expect(schema.isHeading(BlockType.h2), isTrue);
      expect(schema.isHeading(BlockType.h3), isTrue);
      expect(schema.isHeading(BlockType.paragraph), isFalse);
      expect(schema.isHeading(BlockType.listItem), isFalse);
      expect(schema.isHeading(BlockType.divider), isFalse);
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
      expect(h1Style!.fontSize, 14 * 1.75); // ratio-based
      expect(h1Style.fontWeight, FontWeight.bold);
    });

    test('h2 baseStyle returns medium bold font', () {
      final schema = EditorSchema.standard();
      const base = TextStyle(fontSize: 14);
      final h2Style = schema.blockDef(BlockType.h2).baseStyle!(base);
      expect(h2Style!.fontSize, 14 * 1.375); // ratio-based
      expect(h2Style.fontWeight, FontWeight.bold);
    });

    test('h3 baseStyle returns semibold font', () {
      final schema = EditorSchema.standard();
      const base = TextStyle(fontSize: 14);
      final h3Style = schema.blockDef(BlockType.h3).baseStyle!(base);
      expect(h3Style!.fontSize, 14 * 1.125); // ratio-based
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
        defaultBlockType: BlockType.paragraph,
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
    final schema = EditorSchema.standard();

    test('## space converts to H2', () {
      final rule = PrefixBlockRule('##', BlockType.h2);
      // Doc has "##" typed so far; user types space.
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.paragraph,
          segments: [const StyledSegment('##')],
        ),
      ]);
      final tx = Transaction(
        operations: [InsertText(0, 2, ' ')],
        selectionAfter: const TextSelection.collapsed(offset: 3),
      );
      final result = rule.tryTransform(tx, doc, schema);
      expect(result, isNotNull);
      final applied = result!.apply(doc);
      expect(applied.allBlocks[0].blockType, BlockType.h2);
      expect(applied.allBlocks[0].plainText, '');
    });

    test('### space converts to H3', () {
      final rule = PrefixBlockRule('###', BlockType.h3);
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.paragraph,
          segments: [const StyledSegment('###')],
        ),
      ]);
      final tx = Transaction(
        operations: [InsertText(0, 3, ' ')],
        selectionAfter: const TextSelection.collapsed(offset: 4),
      );
      final result = rule.tryTransform(tx, doc, schema);
      expect(result, isNotNull);
      final applied = result!.apply(doc);
      expect(applied.allBlocks[0].blockType, BlockType.h3);
      expect(applied.allBlocks[0].plainText, '');
    });

    test('## space on paragraph with existing text', () {
      final rule = PrefixBlockRule('##', BlockType.h2);
      // Doc has "##hello" typed; user inserts space at offset 2.
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.paragraph,
          segments: [const StyledSegment('##hello')],
        ),
      ]);
      final tx = Transaction(
        operations: [InsertText(0, 2, ' ')],
        selectionAfter: const TextSelection.collapsed(offset: 3),
      );
      final result = rule.tryTransform(tx, doc, schema);
      expect(result, isNotNull);
      final applied = result!.apply(doc);
      expect(applied.allBlocks[0].blockType, BlockType.h2);
      expect(applied.allBlocks[0].plainText, 'hello');
    });
  });

  group('H2/H3 policies', () {
    final policies = EditorSchema.standard().policies;

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
      final result = IndentBlock(1, policies: policies).apply(doc);
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
      final result = ChangeBlockType(
        1,
        BlockType.h3,
        policies: policies,
      ).apply(doc);
      // Should be no-op — nested block can't become h3.
      expect(result.allBlocks[1].blockType, BlockType.paragraph);
    });
  });

  group('Schema-bundled input rules', () {
    test('inputRules collects block rules then inline rules in map order', () {
      final schema = EditorSchema.standard();
      final rules = schema.inputRules;

      // Should have rules from all block defs + inline style defs.
      expect(rules.isNotEmpty, isTrue);

      // PrefixBlockRule for ### (h3) should come before # (h1).
      final h3Idx = rules.indexWhere(
        (r) => r is PrefixBlockRule && r.prefix == '###',
      );
      final h1Idx = rules.indexWhere((r) => r is HeadingRule);
      expect(
        h3Idx,
        lessThan(h1Idx),
        reason: 'h3 prefix rule should come before h1',
      );

      // TaskItemRule should come before ListItemRule.
      final taskIdx = rules.indexWhere((r) => r is TaskItemRule);
      final listIdx = rules.indexWhere((r) => r is ListItemRule);
      expect(
        taskIdx,
        lessThan(listIdx),
        reason: 'task rule should come before list rule',
      );

      // Block rules should come before inline rules.
      final lastBlockRule = rules.lastIndexWhere(
        (r) =>
            r is PrefixBlockRule ||
            r is HeadingRule ||
            r is ListItemRule ||
            r is NumberedListRule ||
            r is DividerRule ||
            r is TaskItemRule ||
            r is EmptyListItemRule ||
            r is ListItemBackspaceRule ||
            r is DividerBackspaceRule ||
            r is NestedBackspaceRule,
      );
      final firstInlineRule = rules.indexWhere(
        (r) =>
            r is LinkWrapRule ||
            r is BoldWrapRule ||
            r is ItalicWrapRule ||
            r is StrikethroughWrapRule,
      );
      expect(
        lastBlockRule,
        lessThan(firstInlineRule),
        reason: 'all block rules should precede inline rules',
      );

      // LinkWrapRule before BoldWrapRule before ItalicWrapRule.
      final linkIdx = rules.indexWhere((r) => r is LinkWrapRule);
      final boldIdx = rules.indexWhere((r) => r is BoldWrapRule);
      final italicIdx = rules.indexWhere((r) => r is ItalicWrapRule);
      expect(linkIdx, lessThan(boldIdx));
      expect(boldIdx, lessThan(italicIdx));
    });

    test('EditorController uses schema rules with no manual list', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: const [],
          ),
        ]),
      );

      // Type "# " — should trigger heading rule from schema.
      controller.value = const TextEditingValue(
        text: '#',
        selection: TextSelection.collapsed(offset: 1),
      );
      controller.value = const TextEditingValue(
        text: '# ',
        selection: TextSelection.collapsed(offset: 2),
      );

      expect(controller.document.allBlocks[0].blockType, BlockType.h1);
    });
  });
}
