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

    test('select within block and delete', () {
      final controller = EditorController(
        document: Document([
          TextBlock(id: 'a', segments: [const StyledSegment('hello world')]),
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
        document: Document([
          TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
          TextBlock(id: 'b', segments: [const StyledSegment('world')]),
        ]),
        undoGrouping: (_, __) => false,
      );

      // Initial display text: 'hello\nworld' (no prefixes — paragraphs).
      // Select from offset 3 ('hel|lo') to offset 8 ('wor|ld') and delete.
      // Deleted: 'lo\nwor' (6 chars), result: 'helld'.
      controller.value = const TextEditingValue(
        text: 'helld',
        selection: TextSelection.collapsed(offset: 3),
      );

      expect(controller.document.allBlocks.length, 1);
      expect(controller.document.allBlocks[0].plainText, 'helld');
    });

    test('select across blocks and type character (replace)', () {
      final controller = EditorController(
        document: Document([
          TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
          TextBlock(id: 'b', segments: [const StyledSegment('world')]),
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
        document: Document([
          TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
          TextBlock(id: 'b', segments: [const StyledSegment('world')]),
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
        document: Document([
          TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
          TextBlock(id: 'b', segments: [const StyledSegment('world')]),
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
        document: Document([
          TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
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
        document: Document([
          TextBlock(id: 'a', segments: [const StyledSegment('hello world')]),
        ]),
      );

      // Select 'world' (offset 6..11).
      controller.value = const TextEditingValue(
        text: 'hello world',
        selection: TextSelection(baseOffset: 6, extentOffset: 11),
      );

      controller.toggleStyle(InlineStyle.italic);
      expect(
        controller.document.allBlocks[0].segments
            .any((s) => s.text == 'world' && s.styles.contains(InlineStyle.italic)),
        isTrue,
      );
    });

    test('toggleStyle with selection updates activeStyles before notify', () {
      // Regression: activeStyles must be updated BEFORE _syncToTextField
      // triggers notifyListeners, so the toolbar sees the new state.
      final controller = EditorController(
        document: Document([
          TextBlock(id: 'a', segments: [const StyledSegment('hello world')]),
        ]),
      );

      // Select 'world' (offset 6..11).
      controller.value = const TextEditingValue(
        text: 'hello world',
        selection: TextSelection(baseOffset: 6, extentOffset: 11),
      );

      // Record activeStyles at the moment notifyListeners fires from toggleStyle.
      // Register AFTER the setup value-set to avoid capturing that notification.
      Set<InlineStyle>? stylesAtNotify;
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
        document: Document([
          TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
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
        document: Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.h1,
            segments: [const StyledSegment('title')],
          ),
          TextBlock(id: 'b', segments: [const StyledSegment('body')]),
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
        document: Document([
          TextBlock(id: 'a', segments: [
            const StyledSegment('hello ', {}),
            const StyledSegment('bold', {InlineStyle.bold}),
            const StyledSegment(' world', {}),
          ]),
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
        document: Document([
          TextBlock(id: 'a', segments: [
            const StyledSegment('hello ', {}),
            const StyledSegment('bold', {InlineStyle.bold}),
            const StyledSegment(' world', {}),
          ]),
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
          document: Document([
            TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
            TextBlock(
              id: 'b',
              blockType: BlockType.listItem,
              segments: [const StyledSegment('item')],
            ),
          ]),
        );

        // Display: "hello\n\uFFFCitem" — 11 chars
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

        // During composing, document should be UNCHANGED.
        expect(controller.document.allBlocks.length, 2,
            reason: 'block count must not change during composing');
        expect(controller.document.allBlocks[0].plainText, 'hello',
            reason: 'first block must not change during composing');

        // Step 2: User presses E to complete the diacritic.
        // Flutter resolves composing: replaces the ´ with é.
        controller.value = TextEditingValue(
          text: 'helloé\n\uFFFCitem',
          selection: const TextSelection.collapsed(offset: 6),
          composing: TextRange.empty,
        );

        // Document should have 2 blocks, first block is "helloé".
        expect(controller.document.allBlocks.length, 2,
            reason: 'block count must stay 2 after composing resolves');
        expect(controller.document.allBlocks[0].plainText, 'helloé');
        expect(controller.document.allBlocks[1].plainText, 'item');
      });

      test('diacritic mid-word composes in place', () {
        final controller = EditorController(
          document: Document([
            TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
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

        // Document unchanged during composing.
        expect(controller.document.blocks[0].plainText, 'hello',
            reason: 'document unchanged during composing');

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

        expect(controller.document.allBlocks[0].plainText, 'cafe',
            reason: 'model unchanged during composing');

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
          document: Document([
            TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
          ]),
        );

        // Step 1: Dead key starts composing.
        controller.value = const TextEditingValue(
          text: 'hello\u0301',
          selection: TextSelection.collapsed(offset: 6),
          composing: TextRange(start: 5, end: 6),
        );

        expect(controller.document.blocks[0].plainText, 'hello');

        // Step 2: User presses Escape or another key that cancels composing.
        // Flutter removes the placeholder, text goes back to "hello".
        controller.value = const TextEditingValue(
          text: 'hello',
          selection: TextSelection.collapsed(offset: 5),
          composing: TextRange.empty,
        );

        expect(controller.document.blocks[0].plainText, 'hello',
            reason: 'document unchanged after cancelled composing');
      });

      test('multi-step composing resolves correctly', () {
        // Simulates CJK-style input where composing text changes multiple
        // times before resolving.
        final controller = EditorController(
          document: Document([
            TextBlock(id: 'a', segments: [const StyledSegment('ab')]),
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
        expect(controller.document.blocks[0].plainText, 'ab');

        // Step 2: Composing text changes (user picks different candidate).
        controller.value = const TextEditingValue(
          text: 'abxy',
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange(start: 2, end: 4),
        );
        expect(controller.document.blocks[0].plainText, 'ab');

        // Step 3: Resolve.
        controller.value = const TextEditingValue(
          text: 'abZ',
          selection: TextSelection.collapsed(offset: 3),
          composing: TextRange.empty,
        );
        expect(controller.document.blocks[0].plainText, 'abZ');
      });
    });
  });
}
