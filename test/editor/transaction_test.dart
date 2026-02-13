import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InsertText', () {
    test('inserts text at offset', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
      ]);
      final result = InsertText(0, 5, ' world').apply(doc);
      expect(result.blocks[0].plainText, 'hello world');
    });

    test('inserts at beginning', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('world')]),
      ]);
      final result = InsertText(0, 0, 'hello ').apply(doc);
      expect(result.blocks[0].plainText, 'hello world');
    });

    test('inherits style when appending to a styled segment', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          segments: [
            const StyledSegment('hello', {InlineStyle.bold}),
          ],
        ),
      ]);
      final result = InsertText(0, 5, ' world').apply(doc);
      expect(result.blocks[0].plainText, 'hello world');
      // The appended text should inherit bold from the segment it continues.
      expect(result.blocks[0].segments.length, 1);
      expect(result.blocks[0].segments[0].styles, {InlineStyle.bold});
    });

    test('inherits style when inserting inside a styled segment', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          segments: [
            const StyledSegment('onetwothree', {InlineStyle.bold}),
          ],
        ),
      ]);
      final result = InsertText(0, 3, 'a').apply(doc);
      expect(result.blocks[0].plainText, 'oneatwothree');
      // All text should remain bold.
      expect(result.blocks[0].segments.length, 1);
      expect(result.blocks[0].segments[0].styles, {InlineStyle.bold});
    });

    test('style persists across multiple sequential inserts', () {
      // Simulate: bold "hello", then type space, then type "world"
      var doc = Document([
        TextBlock(
          id: 'a',
          segments: [
            const StyledSegment('hello', {InlineStyle.bold}),
          ],
        ),
      ]);

      // Type space
      doc = InsertText(0, 5, ' ').apply(doc);
      expect(doc.blocks[0].plainText, 'hello ');
      expect(doc.blocks[0].segments.length, 1);
      expect(doc.blocks[0].segments[0].styles, {InlineStyle.bold});

      // Type 'w'
      doc = InsertText(0, 6, 'w').apply(doc);
      expect(doc.blocks[0].plainText, 'hello w');
      expect(doc.blocks[0].segments.length, 1);
      expect(doc.blocks[0].segments[0].styles, {InlineStyle.bold});

      // Type 'orld'
      doc = InsertText(0, 7, 'o').apply(doc);
      doc = InsertText(0, 8, 'r').apply(doc);
      doc = InsertText(0, 9, 'l').apply(doc);
      doc = InsertText(0, 10, 'd').apply(doc);
      expect(doc.blocks[0].plainText, 'hello world');
      expect(doc.blocks[0].segments.length, 1);
      expect(doc.blocks[0].segments[0].styles, {InlineStyle.bold});
    });
  });

  group('DeleteText', () {
    test('deletes text at offset', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hello world')]),
      ]);
      final result = DeleteText(0, 5, 6).apply(doc);
      expect(result.blocks[0].plainText, 'hello');
    });
  });

  group('ToggleStyle', () {
    test('applies bold to unstyled range', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hello world')]),
      ]);
      final result = ToggleStyle(0, 0, 5, InlineStyle.bold).apply(doc);
      expect(result.blocks[0].segments.length, 2);
      expect(result.blocks[0].segments[0].text, 'hello');
      expect(result.blocks[0].segments[0].styles, {InlineStyle.bold});
      expect(result.blocks[0].segments[1].text, ' world');
      expect(result.blocks[0].segments[1].styles, <InlineStyle>{});
    });

    test('removes bold from fully-styled range', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          segments: [
            const StyledSegment('hello world', {InlineStyle.bold}),
          ],
        ),
      ]);
      final result = ToggleStyle(0, 0, 5, InlineStyle.bold).apply(doc);
      expect(result.blocks[0].segments[0].text, 'hello');
      expect(result.blocks[0].segments[0].styles, <InlineStyle>{});
    });
  });

  group('SplitBlock', () {
    test('splits block at offset', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hello world')]),
      ]);
      final result = SplitBlock(0, 5).apply(doc);
      expect(result.blocks.length, 2);
      expect(result.blocks[0].plainText, 'hello');
      expect(result.blocks[1].plainText, ' world');
    });

    test('split at start creates empty first block', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
      ]);
      final result = SplitBlock(0, 0).apply(doc);
      expect(result.blocks.length, 2);
      expect(result.blocks[0].plainText, '');
      expect(result.blocks[1].plainText, 'hello');
    });
  });

  group('MergeBlocks', () {
    test('merges second block into first', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
        TextBlock(id: 'b', segments: [const StyledSegment(' world')]),
      ]);
      final result = MergeBlocks(1).apply(doc);
      expect(result.blocks.length, 1);
      expect(result.blocks[0].plainText, 'hello world');
    });

    test('merging first block is no-op', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
      ]);
      final result = MergeBlocks(0).apply(doc);
      expect(result.blocks.length, 1);
    });
  });

  group('ChangeBlockType', () {
    test('changes block type', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
      ]);
      final result = ChangeBlockType(0, BlockType.h1).apply(doc);
      expect(result.blocks[0].blockType, BlockType.h1);
      expect(result.blocks[0].plainText, 'hello');
    });
  });

  group('SplitBlock with block types', () {
    test('Enter on heading creates paragraph', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.h1,
          segments: [const StyledSegment('heading')],
        ),
      ]);
      final result = SplitBlock(0, 7).apply(doc);
      expect(result.blocks[0].blockType, BlockType.h1);
      expect(result.blocks[1].blockType, BlockType.paragraph);
    });

    test('Enter on list item creates another list item', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.listItem,
          segments: [const StyledSegment('item')],
        ),
      ]);
      final result = SplitBlock(0, 4).apply(doc);
      expect(result.blocks[0].blockType, BlockType.listItem);
      expect(result.blocks[1].blockType, BlockType.listItem);
    });
  });

  group('Transaction', () {
    test('applies multiple operations in sequence', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
      ]);
      final tx = Transaction(
        operations: [
          InsertText(0, 5, ' world'),
          ToggleStyle(0, 0, 5, InlineStyle.bold),
        ],
      );
      final result = tx.apply(doc);
      expect(result.blocks[0].plainText, 'hello world');
      expect(result.blocks[0].segments[0].styles, {InlineStyle.bold});
    });
  });
}
