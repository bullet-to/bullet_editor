import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter_test/flutter_test.dart';

/// Day 3–4 controller skeleton suite (architecture plan row 3–4): batch loop
/// + missing-id rejection, setSelection normalization, setDocument,
/// undo/redo, the editing verbs, and the G13 group-gate invariant tests.
/// Command-level scenarios are adapted from the v2 crown-jewel suite
/// (test_archive/adapt_later/editor_controller_test.dart).
void main() {
  final schema = EditorSchema.standard();

  TextBlock para(
    String id,
    String text, {
    List<TextBlock> children = const [],
  }) => TextBlock(
    id: id,
    blockType: ParagraphKeys.type,
    segments: [StyledSegment(text)],
    children: children,
  );

  TextBlock typed(
    String id,
    String type,
    String text, {
    List<TextBlock> children = const [],
    Map<String, dynamic> metadata = const {},
  }) => TextBlock(
    id: id,
    blockType: type,
    segments: [StyledSegment(text)],
    children: children,
    metadata: metadata,
  );

  EditorController controller(
    List<TextBlock> blocks, {
    ShouldGroupUndo? grouping,
  }) => EditorController(
    document: Document(blocks),
    schema: schema,
    // Deterministic undo by default: every batch is its own entry.
    undoGrouping: grouping ?? (previous, current) => false,
  );

  DocSelection caret(String blockId, int offset) =>
      DocSelection.collapsed(DocPosition(blockId, offset));

  /// Tree shape as nested (id, type) pairs for identity assertions.
  List<(String, int)> shape(Document doc) => [
    for (var i = 0; i < doc.allBlocks.length; i++)
      (doc.allBlocks[i].id, doc.depthOf(i)),
  ];

  group('batch loop / apply', () {
    test('applies a batch atomically and notifies once', () {
      final c = controller([para('a', 'hello')]);
      var notifications = 0;
      c.addListener(() => notifications++);

      final result = c.apply([
        InsertText('a', 5, ' world'),
        InsertText('a', 0, '> '),
      ]);

      expect(result, isA<EditApplied>());
      expect(c.document.blockById('a')!.plainText, '> hello world');
      expect(notifications, 1);
    });

    test('a gone id mid-batch rejects the WHOLE batch pre-commit', () {
      final c = controller([para('a', 'hello')]);
      var notifications = 0;
      c.addListener(() => notifications++);

      final result = c.apply([
        InsertText('a', 0, 'x'),
        InsertText('gone', 0, 'y'),
      ]);

      expect(result, isA<EditRejected>());
      expect((result as EditRejected).rejectedOp, isA<InsertText>());
      expect(
        c.document.blockById('a')!.plainText,
        'hello',
        reason: 'the first op must not have committed',
      );
      expect(c.canUndo, isFalse, reason: 'rejected batches push no undo');
      expect(notifications, 0);
    });

    test('op-gate: apply([IndentBlock(firstSibling), IndentBlock(next)]) '
        'rejects and leaves the tree unchanged', () {
      final c = controller([
        typed('a', ListItemKeys.type, 'one'),
        typed('b', ListItemKeys.type, 'two'),
      ]);
      final before = shape(c.document);

      final result = c.apply([IndentBlock('a'), IndentBlock('b')]);

      expect(result, isA<EditRejected>());
      expect(shape(c.document), before);
    });

    test('an empty batch commits nothing: no undo entry, redo intact', () {
      final c = controller([para('a', 'hello')]);
      c.setSelection(caret('a', 0));
      c.insertText('x');
      c.undo();
      expect(c.canRedo, isTrue);

      final result = c.apply(const []);

      expect(result, isA<EditApplied>());
      expect(c.canUndo, isFalse);
      expect(c.canRedo, isTrue, reason: 'an empty batch must not clear redo');
    });

    test('selectionAfter is honored and normalized', () {
      final c = controller([para('a', 'hi')]);
      c.apply(
        [InsertText('a', 2, '!')],
        selectionAfter: caret('a', 99), // beyond length → clamped
      );
      expect(c.selection, caret('a', 3));
    });

    test('without selectionAfter the current selection is revalidated', () {
      final c = controller([para('a', 'one'), para('b', 'two')]);
      c.setSelection(caret('b', 2));
      c.apply([RemoveBlock('b')]);
      expect(c.selection, isNull, reason: 'a gone id cannot be clamped');
    });
  });

  group('setSelection normalization', () {
    test('clamps text offsets to [0, block.length]', () {
      final c = controller([para('a', 'abc')]);
      c.setSelection(caret('a', 99));
      expect(c.selection, caret('a', 3));
    });

    test('rejects a selection naming a gone id (keeps the previous one)', () {
      final c = controller([para('a', 'abc')]);
      c.setSelection(caret('a', 1));
      c.setSelection(caret('nope', 0));
      expect(c.selection, caret('a', 1));
    });

    test(
      'a collapsed position on a void becomes the [0,1) atomic selection',
      () {
        final c = controller([
          para('a', 'x'),
          typed('img', ImageKeys.type, ''),
        ]);
        c.setSelection(caret('img', 0));
        expect(
          c.selection,
          DocSelection(
            base: DocPosition('img', 0),
            extent: DocPosition('img', 1),
          ),
        );
      },
    );

    test('void range endpoints clamp to [0, 1]', () {
      final c = controller([
        typed('img', ImageKeys.type, ''),
        para('a', 'xyz'),
      ]);
      c.setSelection(
        DocSelection(base: DocPosition('img', 5), extent: DocPosition('a', 2)),
      );
      expect(c.selection!.base, DocPosition('img', 1));
    });
  });

  group('setDocument', () {
    test('replaces the document, resets undo, normalizes the selection', () {
      final c = controller([para('a', 'old')]);
      c.setSelection(caret('a', 0));
      c.apply([InsertText('a', 0, 'x')]);
      expect(c.canUndo, isTrue);

      c.setDocument(Document([para('n', 'new')]), selection: caret('n', 9));

      expect(c.document.blockById('n'), isNotNull);
      expect(c.canUndo, isFalse);
      expect(c.canRedo, isFalse);
      expect(c.selection, caret('n', 3));
    });
  });

  group('undo / redo', () {
    test('undo restores document AND selection; redo round-trips', () {
      final c = controller([para('a', 'hello')]);
      c.setSelection(caret('a', 5));
      c.insertText('!');
      expect(c.document.blockById('a')!.plainText, 'hello!');
      expect(c.selection, caret('a', 6));

      c.undo();
      expect(c.document.blockById('a')!.plainText, 'hello');
      expect(c.selection, caret('a', 5));
      expect(c.canRedo, isTrue);

      c.redo();
      expect(c.document.blockById('a')!.plainText, 'hello!');
      expect(c.selection, caret('a', 6));
    });

    test('undo after a cross-block delete restores all blocks', () {
      final c = controller([
        para('a', 'one'),
        para('b', 'two'),
        para('c', 'three'),
      ]);
      c.setSelection(
        DocSelection(base: DocPosition('a', 1), extent: DocPosition('c', 2)),
      );
      c.deleteSelection();
      expect(c.document.allBlocks.length, 1);
      expect(c.document.blockById('a')!.plainText, 'oree');

      c.undo();
      expect(c.document.allBlocks.length, 3);
      expect(c.document.blockById('b')!.plainText, 'two');
      expect(c.selection!.extent, DocPosition('c', 2));
    });

    test('grouped edits undo as one entry', () {
      final c = controller(
        [para('a', '')],
        grouping: (previous, current) => true, // everything groups
      );
      c.setSelection(caret('a', 0));
      c.insertText('h');
      c.insertText('i');
      expect(c.document.blockById('a')!.plainText, 'hi');

      c.undo();
      expect(c.document.blockById('a')!.plainText, '');
      expect(c.canUndo, isFalse);
    });

    test('undo/redo with empty stacks are no-ops', () {
      final c = controller([para('a', 'x')]);
      var notifications = 0;
      c.addListener(() => notifications++);
      c.undo();
      c.redo();
      expect(notifications, 0);
    });
  });

  group('insertText', () {
    test('inserts at the caret and advances it', () {
      final c = controller([para('a', 'helo')]);
      c.setSelection(caret('a', 3));
      c.insertText('l');
      expect(c.document.blockById('a')!.plainText, 'hello');
      expect(c.selection, caret('a', 4));
    });

    test('replaces a same-block selection atomically', () {
      final c = controller([para('a', 'hello world')]);
      c.setSelection(
        DocSelection(base: DocPosition('a', 6), extent: DocPosition('a', 11)),
      );
      c.insertText('there');
      expect(c.document.blockById('a')!.plainText, 'hello there');
      expect(c.selection, caret('a', 11));
    });

    test('replaces a cross-block selection (one undo entry)', () {
      final c = controller([para('a', 'one'), para('b', 'two')]);
      c.setSelection(
        DocSelection(base: DocPosition('a', 2), extent: DocPosition('b', 1)),
      );
      c.insertText('X');
      expect(c.document.allBlocks.length, 1);
      expect(c.document.blockById('a')!.plainText, 'onXwo');
      expect(c.selection, caret('a', 3));

      c.undo();
      expect(c.document.allBlocks.length, 2);
    });

    test('typing over a selected void replaces it with a default block', () {
      final c = controller([
        para('a', 'above'),
        typed('img', ImageKeys.type, ''),
        para('b', 'below'),
      ]);
      c.setSelection(caret('img', 0)); // normalizes to atomic [0,1)
      c.insertText('hi');

      expect(c.document.blockById('img'), isNull);
      final blocks = c.document.allBlocks;
      expect(blocks.length, 3);
      expect(blocks[1].blockType, ParagraphKeys.type);
      expect(blocks[1].plainText, 'hi');
      expect(c.selection, caret(blocks[1].id, 2));
    });

    test('no selection is a no-op', () {
      final c = controller([para('a', 'x')]);
      c.insertText('y');
      expect(c.document.blockById('a')!.plainText, 'x');
    });
  });

  group('insertNewline', () {
    test('splits a paragraph and preserves styles on both halves', () {
      final c = EditorController(
        document: Document([
          TextBlock(
            id: 'a',
            blockType: ParagraphKeys.type,
            segments: [
              const StyledSegment('plain '),
              const StyledSegment('boldtext', {InlineStyleKeys.bold}),
            ],
          ),
        ]),
        schema: schema,
      );
      c.setSelection(caret('a', 10)); // 'plain bold|text'
      c.insertNewline();

      final blocks = c.document.allBlocks;
      expect(blocks.length, 2);
      expect(blocks[0].plainText, 'plain bold');
      expect(blocks[0].segments.last.styles, {InlineStyleKeys.bold});
      expect(blocks[1].plainText, 'text');
      expect(blocks[1].segments.first.styles, {InlineStyleKeys.bold});
      expect(c.selection, caret(blocks[1].id, 0));
    });

    test('on a heading the new block is a paragraph', () {
      final c = controller([typed('h', HeadingKeys.h1, 'Title')]);
      c.setSelection(caret('h', 5));
      c.insertNewline();
      expect(c.document.allBlocks[1].blockType, ParagraphKeys.type);
    });

    test('on a list item the new block inherits the type', () {
      final c = controller([typed('l', ListItemKeys.type, 'item')]);
      c.setSelection(caret('l', 4));
      c.insertNewline();
      expect(c.document.allBlocks[1].blockType, ListItemKeys.type);
    });

    test('on a task item the new block starts unchecked', () {
      final c = controller([
        typed(
          't',
          TaskItemKeys.type,
          'task',
          metadata: {TaskItemKeys.checked: true},
        ),
      ]);
      c.setSelection(caret('t', 4));
      c.insertNewline();
      final newBlock = c.document.allBlocks[1];
      expect(newBlock.blockType, TaskItemKeys.type);
      expect(newBlock.metadata[TaskItemKeys.checked], isFalse);
    });

    test('on a block quote the new block continues the quote', () {
      final c = controller([typed('q', BlockQuoteKeys.type, 'wise words')]);
      c.setSelection(caret('q', 10));
      c.insertNewline();
      expect(c.document.allBlocks[1].blockType, BlockQuoteKeys.type);
    });

    test('on an EMPTY block quote converts to a paragraph (the escape)', () {
      final c = controller([typed('q', BlockQuoteKeys.type, '')]);
      c.setSelection(caret('q', 0));
      c.insertNewline();
      expect(c.document.allBlocks.length, 1);
      expect(c.document.blockById('q')!.blockType, ParagraphKeys.type);
    });

    test(
      'on an EMPTY list item converts to a paragraph instead of splitting',
      () {
        final c = controller([typed('l', ListItemKeys.type, '')]);
        c.setSelection(caret('l', 0));
        c.insertNewline();
        expect(c.document.allBlocks.length, 1);
        expect(c.document.blockById('l')!.blockType, ParagraphKeys.type);
        expect(c.selection, caret('l', 0));
      },
    );

    test('at offset 0 of a non-empty block inserts an empty block above', () {
      final c = controller([para('a', 'text')]);
      c.setSelection(caret('a', 0));
      c.insertNewline();
      final blocks = c.document.allBlocks;
      expect(blocks.length, 2);
      expect(blocks[0].plainText, '');
      expect(blocks[1].id, 'a');
      expect(c.selection, caret('a', 0));
    });

    test('in a code block inserts \\n instead of splitting', () {
      final c = controller([typed('code', CodeBlockKeys.type, 'line one')]);
      c.setSelection(caret('code', 8));
      c.insertNewline();
      expect(c.document.allBlocks.length, 1);
      expect(c.document.blockById('code')!.plainText, 'line one\n');
      expect(c.selection, caret('code', 9));
    });

    test('with a selection, replaces it then splits', () {
      final c = controller([para('a', 'hello world')]);
      c.setSelection(
        DocSelection(base: DocPosition('a', 5), extent: DocPosition('a', 11)),
      );
      c.insertNewline();
      final blocks = c.document.allBlocks;
      expect(blocks.length, 2);
      expect(blocks[0].plainText, 'hello');
      expect(blocks[1].plainText, '');
      expect(c.selection, caret(blocks[1].id, 0));
    });
  });

  group('backspace', () {
    test('deletes one character mid-text', () {
      final c = controller([para('a', 'hello')]);
      c.setSelection(caret('a', 5));
      c.backspace();
      expect(c.document.blockById('a')!.plainText, 'hell');
      expect(c.selection, caret('a', 4));
    });

    test('deletes a whole grapheme cluster, never half a surrogate pair', () {
      const emoji = '👍'; // non-BMP: two UTF-16 code units, one grapheme
      final c = controller([para('e', 'x$emoji')]);
      c.setSelection(caret('e', 1 + emoji.length));
      c.backspace();
      expect(c.document.blockById('e')!.plainText, 'x');
      expect(c.selection, caret('e', 1));
    });

    test('at the start of a paragraph merges into the previous block', () {
      final c = controller([para('a', 'one'), para('b', 'two')]);
      c.setSelection(caret('b', 0));
      c.backspace();
      expect(c.document.allBlocks.length, 1);
      expect(c.document.blockById('a')!.plainText, 'onetwo');
      expect(c.selection, caret('a', 3));
    });

    test('at the start of a heading converts it to a paragraph', () {
      final c = controller([para('a', 'one'), typed('h', HeadingKeys.h1, 'T')]);
      c.setSelection(caret('h', 0));
      c.backspace();
      expect(c.document.blockById('h')!.blockType, ParagraphKeys.type);
      expect(c.document.allBlocks.length, 2);
      expect(c.selection, caret('h', 0));
    });

    test('v2 chain: nested paragraph outdents, root paragraph merges', () {
      final c = controller([
        typed('l', ListItemKeys.type, 'item', children: [para('p', 'nested')]),
      ]);
      c.setSelection(caret('p', 0));

      c.backspace(); // outdent: p becomes a sibling after l
      expect(c.document.depthOf(c.document.idToFlatIndex['p']!), 0);
      expect(c.selection, caret('p', 0));

      c.backspace(); // root paragraph: merge into l
      expect(c.document.allBlocks.length, 1);
      expect(c.document.blockById('l')!.plainText, 'itemnested');
    });

    test(
      'on an empty root list item converts and keeps the cursor in place',
      () {
        final c = controller([
          para('a', 'x'),
          typed('l', ListItemKeys.type, ''),
        ]);
        c.setSelection(caret('l', 0));
        c.backspace();
        expect(c.document.blockById('l')!.blockType, ParagraphKeys.type);
        expect(c.selection, caret('l', 0));
      },
    );

    test('at offset 0 of the first block is a no-op', () {
      final c = controller([para('a', 'text')]);
      c.setSelection(caret('a', 0));
      var notifications = 0;
      c.addListener(() => notifications++);
      c.backspace();
      expect(c.document.blockById('a')!.plainText, 'text');
      expect(notifications, 0);
    });

    test('after a divider deletes it immediately (voidBackspace policy)', () {
      final c = controller([
        para('a', 'above'),
        typed('d', DividerKeys.type, ''),
        para('b', 'below'),
      ]);
      c.setSelection(caret('b', 0));
      c.backspace();
      expect(c.document.blockById('d'), isNull);
      expect(c.selection, caret('b', 0));
    });

    test(
      'after an image selects it first; the second backspace deletes (G9)',
      () {
        final c = controller([
          para('a', 'above'),
          typed('img', ImageKeys.type, ''),
          para('b', 'below'),
        ]);
        c.setSelection(caret('b', 0));

        c.backspace();
        expect(c.document.blockById('img'), isNotNull);
        expect(
          c.selection,
          DocSelection(
            base: DocPosition('img', 0),
            extent: DocPosition('img', 1),
          ),
        );

        c.backspace();
        expect(c.document.blockById('img'), isNull);
        expect(
          c.selection,
          caret('a', 5),
          reason: 'caret goes to the previous text block\'s end',
        );
      },
    );
  });

  group('deleteSelection / G9 void caret rules', () {
    test('deleting a selected image with no previous text block puts the '
        'caret at the next text block start', () {
      final c = controller([
        typed('img', ImageKeys.type, ''),
        para('a', 'after'),
      ]);
      c.setSelection(caret('img', 0));
      c.deleteSelection();
      expect(c.document.blockById('img'), isNull);
      expect(c.selection, caret('a', 0));
    });

    test(
      'deleting the sole (void) block falls back to the empty paragraph',
      () {
        final c = controller([typed('img', ImageKeys.type, '')]);
        c.setSelection(caret('img', 0));
        c.deleteSelection();
        final blocks = c.document.allBlocks;
        expect(blocks.length, 1);
        expect(blocks.single.blockType, ParagraphKeys.type);
        expect(blocks.single.plainText, '');
        expect(c.selection, caret(blocks.single.id, 0));
      },
    );

    test('select-all (text endpoints) and delete leaves one empty block', () {
      final c = controller([para('a', 'one'), para('b', 'two')]);
      c.setSelection(
        DocSelection(base: DocPosition('a', 0), extent: DocPosition('b', 3)),
      );
      c.deleteSelection();
      expect(c.document.allBlocks.length, 1);
      expect(c.document.blockById('a')!.plainText, '');
      expect(c.selection, caret('a', 0));
    });
  });

  group('G13 group indent/outdent gates', () {
    test(
      'Tab then Shift-Tab on a 3-sibling selection whose first block is at '
      'sibling index 0 (some with children) is an identity on the tree shape',
      () {
        final c = controller([
          typed(
            'a',
            ListItemKeys.type,
            'one',
            children: [typed('a1', ListItemKeys.type, 'one.one')],
          ),
          typed('b', ListItemKeys.type, 'two'),
          typed('c', ListItemKeys.type, 'three'),
        ]);
        final before = shape(c.document);
        c.setSelection(
          DocSelection(base: DocPosition('a', 0), extent: DocPosition('c', 5)),
        );

        c.indent(); // first member has no resolved target → whole group no-op
        expect(shape(c.document), before);

        c.outdent(); // all members at root → whole group no-op
        expect(shape(c.document), before);
      },
    );

    test('two paragraphs selected after a list item indent under it '
        '(the resolved-target rule, not the fellow-member trap)', () {
      final c = controller([
        typed('l', ListItemKeys.type, 'item'),
        para('p1', 'one'),
        para('p2', 'two'),
      ]);
      c.setSelection(
        DocSelection(base: DocPosition('p1', 0), extent: DocPosition('p2', 3)),
      );

      c.indent();

      final l = c.document.blockById('l')!;
      expect(l.children.map((b) => b.id), ['p1', 'p2']);
      expect(
        c.selection!.base,
        DocPosition('p1', 0),
        reason: 'id-based selection survives the reindex',
      );
    });

    test('Shift-Tab on a mixed-depth selection no-ops the whole group', () {
      final c = controller([
        typed(
          'l',
          ListItemKeys.type,
          'item',
          children: [typed('x', ListItemKeys.type, 'nested')],
        ),
        typed('m', ListItemKeys.type, 'root'),
      ]);
      final before = shape(c.document);
      c.setSelection(
        DocSelection(base: DocPosition('x', 0), extent: DocPosition('m', 4)),
      );

      c.outdent();

      expect(shape(c.document), before);
    });

    test('a contiguous run indents under the single shared target', () {
      final c = controller([
        typed('z', ListItemKeys.type, 'target'),
        typed('a', ListItemKeys.type, 'one'),
        typed('b', ListItemKeys.type, 'two'),
      ]);
      c.setSelection(
        DocSelection(base: DocPosition('a', 0), extent: DocPosition('b', 3)),
      );

      c.indent();

      expect(c.document.blockById('z')!.children.map((b) => b.id), ['a', 'b']);
    });

    test('a selected ancestor carries its subtree (no double indent)', () {
      final c = controller([
        typed('z', ListItemKeys.type, 'target'),
        typed(
          'a',
          ListItemKeys.type,
          'parent',
          children: [typed('a1', ListItemKeys.type, 'child')],
        ),
      ]);
      c.setSelection(
        DocSelection(base: DocPosition('a', 0), extent: DocPosition('a1', 5)),
      );

      c.indent();

      final z = c.document.blockById('z')!;
      expect(z.children.map((b) => b.id), ['a']);
      expect(z.children.single.children.map((b) => b.id), ['a1']);
    });

    test('group outdent preserves sibling order', () {
      final c = controller([
        typed(
          'z',
          ListItemKeys.type,
          'parent',
          children: [
            typed('a', ListItemKeys.type, 'one'),
            typed('b', ListItemKeys.type, 'two'),
          ],
        ),
      ]);
      c.setSelection(
        DocSelection(base: DocPosition('a', 0), extent: DocPosition('b', 3)),
      );

      c.outdent();

      expect(c.document.blocks.map((b) => b.id), ['z', 'a', 'b']);
      expect(c.document.blockById('z')!.children, isEmpty);
    });

    test('a target that cannot have children fails the whole group', () {
      final c = controller([
        typed('h', HeadingKeys.h1, 'Title'),
        para('p1', 'one'),
        para('p2', 'two'),
      ]);
      final before = shape(c.document);
      c.setSelection(
        DocSelection(base: DocPosition('p1', 0), extent: DocPosition('p2', 3)),
      );

      c.indent();

      expect(shape(c.document), before);
    });
  });
}
