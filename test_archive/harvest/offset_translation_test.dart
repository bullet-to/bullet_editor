import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bullet_editor/bullet_editor.dart';

void main() {
  group('Offset translation', () {
    test('display text includes prefix chars for list items', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('hello')]),
          TextBlock(
            id: 'b',
            blockType: BlockType.listItem,
            segments: [const StyledSegment('item')],
          ),
        ]),
      );

      // Display: "hello\n\uFFFCitem"
      // (no spacer — listItem has spacingBefore: 0, then prefix \uFFFC)
      expect(controller.text, 'hello\n\uFFFCitem');
      // Model: "hello\nitem"
      expect(controller.document.plainText, 'hello\nitem');
    });

    test('display text includes prefix for nested list items', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
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

      // List items have spacingBefore 0 → no spacer between them.
      // Display: "\uFFFCparent\n\uFFFCchild"
      expect(controller.text, '\uFFFCparent\n\uFFFCchild');
    });

    test('typing in list item works correctly with prefix', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
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
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('para')]),
        ]),
      );

      // No prefix char — display == model.
      expect(controller.text, 'para');
      expect(controller.document.plainText, 'para');
    });

    test('cursor skips over spacer and prefix char when arrowing right', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('abc')]),
          TextBlock(
            id: 'b',
            blockType: BlockType.listItem,
            segments: [const StyledSegment('def')],
          ),
        ]),
      );

      // Display: "abc\n\uFFFCdef"
      // (no spacer — listItem has spacingBefore: 0, prefix \uFFFC)
      final displayText = controller.text;
      expect(displayText, 'abc\n\uFFFCdef');

      // Position at end of "abc" (offset 3).
      controller.value = TextEditingValue(
        text: displayText,
        selection: const TextSelection.collapsed(offset: 3),
      );

      // Arrow right → Flutter puts cursor at 4 (\uFFFC prefix).
      // Controller should skip past prefix \uFFFC to 5.
      controller.value = TextEditingValue(
        text: displayText,
        selection: const TextSelection.collapsed(offset: 4),
      );
      expect(controller.value.selection.baseOffset, 5,
          reason: 'Cursor should skip over prefix to start of text');
    });

    test('cursor skips over prefix and spacer char when arrowing left', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('abc')]),
          TextBlock(
            id: 'b',
            blockType: BlockType.listItem,
            segments: [const StyledSegment('def')],
          ),
        ]),
      );

      final displayText = controller.text;

      // "abc\n\uFFFCdef" — "d" is at index 5.
      // Position at start of "def" (offset 5).
      controller.value = TextEditingValue(
        text: displayText,
        selection: const TextSelection.collapsed(offset: 5),
      );

      // Arrow left → Flutter puts cursor at 4 (\uFFFC prefix).
      // Controller should skip back to 3 (end of "abc").
      controller.value = TextEditingValue(
        text: displayText,
        selection: const TextSelection.collapsed(offset: 4),
      );
      expect(controller.value.selection.baseOffset, 3,
          reason: 'Cursor should skip back over prefix');
    });

    test('mixed blocks: paragraph then list item', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('abc')]),
          TextBlock(
            id: 'b',
            blockType: BlockType.listItem,
            segments: [const StyledSegment('def')],
          ),
          TextBlock(id: 'c', blockType: BlockType.paragraph, segments: [const StyledSegment('ghi')]),
        ]),
      );

      // listItem has spacingBefore: 0, but paragraph at index 2 has spacingBefore: 0.3 → spacer before 'ghi'.
      expect(controller.text, 'abc\n\uFFFCdef\n\u200C\nghi');

      // Type in the paragraph (no prefix) — offset 1 in display = offset 1 in model.
      controller.value = const TextEditingValue(
        text: 'aXbc\n\uFFFCdef\n\u200C\nghi',
        selection: TextSelection.collapsed(offset: 2),
      );
      expect(controller.document.allBlocks[0].plainText, 'aXbc');

      // Type in the list item — display offset 6 (after prefix) = model offset 5.
      // Reset first.
    });
  });

  group('Empty block placeholder', () {
    test('display text includes \\u200B for empty paragraphs', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('hello')]),
          TextBlock(id: 'b', blockType: BlockType.paragraph), // empty paragraph
        ]),
      );

      // Spacer \u200C\n before paragraph at index 1 (spacingBefore: 0.3).
      expect(controller.text, 'hello\n\u200C\n\u200B');
      // Model: "hello\n"
      expect(controller.document.plainText, 'hello\n');
    });

    test('empty list items do NOT get \\u200B (they have a prefix)', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
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
        schema: EditorSchema.standard(),
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
        TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('hi')]),
        TextBlock(id: 'b', blockType: BlockType.paragraph), // empty paragraph
      ]);

      // Display: "hi\n\u200B"
      // Positions: h(0) i(1) \n(2) \u200B(3)
      // Block 1 start in model = 2 (hi) + 1 (\n) = 3
      expect(displayToModel(doc, 3, schema), 3);
      // After \u200B (position 4, end of text)
      expect(displayToModel(doc, 4, schema), 3);
    });

    test('modelToDisplay maps block start to after spacer', () {
      final schema = EditorSchema.standard();
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('hi')]),
        TextBlock(id: 'b', blockType: BlockType.paragraph), // empty paragraph
      ]);

      // Display: "hi\n\u200C\n\u200B" — spacer before paragraph at index 1.
      // Model offset 3 = start of empty block → display position 5 (after spacer \u200C\n, at \u200B)
      expect(modelToDisplay(doc, 3, schema), 5);
    });

    test('divider then empty paragraph: display text is correct', () {
      final schema = EditorSchema.standard();
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.divider),
        TextBlock(id: 'b', blockType: BlockType.paragraph), // empty paragraph
      ]);

      final display = buildDisplayText(doc, schema);
      // \uFFFC (divider prefix) \n \u200C\n (spacer — paragraph has spacingBefore: 0.3) \u200B (empty para placeholder)
      expect(display, '\uFFFC\n\u200C\n\u200B');
    });

    test('divider then empty paragraph: offset mapping round-trips', () {
      final schema = EditorSchema.standard();
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.divider),
        TextBlock(id: 'b', blockType: BlockType.paragraph), // empty paragraph
      ]);

      // Model offset 1 = start of empty paragraph (divider=0 chars + \n=1)
      final displayOffset = modelToDisplay(doc, 1, schema);
      expect(displayToModel(doc, displayOffset, schema), 1);
    });

    test('typing on empty paragraph after divider inserts correctly', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(id: 'a', blockType: BlockType.divider),
          TextBlock(id: 'b', blockType: BlockType.paragraph), // empty paragraph
        ]),
      );

      final displayText = controller.text;
      // Spacer \u200C\n before paragraph at index 1 (spacingBefore: 0.3).
      expect(displayText, '\uFFFC\n\u200C\n\u200B');

      // Simulate typing 'H' at position 4 (the \u200B position, after spacer).
      controller.value = TextEditingValue(
        text: '\uFFFC\n\u200C\nH\u200B',
        selection: const TextSelection.collapsed(offset: 5),
      );

      expect(controller.document.allBlocks[1].plainText, 'H');
    });

    test('multiple empty paragraphs each get \\u200B', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(id: 'a', blockType: BlockType.paragraph),
          TextBlock(id: 'b', blockType: BlockType.paragraph),
          TextBlock(id: 'c', blockType: BlockType.paragraph),
        ]),
      );

      // Paragraphs at index 1 and 2 each get spacer \u200C\n (spacingBefore: 0.3).
      expect(controller.text, '\u200B\n\u200C\n\u200B\n\u200C\n\u200B');
    });
  });

  group('Hint text (empty document)', () {
    test('single empty paragraph produces empty display text', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document.empty(BlockType.paragraph),
      );

      // Empty string so TextField shows hint text.
      expect(controller.text, '');
    });

    test('single empty paragraph cursor is at offset 0', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document.empty(BlockType.paragraph),
      );

      expect(controller.selection, const TextSelection.collapsed(offset: 0));
    });

    test('typing on empty document produces non-empty display text', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document.empty(BlockType.paragraph),
      );

      // Simulate typing a character.
      controller.value = const TextEditingValue(
        text: 'a',
        selection: TextSelection.collapsed(offset: 1),
      );

      expect(controller.document.blocks[0].plainText, 'a');
      expect(controller.text, 'a');
    });

    test('non-empty single paragraph does not return empty string', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('hi')]),
        ]),
      );

      expect(controller.text, 'hi');
    });

    test('empty list item still has prefix char (not empty string)', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(id: 'a', blockType: BlockType.listItem, segments: const []),
        ]),
      );

      // List items have a prefix, so display text is not empty.
      expect(controller.text, '\uFFFC');
      expect(controller.text.isNotEmpty, true);
    });

    test('two empty paragraphs produce non-empty display text', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(id: 'a', blockType: BlockType.paragraph, segments: const []),
          TextBlock(id: 'b', blockType: BlockType.paragraph, segments: const []),
        ]),
      );

      // Two blocks → not the single-empty-paragraph case.
      expect(controller.text.isNotEmpty, true);
    });
  });
}
