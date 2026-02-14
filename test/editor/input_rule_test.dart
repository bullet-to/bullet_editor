import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final schema = EditorSchema.standard();
  group('BoldWrapRule', () {
    test('detects **text** and transforms to bold', () {
      final rule = BoldWrapRule();

      // Simulate: document has "hello " and user has typed "**world**"
      // so the pending transaction inserts the final "*" making it "hello **world**"
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('hello **world*')]),
      ]);

      // The pending transaction adds the closing "*"
      final pending = Transaction(
        operations: [InsertText(0, 14, '*')],
        selectionAfter: const TextSelection.collapsed(offset: 15),
      );

      final result = rule.tryTransform(pending, doc, schema);
      expect(result, isNotNull);

      // Apply the transformed transaction to the original doc.
      final newDoc = result!.apply(doc);

      // The asterisks should be removed and "world" should be bold.
      expect(newDoc.blocks[0].plainText, 'hello world');
      expect(
        newDoc.blocks[0].segments.any(
          (s) => s.text == 'world' && s.styles.contains(InlineStyle.bold),
        ),
        isTrue,
      );

      // Cursor should be right after "world" (offset 11 = "hello world".length).
      expect(result.selectionAfter!.baseOffset, 11);
    });

    test(
      'does NOT fire when **text** already exists and unrelated edit happens',
      () {
        final rule = BoldWrapRule();

        // Block already has **text** as literal characters.
        final doc = Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: [const StyledSegment('Type **text** here')],
          ),
        ]);

        // User types a space at the end — unrelated to the pattern.
        final pending = Transaction(
          operations: [InsertText(0, 18, ' ')],
          selectionAfter: const TextSelection.collapsed(offset: 19),
        );

        // Rule should NOT fire — the pattern wasn't just completed.
        expect(rule.tryTransform(pending, doc, schema), isNull);
      },
    );

    test('cursor lands after bold text when pattern is mid-sentence', () {
      final rule = BoldWrapRule();

      // "abc **trigger* bold" — user is about to type the closing *
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.paragraph,
          segments: [const StyledSegment('abc **trigger* bold')],
        ),
      ]);

      // User types closing * at position 14 (right after the existing *)
      final pending = Transaction(
        operations: [InsertText(0, 14, '*')],
        selectionAfter: const TextSelection.collapsed(offset: 15),
      );

      final result = rule.tryTransform(pending, doc, schema);
      expect(result, isNotNull);

      final newDoc = result!.apply(doc);

      // Should be "abc trigger bold" with "trigger" bold.
      expect(newDoc.blocks[0].plainText, 'abc trigger bold');
      expect(
        newDoc.blocks[0].segments.any(
          (s) => s.text == 'trigger' && s.styles.contains(InlineStyle.bold),
        ),
        isTrue,
      );

      // Cursor should be right after "trigger" = offset 11 ("abc trigger".length)
      expect(result.selectionAfter!.baseOffset, 11);
    });

    test('cursor correct when bold pattern is in second block', () {
      final rule = BoldWrapRule();

      // Two blocks: block 0 = "first", block 1 = "abc **trigger* bold"
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('first')]),
        TextBlock(
          id: 'b',
          blockType: BlockType.paragraph,
          segments: [const StyledSegment('abc **trigger* bold')],
        ),
      ]);

      // User types * in block 1 at local offset 14.
      // Global offset: 5 (first) + 1 (\n) + 14 = 20
      final pending = Transaction(
        operations: [InsertText(1, 14, '*')],
        selectionAfter: const TextSelection.collapsed(offset: 20),
      );

      final result = rule.tryTransform(pending, doc, schema);
      expect(result, isNotNull);

      final newDoc = result!.apply(doc);
      expect(newDoc.blocks[1].plainText, 'abc trigger bold');

      // Cursor should be after "trigger" in block 1.
      // Global: 5 + 1 + 11 = 17  ("first\nabc trigger".length)
      expect(result.selectionAfter!.baseOffset, 17);
    });

    test('returns null when no pattern found', () {
      final rule = BoldWrapRule();
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('hello world')]),
      ]);
      final pending = Transaction(
        operations: [InsertText(0, 11, '!')],
        selectionAfter: const TextSelection.collapsed(offset: 12),
      );

      expect(rule.tryTransform(pending, doc, schema), isNull);
    });
  });

  group('HeadingRule', () {
    test('# followed by space converts to H1', () {
      final rule = HeadingRule();
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('#')]),
      ]);

      final pending = Transaction(
        operations: [InsertText(0, 1, ' ')],
        selectionAfter: const TextSelection.collapsed(offset: 2),
      );

      final result = rule.tryTransform(pending, doc, schema);
      expect(result, isNotNull);

      final newDoc = result!.apply(doc);
      expect(newDoc.blocks[0].blockType, BlockType.h1);
      expect(newDoc.blocks[0].plainText, '');
    });

    test('# space at start of paragraph with existing text converts to H1', () {
      final rule = HeadingRule();
      // User typed # at the start of "hello", then space. Block has "# hello".
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('#hello')]),
      ]);

      final pending = Transaction(
        operations: [InsertText(0, 1, ' ')],
        selectionAfter: const TextSelection.collapsed(offset: 2),
      );

      final result = rule.tryTransform(pending, doc, schema);
      expect(result, isNotNull);

      final newDoc = result!.apply(doc);
      expect(newDoc.blocks[0].blockType, BlockType.h1);
      expect(newDoc.blocks[0].plainText, 'hello');
    });

    test('does not fire on # mid-text', () {
      final rule = HeadingRule();
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('hello #')]),
      ]);

      final pending = Transaction(
        operations: [InsertText(0, 7, ' ')],
        selectionAfter: const TextSelection.collapsed(offset: 8),
      );

      expect(rule.tryTransform(pending, doc, schema), isNull);
    });

    test('does not fire if block is already H1', () {
      final rule = HeadingRule();
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.h1,
          segments: [const StyledSegment('#')],
        ),
      ]);

      final pending = Transaction(
        operations: [InsertText(0, 1, ' ')],
        selectionAfter: const TextSelection.collapsed(offset: 2),
      );

      expect(rule.tryTransform(pending, doc, schema), isNull);
    });
  });

  group('HeadingBackspaceRule', () {
    test('backspace at start of H3 converts to paragraph', () {
      final rule = HeadingBackspaceRule();
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('above')]),
        TextBlock(
          id: 'b',
          blockType: BlockType.h3,
          segments: [const StyledSegment('title')],
        ),
      ]);

      final pending = Transaction(operations: [MergeBlocks(1)]);
      final result = rule.tryTransform(pending, doc, schema);
      expect(result, isNotNull);
      final newDoc = result!.apply(doc);
      expect(newDoc.allBlocks[1].blockType, BlockType.paragraph);
      expect(newDoc.allBlocks[1].plainText, 'title');
    });

    test('backspace at start of H1 converts to paragraph', () {
      final rule = HeadingBackspaceRule();
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('above')]),
        TextBlock(
          id: 'b',
          blockType: BlockType.h1,
          segments: [const StyledSegment('title')],
        ),
      ]);

      final pending = Transaction(operations: [MergeBlocks(1)]);
      final result = rule.tryTransform(pending, doc, schema);
      expect(result, isNotNull);
      final newDoc = result!.apply(doc);
      expect(newDoc.allBlocks[1].blockType, BlockType.paragraph);
    });

    test('does not fire on paragraph', () {
      final rule = HeadingBackspaceRule();
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('above')]),
        TextBlock(id: 'b', blockType: BlockType.paragraph, segments: [const StyledSegment('below')]),
      ]);

      final pending = Transaction(operations: [MergeBlocks(1)]);
      expect(rule.tryTransform(pending, doc, schema), isNull);
    });

    test('uses schema.isHeading — fires for custom heading block', () {
      // Build a custom schema where 'myHeading' has isHeading: true.
      final customSchema = EditorSchema<String, String>(
        defaultBlockType: 'para',
        blocks: {
          'para': const BlockDef(label: 'P'),
          'myHeading': const BlockDef(label: 'H', isHeading: true),
        },
        inlineStyles: {},
      );

      final rule = HeadingBackspaceRule();
      final doc = Document([
        TextBlock(id: 'a', blockType: 'para', segments: [const StyledSegment('above')]),
        TextBlock(id: 'b', blockType: 'myHeading', segments: [const StyledSegment('title')]),
      ]);

      final pending = Transaction(operations: [MergeBlocks(1)]);
      final result = rule.tryTransform(pending, doc, customSchema);
      expect(result, isNotNull);
      final newDoc = result!.apply(doc);
      // Should convert to the schema's defaultBlockType ('para').
      expect(newDoc.allBlocks[1].blockType, 'para');
      expect(newDoc.allBlocks[1].plainText, 'title');
    });
  });

  group('ListItemRule', () {
    test('- followed by space converts to list item', () {
      final rule = ListItemRule();
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('-')]),
      ]);

      final pending = Transaction(
        operations: [InsertText(0, 1, ' ')],
        selectionAfter: const TextSelection.collapsed(offset: 2),
      );

      final result = rule.tryTransform(pending, doc, schema);
      expect(result, isNotNull);

      final newDoc = result!.apply(doc);
      expect(newDoc.blocks[0].blockType, BlockType.listItem);
      expect(newDoc.blocks[0].plainText, '');
    });
  });

  group('EmptyListItemRule', () {
    test('Enter on empty list item converts to paragraph', () {
      final rule = EmptyListItemRule();
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.listItem, segments: const []),
      ]);

      final pending = Transaction(
        operations: [SplitBlock(0, 0, defaultBlockType: BlockType.paragraph, isListLikeFn: schema.isListLike)],
        selectionAfter: const TextSelection.collapsed(offset: 1),
      );

      final result = rule.tryTransform(pending, doc, schema);
      expect(result, isNotNull);

      final newDoc = result!.apply(doc);
      expect(newDoc.blocks[0].blockType, BlockType.paragraph);
    });

    test('does not fire on non-empty list item', () {
      final rule = EmptyListItemRule();
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.listItem,
          segments: [const StyledSegment('content')],
        ),
      ]);

      final pending = Transaction(
        operations: [SplitBlock(0, 7, defaultBlockType: BlockType.paragraph, isListLikeFn: schema.isListLike)],
        selectionAfter: const TextSelection.collapsed(offset: 8),
      );

      expect(rule.tryTransform(pending, doc, schema), isNull);
    });
  });

  group('ListItemBackspaceRule', () {
    test('backspace at start of list item converts to paragraph', () {
      final rule = ListItemBackspaceRule();
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('above')]),
        TextBlock(
          id: 'b',
          blockType: BlockType.listItem,
          segments: [const StyledSegment('item')],
        ),
      ]);

      final pending = Transaction(
        operations: [MergeBlocks(1)],
        selectionAfter: const TextSelection.collapsed(offset: 5),
      );

      final result = rule.tryTransform(pending, doc, schema);
      expect(result, isNotNull);

      final newDoc = result!.apply(doc);
      expect(newDoc.allBlocks.length, 2);
      expect(newDoc.allBlocks[1].blockType, BlockType.paragraph);
      expect(newDoc.allBlocks[1].plainText, 'item');
    });

    test('does not fire on non-list-item merge', () {
      final rule = ListItemBackspaceRule();
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('above')]),
        TextBlock(id: 'b', blockType: BlockType.paragraph, segments: [const StyledSegment('below')]),
      ]);

      final pending = Transaction(
        operations: [MergeBlocks(1)],
        selectionAfter: const TextSelection.collapsed(offset: 5),
      );

      expect(rule.tryTransform(pending, doc, schema), isNull);
    });
  });

  group('ItalicWrapRule', () {
    test('*text* converts to italic', () {
      final rule = ItalicWrapRule();
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('hello *world')]),
      ]);
      final pending = Transaction(
        operations: [InsertText(0, 12, '*')],
        selectionAfter: const TextSelection.collapsed(offset: 13),
      );
      final result = rule.tryTransform(pending, doc, schema);
      expect(result, isNotNull);
      final resultDoc = result!.apply(doc);
      expect(resultDoc.allBlocks[0].plainText, 'hello world');
      expect(
        resultDoc.allBlocks[0].segments.any(
          (s) => s.text == 'world' && s.styles.contains(InlineStyle.italic),
        ),
        isTrue,
      );
    });
  });

  group('StrikethroughWrapRule', () {
    test('~~text~~ converts to strikethrough', () {
      final rule = StrikethroughWrapRule();
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('hello ~~world~')]),
      ]);
      final pending = Transaction(
        operations: [InsertText(0, 14, '~')],
        selectionAfter: const TextSelection.collapsed(offset: 15),
      );
      final result = rule.tryTransform(pending, doc, schema);
      expect(result, isNotNull);
      final resultDoc = result!.apply(doc);
      expect(resultDoc.allBlocks[0].plainText, 'hello world');
      expect(
        resultDoc.allBlocks[0].segments.any(
          (s) =>
              s.text == 'world' && s.styles.contains(InlineStyle.strikethrough),
        ),
        isTrue,
      );
    });
  });

  group('NumberedListRule', () {
    test('1. followed by space converts to numbered list', () {
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('1.')]),
      ]);
      final pending = Transaction(
        operations: [InsertText(0, 2, ' ')],
        selectionAfter: const TextSelection.collapsed(offset: 3),
      );
      final rule = NumberedListRule();
      final result = rule.tryTransform(pending, doc, schema);
      expect(result, isNotNull);
      final resultDoc = result!.apply(doc);
      expect(resultDoc.allBlocks[0].blockType, BlockType.numberedList);
      expect(resultDoc.allBlocks[0].plainText, '');
    });
  });

  group('TaskItemRule', () {
    test('- [ ] followed by space creates unchecked task', () {
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('- [ ]')]),
      ]);
      final pending = Transaction(
        operations: [InsertText(0, 5, ' ')],
        selectionAfter: const TextSelection.collapsed(offset: 6),
      );
      final rule = TaskItemRule();
      final result = rule.tryTransform(pending, doc, schema);
      expect(result, isNotNull);
      final resultDoc = result!.apply(doc);
      expect(resultDoc.allBlocks[0].blockType, BlockType.taskItem);
      expect(resultDoc.allBlocks[0].metadata['checked'], false);
      expect(resultDoc.allBlocks[0].plainText, '');
    });

    test('- [x] followed by space creates checked task', () {
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('- [x]')]),
      ]);
      final pending = Transaction(
        operations: [InsertText(0, 5, ' ')],
        selectionAfter: const TextSelection.collapsed(offset: 6),
      );
      final rule = TaskItemRule();
      final result = rule.tryTransform(pending, doc, schema);
      expect(result, isNotNull);
      final resultDoc = result!.apply(doc);
      expect(resultDoc.allBlocks[0].blockType, BlockType.taskItem);
      expect(resultDoc.allBlocks[0].metadata['checked'], true);
    });

    test('[ ] on a list item converts to task (post-ListItemRule path)', () {
      // After ListItemRule eats "- ", the user is on a listItem typing "[ ] ".
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.listItem,
          segments: [const StyledSegment('[ ]')],
        ),
      ]);
      final pending = Transaction(
        operations: [InsertText(0, 3, ' ')],
        selectionAfter: const TextSelection.collapsed(offset: 4),
      );
      final rule = TaskItemRule();
      final result = rule.tryTransform(pending, doc, schema);
      expect(result, isNotNull);
      final resultDoc = result!.apply(doc);
      expect(resultDoc.allBlocks[0].blockType, BlockType.taskItem);
      expect(resultDoc.allBlocks[0].metadata['checked'], false);
      expect(resultDoc.allBlocks[0].plainText, '');
    });
  });

  group('EmptyListItemRule with list-like types', () {
    test('Enter on empty numbered list converts to paragraph', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.numberedList,
          segments: [const StyledSegment('')],
        ),
      ]);
      final pending = Transaction(
        operations: [SplitBlock(0, 0, defaultBlockType: BlockType.paragraph, isListLikeFn: schema.isListLike)],
        selectionAfter: const TextSelection.collapsed(offset: 0),
      );
      final rule = EmptyListItemRule();
      final result = rule.tryTransform(pending, doc, schema);
      expect(result, isNotNull);
      final resultDoc = result!.apply(doc);
      expect(resultDoc.allBlocks[0].blockType, BlockType.paragraph);
    });

    test('Enter on empty task converts to paragraph', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.taskItem,
          segments: [const StyledSegment('')],
          metadata: {'checked': false},
        ),
      ]);
      final pending = Transaction(
        operations: [SplitBlock(0, 0, defaultBlockType: BlockType.paragraph, isListLikeFn: schema.isListLike)],
        selectionAfter: const TextSelection.collapsed(offset: 0),
      );
      final rule = EmptyListItemRule();
      final result = rule.tryTransform(pending, doc, schema);
      expect(result, isNotNull);
    });
  });

  group('DividerRule', () {
    test(
      'typing --- converts paragraph to divider with trailing paragraph',
      () {
        // Doc has "--" typed; user types the third "-".
        final doc = Document([
          TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('--')]),
        ]);
        final pending = Transaction(
          operations: [InsertText(0, 2, '-')],
          selectionAfter: const TextSelection.collapsed(offset: 3),
        );
        final rule = DividerRule();
        final result = rule.tryTransform(pending, doc, schema);
        expect(result, isNotNull);
        final resultDoc = result!.apply(doc);
        expect(resultDoc.allBlocks.length, 2);
        expect(resultDoc.allBlocks[0].blockType, BlockType.divider);
        expect(resultDoc.allBlocks[0].plainText, '');
        expect(resultDoc.allBlocks[1].blockType, BlockType.paragraph);
        expect(resultDoc.allBlocks[1].plainText, '');
      },
    );

    test('does not fire on non-paragraph blocks', () {
      // Doc has "--" in an H1; user types "-".
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.h1,
          segments: [const StyledSegment('--')],
        ),
      ]);
      final pending = Transaction(
        operations: [InsertText(0, 2, '-')],
        selectionAfter: const TextSelection.collapsed(offset: 3),
      );
      final rule = DividerRule();
      expect(rule.tryTransform(pending, doc, schema), isNull);
    });

    test('does not fire when text is not exactly ---', () {
      // Doc has "a-" typed; user types "-".
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('a-')]),
      ]);
      final pending = Transaction(
        operations: [InsertText(0, 2, '-')],
        selectionAfter: const TextSelection.collapsed(offset: 3),
      );
      final rule = DividerRule();
      expect(rule.tryTransform(pending, doc, schema), isNull);
    });
  });

  group('DividerBackspaceRule', () {
    test('backspace at start of block after divider removes divider', () {
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.divider),
        TextBlock(id: 'b', blockType: BlockType.paragraph, segments: [const StyledSegment('Hello')]),
      ]);
      final pending = Transaction(
        operations: [MergeBlocks(1)],
        selectionAfter: const TextSelection.collapsed(offset: 0),
      );
      final rule = DividerBackspaceRule();
      final result = rule.tryTransform(pending, doc, schema);
      expect(result, isNotNull);
      final resultDoc = result!.apply(doc);
      // Divider removed, only the paragraph remains.
      expect(resultDoc.allBlocks.length, 1);
      expect(resultDoc.allBlocks[0].blockType, BlockType.paragraph);
      expect(resultDoc.allBlocks[0].plainText, 'Hello');
    });

    test('does not fire when preceding block is not a divider', () {
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('first')]),
        TextBlock(id: 'b', blockType: BlockType.paragraph, segments: [const StyledSegment('second')]),
      ]);
      final pending = Transaction(
        operations: [MergeBlocks(1)],
        selectionAfter: const TextSelection.collapsed(offset: 5),
      );
      final rule = DividerBackspaceRule();
      expect(rule.tryTransform(pending, doc, schema), isNull);
    });
  });

  group('RemoveBlock', () {
    test('removes a block from document', () {
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('first')]),
        TextBlock(id: 'b', blockType: BlockType.divider),
        TextBlock(id: 'c', blockType: BlockType.paragraph, segments: [const StyledSegment('third')]),
      ]);
      final result = RemoveBlock(1).apply(doc);
      expect(result.allBlocks.length, 2);
      expect(result.allBlocks[0].plainText, 'first');
      expect(result.allBlocks[1].plainText, 'third');
    });

    test('does not remove the last block', () {
      final doc = Document([TextBlock(id: 'a', blockType: BlockType.divider)]);
      final result = RemoveBlock(0).apply(doc);
      expect(result.allBlocks.length, 1);
    });
  });

  group('LinkWrapRule', () {
    test('[text](url) converts to link with URL attribute', () {
      // Doc has "[Google](https://google.com" typed; user types ")".
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.paragraph,
          segments: [const StyledSegment('[Google](https://google.com')],
        ),
      ]);
      final pending = Transaction(
        operations: [InsertText(0, 27, ')')],
        selectionAfter: const TextSelection.collapsed(offset: 28),
      );
      final rule = LinkWrapRule();
      final result = rule.tryTransform(pending, doc, schema);
      expect(result, isNotNull);
      final applied = result!.apply(doc);
      final seg = applied.allBlocks[0].segments[0];
      expect(seg.text, 'Google');
      expect(seg.styles, {InlineStyle.link});
      expect(seg.attributes['url'], 'https://google.com');
    });

    test('does not fire without closing paren', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.paragraph,
          segments: [const StyledSegment('[Google](https://google.com')],
        ),
      ]);
      final pending = Transaction(
        operations: [InsertText(0, 27, 'x')],
        selectionAfter: const TextSelection.collapsed(offset: 28),
      );
      expect(LinkWrapRule().tryTransform(pending, doc, schema), isNull);
    });

    test('[text](url) mid-paragraph works', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.paragraph,
          segments: [const StyledSegment('Visit [Google](https://g.co')],
        ),
      ]);
      final pending = Transaction(
        operations: [InsertText(0, 27, ')')],
        selectionAfter: const TextSelection.collapsed(offset: 28),
      );
      final result = LinkWrapRule().tryTransform(pending, doc, schema);
      expect(result, isNotNull);
      final applied = result!.apply(doc);
      final segs = applied.allBlocks[0].segments;
      expect(segs.any((s) => s.text == 'Visit '), isTrue);
      expect(
        segs.any((s) =>
            s.text == 'Google' &&
            s.styles.contains(InlineStyle.link) &&
            s.attributes['url'] == 'https://g.co'),
        isTrue,
      );
    });
  });
}
