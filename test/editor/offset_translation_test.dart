import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bullet_editor/bullet_editor.dart';

void main() {
  group('Offset translation', () {
    test('display text includes prefix chars for list items', () {
      final controller = EditorController(
        document: Document([
          TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
          TextBlock(
            id: 'b',
            blockType: BlockType.listItem,
            segments: [const StyledSegment('item')],
          ),
        ]),
      );

      // Display: "hello\n\uFFFCitem"
      expect(controller.text, 'hello\n\uFFFCitem');
      // Model: "hello\nitem"
      expect(controller.document.plainText, 'hello\nitem');
    });

    test('display text includes prefix for nested list items', () {
      final controller = EditorController(
        document: Document([
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
        ]),
      );

      // Display: "\uFFFCparent\n\uFFFCchild"
      expect(controller.text, '\uFFFCparent\n\uFFFCchild');
    });

    test('typing in list item works correctly with prefix', () {
      final controller = EditorController(
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.listItem,
            segments: [const StyledSegment('item')],
          ),
        ]),
      );

      // Display: "\uFFFCitem" — type 'x' at end (display offset 5).
      controller.value = const TextEditingValue(
        text: '\uFFFCitemx',
        selection: TextSelection.collapsed(offset: 6),
      );

      expect(controller.document.allBlocks[0].plainText, 'itemx');
    });

    test('paragraphs have no prefix', () {
      final controller = EditorController(
        document: Document([
          TextBlock(id: 'a', segments: [const StyledSegment('para')]),
        ]),
      );

      // No prefix char — display == model.
      expect(controller.text, 'para');
      expect(controller.document.plainText, 'para');
    });

    test('mixed blocks: paragraph then list item', () {
      final controller = EditorController(
        document: Document([
          TextBlock(id: 'a', segments: [const StyledSegment('abc')]),
          TextBlock(
            id: 'b',
            blockType: BlockType.listItem,
            segments: [const StyledSegment('def')],
          ),
          TextBlock(id: 'c', segments: [const StyledSegment('ghi')]),
        ]),
      );

      // Display: "abc\n\uFFFCdef\nghi"
      expect(controller.text, 'abc\n\uFFFCdef\nghi');

      // Type in the paragraph (no prefix) — offset 1 in display = offset 1 in model.
      controller.value = const TextEditingValue(
        text: 'aXbc\n\uFFFCdef\nghi',
        selection: TextSelection.collapsed(offset: 2),
      );
      expect(controller.document.allBlocks[0].plainText, 'aXbc');

      // Type in the list item — display offset 6 (after \uFFFC) = model offset 5.
      // Reset first.
    });
  });
}
