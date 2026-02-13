import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BoldWrapRule', () {
    test('detects **text** and transforms to bold', () {
      final rule = BoldWrapRule();

      // Simulate: document has "hello " and user has typed "**world**"
      // so the pending transaction inserts the final "*" making it "hello **world**"
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hello **world*')]),
      ]);

      // The pending transaction adds the closing "*"
      final pending = Transaction(
        operations: [InsertText(0, 14, '*')],
        selectionAfter: const TextSelection.collapsed(offset: 15),
      );

      final result = rule.tryTransform(pending, doc);
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
            segments: [const StyledSegment('Type **text** here')],
          ),
        ]);

        // User types a space at the end — unrelated to the pattern.
        final pending = Transaction(
          operations: [InsertText(0, 18, ' ')],
          selectionAfter: const TextSelection.collapsed(offset: 19),
        );

        // Rule should NOT fire — the pattern wasn't just completed.
        expect(rule.tryTransform(pending, doc), isNull);
      },
    );

    test('cursor lands after bold text when pattern is mid-sentence', () {
      final rule = BoldWrapRule();

      // "abc **trigger* bold" — user is about to type the closing *
      final doc = Document([
        TextBlock(
          id: 'a',
          segments: [const StyledSegment('abc **trigger* bold')],
        ),
      ]);

      // User types closing * at position 14 (right after the existing *)
      final pending = Transaction(
        operations: [InsertText(0, 14, '*')],
        selectionAfter: const TextSelection.collapsed(offset: 15),
      );

      final result = rule.tryTransform(pending, doc);
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
        TextBlock(id: 'a', segments: [const StyledSegment('first')]),
        TextBlock(
          id: 'b',
          segments: [const StyledSegment('abc **trigger* bold')],
        ),
      ]);

      // User types * in block 1 at local offset 14.
      // Global offset: 5 (first) + 1 (\n) + 14 = 20
      final pending = Transaction(
        operations: [InsertText(1, 14, '*')],
        selectionAfter: const TextSelection.collapsed(offset: 20),
      );

      final result = rule.tryTransform(pending, doc);
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
        TextBlock(id: 'a', segments: [const StyledSegment('hello world')]),
      ]);
      final pending = Transaction(
        operations: [InsertText(0, 11, '!')],
        selectionAfter: const TextSelection.collapsed(offset: 12),
      );

      expect(rule.tryTransform(pending, doc), isNull);
    });
  });

  group('HeadingRule', () {
    test('# followed by space converts to H1', () {
      final rule = HeadingRule();
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('#')]),
      ]);

      final pending = Transaction(
        operations: [InsertText(0, 1, ' ')],
        selectionAfter: const TextSelection.collapsed(offset: 2),
      );

      final result = rule.tryTransform(pending, doc);
      expect(result, isNotNull);

      final newDoc = result!.apply(doc);
      expect(newDoc.blocks[0].blockType, BlockType.h1);
      expect(newDoc.blocks[0].plainText, '');
    });

    test('does not fire on # mid-text', () {
      final rule = HeadingRule();
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hello #')]),
      ]);

      final pending = Transaction(
        operations: [InsertText(0, 7, ' ')],
        selectionAfter: const TextSelection.collapsed(offset: 8),
      );

      expect(rule.tryTransform(pending, doc), isNull);
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

      expect(rule.tryTransform(pending, doc), isNull);
    });
  });

  group('ListItemRule', () {
    test('- followed by space converts to list item', () {
      final rule = ListItemRule();
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('-')]),
      ]);

      final pending = Transaction(
        operations: [InsertText(0, 1, ' ')],
        selectionAfter: const TextSelection.collapsed(offset: 2),
      );

      final result = rule.tryTransform(pending, doc);
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
        operations: [SplitBlock(0, 0)],
        selectionAfter: const TextSelection.collapsed(offset: 1),
      );

      final result = rule.tryTransform(pending, doc);
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
        operations: [SplitBlock(0, 7)],
        selectionAfter: const TextSelection.collapsed(offset: 8),
      );

      expect(rule.tryTransform(pending, doc), isNull);
    });
  });
}
