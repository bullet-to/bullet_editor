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

      // Display: "hello\n\uFFFC\uFFFCitem"
      // (paragraph spacingAfter → spacer \uFFFC, then prefix \uFFFC)
      expect(controller.text, 'hello\n\uFFFC\uFFFCitem');
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

      // List items have spacingAfter 0 → no spacer between them.
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

    test('cursor skips over spacer and prefix char when arrowing right', () {
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

      // Display: "abc\n\uFFFC\uFFFCdef"
      // (spacer + prefix, both \uFFFC)
      final displayText = controller.text;
      expect(displayText, 'abc\n\uFFFC\uFFFCdef');

      // Position at end of "abc" (offset 3).
      controller.value = TextEditingValue(
        text: displayText,
        selection: const TextSelection.collapsed(offset: 3),
      );

      // Arrow right → Flutter puts cursor at 4 (first \uFFFC = spacer).
      // Controller should skip past both \uFFFC chars to 6 (start of "def").
      controller.value = TextEditingValue(
        text: displayText,
        selection: const TextSelection.collapsed(offset: 4),
      );
      expect(controller.value.selection.baseOffset, 6,
          reason: 'Cursor should skip over spacer and prefix to start of text');
    });

    test('cursor skips over prefix and spacer char when arrowing left', () {
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

      // "abc\n\uFFFC\uFFFCdef" — "d" is at index 6.
      // Position at start of "def" (offset 6).
      controller.value = TextEditingValue(
        text: displayText,
        selection: const TextSelection.collapsed(offset: 6),
      );

      // Arrow left → Flutter puts cursor at 5 (second \uFFFC = prefix).
      // Controller should skip back to 3 (end of "abc").
      controller.value = TextEditingValue(
        text: displayText,
        selection: const TextSelection.collapsed(offset: 5),
      );
      expect(controller.value.selection.baseOffset, 3,
          reason: 'Cursor should skip back over prefix and spacer');
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

      // paragraph(spacingAfter) → spacer + list prefix, list(no spacingAfter) → no spacer
      expect(controller.text, 'abc\n\uFFFC\uFFFCdef\nghi');

      // Type in the paragraph (no prefix) — offset 1 in display = offset 1 in model.
      controller.value = const TextEditingValue(
        text: 'aXbc\n\uFFFC\uFFFCdef\nghi',
        selection: TextSelection.collapsed(offset: 2),
      );
      expect(controller.document.allBlocks[0].plainText, 'aXbc');

      // Type in the list item — display offset 7 (after both \uFFFC) = model offset 5.
      // Reset first.
    });
  });

  group('Empty block placeholder', () {
    test('display text includes \\u200B for empty paragraphs', () {
      final controller = EditorController(
        document: Document([
          TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
          TextBlock(id: 'b'), // empty paragraph
        ]),
      );

      // paragraph spacingAfter → spacer \uFFFC before empty paragraph.
      expect(controller.text, 'hello\n\uFFFC\u200B');
      // Model: "hello\n"
      expect(controller.document.plainText, 'hello\n');
    });

    test('empty list items do NOT get \\u200B (they have a prefix)', () {
      final controller = EditorController(
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.listItem,
            segments: const [],
          ),
        ]),
      );

      // Display: just the prefix char, no \u200B.
      expect(controller.text, '\uFFFC');
    });

    test('empty divider does NOT get \\u200B (it has a prefix)', () {
      final controller = EditorController(
        document: Document([
          TextBlock(id: 'a', blockType: BlockType.divider),
        ]),
      );

      expect(controller.text, '\uFFFC');
      expect(controller.text.contains('\u200B'), isFalse);
    });

    test('displayToModel maps \\u200B position to block start', () {
      final schema = EditorSchema.standard();
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hi')]),
        TextBlock(id: 'b'), // empty paragraph
      ]);

      // Display: "hi\n\uFFFC\u200B"
      // Positions: h(0) i(1) \n(2) \uFFFC(3=spacer) \u200B(4)
      // Block 1 start in model = 2 (hi) + 1 (\n) = 3
      expect(displayToModel(doc, 4, schema), 3);
      // After \u200B (position 5, end of text)
      expect(displayToModel(doc, 5, schema), 3);
    });

    test('modelToDisplay maps block start to after spacer', () {
      final schema = EditorSchema.standard();
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hi')]),
        TextBlock(id: 'b'), // empty paragraph
      ]);

      // Model offset 3 = start of empty block → display position 4 (\u200B)
      expect(modelToDisplay(doc, 3, schema), 4);
    });

    test('divider then empty paragraph: display text is correct', () {
      final schema = EditorSchema.standard();
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.divider),
        TextBlock(id: 'b'), // empty paragraph
      ]);

      final display = buildDisplayText(doc, schema);
      // \uFFFC (divider prefix) \n \uFFFC (spacer) \u200B (empty para)
      expect(display, '\uFFFC\n\uFFFC\u200B');
    });

    test('divider then empty paragraph: offset mapping round-trips', () {
      final schema = EditorSchema.standard();
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.divider),
        TextBlock(id: 'b'), // empty paragraph
      ]);

      // Model offset 1 = start of empty paragraph (divider=0 chars + \n=1)
      final displayOffset = modelToDisplay(doc, 1, schema);
      expect(displayToModel(doc, displayOffset, schema), 1);
    });

    test('typing on empty paragraph after divider inserts correctly', () {
      final controller = EditorController(
        document: Document([
          TextBlock(id: 'a', blockType: BlockType.divider),
          TextBlock(id: 'b'), // empty paragraph
        ]),
      );

      final displayText = controller.text;
      expect(displayText, '\uFFFC\n\uFFFC\u200B');

      // Simulate typing 'H' at position 3 (the \u200B position).
      controller.value = TextEditingValue(
        text: '\uFFFC\n\uFFFCH\u200B',
        selection: const TextSelection.collapsed(offset: 4),
      );

      expect(controller.document.allBlocks[1].plainText, 'H');
    });

    test('multiple empty paragraphs each get \\u200B', () {
      final controller = EditorController(
        document: Document([
          TextBlock(id: 'a'),
          TextBlock(id: 'b'),
          TextBlock(id: 'c'),
        ]),
      );

      // Each paragraph has spacingAfter → spacer before next block.
      expect(controller.text, '\u200B\n\uFFFC\u200B\n\uFFFC\u200B');
    });
  });
}
