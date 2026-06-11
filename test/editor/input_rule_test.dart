import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/services.dart' show TextRange;
import 'package:flutter_test/flutter_test.dart';

/// Applies an [InputRuleOutcome]'s follow-up operations sequentially to
/// [docAfter] (the document as it looks after the triggering insertion).
Document applyOutcome(
  Document docAfter,
  InputRuleOutcome outcome,
  EditorSchema schema,
) {
  final ctx = schema.editContext();
  var doc = docAfter;
  for (final op in outcome.operations) {
    final next = op.apply(doc, ctx);
    expect(next, isNotNull, reason: 'op $op rejected');
    doc = next!;
  }
  return doc;
}

void main() {
  final schema = EditorSchema.standard();

  // Deleted v2 rule groups (behavior moved into BlockDef policies, applied by
  // the controller, days 5–7):
  // - HeadingBackspaceRule → BlockDef `backspaceAtStart` policy.
  // - EmptyListItemRule (incl. list-like types) → BlockDef `split` policy.
  // - ListItemBackspaceRule → BlockDef `backspaceAtStart` policy.
  // - NestedBackspaceRule → BlockDef `backspaceAtStart`/`split` policies.
  // - DividerBackspaceRule → BlockDef `voidBackspace` policy.

  group('BoldWrapRule', () {
    test('detects **text** and transforms to bold', () {
      final rule = BoldWrapRule();

      // Post-application: the closing "*" has already been inserted at
      // offset 14, making the committed text "hello **world**".
      final docAfter = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('hello **world**')],
        ),
      ]);

      final outcome = rule.tryTransform(
        docAfter,
        'a',
        const TextRange(start: 14, end: 15),
        schema,
      );
      expect(outcome, isNotNull);

      final newDoc = applyOutcome(docAfter, outcome!, schema);

      // The asterisks should be removed and "world" should be bold.
      expect(newDoc.blocks[0].plainText, 'hello world');
      expect(
        newDoc.blocks[0].segments.any(
          (s) => s.text == 'world' && s.styles.contains(InlineStyleKeys.bold),
        ),
        isTrue,
      );

      // Caret should be right after "world" (offset 11 = "hello world".length).
      expect(
        outcome.selectionAfter,
        DocSelection.collapsed(const DocPosition('a', 11)),
      );
    });

    test(
      'does NOT fire when **text** already exists and unrelated edit happens',
      () {
        final rule = BoldWrapRule();

        // Block already has **text** as literal characters; the user typed a
        // space at the end — unrelated to the pattern.
        final docAfter = Document([
          TextBlock(
            id: 'a',
            blockType: ParagraphKeys.type,
            segments: [const StyledSegment('Type **text** here ')],
          ),
        ]);

        // Rule should NOT fire — the pattern wasn't just completed.
        expect(
          rule.tryTransform(
            docAfter,
            'a',
            const TextRange(start: 18, end: 19),
            schema,
          ),
          isNull,
        );
      },
    );

    test('cursor lands after bold text when pattern is mid-sentence', () {
      final rule = BoldWrapRule();

      // User typed the closing * at offset 14 → "abc **trigger** bold".
      final docAfter = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('abc **trigger** bold')],
        ),
      ]);

      final outcome = rule.tryTransform(
        docAfter,
        'a',
        const TextRange(start: 14, end: 15),
        schema,
      );
      expect(outcome, isNotNull);

      final newDoc = applyOutcome(docAfter, outcome!, schema);

      // Should be "abc trigger bold" with "trigger" bold.
      expect(newDoc.blocks[0].plainText, 'abc trigger bold');
      expect(
        newDoc.blocks[0].segments.any(
          (s) => s.text == 'trigger' && s.styles.contains(InlineStyleKeys.bold),
        ),
        isTrue,
      );

      // Caret right after "trigger" = offset 11 ("abc trigger".length).
      expect(
        outcome.selectionAfter,
        DocSelection.collapsed(const DocPosition('a', 11)),
      );
    });

    test('cursor correct when bold pattern is in second block', () {
      final rule = BoldWrapRule();

      // Two blocks; user typed the closing * in block 'b' at local offset 14.
      final docAfter = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('first')],
        ),
        TextBlock(
          id: 'b',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('abc **trigger** bold')],
        ),
      ]);

      final outcome = rule.tryTransform(
        docAfter,
        'b',
        const TextRange(start: 14, end: 15),
        schema,
      );
      expect(outcome, isNotNull);

      final newDoc = applyOutcome(docAfter, outcome!, schema);
      expect(newDoc.blocks[1].plainText, 'abc trigger bold');

      // Caret should be after "trigger" in block 'b' (local offset 11).
      expect(
        outcome.selectionAfter,
        DocSelection.collapsed(const DocPosition('b', 11)),
      );
    });

    test('returns null when no pattern found', () {
      final rule = BoldWrapRule();
      final docAfter = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('hello world!')],
        ),
      ]);

      expect(
        rule.tryTransform(
          docAfter,
          'a',
          const TextRange(start: 11, end: 12),
          schema,
        ),
        isNull,
      );
    });
  });

  group('HeadingRule', () {
    test('# followed by space converts to H1', () {
      const rule = HeadingRule();
      // The space after "#" has been committed → block text is "# ".
      final docAfter = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('# ')],
        ),
      ]);

      final outcome = rule.tryTransform(
        docAfter,
        'a',
        const TextRange(start: 1, end: 2),
        schema,
      );
      expect(outcome, isNotNull);

      final newDoc = applyOutcome(docAfter, outcome!, schema);
      expect(newDoc.blocks[0].blockType, HeadingKeys.h1);
      expect(newDoc.blocks[0].plainText, '');
      expect(
        outcome.selectionAfter,
        DocSelection.collapsed(const DocPosition('a', 0)),
      );
    });

    test('# space at start of paragraph with existing text converts to H1', () {
      const rule = HeadingRule();
      // User typed # at the start of "hello", then space → "# hello".
      final docAfter = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('# hello')],
        ),
      ]);

      final outcome = rule.tryTransform(
        docAfter,
        'a',
        const TextRange(start: 1, end: 2),
        schema,
      );
      expect(outcome, isNotNull);

      final newDoc = applyOutcome(docAfter, outcome!, schema);
      expect(newDoc.blocks[0].blockType, HeadingKeys.h1);
      expect(newDoc.blocks[0].plainText, 'hello');
    });

    test('does not fire on # mid-text', () {
      const rule = HeadingRule();
      final docAfter = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('hello # ')],
        ),
      ]);

      expect(
        rule.tryTransform(
          docAfter,
          'a',
          const TextRange(start: 7, end: 8),
          schema,
        ),
        isNull,
      );
    });

    test('does not fire if block is already H1', () {
      const rule = HeadingRule();
      final docAfter = Document([
        TextBlock(
          id: 'a',
          blockType: HeadingKeys.h1,
          segments: [const StyledSegment('# ')],
        ),
      ]);

      expect(
        rule.tryTransform(
          docAfter,
          'a',
          const TextRange(start: 1, end: 2),
          schema,
        ),
        isNull,
      );
    });
  });

  // HeadingBackspaceRule group deleted — behavior moved to the BlockDef
  // `backspaceAtStart` policy (controller-implemented, days 5–7).

  group('ListItemRule', () {
    test('- followed by space converts to list item', () {
      const rule = ListItemRule();
      final docAfter = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('- ')],
        ),
      ]);

      final outcome = rule.tryTransform(
        docAfter,
        'a',
        const TextRange(start: 1, end: 2),
        schema,
      );
      expect(outcome, isNotNull);

      final newDoc = applyOutcome(docAfter, outcome!, schema);
      expect(newDoc.blocks[0].blockType, ListItemKeys.type);
      expect(newDoc.blocks[0].plainText, '');
    });
  });

  // EmptyListItemRule group deleted — behavior moved to the BlockDef `split`
  // policy (controller-implemented, days 5–7).

  // ListItemBackspaceRule group deleted — behavior moved to the BlockDef
  // `backspaceAtStart` policy (controller-implemented, days 5–7).

  group('ItalicWrapRule', () {
    test('*text* converts to italic', () {
      final rule = ItalicWrapRule();
      // Closing * committed at offset 12 → "hello *world*".
      final docAfter = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('hello *world*')],
        ),
      ]);

      final outcome = rule.tryTransform(
        docAfter,
        'a',
        const TextRange(start: 12, end: 13),
        schema,
      );
      expect(outcome, isNotNull);

      final resultDoc = applyOutcome(docAfter, outcome!, schema);
      expect(resultDoc.allBlocks[0].plainText, 'hello world');
      expect(
        resultDoc.allBlocks[0].segments.any(
          (s) => s.text == 'world' && s.styles.contains(InlineStyleKeys.italic),
        ),
        isTrue,
      );
    });

    test('does not steal the first closing star from bold syntax', () {
      final rule = ItalicWrapRule();
      // User typed the first closing * of would-be bold → "**world*".
      final docAfter = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('**world*')],
        ),
      ]);

      expect(
        rule.tryTransform(
          docAfter,
          'a',
          const TextRange(start: 7, end: 8),
          schema,
        ),
        isNull,
      );
    });
  });

  group('StrikethroughWrapRule', () {
    test('~~text~~ converts to strikethrough', () {
      final rule = StrikethroughWrapRule();
      // Closing ~ committed at offset 14 → "hello ~~world~~".
      final docAfter = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('hello ~~world~~')],
        ),
      ]);

      final outcome = rule.tryTransform(
        docAfter,
        'a',
        const TextRange(start: 14, end: 15),
        schema,
      );
      expect(outcome, isNotNull);

      final resultDoc = applyOutcome(docAfter, outcome!, schema);
      expect(resultDoc.allBlocks[0].plainText, 'hello world');
      expect(
        resultDoc.allBlocks[0].segments.any(
          (s) =>
              s.text == 'world' &&
              s.styles.contains(InlineStyleKeys.strikethrough),
        ),
        isTrue,
      );
    });
  });

  group('NumberedListRule', () {
    test('1. followed by space converts to numbered list', () {
      const rule = NumberedListRule();
      final docAfter = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('1. ')],
        ),
      ]);

      final outcome = rule.tryTransform(
        docAfter,
        'a',
        const TextRange(start: 2, end: 3),
        schema,
      );
      expect(outcome, isNotNull);

      final resultDoc = applyOutcome(docAfter, outcome!, schema);
      expect(resultDoc.allBlocks[0].blockType, NumberedListKeys.type);
      expect(resultDoc.allBlocks[0].plainText, '');
    });
  });

  group('TaskItemRule', () {
    test('- [ ] followed by space creates unchecked task', () {
      const rule = TaskItemRule();
      final docAfter = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('- [ ] ')],
        ),
      ]);

      final outcome = rule.tryTransform(
        docAfter,
        'a',
        const TextRange(start: 5, end: 6),
        schema,
      );
      expect(outcome, isNotNull);

      final resultDoc = applyOutcome(docAfter, outcome!, schema);
      expect(resultDoc.allBlocks[0].blockType, TaskItemKeys.type);
      expect(resultDoc.allBlocks[0].metadata['checked'], false);
      expect(resultDoc.allBlocks[0].plainText, '');
    });

    test('- [x] followed by space creates checked task', () {
      const rule = TaskItemRule();
      final docAfter = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('- [x] ')],
        ),
      ]);

      final outcome = rule.tryTransform(
        docAfter,
        'a',
        const TextRange(start: 5, end: 6),
        schema,
      );
      expect(outcome, isNotNull);

      final resultDoc = applyOutcome(docAfter, outcome!, schema);
      expect(resultDoc.allBlocks[0].blockType, TaskItemKeys.type);
      expect(resultDoc.allBlocks[0].metadata['checked'], true);
    });

    test('[ ] on a list item converts to task (post-ListItemRule path)', () {
      // After ListItemRule eats "- ", the user is on a listItem typing "[ ] ".
      const rule = TaskItemRule();
      final docAfter = Document([
        TextBlock(
          id: 'a',
          blockType: ListItemKeys.type,
          segments: [const StyledSegment('[ ] ')],
        ),
      ]);

      final outcome = rule.tryTransform(
        docAfter,
        'a',
        const TextRange(start: 3, end: 4),
        schema,
      );
      expect(outcome, isNotNull);

      final resultDoc = applyOutcome(docAfter, outcome!, schema);
      expect(resultDoc.allBlocks[0].blockType, TaskItemKeys.type);
      expect(resultDoc.allBlocks[0].metadata['checked'], false);
      expect(resultDoc.allBlocks[0].plainText, '');
    });

    test('[ ] on paragraph creates unchecked task (no hyphen)', () {
      const rule = TaskItemRule();
      final docAfter = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('[ ] ')],
        ),
      ]);

      final outcome = rule.tryTransform(
        docAfter,
        'a',
        const TextRange(start: 3, end: 4),
        schema,
      );
      expect(outcome, isNotNull);

      final resultDoc = applyOutcome(docAfter, outcome!, schema);
      expect(resultDoc.allBlocks[0].blockType, TaskItemKeys.type);
      expect(resultDoc.allBlocks[0].metadata['checked'], false);
      expect(resultDoc.allBlocks[0].plainText, '');
    });

    test('[x] on paragraph creates checked task (no hyphen)', () {
      const rule = TaskItemRule();
      final docAfter = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('[x] ')],
        ),
      ]);

      final outcome = rule.tryTransform(
        docAfter,
        'a',
        const TextRange(start: 3, end: 4),
        schema,
      );
      expect(outcome, isNotNull);

      final resultDoc = applyOutcome(docAfter, outcome!, schema);
      expect(resultDoc.allBlocks[0].blockType, TaskItemKeys.type);
      expect(resultDoc.allBlocks[0].metadata['checked'], true);
      expect(resultDoc.allBlocks[0].plainText, '');
    });
  });

  group('DividerRule', () {
    test(
      'typing --- converts paragraph to divider with trailing paragraph',
      () {
        // The third "-" has been committed → block text is "---".
        const rule = DividerRule();
        final docAfter = Document([
          TextBlock(
            id: 'a',
            blockType: ParagraphKeys.type,
            segments: [const StyledSegment('---')],
          ),
        ]);

        final outcome = rule.tryTransform(
          docAfter,
          'a',
          const TextRange(start: 2, end: 3),
          schema,
        );
        expect(outcome, isNotNull);

        final resultDoc = applyOutcome(docAfter, outcome!, schema);
        expect(resultDoc.allBlocks.length, 2);
        expect(resultDoc.allBlocks[0].blockType, DividerKeys.type);
        expect(resultDoc.allBlocks[0].plainText, '');
        expect(resultDoc.allBlocks[1].blockType, ParagraphKeys.type);
        expect(resultDoc.allBlocks[1].plainText, '');

        // Caret targets the new trailing block's id at offset 0.
        expect(
          outcome.selectionAfter,
          DocSelection.collapsed(DocPosition(resultDoc.allBlocks[1].id, 0)),
        );
      },
    );

    test('does not fire on non-paragraph blocks', () {
      const rule = DividerRule();
      final docAfter = Document([
        TextBlock(
          id: 'a',
          blockType: HeadingKeys.h1,
          segments: [const StyledSegment('---')],
        ),
      ]);

      expect(
        rule.tryTransform(
          docAfter,
          'a',
          const TextRange(start: 2, end: 3),
          schema,
        ),
        isNull,
      );
    });

    test('does not fire when text is not exactly ---', () {
      const rule = DividerRule();
      final docAfter = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('a--')],
        ),
      ]);

      expect(
        rule.tryTransform(
          docAfter,
          'a',
          const TextRange(start: 2, end: 3),
          schema,
        ),
        isNull,
      );
    });
  });

  // DividerBackspaceRule group deleted — behavior moved to the BlockDef
  // `voidBackspace` policy.

  group('CodeBlockEnterRule', () {
    test('Enter inside a code block inserts a literal newline', () {
      const rule = CodeBlockEnterRule();
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: CodeBlockKeys.type,
          segments: [const StyledSegment('hello')],
        ),
      ]);

      final outcome = rule.intercept(
        const StructuralTrigger.split('a', 5),
        doc,
        schema,
      );
      expect(outcome, isNotNull);

      final resultDoc = applyOutcome(doc, outcome!, schema);
      // Still one block — the newline is embedded, not a split.
      expect(resultDoc.allBlocks.length, 1);
      expect(resultDoc.allBlocks[0].blockType, CodeBlockKeys.type);
      expect(resultDoc.allBlocks[0].plainText, 'hello\n');
      expect(
        outcome.selectionAfter,
        DocSelection.collapsed(const DocPosition('a', 6)),
      );
    });

    test('does not intercept Enter on non-code blocks', () {
      const rule = CodeBlockEnterRule();
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('hello')],
        ),
      ]);

      expect(
        rule.intercept(const StructuralTrigger.split('a', 5), doc, schema),
        isNull,
      );
    });

    test('does not intercept backspace-at-start triggers', () {
      const rule = CodeBlockEnterRule();
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('above')],
        ),
        TextBlock(
          id: 'b',
          blockType: CodeBlockKeys.type,
          segments: [const StyledSegment('code')],
        ),
      ]);

      expect(
        rule.intercept(
          const StructuralTrigger.backspaceAtStart('b'),
          doc,
          schema,
        ),
        isNull,
      );
    });
  });

  group('RemoveBlock', () {
    test('removes a block from document', () {
      final ctx = schema.editContext();
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('first')],
        ),
        TextBlock(id: 'b', blockType: DividerKeys.type),
        TextBlock(
          id: 'c',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('third')],
        ),
      ]);
      final result = RemoveBlock('b').apply(doc, ctx);
      expect(result, isNotNull);
      expect(result!.allBlocks.length, 2);
      expect(result.allBlocks[0].plainText, 'first');
      expect(result.allBlocks[1].plainText, 'third');
    });

    test('removing the last block swaps in an empty default paragraph', () {
      final ctx = schema.editContext();
      final doc = Document([TextBlock(id: 'a', blockType: DividerKeys.type)]);
      final result = RemoveBlock('a').apply(doc, ctx);
      expect(result, isNotNull);
      expect(result!.allBlocks.length, 1);
      expect(result.allBlocks[0].blockType, ParagraphKeys.type);
      expect(result.allBlocks[0].plainText, '');
    });
  });

  group('LinkWrapRule', () {
    test('[text](url) converts to link with URL attribute', () {
      // Closing ")" committed at offset 27 → "[Google](https://google.com)".
      final rule = LinkWrapRule();
      final docAfter = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('[Google](https://google.com)')],
        ),
      ]);

      final outcome = rule.tryTransform(
        docAfter,
        'a',
        const TextRange(start: 27, end: 28),
        schema,
      );
      expect(outcome, isNotNull);

      final applied = applyOutcome(docAfter, outcome!, schema);
      final seg = applied.allBlocks[0].segments[0];
      expect(seg.text, 'Google');
      expect(seg.styles, {InlineEntityKeys.link});
      expect(seg.attributes['url'], 'https://google.com');
      expect(
        outcome.selectionAfter,
        DocSelection.collapsed(const DocPosition('a', 6)),
      );
    });

    test('does not fire without closing paren', () {
      final docAfter = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('[Google](https://google.comx')],
        ),
      ]);

      expect(
        LinkWrapRule().tryTransform(
          docAfter,
          'a',
          const TextRange(start: 27, end: 28),
          schema,
        ),
        isNull,
      );
    });

    test('[text](url) mid-paragraph works', () {
      final docAfter = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('Visit [Google](https://g.co)')],
        ),
      ]);

      final outcome = LinkWrapRule().tryTransform(
        docAfter,
        'a',
        const TextRange(start: 27, end: 28),
        schema,
      );
      expect(outcome, isNotNull);

      final applied = applyOutcome(docAfter, outcome!, schema);
      final segs = applied.allBlocks[0].segments;
      expect(segs.any((s) => s.text == 'Visit '), isTrue);
      expect(
        segs.any(
          (s) =>
              s.text == 'Google' &&
              s.styles.contains(InlineEntityKeys.link) &&
              s.attributes['url'] == 'https://g.co',
        ),
        isTrue,
      );
    });

    test('fires when the inserted chunk ends with closing paren', () {
      // "com)" was inserted as a chunk at offset 22, completing the pattern.
      final docAfter = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('[link](https://google.com)')],
        ),
      ]);

      final outcome = LinkWrapRule().tryTransform(
        docAfter,
        'a',
        const TextRange(start: 22, end: 26),
        schema,
      );
      expect(outcome, isNotNull);

      final applied = applyOutcome(docAfter, outcome!, schema);
      final seg = applied.allBlocks[0].segments[0];
      expect(seg.text, 'link');
      expect(seg.styles, {InlineEntityKeys.link});
      expect(seg.attributes['url'], 'https://google.com');
    });
  });
}
