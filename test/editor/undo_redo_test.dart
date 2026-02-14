import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UndoManager', () {
    test('push and undo returns the snapshot', () {
      final manager = UndoManager(grouping: (_, __) => false);
      final doc = Document([
        TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('hello')]),
      ]);
      final entry = UndoEntry(
        document: doc,
        selection: const TextSelection.collapsed(offset: 0),
        timestamp: DateTime.now(),
      );

      manager.push(entry);
      expect(manager.canUndo, isTrue);

      final popped = manager.undo();
      expect(popped, isNotNull);
      expect(popped!.document.allBlocks[0].plainText, 'hello');
      expect(manager.canUndo, isFalse);
    });

    test('redo returns null when empty', () {
      final manager = UndoManager();
      expect(manager.redo(), isNull);
      expect(manager.canRedo, isFalse);
    });

    test('push clears redo stack', () {
      final manager = UndoManager(grouping: (_, __) => false);
      final now = DateTime.now();
      final entry1 = UndoEntry(
        document: Document.empty(BlockType.paragraph),
        selection: const TextSelection.collapsed(offset: 0),
        timestamp: now,
      );
      final entry2 = UndoEntry(
        document: Document.empty(BlockType.paragraph),
        selection: const TextSelection.collapsed(offset: 0),
        timestamp: now.add(const Duration(seconds: 1)),
      );

      manager.push(entry1);
      manager.push(entry2);

      // Undo to get an entry on the redo stack.
      manager.undo();
      manager.pushRedo(UndoEntry(
        document: Document.empty(BlockType.paragraph),
        selection: const TextSelection.collapsed(offset: 0),
        timestamp: now,
      ));
      expect(manager.canRedo, isTrue);

      // New push should clear redo.
      manager.push(UndoEntry(
        document: Document.empty(BlockType.paragraph),
        selection: const TextSelection.collapsed(offset: 0),
        timestamp: now.add(const Duration(seconds: 2)),
      ));
      expect(manager.canRedo, isFalse);
    });

    test('time-based grouping merges fast edits', () {
      final manager = UndoManager(); // default 300ms grouping
      final now = DateTime.now();

      manager.push(UndoEntry(
        document: Document.empty(BlockType.paragraph),
        selection: const TextSelection.collapsed(offset: 0),
        timestamp: now,
      ));

      // Push within 300ms — should group (not add new entry).
      manager.push(UndoEntry(
        document: Document.empty(BlockType.paragraph),
        selection: const TextSelection.collapsed(offset: 1),
        timestamp: now.add(const Duration(milliseconds: 100)),
      ));

      // Only one entry on the stack.
      expect(manager.canUndo, isTrue);
      manager.undo();
      expect(manager.canUndo, isFalse);
    });

    test('time-based grouping separates slow edits', () {
      final manager = UndoManager(); // default 300ms grouping
      final now = DateTime.now();

      manager.push(UndoEntry(
        document: Document.empty(BlockType.paragraph),
        selection: const TextSelection.collapsed(offset: 0),
        timestamp: now,
      ));

      // Push after 500ms — should NOT group.
      manager.push(UndoEntry(
        document: Document.empty(BlockType.paragraph),
        selection: const TextSelection.collapsed(offset: 1),
        timestamp: now.add(const Duration(milliseconds: 500)),
      ));

      // Two entries on the stack.
      expect(manager.canUndo, isTrue);
      manager.undo();
      expect(manager.canUndo, isTrue);
      manager.undo();
      expect(manager.canUndo, isFalse);
    });

    test('max stack size drops oldest', () {
      final manager = UndoManager(
        grouping: (_, __) => false,
        maxStackSize: 3,
      );

      for (var i = 0; i < 5; i++) {
        manager.push(UndoEntry(
          document: Document([
            TextBlock(id: 'b$i', blockType: BlockType.paragraph, segments: [StyledSegment('text $i')]),
          ]),
          selection: const TextSelection.collapsed(offset: 0),
          timestamp: DateTime.now().add(Duration(seconds: i)),
        ));
      }

      // Only 3 entries remain (entries 2, 3, 4).
      var count = 0;
      while (manager.canUndo) {
        manager.undo();
        count++;
      }
      expect(count, 3);
    });

    test('custom grouping callback works', () {
      // Never group — every push creates a new entry.
      final manager = UndoManager(grouping: (_, __) => false);
      final now = DateTime.now();

      manager.push(UndoEntry(
        document: Document.empty(BlockType.paragraph),
        selection: const TextSelection.collapsed(offset: 0),
        timestamp: now,
      ));
      manager.push(UndoEntry(
        document: Document.empty(BlockType.paragraph),
        selection: const TextSelection.collapsed(offset: 0),
        timestamp: now, // Same timestamp but grouping says false.
      ));

      // Two entries.
      manager.undo();
      expect(manager.canUndo, isTrue);
    });
  });

  group('EditorController undo/redo', () {
    test('type text then undo restores, redo re-applies', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('hello')]),
        ]),
        // Disable grouping so each edit is a separate undo step.
        undoGrouping: (_, __) => false,
      );

      // Type ' world' at the end.
      controller.value = const TextEditingValue(
        text: 'hello world',
        selection: TextSelection.collapsed(offset: 11),
      );
      expect(controller.document.allBlocks[0].plainText, 'hello world');

      // Undo — back to 'hello'.
      controller.undo();
      expect(controller.document.allBlocks[0].plainText, 'hello');

      // Redo — back to 'hello world'.
      controller.redo();
      expect(controller.document.allBlocks[0].plainText, 'hello world');
    });

    test('undo after block type change restores paragraph', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('#')]),
        ]),
        undoGrouping: (_, __) => false,
      );

      // Type space after '#' to trigger heading rule.
      controller.value = const TextEditingValue(
        text: '# ',
        selection: TextSelection.collapsed(offset: 2),
      );
      expect(controller.document.allBlocks[0].blockType, BlockType.h1);

      // Undo — should restore paragraph with '# ' or '#'.
      controller.undo();
      expect(controller.document.allBlocks[0].blockType, BlockType.paragraph);
    });

    test('undo after indent restores flat structure', () {
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
        undoGrouping: (_, __) => false,
      );

      // Move cursor to second block (past 'first\n' = offset 6, +1 for prefix = 7).
      // Display: '\uFFFCfirst\n\uFFFCsecond'
      //           0     1-5  6  7     8-13
      controller.value = TextEditingValue(
        text: controller.text,
        selection: const TextSelection.collapsed(offset: 8),
      );

      // Indent the second block.
      controller.indent();
      expect(controller.document.depthOf(1), 1);

      // Undo — flat again.
      controller.undo();
      expect(controller.document.depthOf(1), 0);
    });

    test('redo stack clears on new edit after undo', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('abc')]),
        ]),
        undoGrouping: (_, __) => false,
      );

      // Type 'd'.
      controller.value = const TextEditingValue(
        text: 'abcd',
        selection: TextSelection.collapsed(offset: 4),
      );

      // Undo.
      controller.undo();
      expect(controller.canRedo, isTrue);

      // New edit — should clear redo.
      controller.value = const TextEditingValue(
        text: 'abcx',
        selection: TextSelection.collapsed(offset: 4),
      );
      expect(controller.canRedo, isFalse);
    });

    test('canUndo and canRedo reflect stack state', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('hi')]),
        ]),
        undoGrouping: (_, __) => false,
      );

      expect(controller.canUndo, isFalse);
      expect(controller.canRedo, isFalse);

      // Make an edit.
      controller.value = const TextEditingValue(
        text: 'hi!',
        selection: TextSelection.collapsed(offset: 3),
      );
      expect(controller.canUndo, isTrue);
      expect(controller.canRedo, isFalse);

      // Undo.
      controller.undo();
      expect(controller.canUndo, isFalse);
      expect(controller.canRedo, isTrue);

      // Redo.
      controller.redo();
      expect(controller.canUndo, isTrue);
      expect(controller.canRedo, isFalse);
    });

    test('undo on empty stack is a no-op', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('hello')]),
        ]),
      );

      // Should not throw or change anything.
      controller.undo();
      expect(controller.document.allBlocks[0].plainText, 'hello');
    });

    test('undo restores cursor to pre-edit position', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('hello')]),
        ]),
        undoGrouping: (_, __) => false,
      );

      // Cursor starts at end of 'hello' (offset 5).
      controller.value = const TextEditingValue(
        text: 'hello',
        selection: TextSelection.collapsed(offset: 5),
      );

      // Type ' world' — cursor moves to 11.
      controller.value = const TextEditingValue(
        text: 'hello world',
        selection: TextSelection.collapsed(offset: 11),
      );
      expect(controller.document.allBlocks[0].plainText, 'hello world');

      // Undo — cursor should go back to 5 (where it was before typing ' world'),
      // not stay at 11.
      controller.undo();
      expect(controller.document.allBlocks[0].plainText, 'hello');
      expect(controller.value.selection.baseOffset, 5);
    });

    test('undo after Enter restores cursor to pre-split position', () {
      final controller = EditorController(
        schema: EditorSchema.standard(),
        document: Document([
          TextBlock(id: 'a', blockType: BlockType.paragraph, segments: [const StyledSegment('helloworld')]),
        ]),
        undoGrouping: (_, __) => false,
      );

      // Place cursor at offset 5 (between 'hello' and 'world').
      controller.value = const TextEditingValue(
        text: 'helloworld',
        selection: TextSelection.collapsed(offset: 5),
      );

      // Press Enter — splits into 'hello' and 'world'.
      controller.value = const TextEditingValue(
        text: 'hello\nworld',
        selection: TextSelection.collapsed(offset: 6),
      );
      expect(controller.document.allBlocks.length, 2);

      // Undo — should restore to one block with cursor at 5.
      controller.undo();
      expect(controller.document.allBlocks.length, 1);
      expect(controller.document.allBlocks[0].plainText, 'helloworld');
      expect(controller.value.selection.baseOffset, 5);
    });
  });
}
