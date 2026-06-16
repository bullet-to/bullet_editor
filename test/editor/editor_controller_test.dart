import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/services.dart' show SystemChannels, TextRange;
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

    test('clears the composition undo-group flags: the next composition\'s '
        'first batch pushes its pre-composition snapshot (headless — no IME '
        'service terminates for us)', () {
      final c = controller([para('a', '')]);
      c.setSelection(caret('a', 0));
      // A composition left open across setDocument: with no registered
      // external-change handler, only setDocument itself can clear the
      // composition-scoped undo state.
      c.imeEdit(() {
        c.imeInsertText('k');
        c.imeSetComposing(
          const ComposingState(
            blockId: 'a',
            range: TextRange(start: 0, end: 1),
          ),
        );
      });

      c.setDocument(Document([para('n', 'fresh')]), selection: caret('n', 5));
      expect(c.composing, isNull);

      // The next composition's FIRST batch must push the pre-composition
      // snapshot; a stale "snapshot pushed" flag would suppress it and
      // undo would overshoot (here: have nothing to restore at all).
      c.imeEdit(() {
        c.imeInsertText('x');
        c.imeSetComposing(
          const ComposingState(
            blockId: 'n',
            range: TextRange(start: 5, end: 6),
          ),
        );
      });
      expect(c.document.blockById('n')!.plainText, 'freshx');

      c.undo();
      expect(c.document.blockById('n')!.plainText, 'fresh');
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

    test('the empty-item ladder: each Enter outdents one level, the last '
        'converts at root (checkpoint-2/3)', () {
      final c = controller([
        typed(
          'a',
          ListItemKeys.type,
          'one',
          children: [
            typed(
              'b',
              ListItemKeys.type,
              'two',
              children: [typed('c', ListItemKeys.type, '')],
            ),
          ],
        ),
      ]);
      c.setSelection(caret('c', 0));

      c.insertNewline(); // Depth 2 → sibling after b.
      expect(shape(c.document), [('a', 0), ('b', 1), ('c', 1)]);
      expect(c.document.blockById('c')!.blockType, ListItemKeys.type);
      expect(c.selection, caret('c', 0));

      c.insertNewline(); // Depth 1 → sibling after a.
      expect(shape(c.document), [('a', 0), ('b', 1), ('c', 0)]);
      expect(c.document.blockById('c')!.blockType, ListItemKeys.type);
      expect(c.selection, caret('c', 0));

      c.insertNewline(); // Root → exits the list.
      expect(shape(c.document), [('a', 0), ('b', 1), ('c', 0)]);
      expect(c.document.blockById('c')!.blockType, ParagraphKeys.type);
      expect(c.selection, caret('c', 0));
    });

    test('the ladder preserves the block type while climbing (task item)', () {
      final c = controller([
        typed(
          't',
          TaskItemKeys.type,
          'parent',
          metadata: {TaskItemKeys.checked: false},
          children: [
            typed(
              'u',
              TaskItemKeys.type,
              '',
              metadata: {TaskItemKeys.checked: false},
            ),
          ],
        ),
      ]);
      c.setSelection(caret('u', 0));

      c.insertNewline();
      expect(shape(c.document), [('t', 0), ('u', 0)]);
      expect(c.document.blockById('u')!.blockType, TaskItemKeys.type);
      expect(c.selection, caret('u', 0));

      c.insertNewline();
      expect(c.document.blockById('u')!.blockType, ParagraphKeys.type);
    });

    test('an EMPTY nested block quote climbs the ladder; the root quote '
        'converts (the listLike escape)', () {
      final c = controller([
        typed(
          'q',
          BlockQuoteKeys.type,
          'outer',
          children: [typed('r', BlockQuoteKeys.type, '')],
        ),
      ]);
      c.setSelection(caret('r', 0));

      c.insertNewline();
      expect(shape(c.document), [('q', 0), ('r', 0)]);
      expect(c.document.blockById('r')!.blockType, BlockQuoteKeys.type);

      c.insertNewline();
      expect(c.document.blockById('r')!.blockType, ParagraphKeys.type);
    });

    test('the ladder carries children and adopts later siblings — '
        'outdent()/G13 semantics, not a new reparenting rule', () {
      final c = controller([
        typed(
          'a',
          ListItemKeys.type,
          'one',
          children: [
            typed(
              'b',
              ListItemKeys.type,
              '',
              children: [typed('d', ListItemKeys.type, 'child')],
            ),
            typed('e', ListItemKeys.type, 'after'),
          ],
        ),
      ]);
      c.setSelection(caret('b', 0));

      c.insertNewline();

      expect(shape(c.document), [('a', 0), ('b', 0), ('d', 1), ('e', 1)]);
      expect(c.document.blockById('b')!.blockType, ListItemKeys.type);
      expect(c.selection, caret('b', 0));
    });

    test('a NON-empty nested list item still splits normally', () {
      final c = controller([
        typed(
          'a',
          ListItemKeys.type,
          'one',
          children: [typed('b', ListItemKeys.type, 'two')],
        ),
      ]);
      c.setSelection(caret('b', 3));

      c.insertNewline();

      final blocks = c.document.allBlocks;
      expect(blocks.length, 3);
      expect(blocks[2].blockType, ListItemKeys.type);
      expect(c.document.depthOf(2), 1, reason: 'the split stays nested');
      expect(c.selection, caret(blocks[2].id, 0));
    });

    test('undo after a ladder step restores the previous nesting', () {
      final c = controller([
        typed(
          'a',
          ListItemKeys.type,
          'one',
          children: [typed('b', ListItemKeys.type, '')],
        ),
      ]);
      c.setSelection(caret('b', 0));
      final before = shape(c.document);

      c.insertNewline();
      expect(shape(c.document), [('a', 0), ('b', 0)]);

      c.undo();
      expect(shape(c.document), before);
      expect(c.document.blockById('b')!.blockType, ListItemKeys.type);
      expect(c.selection, caret('b', 0));
    });

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

    test('on an EMPTY line below a void, the empty line collapses and the '
        'void is selected — for dividers AND images', () {
      // Checkpoint-2 finding: acting on the void while the empty line
      // survived felt backwards. The next backspace deletes the void (G9).
      for (final voidType in [DividerKeys.type, ImageKeys.type]) {
        final c = controller([
          para('a', 'above'),
          typed('v', voidType, ''),
          para('empty', ''),
        ]);
        c.setSelection(caret('empty', 0));

        c.backspace();
        expect(
          c.document.blockById('empty'),
          isNull,
          reason: 'the empty line collapses ($voidType)',
        );
        expect(c.document.blockById('v'), isNotNull);
        expect(
          c.selection,
          DocSelection(base: DocPosition('v', 0), extent: DocPosition('v', 1)),
        );

        c.backspace();
        expect(
          c.document.blockById('v'),
          isNull,
          reason: 'the second backspace deletes the void ($voidType)',
        );
        expect(c.selection, caret('a', 5));
      }
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

  // --- Clipboard (architecture §Context menus) — the toolbar wires to these.
  group('clipboard', () {
    test('selectAll spans the whole document', () {
      final c = controller([para('a', 'hello'), para('b', 'world')]);
      c.selectAll();
      final (start, end) = c.selection!.normalized(c.document);
      expect(start, DocPosition('a', 0));
      expect(end, DocPosition('b', 5));
    });

    test('selectAll on a blockless document is a no-op', () {
      final c = controller([]);
      c.selectAll();
      expect(c.selection, isNull);
    });

    testWidgets('copySelectionAsMarkdown writes the selection markdown', (
      tester,
    ) async {
      String? written;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            written = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      final c = controller([para('a', 'hello world')]);
      c.setSelection(
        DocSelection(base: DocPosition('a', 0), extent: DocPosition('a', 5)),
      );
      await c.copySelectionAsMarkdown();
      expect(written, 'hello');
    });

    testWidgets('copy on a collapsed selection writes nothing', (tester) async {
      var calls = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') calls++;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final c = controller([para('a', 'hello')]);
      c.setSelection(DocSelection.collapsed(DocPosition('a', 2)));
      await c.copySelectionAsMarkdown();
      expect(calls, 0);
    });

    testWidgets('cut copies then deletes the selection', (tester) async {
      String? written;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            written = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final c = controller([para('a', 'hello world')]);
      c.setSelection(
        DocSelection(base: DocPosition('a', 0), extent: DocPosition('a', 6)),
      );
      await c.cut();
      expect(written, 'hello '); // markdown of "hello "
      expect(c.document.blockById('a')!.plainText, 'world');
    });

    testWidgets('pasteMarkdown degrades to plain insertion (day 14 TODO)', (
      tester,
    ) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            return <String, dynamic>{'text': 'pasted'};
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final c = controller([para('a', 'hi ')]);
      c.setSelection(DocSelection.collapsed(DocPosition('a', 3)));
      await c.pasteMarkdown();
      expect(c.document.blockById('a')!.plainText, 'hi pasted');
    });
  });
}
