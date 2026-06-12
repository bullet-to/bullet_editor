import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// A minimal pattern rule declaring an inline key that is not registered in
/// the schema — used to exercise `validate()`'s referencedInlineKeys check.
class _UnregisteredInlineKeyRule extends PatternInputRule {
  const _UnregisteredInlineKeyRule();

  @override
  Set<Object> get referencedInlineKeys => const {'notARegisteredKey'};

  @override
  InputRuleOutcome? tryTransform(
    Document docAfter,
    String blockId,
    TextRange editedRange,
    EditorSchema schema,
  ) => null;
}

/// A trivially valid markdown codec for synthetic block defs in tests.
BlockCodec _passthroughCodec() =>
    BlockCodec(encode: (block, ctx) => ctx.content);

void main() {
  group('EditorSchema', () {
    test('standard() contains all built-in block types', () {
      final schema = EditorSchema.standard();
      final expected = [
        ...HeadingKeys.all,
        ParagraphKeys.type,
        ListItemKeys.type,
        NumberedListKeys.type,
        TaskItemKeys.type,
        BlockQuoteKeys.type,
        CodeBlockKeys.type,
        DividerKeys.type,
        // Image is enabled in the standard schema.
        ImageKeys.type,
      ];
      for (final type in expected) {
        expect(
          schema.blocks.containsKey(type),
          isTrue,
          reason: '$type missing from standard schema',
        );
      }
    });

    test(
      'standard() contains all built-in inline styles and the link entity',
      () {
        final schema = EditorSchema.standard();
        const styles = [
          InlineStyleKeys.bold,
          InlineStyleKeys.italic,
          InlineStyleKeys.strikethrough,
          InlineStyleKeys.code,
        ];
        for (final style in styles) {
          expect(
            schema.inlineStyles.containsKey(style),
            isTrue,
            reason: '$style missing from standard schema',
          );
        }
        expect(
          schema.inlineEntities.containsKey(InlineEntityKeys.link),
          isTrue,
        );
      },
    );

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

    test('list-like types have the listLike split + backspace policies', () {
      final schema = EditorSchema.standard();
      for (final type in [
        ListItemKeys.type,
        NumberedListKeys.type,
        TaskItemKeys.type,
        // Quotes continue on Enter too (checkpoint-2 decision — the
        // Medium/Bear norm, replacing v2's split-to-paragraph).
        BlockQuoteKeys.type,
      ]) {
        final split = schema.splitPolicyOf(type);
        expect(
          split.newBlockType,
          SplitNewBlockType.inherit,
          reason: '$type should inherit type on split',
        );
        expect(
          split.onSplitEmpty,
          OnSplitEmpty.convertToDefault,
          reason: '$type should convert to default when split empty',
        );
        expect(
          schema.backspaceAtStartOf(type),
          BackspaceAtStartPolicy.outdentOrConvert,
          reason: '$type should outdent-or-convert on backspace at start',
        );
      }
    });

    test('paragraph takes the default split policy', () {
      final schema = EditorSchema.standard();
      final split = schema.splitPolicyOf(ParagraphKeys.type);
      expect(split.onEnter, OnEnter.split);
      expect(split.newBlockType, SplitNewBlockType.defaultType);
      expect(split.onSplitEmpty, OnSplitEmpty.none);
      // v2 muscle memory (day 3-4): nested paragraphs outdent on backspace
      // at start; at root the convert half is the identity, so the
      // controller's structural-backspace path merges.
      expect(
        schema.backspaceAtStartOf(ParagraphKeys.type),
        BackspaceAtStartPolicy.outdentOrConvert,
      );
      expect(schema.blockDef(ParagraphKeys.type).headingLevel, isNull);
    });

    test('code block declares Enter-inserts-line-break (replaces the old '
        'CodeBlockEnterRule interceptor)', () {
      final schema = EditorSchema.standard();
      final split = schema.splitPolicyOf(CodeBlockKeys.type);
      expect(split.onEnter, OnEnter.insertLineBreak);
      // And the code block carries no input rules at all anymore.
      expect(schema.blockDef(CodeBlockKeys.type).inputRules, isEmpty);
    });

    test('defaultBlockType is paragraph', () {
      final schema = EditorSchema.standard();
      expect(schema.defaultBlockType, ParagraphKeys.type);
    });

    test('headings declare headingLevel and convertToDefault backspace', () {
      final schema = EditorSchema.standard();
      for (var level = 1; level <= 6; level++) {
        final key = HeadingKeys.all[level - 1];
        expect(
          schema.blockDef(key).headingLevel,
          level,
          reason: '$key should declare headingLevel $level',
        );
        expect(
          schema.backspaceAtStartOf(key),
          BackspaceAtStartPolicy.convertToDefault,
          reason: '$key should convert to default on backspace at start',
        );
      }
      // Non-headings declare no heading level.
      expect(schema.blockDef(ListItemKeys.type).headingLevel, isNull);
      expect(schema.blockDef(DividerKeys.type).headingLevel, isNull);
    });

    test('policies aggregates from block defs', () {
      final schema = EditorSchema.standard();
      final policies = schema.policies;
      expect(policies[HeadingKeys.h1]!.canBeChild, isFalse);
      expect(policies[ListItemKeys.type]!.canHaveChildren, isTrue);
      expect(policies[ListItemKeys.type]!.maxDepth, 6);
    });

    test('block labels match expected values', () {
      final schema = EditorSchema.standard();
      expect(schema.blockDef(ParagraphKeys.type).label, 'Paragraph');
      expect(schema.blockDef(HeadingKeys.h1).label, 'Heading 1');
      expect(schema.blockDef(HeadingKeys.h2).label, 'Heading 2');
      expect(schema.blockDef(HeadingKeys.h3).label, 'Heading 3');
      expect(schema.blockDef(ListItemKeys.type).label, 'Bullet List');
      expect(schema.blockDef(NumberedListKeys.type).label, 'Numbered List');
      expect(schema.blockDef(TaskItemKeys.type).label, 'Task');
      expect(schema.blockDef(DividerKeys.type).label, 'Divider');
    });

    test('h1 baseStyle returns larger bold font', () {
      final schema = EditorSchema.standard();
      const base = TextStyle(fontSize: 14);
      final h1Style = schema.blockDef(HeadingKeys.h1).baseStyle!(base);
      expect(h1Style!.fontSize, 14 * 1.75); // ratio-based
      expect(h1Style.fontWeight, FontWeight.bold);
    });

    test('h2 baseStyle returns medium bold font', () {
      final schema = EditorSchema.standard();
      const base = TextStyle(fontSize: 14);
      final h2Style = schema.blockDef(HeadingKeys.h2).baseStyle!(base);
      expect(h2Style!.fontSize, 14 * 1.375); // ratio-based
      expect(h2Style.fontWeight, FontWeight.bold);
    });

    test('h3 baseStyle returns semibold font', () {
      final schema = EditorSchema.standard();
      const base = TextStyle(fontSize: 14);
      final h3Style = schema.blockDef(HeadingKeys.h3).baseStyle!(base);
      expect(h3Style!.fontSize, 14 * 1.125); // ratio-based
      expect(h3Style.fontWeight, FontWeight.w600);
    });

    test('paragraph has no baseStyle override', () {
      final schema = EditorSchema.standard();
      expect(schema.blockDef(ParagraphKeys.type).baseStyle, isNull);
    });

    test('bold applyStyle adds FontWeight.bold', () {
      final schema = EditorSchema.standard();
      const base = TextStyle(fontSize: 14);
      final result = schema
          .inlineStyleDef(InlineStyleKeys.bold)
          .applyStyle(base);
      expect(result.fontWeight, FontWeight.bold);
    });

    test('italic applyStyle adds FontStyle.italic', () {
      final schema = EditorSchema.standard();
      const base = TextStyle(fontSize: 14);
      final result = schema
          .inlineStyleDef(InlineStyleKeys.italic)
          .applyStyle(base);
      expect(result.fontStyle, FontStyle.italic);
    });

    test('strikethrough applyStyle adds lineThrough', () {
      final schema = EditorSchema.standard();
      const base = TextStyle(fontSize: 14);
      final result = schema
          .inlineStyleDef(InlineStyleKeys.strikethrough)
          .applyStyle(base);
      expect(result.decoration, TextDecoration.lineThrough);
    });

    test('custom schema with third-party block type', () {
      final schema = EditorSchema(
        defaultBlockType: ParagraphKeys.type,
        blocks: {
          ...EditorSchema.standard().blocks,
          'callout': const BlockDef(label: 'Callout'),
        },
        inlineStyles: EditorSchema.standard().inlineStyles,
      );
      expect(schema.blockDef('callout').label, 'Callout');
      // Built-in types still work.
      expect(schema.blockDef(ParagraphKeys.type).label, 'Paragraph');
    });
  });

  group('EditorSchema.validate', () {
    test('standard schema validates', () {
      expect(EditorSchema.standard().validate(), isTrue);
    });

    test('void block type without componentBuilder throws', () {
      final schema = EditorSchema(
        defaultBlockType: ParagraphKeys.type,
        blocks: {
          ParagraphKeys.type: Blocks.paragraph(),
          'embed': BlockDef(
            label: 'Embed',
            isVoid: true,
            voidBackspace: VoidBackspacePolicy.immediateDelete,
            codecs: {Format.markdown: _passthroughCodec()},
          ),
        },
        inlineStyles: const {},
      );
      expect(schema.validate, throwsStateError);
    });

    test('void block type without voidBackspace throws', () {
      final schema = EditorSchema(
        defaultBlockType: ParagraphKeys.type,
        blocks: {
          ParagraphKeys.type: Blocks.paragraph(),
          'embed': BlockDef(
            label: 'Embed',
            isVoid: true,
            componentBuilder: (ctx) => const SizedBox(),
            codecs: {Format.markdown: _passthroughCodec()},
          ),
        },
        inlineStyles: const {},
      );
      expect(schema.validate, throwsStateError);
    });

    test('block type without a markdown codec throws', () {
      final schema = EditorSchema(
        defaultBlockType: ParagraphKeys.type,
        blocks: {
          ParagraphKeys.type: Blocks.paragraph(),
          'callout': const BlockDef(label: 'Callout'),
        },
        inlineStyles: const {},
      );
      expect(schema.validate, throwsStateError);
    });

    test('non-empty metadataKeys without newBlockMetadata throws', () {
      final schema = EditorSchema(
        defaultBlockType: ParagraphKeys.type,
        blocks: {
          ParagraphKeys.type: Blocks.paragraph(),
          'poll': BlockDef(
            label: 'Poll',
            metadataKeys: const {'votes'},
            codecs: {Format.markdown: _passthroughCodec()},
          ),
        },
        inlineStyles: const {},
      );
      expect(schema.validate, throwsStateError);
    });

    test('newBlockMetadata emitting an undeclared key throws', () {
      final schema = EditorSchema(
        defaultBlockType: ParagraphKeys.type,
        blocks: {
          ParagraphKeys.type: Blocks.paragraph(),
          'poll': BlockDef(
            label: 'Poll',
            metadataKeys: const {'votes'},
            newBlockMetadata: (splitBlock) => const {'sneaky': true},
            codecs: {Format.markdown: _passthroughCodec()},
          ),
        },
        inlineStyles: const {},
      );
      expect(schema.validate, throwsStateError);
    });

    test('input rule referencing an unregistered inline key throws', () {
      final schema = EditorSchema(
        defaultBlockType: ParagraphKeys.type,
        blocks: {
          ParagraphKeys.type: Blocks.paragraph(),
          'callout': BlockDef(
            label: 'Callout',
            codecs: {Format.markdown: _passthroughCodec()},
            inputRules: const [_UnregisteredInlineKeyRule()],
          ),
        },
        inlineStyles: const {},
      );
      expect(schema.validate, throwsStateError);
    });

    test('unregistered defaultBlockType throws', () {
      final schema = EditorSchema(
        defaultBlockType: 'missing',
        blocks: {ParagraphKeys.type: Blocks.paragraph()},
        inlineStyles: const {},
      );
      expect(schema.validate, throwsStateError);
    });

    test('void defaultBlockType throws', () {
      final schema = EditorSchema(
        defaultBlockType: DividerKeys.type,
        blocks: {
          ParagraphKeys.type: Blocks.paragraph(),
          DividerKeys.type: Blocks.divider(),
        },
        inlineStyles: const {},
      );
      expect(schema.validate, throwsStateError);
    });
  });

  group('H2/H3 codec', () {
    final codec = MarkdownCodec();

    test('encode h2 block', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: HeadingKeys.h2,
          segments: [const StyledSegment('Section')],
        ),
      ]);
      expect(codec.encode(doc), '## Section');
    });

    test('encode h3 block', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: HeadingKeys.h3,
          segments: [const StyledSegment('Subsection')],
        ),
      ]);
      expect(codec.encode(doc), '### Subsection');
    });

    test('decode h2', () {
      final doc = codec.decode('## Section');
      expect(doc.blocks.length, 1);
      expect(doc.blocks[0].blockType, HeadingKeys.h2);
      expect(doc.blocks[0].plainText, 'Section');
    });

    test('decode h3', () {
      final doc = codec.decode('### Subsection');
      expect(doc.blocks.length, 1);
      expect(doc.blocks[0].blockType, HeadingKeys.h3);
      expect(doc.blocks[0].plainText, 'Subsection');
    });

    test('round-trip h2 with bold', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: HeadingKeys.h2,
          segments: [
            const StyledSegment('plain '),
            const StyledSegment('bold', {InlineStyleKeys.bold}),
          ],
        ),
      ]);
      final markdown = codec.encode(doc);
      expect(markdown, '## plain **bold**');
      final decoded = codec.decode(markdown);
      expect(decoded.blocks[0].blockType, HeadingKeys.h2);
      expect(decoded.blocks[0].segments.length, 2);
      expect(
        decoded.blocks[0].segments[1].styles,
        contains(InlineStyleKeys.bold),
      );
    });
  });

  group('H2/H3 input rules', () {
    final schema = EditorSchema.standard();

    /// Apply all outcome operations in order against [doc].
    Document applyOutcome(InputRuleOutcome outcome, Document doc) {
      var result = doc;
      final ctx = schema.editContext();
      for (final op in outcome.operations) {
        final next = op.apply(result, ctx);
        expect(next, isNotNull, reason: '$op should apply');
        result = next!;
      }
      return result;
    }

    test('## space converts to H2', () {
      const rule = PrefixBlockRule('##', HeadingKeys.h2);
      // The user typed "##" then a space; rules run against the post-edit doc.
      final docAfter = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('## ')],
        ),
      ]);
      final outcome = rule.tryTransform(
        docAfter,
        'a',
        const TextRange(start: 2, end: 3),
        schema,
      );
      expect(outcome, isNotNull);
      final applied = applyOutcome(outcome!, docAfter);
      expect(applied.allBlocks[0].blockType, HeadingKeys.h2);
      expect(applied.allBlocks[0].plainText, '');
    });

    test('### space converts to H3', () {
      const rule = PrefixBlockRule('###', HeadingKeys.h3);
      final docAfter = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('### ')],
        ),
      ]);
      final outcome = rule.tryTransform(
        docAfter,
        'a',
        const TextRange(start: 3, end: 4),
        schema,
      );
      expect(outcome, isNotNull);
      final applied = applyOutcome(outcome!, docAfter);
      expect(applied.allBlocks[0].blockType, HeadingKeys.h3);
      expect(applied.allBlocks[0].plainText, '');
    });

    test('## space on paragraph with existing text', () {
      const rule = PrefixBlockRule('##', HeadingKeys.h2);
      // The user had "##hello" and inserted a space at offset 2.
      final docAfter = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('## hello')],
        ),
      ]);
      final outcome = rule.tryTransform(
        docAfter,
        'a',
        const TextRange(start: 2, end: 3),
        schema,
      );
      expect(outcome, isNotNull);
      final applied = applyOutcome(outcome!, docAfter);
      expect(applied.allBlocks[0].blockType, HeadingKeys.h2);
      expect(applied.allBlocks[0].plainText, 'hello');
    });
  });

  group('H2/H3 policies', () {
    final ctx = EditorSchema.standard().editContext();

    test('h2 cannot be indented (canBeChild: false)', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ListItemKeys.type,
          segments: [const StyledSegment('parent')],
        ),
        TextBlock(
          id: 'b',
          blockType: HeadingKeys.h2,
          segments: [const StyledSegment('heading')],
        ),
      ]);
      // The G13 gate fails — the op rejects rather than silently no-oping.
      final result = IndentBlock('b').apply(doc, ctx);
      expect(result, isNull);
    });

    test('nested block cannot be changed to h3 (canBeChild: false)', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ListItemKeys.type,
          segments: [const StyledSegment('parent')],
          children: [
            TextBlock(
              id: 'b',
              blockType: ParagraphKeys.type,
              segments: [const StyledSegment('child')],
            ),
          ],
        ),
      ]);
      // Rejected — a nested block can't become h3.
      final result = ChangeBlockType('b', HeadingKeys.h3).apply(doc, ctx);
      expect(result, isNull);
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
      final h1Idx = rules.indexWhere(
        (r) => r is PrefixBlockRule && r.prefix == '#',
      );
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
        (r) => r is PrefixBlockRule || r is TaskItemRule || r is DividerRule,
      );
      final firstInlineRule = rules.indexWhere(
        (r) => r is LinkWrapRule || r is InlineWrapRule,
      );
      expect(
        lastBlockRule,
        lessThan(firstInlineRule),
        reason: 'all block rules should precede inline rules',
      );

      // LinkWrapRule (entity) before BoldWrapRule before ItalicWrapRule.
      final linkIdx = rules.indexWhere((r) => r is LinkWrapRule);
      final boldIdx = rules.indexWhere((r) => r is BoldWrapRule);
      final italicIdx = rules.indexWhere((r) => r is ItalicWrapRule);
      expect(linkIdx, lessThan(boldIdx));
      expect(boldIdx, lessThan(italicIdx));
    });
  });
}
