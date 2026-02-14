import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EditorController', () {
    test('assert fires when type params are Object (untyped declaration)', () {
      // Simulates: EditorController _ctrl = EditorController(schema: ...);
      // where the field type forces <Object, Object>.
      expect(
        () => EditorController<Object, Object>(schema: EditorSchema.standard()),
        throwsA(isA<AssertionError>()),
      );
    });

    test('bold rule fires and cursor lands correctly via controller', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: [const StyledSegment('abc **trigger*')],
          ),
        ]),
        // Rules come from schema.
      );

      // Simulate user typing the closing * at position 14.
      // The controller's text is currently "abc **trigger*" (14 chars).
      // We set the value as if Flutter updated it with the new char.
      controller.value = const TextEditingValue(
        text: 'abc **trigger**',
        selection: TextSelection.collapsed(offset: 15),
      );

      // After the bold rule fires:
      // - Asterisks removed, "trigger" is bold
      // - Text should be "abc trigger"
      expect(controller.document.blocks[0].plainText, 'abc trigger');
      expect(
        controller.document.blocks[0].segments.any(
          (s) => s.text == 'trigger' && s.styles.contains(InlineStyle.bold),
        ),
        isTrue,
      );

      // Cursor should be at offset 11 (after "trigger" in "abc trigger")
      expect(controller.value.selection.baseOffset, 11);
    });

    test('typing after bold continues the style', () {
      // Start with a document that already has bold text.
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: [
              const StyledSegment('hello', {InlineStyle.bold}),
            ],
          ),
        ]),
      );

      expect(controller.text, 'hello');
      // Active styles should be bold (cursor is at end of bold text after init).
      expect(controller.activeStyles, contains(InlineStyle.bold));

      // User types a space.
      controller.value = const TextEditingValue(
        text: 'hello ',
        selection: TextSelection.collapsed(offset: 6),
      );

      // The space should be bold.
      expect(controller.document.blocks[0].plainText, 'hello ');
      expect(controller.document.blocks[0].segments.length, 1);
      expect(controller.document.blocks[0].segments[0].styles, {
        InlineStyle.bold,
      });

      // User types "w".
      controller.value = const TextEditingValue(
        text: 'hello w',
        selection: TextSelection.collapsed(offset: 7),
      );

      expect(controller.document.blocks[0].plainText, 'hello w');
      expect(controller.document.blocks[0].segments.length, 1);
      expect(controller.document.blocks[0].segments[0].styles, {
        InlineStyle.bold,
      });
    });

    test('space typed at bold/unstyled boundary inherits bold', () {
      // "abc trigger bold" where "trigger" is bold.
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: [
              const StyledSegment('abc '),
              const StyledSegment('trigger', {InlineStyle.bold}),
              const StyledSegment(' bold'),
            ],
          ),
        ]),
      );

      expect(controller.text, 'abc trigger bold');

      // First, position cursor after "trigger" (offset 11) — selection-only change.
      controller.value = const TextEditingValue(
        text: 'abc trigger bold',
        selection: TextSelection.collapsed(offset: 11),
      );
      // Active styles should now be bold.
      expect(controller.activeStyles, contains(InlineStyle.bold));

      // Now type space. New text: "abc trigger  bold", cursor at 12.
      controller.value = const TextEditingValue(
        text: 'abc trigger  bold',
        selection: TextSelection.collapsed(offset: 12),
      );

      // The space should be bold (active styles were bold when typed).
      final segments = controller.document.blocks[0].segments;
      var pos = 0;
      Set<Object>? styleAtInsert;
      for (final seg in segments) {
        if (pos + seg.text.length > 11) {
          styleAtInsert = seg.styles;
          break;
        }
        pos += seg.text.length;
      }
      expect(
        styleAtInsert,
        contains(InlineStyle.bold),
        reason: 'Space typed after bold text should inherit bold',
      );
    });
    test('Enter splits block and preserves styles on both halves', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: [
              const StyledSegment('hello world', {InlineStyle.bold}),
            ],
          ),
        ]),
      );

      // Cursor at offset 5 (between "hello" and " world").
      controller.value = const TextEditingValue(
        text: 'hello world',
        selection: TextSelection.collapsed(offset: 5),
      );

      // Press Enter — Flutter inserts \n at offset 5.
      controller.value = const TextEditingValue(
        text: 'hello\n world',
        selection: TextSelection.collapsed(offset: 6),
      );

      expect(controller.document.blocks.length, 2);
      expect(controller.document.blocks[0].plainText, 'hello');
      expect(controller.document.blocks[1].plainText, ' world');
      // Both halves should remain bold.
      expect(controller.document.blocks[0].segments[0].styles, {
        InlineStyle.bold,
      });
      expect(controller.document.blocks[1].segments[0].styles, {
        InlineStyle.bold,
      });
    });

    test('Backspace at block start merges blocks', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: [const StyledSegment('hello')],
          ),
          TextBlock(
            id: 'b',
            blockType: BlockType.paragraph,
            segments: [const StyledSegment('world')],
          ),
        ]),
      );

      // No spacer — paragraph has spacingBefore: 0.
      expect(controller.text, 'hello\nworld');

      // Cursor at start of "world" (display offset 6), press backspace.
      // Flutter removes the \n, producing "helloworld". The
      // controller sees the diff and merges the blocks.
      controller.value = const TextEditingValue(
        text: 'helloworld',
        selection: TextSelection.collapsed(offset: 5),
      );

      expect(controller.document.blocks.length, 1);
      expect(controller.document.blocks[0].plainText, 'helloworld');
    });

    test(
      'Backspace at heading start demotes h1 → paragraph (HeadingBackspaceRule)',
      () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(
              id: 'a',
              blockType: BlockType.paragraph,
              segments: [const StyledSegment('hello')],
            ),
            TextBlock(
              id: 'b',
              blockType: BlockType.h1,
              segments: [const StyledSegment('world')],
            ),
          ]),
        );

        // h1 has spacingBefore, so display text has spacer \u200C\n before it.
        expect(controller.text, 'hello\n\u200C\nworld');

        // Simulate backspace: Flutter removes the \n at offset 7.
        controller.value = const TextEditingValue(
          text: 'hello\n\u200Cworld',
          selection: TextSelection.collapsed(offset: 7),
        );

        // HeadingBackspaceRule intercepts: h1 → paragraph, no merge.
        expect(controller.document.blocks.length, 2);
        expect(controller.document.blocks[1].blockType, BlockType.paragraph);
        expect(controller.document.blocks[1].plainText, 'world');
      },
    );

    test('Backspace chain: h1 → paragraph → merge with previous block', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: [const StyledSegment('hello')],
          ),
          TextBlock(
            id: 'b',
            blockType: BlockType.h1,
            segments: [const StyledSegment('world')],
          ),
        ]),
      );

      // First backspace: h1 → paragraph (spacer removed since paragraph has no spacingBefore).
      controller.value = const TextEditingValue(
        text: 'hello\n\u200Cworld',
        selection: TextSelection.collapsed(offset: 7),
      );
      expect(controller.document.blocks[1].blockType, BlockType.paragraph);

      // Second backspace: paragraph at root → merges with previous block.
      controller.value = const TextEditingValue(
        text: 'helloworld',
        selection: TextSelection.collapsed(offset: 5),
      );
      expect(controller.document.blocks.length, 1);
      expect(controller.document.blocks[0].plainText, 'helloworld');
      expect(controller.value.selection.baseOffset, 5);
    });

    test('Bold rule at start of block', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: [const StyledSegment('**hello*')],
          ),
        ]),
        // Rules come from schema.
      );

      // Type the closing *.
      controller.value = const TextEditingValue(
        text: '**hello**',
        selection: TextSelection.collapsed(offset: 9),
      );

      expect(controller.document.blocks[0].plainText, 'hello');
      expect(controller.document.blocks[0].segments[0].styles, {
        InlineStyle.bold,
      });
      expect(controller.value.selection.baseOffset, 5);
    });

    test('Multiple bold segments in one block', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: [const StyledSegment('**one** and **two*')],
          ),
        ]),
        // Rules come from schema.
      );

      // Complete the second **two** by typing the closing *.
      controller.value = const TextEditingValue(
        text: '**one** and **two**',
        selection: TextSelection.collapsed(offset: 19),
      );

      // The first **one** is still literal asterisks (rule only fires on the
      // pattern the edit completed). But **two** should become bold.
      final plainText = controller.document.blocks[0].plainText;
      expect(plainText, '**one** and two');
      expect(
        controller.document.blocks[0].segments.any(
          (s) => s.text == 'two' && s.styles.contains(InlineStyle.bold),
        ),
        isTrue,
      );
    });

    test('Deleting bold text keeps model consistent', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: [
              const StyledSegment('abc '),
              const StyledSegment('bold', {InlineStyle.bold}),
              const StyledSegment(' xyz'),
            ],
          ),
        ]),
      );

      expect(controller.text, 'abc bold xyz');

      // Select "bold" (offsets 4-8) and delete it — Flutter replaces with empty.
      controller.value = const TextEditingValue(
        text: 'abc  xyz',
        selection: TextSelection.collapsed(offset: 4),
      );

      expect(controller.document.blocks[0].plainText, 'abc  xyz');
      // "bold" segment should be gone.
      expect(
        controller.document.blocks[0].segments.every(
          (s) => !s.styles.contains(InlineStyle.bold),
        ),
        isTrue,
      );
    });

    test('# space converts paragraph to H1 via controller', () {
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

      // Type '#'
      controller.value = const TextEditingValue(
        text: '#',
        selection: TextSelection.collapsed(offset: 1),
      );
      expect(controller.document.blocks[0].blockType, BlockType.paragraph);

      // Type space — should trigger HeadingRule.
      controller.value = const TextEditingValue(
        text: '# ',
        selection: TextSelection.collapsed(offset: 2),
      );
      expect(controller.document.blocks[0].blockType, BlockType.h1);
      expect(controller.document.blocks[0].plainText, '');
    });

    test('- space converts paragraph to list item via controller', () {
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

      controller.value = const TextEditingValue(
        text: '-',
        selection: TextSelection.collapsed(offset: 1),
      );

      controller.value = const TextEditingValue(
        text: '- ',
        selection: TextSelection.collapsed(offset: 2),
      );
      expect(controller.document.blocks[0].blockType, BlockType.listItem);
      expect(controller.document.blocks[0].plainText, '');
    });

    test('typing space at end of H1 advances cursor correctly', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.h1,
            segments: [const StyledSegment('Title')],
          ),
          TextBlock(
            id: 'b',
            blockType: BlockType.paragraph,
            segments: [const StyledSegment('paragraph')],
          ),
        ]),
        // Rules come from schema.
      );

      // No spacer — paragraph has spacingBefore: 0.
      expect(controller.text, 'Title\nparagraph');

      controller.value = const TextEditingValue(
        text: 'Title\nparagraph',
        selection: TextSelection.collapsed(offset: 5),
      );

      // Type space at end of H1.
      controller.value = const TextEditingValue(
        text: 'Title \nparagraph',
        selection: TextSelection.collapsed(offset: 6),
      );

      // Model should have the space.
      expect(controller.document.blocks[0].plainText, 'Title ');
      expect(controller.document.blocks[0].blockType, BlockType.h1);

      // Cursor should be at 6 (after the space, which is the \n position).
      expect(controller.value.selection.baseOffset, 6);

      // Controller text should reflect the model.
      expect(controller.text, 'Title \nparagraph');
    });

    test('Enter on heading creates paragraph block', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.h1,
            segments: [const StyledSegment('Title')],
          ),
        ]),
        // Rules come from schema.
      );

      // Press Enter at end of heading.
      controller.value = const TextEditingValue(
        text: 'Title\n',
        selection: TextSelection.collapsed(offset: 6),
      );

      expect(controller.document.blocks.length, 2);
      expect(controller.document.blocks[0].blockType, BlockType.h1);
      expect(controller.document.blocks[1].blockType, BlockType.paragraph);
    });

    test('Enter on list item creates another list item', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.listItem,
            segments: [const StyledSegment('first')],
          ),
        ]),
        // Rules come from schema.
      );

      // Display text: "\uFFFCfirst" (prefix + text). Enter at end.
      controller.value = const TextEditingValue(
        text: '\uFFFCfirst\n',
        selection: TextSelection.collapsed(offset: 7),
      );

      expect(controller.document.blocks.length, 2);
      expect(controller.document.blocks[0].blockType, BlockType.listItem);
      expect(controller.document.blocks[1].blockType, BlockType.listItem);
      // Bug 1: cursor should move to the new block, not stay on the old one.
      // The new list item has a prefix, so display offset should be after \n\uFFFC.
      // Display: "\uFFFCfirst\n\uFFFC" — cursor at 8 (start of new empty list item text).
      expect(controller.value.selection.baseOffset, 8);
    });

    test('Enter on empty list item converts to paragraph', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(id: 'a', blockType: BlockType.listItem, segments: const []),
        ]),
        // Rules come from schema.
      );

      // Display text: "\uFFFC" (prefix, no content). Enter.
      controller.value = const TextEditingValue(
        text: '\uFFFC\n',
        selection: TextSelection.collapsed(offset: 2),
      );

      // Should convert to paragraph, not split.
      expect(controller.document.blocks.length, 1);
      expect(controller.document.blocks[0].blockType, BlockType.paragraph);
    });

    test('outdent works on nested paragraph (not just list items)', () {
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
                blockType: BlockType.paragraph,
                segments: [const StyledSegment('nested para')],
              ),
            ],
          ),
        ]),
      );

      // Cursor in nested paragraph — use display text from the controller.
      // Display: "\uFFFCparent\nnested para" — nested para is at display offset 8.
      controller.value = TextEditingValue(
        text: controller.text,
        selection: TextSelection.collapsed(
          offset: controller.text.indexOf('nested'),
        ),
      );

      controller.outdent();

      // Should be outdented to root level.
      expect(controller.document.blocks.length, 2);
      expect(controller.document.blocks[1].id, 'b');
      expect(controller.document.blocks[1].blockType, BlockType.paragraph);
    });

    test('backspace on empty list item keeps cursor in place', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: [const StyledSegment('above')],
          ),
          TextBlock(id: 'b', blockType: BlockType.listItem, segments: const []),
        ]),
      );

      // Display: "above\n\uFFFC" — no spacer (listItem has spacingBefore: 0) + empty list item prefix.
      expect(controller.text, 'above\n\uFFFC');

      controller.value = const TextEditingValue(
        text: 'above\n\uFFFC',
        selection: TextSelection.collapsed(offset: 7),
      );

      // Backspace removes the block — Flutter sends "above" with cursor at 5.
      controller.value = const TextEditingValue(
        text: 'above',
        selection: TextSelection.collapsed(offset: 5),
      );

      // The list item should become a paragraph, NOT merge.
      expect(controller.document.allBlocks.length, 2);
      expect(controller.document.allBlocks[1].blockType, BlockType.paragraph);
    });

    test('backspace chain: nested para → outdent → root para → merge', () {
      // "hello" (list item) with nested "boss" (paragraph).
      // Backspace on "boss": first outdents to root, second merges into "hello".
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.listItem,
            segments: [const StyledSegment('hello')],
            children: [
              TextBlock(
                id: 'b',
                blockType: BlockType.paragraph,
                segments: [const StyledSegment('boss')],
              ),
            ],
          ),
        ]),
      );

      // Step 1: backspace on nested "boss" → should outdent to root.
      var displayText = controller.text;
      var bossStart = displayText.indexOf('boss');
      controller.value = TextEditingValue(
        text:
            '${displayText.substring(0, bossStart - 1)}${displayText.substring(bossStart)}',
        selection: TextSelection.collapsed(offset: bossStart - 1),
      );

      // "boss" should now be at root level, sibling after "hello".
      expect(controller.document.blocks.length, 2);
      expect(controller.document.blocks[1].plainText, 'boss');

      // Step 2: backspace on root "boss" → should merge into "helloboss".
      displayText = controller.text;
      bossStart = displayText.indexOf('boss');
      controller.value = TextEditingValue(
        text:
            '${displayText.substring(0, bossStart - 1)}${displayText.substring(bossStart)}',
        selection: TextSelection.collapsed(offset: bossStart - 1),
      );

      expect(controller.document.allBlocks.length, 1);
      expect(controller.document.allBlocks[0].plainText, 'helloboss');
    });

    test('backspace on nested paragraph outdents instead of merging', () {
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
                blockType: BlockType.paragraph,
                segments: [const StyledSegment('child')],
              ),
            ],
          ),
        ]),
      );

      // Display: "\uFFFCparent\n\uFFFCchild"
      final displayText = controller.text;
      final childStart = displayText.indexOf('child');

      // Backspace at start of nested "child" — delete the prefix.
      final before = displayText.substring(0, childStart - 1);
      final after = displayText.substring(childStart);
      controller.value = TextEditingValue(
        text: '$before$after',
        selection: TextSelection.collapsed(offset: childStart - 1),
      );

      // Should outdent, not merge. "child" moves to root level as sibling.
      expect(controller.document.blocks.length, 2);
      expect(controller.document.blocks[0].id, 'a');
      expect(controller.document.blocks[1].id, 'b');
      expect(controller.document.blocks[1].plainText, 'child');
    });

    test('bold rule in second block of example doc', () {
      // Matches the example app's initial document.
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'b1',
            blockType: BlockType.paragraph,
            segments: [
              const StyledSegment('Hello '),
              const StyledSegment('bold world', {InlineStyle.bold}),
              const StyledSegment('! This is the POC.'),
            ],
          ),
          TextBlock(
            id: 'b2',
            blockType: BlockType.paragraph,
            segments: [
              const StyledSegment(
                'Type two asterisks, then text, then two more asterisks to **trigger* bold.',
              ),
            ],
          ),
        ]),
        // Rules come from schema.
      );

      // Block 0 text: "Hello bold world! This is the POC." (34 chars)
      // Block 1 text: "...to **trigger* bold."
      // Full text: block0 + \n + block1 (no spacer — paragraph has spacingBefore: 0)
      final block0Len = controller.document.blocks[0].plainText.length;
      final block1Text = controller.document.blocks[1].plainText;

      // Find where the second * should go (completing **trigger**)
      final closingStarLocal = block1Text.indexOf('* bold');
      // closingStarLocal points to the * before " bold"
      // User types another * right after it
      final insertLocalOffset = closingStarLocal + 1;
      final insertGlobalOffset = block0Len + 1 + insertLocalOffset; // +1 for \n

      final newBlock1Text =
          '${block1Text.substring(0, insertLocalOffset)}*${block1Text.substring(insertLocalOffset)}';
      final newFullText =
          '${controller.document.blocks[0].plainText}\n$newBlock1Text';

      controller.value = TextEditingValue(
        text: newFullText,
        selection: TextSelection.collapsed(offset: insertGlobalOffset + 1),
      );

      // "trigger" should now be bold, asterisks removed
      expect(
        controller.document.blocks[1].segments.any(
          (s) => s.text == 'trigger' && s.styles.contains(InlineStyle.bold),
        ),
        isTrue,
      );

      // Cursor should be right after "trigger" in block 1, not at end of doc.
      // "...to trigger bold." — "trigger" ends at local offset =
      //   block1 text without asterisks: "Type two asterisks, then text, then two more asterisks to trigger bold."
      //   "trigger" starts where "**trigger**" started, i.e. at the same position as fullMatchStart
      // Cursor should not be at the end of the document.
      final docLen = controller.document.plainText.length;
      expect(
        controller.value.selection.baseOffset,
        lessThan(docLen),
        reason: 'Cursor should not be at end of document',
      );
    });

    test('select within block and delete', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: [const StyledSegment('hello world')],
          ),
        ]),
        undoGrouping: (_, __) => false,
      );

      // Select 'llo w' (offsets 2..7) and delete.
      // Simulates: the user selected, then pressed delete.
      // Flutter gives us new value with the selection deleted.
      controller.value = const TextEditingValue(
        text: 'heorld',
        selection: TextSelection.collapsed(offset: 2),
      );

      expect(controller.document.allBlocks[0].plainText, 'heorld');
      expect(controller.document.allBlocks.length, 1);
    });

    test('select across 2 blocks and delete', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: [const StyledSegment('hello')],
          ),
          TextBlock(
            id: 'b',
            blockType: BlockType.paragraph,
            segments: [const StyledSegment('world')],
          ),
        ]),
        undoGrouping: (_, __) => false,
      );

      // Initial display text: 'hello\nworld' (no spacer — paragraph has spacingBefore: 0).
      // Select from offset 3 ('hel|lo') to offset 8 ('wor|ld') and delete.
      // Deleted: 'lo\nwor' (5 chars), result: 'helld'.
      controller.value = const TextEditingValue(
        text: 'helld',
        selection: TextSelection.collapsed(offset: 3),
      );

      expect(controller.document.allBlocks.length, 1);
      expect(controller.document.allBlocks[0].plainText, 'helld');
    });

    test('select across blocks and type character (replace)', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: [const StyledSegment('hello')],
          ),
          TextBlock(
            id: 'b',
            blockType: BlockType.paragraph,
            segments: [const StyledSegment('world')],
          ),
        ]),
        undoGrouping: (_, __) => false,
      );

      // Select from offset 3 to offset 8, then type 'X'.
      // Deleted: 'lo\nwor', inserted: 'X', result: 'helXld'.
      controller.value = const TextEditingValue(
        text: 'helXld',
        selection: TextSelection.collapsed(offset: 4),
      );

      expect(controller.document.allBlocks.length, 1);
      expect(controller.document.allBlocks[0].plainText, 'helXld');
    });

    test('select all and delete', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: [const StyledSegment('hello')],
          ),
          TextBlock(
            id: 'b',
            blockType: BlockType.paragraph,
            segments: [const StyledSegment('world')],
          ),
        ]),
        undoGrouping: (_, __) => false,
      );

      // Select all and delete.
      controller.value = const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      );

      expect(controller.document.allBlocks.length, 1);
      expect(controller.document.allBlocks[0].plainText, '');
    });

    test('undo after cross-block delete restores all blocks', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: [const StyledSegment('hello')],
          ),
          TextBlock(
            id: 'b',
            blockType: BlockType.paragraph,
            segments: [const StyledSegment('world')],
          ),
        ]),
        undoGrouping: (_, __) => false,
      );

      // Select across both blocks and delete.
      controller.value = const TextEditingValue(
        text: 'helld',
        selection: TextSelection.collapsed(offset: 3),
      );
      expect(controller.document.allBlocks.length, 1);

      // Undo — should restore both blocks.
      controller.undo();
      expect(controller.document.allBlocks.length, 2);
      expect(controller.document.allBlocks[0].plainText, 'hello');
      expect(controller.document.allBlocks[1].plainText, 'world');
    });

    test('toggleStyle at collapsed cursor toggles activeStyles', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: [const StyledSegment('hello')],
          ),
        ]),
      );

      // Controller starts with cursor at end of text. activeStyles is
      // derived from the document (no bold at that position).
      expect(controller.activeStyles.contains(InlineStyle.bold), isFalse);

      // Toggle bold on — this is a "pending style" for next typed text.
      controller.toggleStyle(InlineStyle.bold);
      expect(controller.activeStyles.contains(InlineStyle.bold), isTrue);

      // Simulate the system/IME re-setting value at the same cursor position
      // but with a different composing range (forces a value change notification).
      // This happens on macOS when Cmd+B triggers an IME update.
      controller.value = TextEditingValue(
        text: controller.text,
        selection: controller.value.selection,
        composing: const TextRange(start: 0, end: 0),
      );
      // The composing range is empty, so _onValueChanged won't bail early.
      // But it should still preserve the manually toggled active styles
      // because the cursor hasn't moved.
      expect(
        controller.activeStyles.contains(InlineStyle.bold),
        isTrue,
        reason: 'Active styles should survive same-position value re-set',
      );

      // Toggle off.
      controller.toggleStyle(InlineStyle.bold);
      expect(controller.activeStyles.contains(InlineStyle.bold), isFalse);
    });

    test('toggleStyle with selection applies style to range', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: [const StyledSegment('hello world')],
          ),
        ]),
      );

      // Select 'world' (offset 6..11).
      controller.value = const TextEditingValue(
        text: 'hello world',
        selection: TextSelection(baseOffset: 6, extentOffset: 11),
      );

      controller.toggleStyle(InlineStyle.italic);
      expect(
        controller.document.allBlocks[0].segments.any(
          (s) => s.text == 'world' && s.styles.contains(InlineStyle.italic),
        ),
        isTrue,
      );
    });

    test('toggleStyle with selection updates activeStyles before notify', () {
      // Regression: activeStyles must be updated BEFORE _syncToTextField
      // triggers notifyListeners, so the toolbar sees the new state.
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: [const StyledSegment('hello world')],
          ),
        ]),
      );

      // Select 'world' (offset 6..11).
      controller.value = const TextEditingValue(
        text: 'hello world',
        selection: TextSelection(baseOffset: 6, extentOffset: 11),
      );

      // Record activeStyles at the moment notifyListeners fires from toggleStyle.
      // Register AFTER the setup value-set to avoid capturing that notification.
      Set<Object>? stylesAtNotify;
      controller.addListener(() {
        stylesAtNotify ??= Set.of(controller.activeStyles);
      });

      controller.toggleStyle(InlineStyle.bold);

      // The listener should have seen bold as active on the FIRST notification.
      expect(
        stylesAtNotify?.contains(InlineStyle.bold),
        isTrue,
        reason: 'Toolbar must see updated styles during notification',
      );
    });

    test('setBlockType changes block type', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: [const StyledSegment('hello')],
          ),
        ]),
      );

      controller.value = const TextEditingValue(
        text: 'hello',
        selection: TextSelection.collapsed(offset: 0),
      );

      expect(controller.currentBlockType, BlockType.paragraph);
      controller.setBlockType(BlockType.h1);
      expect(controller.currentBlockType, BlockType.h1);
      expect(controller.document.allBlocks[0].blockType, BlockType.h1);
    });

    test('currentBlockType reflects cursor position', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.h1,
            segments: [const StyledSegment('title')],
          ),
          TextBlock(
            id: 'b',
            blockType: BlockType.paragraph,
            segments: [const StyledSegment('body')],
          ),
        ]),
      );

      // Cursor in H1.
      controller.value = TextEditingValue(
        text: controller.text,
        selection: const TextSelection.collapsed(offset: 0),
      );
      expect(controller.currentBlockType, BlockType.h1);

      // Cursor in paragraph (after 'title\n' = offset 6).
      controller.value = TextEditingValue(
        text: controller.text,
        selection: const TextSelection.collapsed(offset: 6),
      );
      expect(controller.currentBlockType, BlockType.paragraph);
    });

    test('activeStyles reflects entire selection (all bold)', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: [
              const StyledSegment('hello ', {}),
              const StyledSegment('bold', {InlineStyle.bold}),
              const StyledSegment(' world', {}),
            ],
          ),
        ]),
      );

      // Select just the bold word 'bold' (offsets 6..10).
      controller.value = TextEditingValue(
        text: controller.text,
        selection: const TextSelection(baseOffset: 6, extentOffset: 10),
      );
      expect(controller.activeStyles.contains(InlineStyle.bold), isTrue);
    });

    test('activeStyles empty when selection spans bold and non-bold', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: [
              const StyledSegment('hello ', {}),
              const StyledSegment('bold', {InlineStyle.bold}),
              const StyledSegment(' world', {}),
            ],
          ),
        ]),
      );

      // Select 'lo bold w' (offsets 3..11) — spans both styled and unstyled.
      controller.value = TextEditingValue(
        text: controller.text,
        selection: const TextSelection(baseOffset: 3, extentOffset: 11),
      );
      expect(controller.activeStyles.contains(InlineStyle.bold), isFalse);
    });

    group('IME / Composing', () {
      test('diacritic at end of paragraph does not corrupt document', () {
        // Two blocks: "hello" paragraph, then "- item" list item.
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(
              id: 'a',
              blockType: BlockType.paragraph,
              segments: [const StyledSegment('hello')],
            ),
            TextBlock(
              id: 'b',
              blockType: BlockType.listItem,
              segments: [const StyledSegment('item')],
            ),
          ]),
        );

        // Display: "hello\n\uFFFCitem" (no spacer — listItem has spacingBefore: 0, prefix \uFFFC)
        // Cursor at end of "hello" (display offset 5).
        final baseText = controller.text;
        expect(baseText, 'hello\n\uFFFCitem');

        // Step 1: User presses Option+E (dead key).
        // Flutter inserts composing placeholder — e.g. accent mark.
        // Text becomes "hello´\n\uFFFCitem", composing range covers the ´.
        controller.value = TextEditingValue(
          text: 'hello\u0301\n\uFFFCitem',
          selection: const TextSelection.collapsed(offset: 6),
          composing: const TextRange(start: 5, end: 6),
        );

        // During composing, the model is updated provisionally (for rendering)
        // but block structure must be preserved.
        expect(
          controller.document.allBlocks.length,
          2,
          reason: 'block count must not change during composing',
        );

        // Step 2: User presses E to complete the diacritic.
        // Flutter resolves composing: replaces the ´ with é.
        controller.value = TextEditingValue(
          text: 'helloé\n\uFFFCitem',
          selection: const TextSelection.collapsed(offset: 6),
          composing: TextRange.empty,
        );

        // Document should have 2 blocks, first block is "helloé".
        expect(
          controller.document.allBlocks.length,
          2,
          reason: 'block count must stay 2 after composing resolves',
        );
        expect(controller.document.allBlocks[0].plainText, 'helloé');
        expect(controller.document.allBlocks[1].plainText, 'item');
      });

      test('diacritic mid-word composes in place', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(
              id: 'a',
              blockType: BlockType.paragraph,
              segments: [const StyledSegment('hello')],
            ),
          ]),
        );

        // Cursor between 'l' and 'o' (offset 3: hel|lo).
        controller.value = const TextEditingValue(
          text: 'hello',
          selection: TextSelection.collapsed(offset: 3),
        );

        // Step 1: Dead key inserts composing placeholder between l and o.
        // "hel´lo" with composing range at the ´.
        controller.value = const TextEditingValue(
          text: 'hel\u0301lo',
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange(start: 3, end: 4),
        );

        // During composing, model is updated provisionally for rendering.
        // Block count must be preserved.

        // Step 2: Resolve composing — ´ becomes é.
        controller.value = const TextEditingValue(
          text: 'helélo',
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange.empty,
        );

        // Document should be "helélo" — the é inserted, o NOT replaced.
        expect(controller.document.blocks[0].plainText, 'helélo');
        expect(controller.value.selection.baseOffset, 4);
      });

      test('diacritic on prefixed block (list item) works correctly', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(
              id: 'a',
              blockType: BlockType.listItem,
              segments: [const StyledSegment('cafe')],
            ),
          ]),
        );

        // Display: "\uFFFCcafe" — cursor at end (display offset 5).
        expect(controller.text, '\uFFFCcafe');

        controller.value = const TextEditingValue(
          text: '\uFFFCcafe',
          selection: TextSelection.collapsed(offset: 5),
        );

        // Step 1: Dead key — "cafe" becomes "cafe´" in display.
        controller.value = const TextEditingValue(
          text: '\uFFFCcafe\u0301',
          selection: TextSelection.collapsed(offset: 6),
          composing: TextRange(start: 5, end: 6),
        );

        // Model updated provisionally during composing for rendering.

        // Step 2: Resolve — "café".
        controller.value = const TextEditingValue(
          text: '\uFFFCcafé',
          selection: TextSelection.collapsed(offset: 5),
          composing: TextRange.empty,
        );

        expect(controller.document.allBlocks[0].plainText, 'café');
      });

      test('composing cancelled leaves document unchanged', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(
              id: 'a',
              blockType: BlockType.paragraph,
              segments: [const StyledSegment('hello')],
            ),
          ]),
        );

        // Step 1: Dead key starts composing.
        controller.value = const TextEditingValue(
          text: 'hello\u0301',
          selection: TextSelection.collapsed(offset: 6),
          composing: TextRange(start: 5, end: 6),
        );

        // Model is provisionally updated during composing.
        expect(controller.document.blocks[0].plainText, 'hello\u0301');

        // Step 2: User presses Escape or another key that cancels composing.
        // Flutter removes the placeholder, text goes back to "hello".
        controller.value = const TextEditingValue(
          text: 'hello',
          selection: TextSelection.collapsed(offset: 5),
          composing: TextRange.empty,
        );

        expect(
          controller.document.blocks[0].plainText,
          'hello',
          reason: 'document unchanged after cancelled composing',
        );
      });

      test('multi-step composing resolves correctly', () {
        // Simulates CJK-style input where composing text changes multiple
        // times before resolving.
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(
              id: 'a',
              blockType: BlockType.paragraph,
              segments: [const StyledSegment('ab')],
            ),
          ]),
        );

        // Cursor at end.
        controller.value = const TextEditingValue(
          text: 'ab',
          selection: TextSelection.collapsed(offset: 2),
        );

        // Step 1: First composing char.
        controller.value = const TextEditingValue(
          text: 'abx',
          selection: TextSelection.collapsed(offset: 3),
          composing: TextRange(start: 2, end: 3),
        );
        // Model provisionally updated during composing.
        expect(controller.document.blocks[0].plainText, 'abx');

        // Step 2: Composing text changes (user picks different candidate).
        controller.value = const TextEditingValue(
          text: 'abxy',
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange(start: 2, end: 4),
        );
        expect(controller.document.blocks[0].plainText, 'abxy');

        // Step 3: Resolve.
        controller.value = const TextEditingValue(
          text: 'abZ',
          selection: TextSelection.collapsed(offset: 3),
          composing: TextRange.empty,
        );
        expect(controller.document.blocks[0].plainText, 'abZ');
      });
    });

    group('Link support', () {
      test('setLink applies link style with URL to selection', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(
              id: 'a',
              blockType: BlockType.paragraph,
              segments: [const StyledSegment('click here please')],
            ),
          ]),
        );

        // Select "here" (offset 6..10).
        controller.value = controller.value.copyWith(
          selection: const TextSelection(baseOffset: 6, extentOffset: 10),
        );

        controller.setLink('https://example.com');

        final segs = controller.document.allBlocks[0].segments;
        final linkSeg = segs.firstWhere((s) => s.text == 'here');
        expect(linkSeg.styles, contains(InlineStyle.link));
        expect(linkSeg.attributes['url'], 'https://example.com');

        // Non-linked parts should not have link style.
        final plainSeg = segs.firstWhere((s) => s.text == 'click ');
        expect(plainSeg.styles, isEmpty);
      });

      test('setLink is no-op on collapsed cursor', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(
              id: 'a',
              blockType: BlockType.paragraph,
              segments: [const StyledSegment('hello')],
            ),
          ]),
        );

        controller.value = controller.value.copyWith(
          selection: const TextSelection.collapsed(offset: 3),
        );

        controller.setLink('https://example.com');

        // No link applied — all segments unchanged.
        expect(controller.document.allBlocks[0].segments[0].styles, isEmpty);
      });
    });

    group('Link tap', () {
      test(
        'buildTextSpan has no recognizers (taps handled at gesture level)',
        () {
          final controller = EditorController(
            schema: EditorSchema.standard(),
            document: Document([
              TextBlock(
                id: 'a',
                blockType: BlockType.paragraph,
                segments: [
                  const StyledSegment('Visit '),
                  const StyledSegment(
                    'Google',
                    {InlineStyle.link},
                    {'url': 'https://google.com'},
                  ),
                  const StyledSegment(' today'),
                ],
              ),
            ]),
          );

          final span = controller.buildTextSpan(
            context: _MockBuildContext(),
            style: const TextStyle(),
            withComposing: false,
          );

          // No recognizers on any span — link taps are detected via
          // segmentAtOffset / linkAtDisplayOffset instead.
          final linkSpan = _findSpanWithText(span, 'Google');
          expect(linkSpan, isNotNull);
          expect(linkSpan!.recognizer, isNull);

          controller.dispose();
        },
      );

      test('segmentAtOffset returns the link segment', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(
              id: 'a',
              blockType: BlockType.paragraph,
              segments: [
                const StyledSegment('Visit '),
                const StyledSegment(
                  'Google',
                  {InlineStyle.link},
                  {'url': 'https://google.com'},
                ),
                const StyledSegment(' today'),
              ],
            ),
          ]),
        );

        // Model offset 6 = start of 'Google' (forward-matching)
        final startSeg = controller.segmentAtOffset(6);
        expect(startSeg, isNotNull);
        expect(startSeg!.text, 'Google');
        expect(startSeg.styles, contains(InlineStyle.link));
        expect(startSeg.attributes['url'], 'https://google.com');

        // Model offset 8 = inside 'Google'
        final midSeg = controller.segmentAtOffset(8);
        expect(midSeg, isNotNull);
        expect(midSeg!.text, 'Google');

        // Model offset 12 = end of 'Google' — forward-match returns ' today'
        // but linkAtDisplayOffset checks both sides and finds the link
        final endSeg = controller.segmentAtOffset(12);
        expect(endSeg, isNotNull);
        expect(endSeg!.text, ' today'); // forward-match at boundary

        // Model offset 2 = inside 'Visit ' segment (no link)
        final plainSeg = controller.segmentAtOffset(2);
        expect(plainSeg, isNotNull);
        expect(plainSeg!.styles, isNot(contains(InlineStyle.link)));

        controller.dispose();
      });

      test('linkAtDisplayOffset returns URL for link, null for plain text', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(
              id: 'a',
              blockType: BlockType.paragraph,
              segments: [
                const StyledSegment('Hi '),
                const StyledSegment(
                  'link',
                  {InlineStyle.link},
                  {'url': 'https://x.com'},
                ),
              ],
            ),
          ]),
        );

        // Display offset 3 = model offset 3 = start of 'link' (forward-match)
        expect(controller.linkAtDisplayOffset(3), 'https://x.com');
        // Display offset 5 = model offset 5 = inside 'link'
        expect(controller.linkAtDisplayOffset(5), 'https://x.com');
        // Display offset 7 = model offset 7 = end of 'link' (backward check)
        expect(controller.linkAtDisplayOffset(7), 'https://x.com');
        // Display offset 1 = model offset 1 = inside 'Hi ' (no link)
        expect(controller.linkAtDisplayOffset(1), isNull);

        controller.dispose();
      });
    });

    group('currentAttributes', () {
      test('returns link URL when cursor is inside a link', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(
              id: 'a',
              blockType: BlockType.paragraph,
              segments: [
                const StyledSegment('before '),
                const StyledSegment(
                  'link',
                  {InlineStyle.link},
                  {'url': 'https://x.com'},
                ),
                const StyledSegment(' after'),
              ],
            ),
          ]),
        );
        // Place cursor inside "link" (display offset 9).
        controller.value = controller.value.copyWith(
          selection: const TextSelection.collapsed(offset: 9),
        );
        expect(controller.currentAttributes['url'], 'https://x.com');
      });

      test('returns empty map when cursor is on plain text', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(
              id: 'a',
              blockType: BlockType.paragraph,
              segments: [const StyledSegment('plain')],
            ),
          ]),
        );
        expect(controller.currentAttributes, isEmpty);
      });
    });

    group('setLink idempotent', () {
      test('setLink on already-linked range updates URL', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(
              id: 'a',
              blockType: BlockType.paragraph,
              segments: [
                const StyledSegment(
                  'click',
                  {InlineStyle.link},
                  {'url': 'https://old.com'},
                ),
              ],
            ),
          ]),
        );
        // Select all.
        controller.value = controller.value.copyWith(
          selection: const TextSelection(baseOffset: 0, extentOffset: 5),
        );
        controller.setLink('https://new.com');

        final seg = controller.document.allBlocks[0].segments[0];
        expect(seg.styles, contains(InlineStyle.link));
        expect(seg.attributes['url'], 'https://new.com');
      });

      test('setLink on plain text applies link', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(
              id: 'a',
              blockType: BlockType.paragraph,
              segments: [const StyledSegment('hello')],
            ),
          ]),
        );
        controller.value = controller.value.copyWith(
          selection: const TextSelection(baseOffset: 0, extentOffset: 5),
        );
        controller.setLink('https://example.com');

        final seg = controller.document.allBlocks[0].segments[0];
        expect(seg.styles, contains(InlineStyle.link));
        expect(seg.attributes['url'], 'https://example.com');
      });
    });

    group('encodeSelection', () {
      test('encodes bold text as markdown', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(
              id: 'a',
              blockType: BlockType.paragraph,
              segments: [
                const StyledSegment('plain '),
                const StyledSegment('bold', {InlineStyle.bold}),
                const StyledSegment(' text'),
              ],
            ),
          ]),
        );
        // Select "bold" (offset 6..10).
        controller.value = controller.value.copyWith(
          selection: const TextSelection(baseOffset: 6, extentOffset: 10),
        );
        final md = controller.encodeSelection();
        expect(md, '**bold**');
      });

      test('encodes cross-block selection', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(
              id: 'a',
              blockType: BlockType.h1,
              segments: [const StyledSegment('Title')],
            ),
            TextBlock(
              id: 'b',
              blockType: BlockType.paragraph,
              segments: [const StyledSegment('Body')],
            ),
          ]),
        );
        // Select all: "Title\nBody" = 10 chars (no spacer — paragraph has spacingBefore: 0).
        controller.value = controller.value.copyWith(
          selection: TextSelection(
            baseOffset: 0,
            extentOffset: controller.text.length,
          ),
        );
        final md = controller.encodeSelection();
        expect(md, contains('# Title'));
        expect(md, contains('Body'));
      });

      test('returns null for collapsed cursor', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(
              id: 'a',
              blockType: BlockType.paragraph,
              segments: [const StyledSegment('hello')],
            ),
          ]),
        );
        expect(controller.encodeSelection(), isNull);
      });
    });

    group('paste markdown', () {
      test('pasting bold markdown preserves formatting', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(
              id: 'a',
              blockType: BlockType.paragraph,
              segments: [const StyledSegment('before after')],
            ),
          ]),
        );
        // Simulate paste of "**bold**" at offset 7 (between "before " and "after").
        controller.value = controller.value.copyWith(
          selection: const TextSelection.collapsed(offset: 7),
        );
        // Simulate the paste by setting value as if Flutter inserted the text.
        controller.value = const TextEditingValue(
          text: 'before **bold**after',
          selection: TextSelection.collapsed(offset: 15),
        );
        // The paste heuristic should decode **bold** as bold.
        final segs = controller.document.allBlocks[0].segments;
        expect(
          segs.any(
            (s) => s.text == 'bold' && s.styles.contains(InlineStyle.bold),
          ),
          isTrue,
          reason: 'Pasted **bold** should be decoded as bold text',
        );
      });

      test('pasting heading markdown creates H1 block', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(
              id: 'a',
              blockType: BlockType.paragraph,
              segments: [const StyledSegment('existing')],
            ),
          ]),
        );
        controller.value = controller.value.copyWith(
          selection: const TextSelection.collapsed(offset: 8),
        );
        // Paste "# Heading\n\nParagraph" — should create blocks.
        controller.value = TextEditingValue(
          text: 'existing# Heading\n\nParagraph',
          selection: const TextSelection.collapsed(offset: 28),
        );
        // Should have multiple blocks with heading type.
        expect(controller.document.allBlocks.length, greaterThanOrEqualTo(2));
      });

      test('pasting on empty paragraph preserves block types correctly', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document.empty(BlockType.paragraph),
        );
        // Paste markdown with mixed block types.
        final md = '# Title\n\nParagraph\n\n- List item';
        controller.value = TextEditingValue(
          text: '\u200B', // empty block placeholder
          selection: const TextSelection.collapsed(offset: 0),
        );
        controller.value = TextEditingValue(
          text: md,
          selection: TextSelection.collapsed(offset: md.length),
        );
        final blocks = controller.document.allBlocks;
        expect(blocks.length, greaterThanOrEqualTo(3));
        // First block should be h1.
        expect(blocks[0].blockType, BlockType.h1);
        // Should have a list item somewhere.
        expect(blocks.any((b) => b.blockType == BlockType.listItem), isTrue);
      });

      test('paste on heading does not make everything a heading', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(
              id: 'a',
              blockType: BlockType.h1,
              segments: [const StyledSegment('Title')],
            ),
          ]),
        );
        // Cursor at end of heading.
        controller.value = controller.value.copyWith(
          selection: const TextSelection.collapsed(offset: 5),
        );
        // Paste "plain\n\nparagraph" after the heading.
        final pasteText = 'plain\n\nparagraph';
        controller.value = TextEditingValue(
          text: 'Title$pasteText',
          selection: TextSelection.collapsed(offset: 5 + pasteText.length),
        );
        // The pasted paragraphs should NOT be headings.
        final blocks = controller.document.allBlocks;
        expect(blocks.length, greaterThanOrEqualTo(2));
        // At least one block after the heading should be paragraph.
        final nonHeadings = blocks.where(
          (b) => b.blockType == BlockType.paragraph,
        );
        expect(
          nonHeadings.isNotEmpty,
          isTrue,
          reason: 'Pasted blocks should not all inherit heading type',
        );
      });
    });

    group('canIndent / canOutdent', () {
      test('canIndent true for list item with previous sibling', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(
              id: 'a',
              blockType: BlockType.listItem,
              segments: [const StyledSegment('first')],
            ),
            TextBlock(
              id: 'b',
              blockType: BlockType.listItem,
              segments: [const StyledSegment('second')],
            ),
          ]),
        );
        // Cursor on second list item.
        controller.value = controller.value.copyWith(
          selection: TextSelection.collapsed(
            offset: controller.text.length,
          ), // end of second
        );
        expect(controller.canIndent, isTrue);
        expect(controller.canOutdent, isFalse); // root level
      });

      test('canIndent false for heading', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(
              id: 'a',
              blockType: BlockType.h1,
              segments: [const StyledSegment('Title')],
            ),
          ]),
        );
        expect(controller.canIndent, isFalse);
      });

      test('canOutdent true for nested block', () {
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
        // Cursor on nested child.
        controller.value = controller.value.copyWith(
          selection: TextSelection.collapsed(offset: controller.text.length),
        );
        expect(controller.canOutdent, isTrue);
      });
    });

    group('canSetBlockType', () {
      test('returns true for valid conversion', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(
              id: 'a',
              blockType: BlockType.paragraph,
              segments: [const StyledSegment('hello')],
            ),
          ]),
        );
        expect(controller.canSetBlockType(BlockType.h1), isTrue);
        expect(controller.canSetBlockType(BlockType.listItem), isTrue);
      });

      test('returns false for void types', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(
              id: 'a',
              blockType: BlockType.paragraph,
              segments: [const StyledSegment('hello')],
            ),
          ]),
        );
        expect(controller.canSetBlockType(BlockType.divider), isFalse);
      });

      test('returns false for heading on nested block', () {
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
                  blockType: BlockType.paragraph,
                  segments: [const StyledSegment('child')],
                ),
              ],
            ),
          ]),
        );
        // Cursor on nested child.
        controller.value = controller.value.copyWith(
          selection: TextSelection.collapsed(offset: controller.text.length),
        );
        expect(controller.canSetBlockType(BlockType.h1), isFalse);
        expect(controller.canSetBlockType(BlockType.paragraph), isTrue);
      });
    });

    group('insertDivider', () {
      test('inserts divider at cursor and creates paragraph after', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(
              id: 'a',
              blockType: BlockType.paragraph,
              segments: [const StyledSegment('hello world')],
            ),
          ]),
        );
        // Cursor at offset 5 ("hello|")
        controller.value = controller.value.copyWith(
          selection: const TextSelection.collapsed(offset: 5),
        );
        controller.insertDivider();

        final blocks = controller.document.allBlocks;
        expect(blocks.length, 3);
        expect(blocks[0].plainText, 'hello');
        expect(blocks[1].blockType, BlockType.divider);
        expect(blocks[2].plainText, ' world');
      });

      test('canInsertDivider false on void block', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(id: 'a', blockType: BlockType.divider),
            TextBlock(
              id: 'b',
              blockType: BlockType.paragraph,
              segments: [const StyledSegment('after')],
            ),
          ]),
        );
        // Cursor pushed to after divider prefix, but model is on divider.
        expect(controller.canInsertDivider, isTrue); // cursor lands on 'after'
      });

      test('canInsertDivider false on nested block', () {
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
        controller.value = controller.value.copyWith(
          selection: TextSelection.collapsed(offset: controller.text.length),
        );
        expect(controller.canInsertDivider, isFalse);
      });
    });

    group('Tab indent', () {
      test('Tab indents a list item under its previous sibling', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(id: 'a', blockType: BlockType.listItem, segments: [const StyledSegment('first')]),
            TextBlock(id: 'b', blockType: BlockType.listItem, segments: [const StyledSegment('second')]),
          ]),
        );

        // Place cursor in the second list item "second".
        // Display: "• first\n• second" — find the offset of 'second'.
        final secondStart = controller.text.indexOf('second');
        controller.value = controller.value.copyWith(
          selection: TextSelection.collapsed(offset: secondStart),
        );

        // Simulate Tab key: insert \t at cursor position.
        final before = controller.text;
        controller.value = controller.value.copyWith(
          text: before.substring(0, secondStart) + '\t' + before.substring(secondStart),
          selection: TextSelection.collapsed(offset: secondStart + 1),
        );

        // "second" should now be nested under "first".
        expect(controller.document.blocks.length, 1);
        expect(controller.document.blocks[0].children.length, 1);
        expect(controller.document.blocks[0].children[0].plainText, 'second');
      });

      test('Tab does nothing for first block (no previous sibling)', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(id: 'a', blockType: BlockType.listItem, segments: [const StyledSegment('only')]),
          ]),
        );

        final cursorPos = controller.text.indexOf('only');
        controller.value = controller.value.copyWith(
          selection: TextSelection.collapsed(offset: cursorPos),
        );

        final before = controller.text;
        controller.value = controller.value.copyWith(
          text: before.substring(0, cursorPos) + '\t' + before.substring(cursorPos),
          selection: TextSelection.collapsed(offset: cursorPos + 1),
        );

        // Still one root block, no nesting.
        expect(controller.document.blocks.length, 1);
        expect(controller.document.blocks[0].children, isEmpty);
      });
    });

    group('Paste cursor', () {
      test('cursor lands at end of pasted markdown content', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document.empty(BlockType.paragraph),
        );
        controller.value = controller.value.copyWith(
          selection: const TextSelection.collapsed(offset: 0),
        );

        // Paste markdown with heading + paragraph.
        const pastedText = '# Title\n\nBody text';
        controller.value = TextEditingValue(
          text: pastedText,
          selection: TextSelection.collapsed(offset: pastedText.length),
        );

        // Should have at least 2 blocks.
        expect(controller.document.allBlocks.length, greaterThanOrEqualTo(2));

        // The cursor (model space) should be at the end of the pasted content.
        final modelCursor = controller.displayToModel(
          controller.value.selection.baseOffset,
        );
        expect(modelCursor, controller.document.plainText.length);
      });
    });

    group('Cut from block start', () {
      test('cutting from start of heading resets to paragraph', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(id: 'a', blockType: BlockType.h1, segments: [const StyledSegment('Title')]),
          ]),
        );

        // Select "Titl" (from start, not all).
        // Display text includes the spacer before h1.
        // Find the offset of 'T' in display text.
        final tStart = controller.text.indexOf('T');
        final lEnd = controller.text.indexOf('l') + 1;
        controller.value = controller.value.copyWith(
          selection: TextSelection(baseOffset: tStart, extentOffset: lEnd),
        );

        // Simulate cut: replace selection with empty.
        controller.value = controller.value.copyWith(
          text: controller.text.substring(0, tStart) + controller.text.substring(lEnd),
          selection: TextSelection.collapsed(offset: tStart),
        );

        // Block should be converted to paragraph with remaining text "e".
        expect(controller.document.allBlocks.first.blockType, BlockType.paragraph);
        expect(controller.document.allBlocks.first.plainText, 'e');
      });

      test('cutting mid-block does NOT reset heading', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(id: 'a', blockType: BlockType.h1, segments: [const StyledSegment('Title')]),
          ]),
        );

        // Select "itl" (not from start).
        final iStart = controller.text.indexOf('i');
        final lEnd = controller.text.indexOf('l') + 1;
        controller.value = controller.value.copyWith(
          selection: TextSelection(baseOffset: iStart, extentOffset: lEnd),
        );

        // Simulate cut: replace selection with empty.
        controller.value = controller.value.copyWith(
          text: controller.text.substring(0, iStart) + controller.text.substring(lEnd),
          selection: TextSelection.collapsed(offset: iStart),
        );

        // Block should remain h1 — not cutting from start.
        expect(controller.document.allBlocks.first.blockType, BlockType.h1);
        expect(controller.document.allBlocks.first.plainText, 'Te');
      });

      test('cutting from start of list item resets to paragraph', () {
        final controller = EditorController(
          schema: EditorSchema.standard(),
          document: Document([
            TextBlock(id: 'a', blockType: BlockType.listItem, segments: [const StyledSegment('item')]),
          ]),
        );

        // Select "ite" from start (after prefix).
        final iStart = controller.text.indexOf('i');
        final eEnd = controller.text.indexOf('e') + 1;
        controller.value = controller.value.copyWith(
          selection: TextSelection(baseOffset: iStart, extentOffset: eEnd),
        );

        controller.value = controller.value.copyWith(
          text: controller.text.substring(0, iStart) + controller.text.substring(eEnd),
          selection: TextSelection.collapsed(offset: iStart),
        );

        expect(controller.document.allBlocks.first.blockType, BlockType.paragraph);
        expect(controller.document.allBlocks.first.plainText, 'm');
      });
    });
  });
}

// -- Test helpers --

class _MockBuildContext extends Fake implements BuildContext {}

/// Recursively find a TextSpan with the given text content.
TextSpan? _findSpanWithText(InlineSpan root, String text) {
  if (root is TextSpan) {
    if (root.text == text) return root;
    if (root.children != null) {
      for (final child in root.children!) {
        final found = _findSpanWithText(child, text);
        if (found != null) return found;
      }
    }
  }
  return null;
}
