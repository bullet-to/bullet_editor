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

    test('cursor skips over prefix char when arrowing right', () {
      final controller = EditorController(
        document: Document([
          TextBlock(id: 'a', segments: [const StyledSegment('abc')]),
          TextBlock(
            id: 'b',
            blockType: BlockType.listItem,
            segments: [const StyledSegment('def')],
          ),
        ]),
      );

      // Use controller's actual display text (not a hardcoded literal).
      final displayText = controller.text;
      expect(displayText, 'abc\n\uFFFCdef');

      // "abc\n\uFFFCdef" — \uFFFC is at index 4.
      // Position at end of "abc" (offset 3).
      controller.value = TextEditingValue(
        text: displayText,
        selection: const TextSelection.collapsed(offset: 3),
      );

      // Arrow right → Flutter puts cursor at 4 (\uFFFC position).
      // Controller should skip to 5 (start of "def").
      controller.value = TextEditingValue(
        text: displayText,
        selection: const TextSelection.collapsed(offset: 4),
      );
      expect(controller.value.selection.baseOffset, 5,
          reason: 'Cursor should skip over prefix char to start of text');
    });

    test('cursor skips over prefix char when arrowing left', () {
      final controller = EditorController(
        document: Document([
          TextBlock(id: 'a', segments: [const StyledSegment('abc')]),
          TextBlock(
            id: 'b',
            blockType: BlockType.listItem,
            segments: [const StyledSegment('def')],
          ),
        ]),
      );

      final displayText = controller.text;

      // "abc\n\uFFFCdef" — \uFFFC is at index 4, "d" at 5.
      // Position at start of "def" (offset 5).
      controller.value = TextEditingValue(
        text: displayText,
        selection: const TextSelection.collapsed(offset: 5),
      );

      // Arrow left → Flutter puts cursor at 4 (\uFFFC position).
      // Controller should skip to 3 (end of "abc").
      controller.value = TextEditingValue(
        text: displayText,
        selection: const TextSelection.collapsed(offset: 4),
      );
      expect(controller.value.selection.baseOffset, 3,
          reason: 'Cursor should skip back over prefix char');
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
