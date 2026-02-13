import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EditorController', () {
    test('bold rule fires and cursor lands correctly via controller', () {
      final controller = EditorController(
        document: Document([
          TextBlock(id: 'a', segments: [const StyledSegment('abc **trigger*')]),
        ]),
        inputRules: [BoldWrapRule()],
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
        document: Document([
          TextBlock(
            id: 'a',
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
        document: Document([
          TextBlock(
            id: 'a',
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
      Set<InlineStyle>? styleAtInsert;
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
        document: Document([
          TextBlock(
            id: 'a',
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
        document: Document([
          TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
          TextBlock(id: 'b', segments: [const StyledSegment('world')]),
        ]),
      );

      expect(controller.text, 'hello\nworld');

      // Cursor at start of "world" (offset 6), press backspace — removes the \n.
      controller.value = const TextEditingValue(
        text: 'helloworld',
        selection: TextSelection.collapsed(offset: 5),
      );

      expect(controller.document.blocks.length, 1);
      expect(controller.document.blocks[0].plainText, 'helloworld');
    });

    test('Bold rule at start of block', () {
      final controller = EditorController(
        document: Document([
          TextBlock(id: 'a', segments: [const StyledSegment('**hello*')]),
        ]),
        inputRules: [BoldWrapRule()],
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
        document: Document([
          TextBlock(
            id: 'a',
            segments: [const StyledSegment('**one** and **two*')],
          ),
        ]),
        inputRules: [BoldWrapRule()],
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
        document: Document([
          TextBlock(
            id: 'a',
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
        document: Document([TextBlock(id: 'a', segments: const [])]),
        inputRules: [
          HeadingRule(),
          ListItemRule(),
          EmptyListItemRule(),
          BoldWrapRule(),
        ],
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
        document: Document([TextBlock(id: 'a', segments: const [])]),
        inputRules: [
          HeadingRule(),
          ListItemRule(),
          EmptyListItemRule(),
          BoldWrapRule(),
        ],
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
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.h1,
            segments: [const StyledSegment('Title')],
          ),
          TextBlock(id: 'b', segments: [const StyledSegment('paragraph')]),
        ]),
        inputRules: [HeadingRule(), ListItemRule(), EmptyListItemRule()],
      );

      // "Title\nparagraph" — cursor at end of "Title" (offset 5).
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
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.h1,
            segments: [const StyledSegment('Title')],
          ),
        ]),
        inputRules: [HeadingRule(), ListItemRule(), EmptyListItemRule()],
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
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.listItem,
            segments: [const StyledSegment('first')],
          ),
        ]),
        inputRules: [HeadingRule(), ListItemRule(), EmptyListItemRule()],
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
        document: Document([
          TextBlock(id: 'a', blockType: BlockType.listItem, segments: const []),
        ]),
        inputRules: [HeadingRule(), ListItemRule(), EmptyListItemRule()],
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
        inputRules: [
          HeadingRule(),
          ListItemRule(),
          EmptyListItemRule(),
          ListItemBackspaceRule(),
          BoldWrapRule(),
        ],
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
        document: Document([
          TextBlock(id: 'a', segments: [const StyledSegment('above')]),
          TextBlock(id: 'b', blockType: BlockType.listItem, segments: const []),
        ]),
        inputRules: [
          HeadingRule(),
          ListItemRule(),
          EmptyListItemRule(),
          ListItemBackspaceRule(),
          BoldWrapRule(),
        ],
      );

      // Display: "above\n\uFFFC" — empty list item with prefix.
      expect(controller.text, 'above\n\uFFFC');

      controller.value = const TextEditingValue(
        text: 'above\n\uFFFC',
        selection: TextSelection.collapsed(offset: 7),
      );

      // Backspace removes the \n\uFFFC — Flutter sends "above" with cursor at 5.
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
        inputRules: [HeadingRule(), ListItemRule(), EmptyListItemRule(), ListItemBackspaceRule(), NestedBackspaceRule(), BoldWrapRule()],
      );

      // Step 1: backspace on nested "boss" → should outdent to root.
      var displayText = controller.text;
      var bossStart = displayText.indexOf('boss');
      controller.value = TextEditingValue(
        text: '${displayText.substring(0, bossStart - 1)}${displayText.substring(bossStart)}',
        selection: TextSelection.collapsed(offset: bossStart - 1),
      );

      // "boss" should now be at root level, sibling after "hello".
      expect(controller.document.blocks.length, 2);
      expect(controller.document.blocks[1].plainText, 'boss');

      // Step 2: backspace on root "boss" → should merge into "helloboss".
      displayText = controller.text;
      bossStart = displayText.indexOf('boss');
      controller.value = TextEditingValue(
        text: '${displayText.substring(0, bossStart - 1)}${displayText.substring(bossStart)}',
        selection: TextSelection.collapsed(offset: bossStart - 1),
      );

      expect(controller.document.allBlocks.length, 1);
      expect(controller.document.allBlocks[0].plainText, 'helloboss');
    });

    test('backspace on nested paragraph outdents instead of merging', () {
      final controller = EditorController(
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
        inputRules: [HeadingRule(), ListItemRule(), EmptyListItemRule(), ListItemBackspaceRule(), NestedBackspaceRule(), BoldWrapRule()],
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
        document: Document([
          TextBlock(
            id: 'b1',
            segments: [
              const StyledSegment('Hello '),
              const StyledSegment('bold world', {InlineStyle.bold}),
              const StyledSegment('! This is the POC.'),
            ],
          ),
          TextBlock(
            id: 'b2',
            segments: [
              const StyledSegment(
                'Type two asterisks, then text, then two more asterisks to **trigger* bold.',
              ),
            ],
          ),
        ]),
        inputRules: [BoldWrapRule()],
      );

      // Block 0 text: "Hello bold world! This is the POC." (34 chars)
      // Block 1 text: "...to **trigger* bold."
      // Full text: block0 + \n + block1
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
  });
}
