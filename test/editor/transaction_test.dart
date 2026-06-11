import 'package:bullet_editor/bullet_editor.dart';
// Transaction is package-private surface — not exported from the barrel.
import 'package:bullet_editor/src/editor/transaction.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Shared context: ops are pure data, schema behavior arrives via ctx.
  final ctx = EditorSchema.standard().editContext();

  group('InsertText', () {
    test('inserts text at offset', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('hello')],
        ),
      ]);
      final result = InsertText('a', 5, ' world').apply(doc, ctx)!;
      expect(result.blocks[0].plainText, 'hello world');
    });

    test('inserts at beginning', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('world')],
        ),
      ]);
      final result = InsertText('a', 0, 'hello ').apply(doc, ctx)!;
      expect(result.blocks[0].plainText, 'hello world');
    });

    test('inherits style when appending to a styled segment', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [
            const StyledSegment('hello', {InlineStyleKeys.bold}),
          ],
        ),
      ]);
      final result = InsertText('a', 5, ' world').apply(doc, ctx)!;
      expect(result.blocks[0].plainText, 'hello world');
      // The appended text should inherit bold from the segment it continues.
      expect(result.blocks[0].segments.length, 1);
      expect(result.blocks[0].segments[0].styles, {InlineStyleKeys.bold});
    });

    test('inherits style when inserting inside a styled segment', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [
            const StyledSegment('onetwothree', {InlineStyleKeys.bold}),
          ],
        ),
      ]);
      final result = InsertText('a', 3, 'a').apply(doc, ctx)!;
      expect(result.blocks[0].plainText, 'oneatwothree');
      // All text should remain bold.
      expect(result.blocks[0].segments.length, 1);
      expect(result.blocks[0].segments[0].styles, {InlineStyleKeys.bold});
    });

    test('style persists across multiple sequential inserts', () {
      // Simulate: bold "hello", then type space, then type "world"
      var doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [
            const StyledSegment('hello', {InlineStyleKeys.bold}),
          ],
        ),
      ]);

      // Type space
      doc = InsertText('a', 5, ' ').apply(doc, ctx)!;
      expect(doc.blocks[0].plainText, 'hello ');
      expect(doc.blocks[0].segments.length, 1);
      expect(doc.blocks[0].segments[0].styles, {InlineStyleKeys.bold});

      // Type 'w'
      doc = InsertText('a', 6, 'w').apply(doc, ctx)!;
      expect(doc.blocks[0].plainText, 'hello w');
      expect(doc.blocks[0].segments.length, 1);
      expect(doc.blocks[0].segments[0].styles, {InlineStyleKeys.bold});

      // Type 'orld'
      doc = InsertText('a', 7, 'o').apply(doc, ctx)!;
      doc = InsertText('a', 8, 'r').apply(doc, ctx)!;
      doc = InsertText('a', 9, 'l').apply(doc, ctx)!;
      doc = InsertText('a', 10, 'd').apply(doc, ctx)!;
      expect(doc.blocks[0].plainText, 'hello world');
      expect(doc.blocks[0].segments.length, 1);
      expect(doc.blocks[0].segments[0].styles, {InlineStyleKeys.bold});
    });
  });

  group('DeleteText', () {
    test('deletes text at offset', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('hello world')],
        ),
      ]);
      final result = DeleteText('a', 5, 6).apply(doc, ctx)!;
      expect(result.blocks[0].plainText, 'hello');
    });
  });

  group('ToggleStyle', () {
    test('applies bold to unstyled range', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('hello world')],
        ),
      ]);
      final result = ToggleStyle(
        'a',
        0,
        5,
        InlineStyleKeys.bold,
      ).apply(doc, ctx)!;
      expect(result.blocks[0].segments.length, 2);
      expect(result.blocks[0].segments[0].text, 'hello');
      expect(result.blocks[0].segments[0].styles, {InlineStyleKeys.bold});
      expect(result.blocks[0].segments[1].text, ' world');
      expect(result.blocks[0].segments[1].styles, isEmpty);
    });

    test('removes bold from fully-styled range', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [
            const StyledSegment('hello world', {InlineStyleKeys.bold}),
          ],
        ),
      ]);
      final result = ToggleStyle(
        'a',
        0,
        5,
        InlineStyleKeys.bold,
      ).apply(doc, ctx)!;
      expect(result.blocks[0].segments[0].text, 'hello');
      expect(result.blocks[0].segments[0].styles, isEmpty);
    });
  });

  group('SplitBlock', () {
    test('splits block at offset', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('hello world')],
        ),
      ]);
      final result = SplitBlock('a', 5).apply(doc, ctx)!;
      expect(result.blocks.length, 2);
      expect(result.blocks[0].plainText, 'hello');
      expect(result.blocks[1].plainText, ' world');
    });

    test('split at start creates empty first block', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('hello')],
        ),
      ]);
      final result = SplitBlock('a', 0).apply(doc, ctx)!;
      expect(result.blocks.length, 2);
      expect(result.blocks[0].plainText, '');
      expect(result.blocks[1].plainText, 'hello');
    });
  });

  group('MergeBlocks', () {
    test('merges second block into first', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('hello')],
        ),
        TextBlock(
          id: 'b',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment(' world')],
        ),
      ]);
      final result = MergeBlocks('b').apply(doc, ctx)!;
      expect(result.blocks.length, 1);
      expect(result.blocks[0].plainText, 'hello world');
    });

    test('merging first block rejects (returns null)', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('hello')],
        ),
      ]);
      final result = MergeBlocks('a').apply(doc, ctx);
      expect(result, isNull);
    });
  });

  group('ChangeBlockType', () {
    test('changes block type', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('hello')],
        ),
      ]);
      final result = ChangeBlockType('a', HeadingKeys.h1).apply(doc, ctx)!;
      expect(result.blocks[0].blockType, HeadingKeys.h1);
      expect(result.blocks[0].plainText, 'hello');
    });
  });

  group('SplitBlock with block types', () {
    test(
      'Enter at start of heading inserts empty paragraph before, heading keeps type',
      () {
        final doc = Document([
          TextBlock(
            id: 'a',
            blockType: HeadingKeys.h1,
            segments: [const StyledSegment('Title')],
          ),
        ]);
        final result = SplitBlock('a', 0).apply(doc, ctx)!;
        expect(result.blocks.length, 2);
        // First block: empty paragraph (the new line inserted before).
        expect(result.blocks[0].blockType, ParagraphKeys.type);
        expect(result.blocks[0].plainText, '');
        // Second block: H1 keeps its type and content.
        expect(result.blocks[1].blockType, HeadingKeys.h1);
        expect(result.blocks[1].plainText, 'Title');
      },
    );

    test('Enter at start of parent list item preserves children', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ListItemKeys.type,
          segments: [const StyledSegment('Parent')],
          children: [
            TextBlock(
              id: 'b',
              blockType: ListItemKeys.type,
              segments: [const StyledSegment('Child')],
            ),
          ],
        ),
      ]);
      final result = SplitBlock('a', 0).apply(doc, ctx)!;
      // New empty list item before, original keeps type + children.
      final flat = result.allBlocks;
      expect(flat.length, 3); // empty + Parent + Child
      expect(flat[0].plainText, '');
      expect(flat[1].plainText, 'Parent');
      expect(flat[1].blockType, ListItemKeys.type);
      // Children still attached to Parent.
      final parent = result.blocks.firstWhere((b) => b.plainText == 'Parent');
      expect(parent.children.length, 1);
      expect(parent.children[0].plainText, 'Child');
    });

    test('Enter on heading creates paragraph', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: HeadingKeys.h1,
          segments: [const StyledSegment('heading')],
        ),
      ]);
      final result = SplitBlock('a', 7).apply(doc, ctx)!;
      expect(result.blocks[0].blockType, HeadingKeys.h1);
      expect(result.blocks[1].blockType, ParagraphKeys.type);
    });

    test('Enter on list item creates another list item', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ListItemKeys.type,
          segments: [const StyledSegment('item')],
        ),
      ]);
      final result = SplitBlock('a', 4).apply(doc, ctx)!;
      expect(result.blocks[0].blockType, ListItemKeys.type);
      expect(result.blocks[1].blockType, ListItemKeys.type);
    });
  });

  group('IndentBlock', () {
    test('makes block a child of its previous sibling', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ListItemKeys.type,
          segments: [const StyledSegment('first')],
        ),
        TextBlock(
          id: 'b',
          blockType: ListItemKeys.type,
          segments: [const StyledSegment('second')],
        ),
      ]);
      final result = IndentBlock('b').apply(doc, ctx)!;
      // 'b' should now be a child of 'a'.
      expect(result.blocks.length, 1);
      expect(result.blocks[0].id, 'a');
      expect(result.blocks[0].children.length, 1);
      expect(result.blocks[0].children[0].id, 'b');
      // allBlocks still has both.
      expect(result.allBlocks.length, 2);
    });

    test('rejects when block has no previous sibling', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ListItemKeys.type,
          segments: [const StyledSegment('only')],
        ),
      ]);
      final result = IndentBlock('a').apply(doc, ctx);
      expect(result, isNull);
    });
  });

  group('OutdentBlock', () {
    test('moves nested block to parent level', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ListItemKeys.type,
          segments: [const StyledSegment('parent')],
          children: [
            TextBlock(
              id: 'b',
              blockType: ListItemKeys.type,
              segments: [const StyledSegment('child')],
            ),
          ],
        ),
      ]);
      final result = OutdentBlock('b').apply(doc, ctx)!;
      // 'b' should now be a sibling after 'a' at root level.
      expect(result.blocks.length, 2);
      expect(result.blocks[0].id, 'a');
      expect(result.blocks[0].children, isEmpty);
      expect(result.blocks[1].id, 'b');
    });

    test('rejects when block is already at root', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ListItemKeys.type,
          segments: [const StyledSegment('root')],
        ),
      ]);
      final result = OutdentBlock('a').apply(doc, ctx);
      expect(result, isNull);
    });
  });

  group('DeleteRange', () {
    test('same block behaves like DeleteText', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('hello world')],
        ),
      ]);
      final result = DeleteRange(
        const DocPosition('a', 2),
        const DocPosition('a', 7),
      ).apply(doc, ctx)!;
      expect(result.allBlocks[0].plainText, 'heorld');
    });

    test('across 2 blocks merges remaining halves', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('hello')],
        ),
        TextBlock(
          id: 'b',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('world')],
        ),
      ]);
      // Delete from offset 3 in block 'a' to offset 2 in block 'b'.
      // Keeps 'hel' + 'rld' = 'helrld'
      final result = DeleteRange(
        const DocPosition('a', 3),
        const DocPosition('b', 2),
      ).apply(doc, ctx)!;
      expect(result.allBlocks.length, 1);
      expect(result.allBlocks[0].plainText, 'helrld');
    });

    test(
      'across 3+ blocks removes middle blocks and merges first and last',
      () {
        final doc = Document([
          TextBlock(
            id: 'a',
            blockType: ParagraphKeys.type,
            segments: [const StyledSegment('aaa')],
          ),
          TextBlock(
            id: 'b',
            blockType: ParagraphKeys.type,
            segments: [const StyledSegment('bbb')],
          ),
          TextBlock(
            id: 'c',
            blockType: ParagraphKeys.type,
            segments: [const StyledSegment('ccc')],
          ),
          TextBlock(
            id: 'd',
            blockType: ParagraphKeys.type,
            segments: [const StyledSegment('ddd')],
          ),
        ]);
        // Delete from offset 1 in block 'a' to offset 2 in block 'd'.
        // Keeps 'a' + 'd' = 'ad', blocks b and c removed.
        final result = DeleteRange(
          const DocPosition('a', 1),
          const DocPosition('d', 2),
        ).apply(doc, ctx)!;
        expect(result.allBlocks.length, 1);
        expect(result.allBlocks[0].plainText, 'ad');
      },
    );

    test('delete entire blocks leaves empty first block', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('hello')],
        ),
        TextBlock(
          id: 'b',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('world')],
        ),
      ]);
      // Delete from offset 0 in block 'a' to offset 5 in block 'b' (everything).
      final result = DeleteRange(
        const DocPosition('a', 0),
        const DocPosition('b', 5),
      ).apply(doc, ctx)!;
      expect(result.allBlocks.length, 1);
      expect(result.allBlocks[0].plainText, '');
    });
  });

  group('Transaction', () {
    test('applies multiple operations in sequence', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('hello')],
        ),
      ]);
      final tx = Transaction(
        operations: [
          InsertText('a', 5, ' world'),
          ToggleStyle('a', 0, 5, InlineStyleKeys.bold),
        ],
        selectionAfter: DocSelection.collapsed(const DocPosition('a', 11)),
      );
      final result = tx.apply(doc, ctx)!;
      expect(result.blocks[0].plainText, 'hello world');
      expect(result.blocks[0].segments[0].styles, {InlineStyleKeys.bold});
    });

    test('rejects the whole batch when any op rejects', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('hello')],
        ),
      ]);
      final tx = Transaction(
        operations: [
          InsertText('a', 5, ' world'),
          InsertText('gone', 0, 'x'), // gone id — rejects
        ],
      );
      expect(tx.apply(doc, ctx), isNull);
    });
  });

  group('SplitBlock with list-like types', () {
    // List-like behavior is no longer threaded through an isListLikeFn
    // parameter — it comes from the standard schema's split policies via ctx.
    test('Enter on numbered list creates another numbered list', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: NumberedListKeys.type,
          segments: [const StyledSegment('first')],
        ),
      ]);
      final result = SplitBlock('a', 5).apply(doc, ctx)!;
      expect(result.allBlocks.length, 2);
      expect(result.allBlocks[0].blockType, NumberedListKeys.type);
      expect(result.allBlocks[1].blockType, NumberedListKeys.type);
    });

    test('Enter on task creates unchecked task', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: TaskItemKeys.type,
          segments: [const StyledSegment('done')],
          metadata: {TaskItemKeys.checked: true},
        ),
      ]);
      final result = SplitBlock('a', 4).apply(doc, ctx)!;
      expect(result.allBlocks.length, 2);
      expect(result.allBlocks[1].blockType, TaskItemKeys.type);
      expect(result.allBlocks[1].metadata[TaskItemKeys.checked], false);
    });
  });

  group('SetMetadata', () {
    test('sets metadata on a block', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: TaskItemKeys.type,
          segments: [const StyledSegment('task')],
          metadata: {TaskItemKeys.checked: false},
        ),
      ]);
      final result = SetMetadata(
        'a',
        TaskItemKeys.checked,
        true,
      ).apply(doc, ctx)!;
      expect(result.allBlocks[0].metadata[TaskItemKeys.checked], true);
    });

    test('gone id rejects (returns null)', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('hello')],
        ),
      ]);
      final result = SetMetadata('gone', 'key', 'value').apply(doc, ctx);
      expect(result, isNull);
    });
  });

  group('ToggleStyle with attributes', () {
    test('applies link style with URL attribute', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('click here')],
        ),
      ]);
      final result = ToggleStyle(
        'a',
        0,
        10,
        InlineEntityKeys.link,
        attributes: {'url': 'https://example.com'},
      ).apply(doc, ctx)!;
      final seg = result.allBlocks[0].segments[0];
      expect(seg.styles, contains(InlineEntityKeys.link));
      expect(seg.attributes['url'], 'https://example.com');
    });

    test('removing link style clears URL attribute', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [
            const StyledSegment(
              'linked',
              {InlineEntityKeys.link},
              {'url': 'https://example.com'},
            ),
          ],
        ),
      ]);
      final result = ToggleStyle(
        'a',
        0,
        6,
        InlineEntityKeys.link,
        attributes: {'url': 'https://example.com'},
      ).apply(doc, ctx)!;
      final seg = result.allBlocks[0].segments[0];
      expect(seg.styles, isNot(contains(InlineEntityKeys.link)));
      expect(seg.attributes.containsKey('url'), isFalse);
    });

    test('link on partial range splits segments correctly', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('hello world')],
        ),
      ]);
      final result = ToggleStyle(
        'a',
        6,
        11,
        InlineEntityKeys.link,
        attributes: {'url': 'https://w.com'},
      ).apply(doc, ctx)!;
      final segs = result.allBlocks[0].segments;
      expect(segs.length, 2);
      expect(segs[0].text, 'hello ');
      expect(segs[0].styles, isEmpty);
      expect(segs[1].text, 'world');
      expect(segs[1].styles, {InlineEntityKeys.link});
      expect(segs[1].attributes['url'], 'https://w.com');
    });
  });

  group('InsertText with attributes', () {
    test('inserts text with link attributes', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('before after')],
        ),
      ]);
      final result = InsertText(
        'a',
        7,
        'link',
        styles: {InlineEntityKeys.link},
        attributes: {'url': 'https://x.com'},
      ).apply(doc, ctx)!;
      final segs = result.allBlocks[0].segments;
      // Should have: 'before ' + 'link' (linked) + 'after'
      expect(
        segs.any(
          (s) =>
              s.text == 'link' &&
              s.styles.contains(InlineEntityKeys.link) &&
              s.attributes['url'] == 'https://x.com',
        ),
        isTrue,
      );
    });
  });

  group('DeleteText preserves attributes', () {
    test('deleting part of a link segment keeps URL', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [
            const StyledSegment(
              'link',
              {InlineEntityKeys.link},
              {'url': 'https://flutter.dev'},
            ),
          ],
        ),
      ]);
      final result = DeleteText('a', 3, 1).apply(doc, ctx)!;
      final seg = result.allBlocks[0].segments[0];
      expect(seg.text, 'lin');
      expect(seg.styles, {InlineEntityKeys.link});
      expect(seg.attributes['url'], 'https://flutter.dev');
    });
  });

  group('SplitBlock preserves attributes', () {
    test('splitting inside a link segment keeps URL on both halves', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [
            const StyledSegment(
              'click here',
              {InlineEntityKeys.link},
              {'url': 'https://x.com'},
            ),
          ],
        ),
      ]);
      final result = SplitBlock('a', 5).apply(doc, ctx)!;
      final seg0 = result.allBlocks[0].segments[0];
      final seg1 = result.allBlocks[1].segments[0];
      expect(seg0.text, 'click');
      expect(seg0.attributes['url'], 'https://x.com');
      expect(seg1.text, ' here');
      expect(seg1.attributes['url'], 'https://x.com');
    });
  });

  group('PasteBlocks', () {
    test('single block paste inserts styled segments', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('hello world')],
        ),
      ]);
      final pasted = [
        TextBlock(
          id: 'p1',
          blockType: ParagraphKeys.type,
          segments: [
            const StyledSegment('bold', {InlineStyleKeys.bold}),
          ],
        ),
      ];
      final result = PasteBlocks('a', 5, pasted).apply(doc, ctx)!;
      expect(result.allBlocks.length, 1);
      expect(result.allBlocks[0].plainText, 'hellobold world');
      expect(
        result.allBlocks[0].segments.any(
          (s) => s.text == 'bold' && s.styles.contains(InlineStyleKeys.bold),
        ),
        isTrue,
      );
    });

    test('multi-block paste splits and inserts', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('before after')],
        ),
      ]);
      final pasted = [
        TextBlock(
          id: 'p1',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('first')],
        ),
        TextBlock(
          id: 'p2',
          blockType: HeadingKeys.h1,
          segments: [const StyledSegment('heading')],
        ),
        TextBlock(
          id: 'p3',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('last')],
        ),
      ];
      final result = PasteBlocks('a', 7, pasted).apply(doc, ctx)!;
      expect(result.allBlocks.length, 3);
      expect(result.allBlocks[0].plainText, 'before first');
      expect(result.allBlocks[1].blockType, HeadingKeys.h1);
      expect(result.allBlocks[1].plainText, 'heading');
      expect(result.allBlocks[2].plainText, 'lastafter');
      // The last pasted TEXT block keeps its own id through the tail merge.
      expect(result.allBlocks[2].id, 'p3');
    });

    test('paste at start of block', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('existing')],
        ),
      ]);
      final pasted = [
        TextBlock(
          id: 'p1',
          blockType: ParagraphKeys.type,
          segments: [
            const StyledSegment('new ', {InlineStyleKeys.italic}),
          ],
        ),
      ];
      final result = PasteBlocks('a', 0, pasted).apply(doc, ctx)!;
      expect(result.allBlocks[0].plainText, 'new existing');
      expect(
        result.allBlocks[0].segments.first.styles,
        contains(InlineStyleKeys.italic),
      );
    });
  });

  group('PasteBlocks on heading', () {
    test(
      'multi-block paste on heading: head keeps heading, rest are pasted types',
      () {
        final doc = Document([
          TextBlock(
            id: 'a',
            blockType: HeadingKeys.h1,
            segments: [const StyledSegment('Title')],
          ),
        ]);
        // Paste paragraph + list item after "Title"
        final pasted = [
          TextBlock(
            id: 'p1',
            blockType: ParagraphKeys.type,
            segments: [const StyledSegment(' extra')],
          ),
          TextBlock(
            id: 'p2',
            blockType: ListItemKeys.type,
            segments: [const StyledSegment('item')],
          ),
        ];
        final result = PasteBlocks('a', 5, pasted).apply(doc, ctx)!;
        // Head should still be h1 with "Title extra"
        expect(result.allBlocks[0].blockType, HeadingKeys.h1);
        expect(result.allBlocks[0].plainText, 'Title extra');
        // Tail should be list item with "item"
        expect(result.allBlocks[1].blockType, ListItemKeys.type);
        expect(result.allBlocks[1].plainText, 'item');
      },
    );
  });

  group('PasteBlocks nesting', () {
    test('pasting nested markdown preserves tree structure', () {
      final codec = MarkdownCodec();
      final decoded = codec.decode('- Parent\n\n  - Nested\n\n- After');
      // decoded should have: Parent (with child Nested), After
      expect(decoded.blocks.length, 2);
      expect(decoded.blocks[0].children.length, 1);

      // Paste into an empty document
      final doc = Document([
        TextBlock(id: 'a', blockType: ParagraphKeys.type, segments: const []),
      ]);
      final result = PasteBlocks('a', 0, decoded.blocks).apply(doc, ctx)!;
      final flat = result.allBlocks;
      // Should have: Parent, Nested (child), After — 3 flat blocks
      expect(flat.length, greaterThanOrEqualTo(3));
    });
  });

  group('PasteBlocks sibling ordering with nested blocks', () {
    test('blocks after a nested parent are siblings, not children', () {
      // Simulate pasting: listItem(with child), divider, numberedList
      final doc = Document([
        TextBlock(id: 'a', blockType: ParagraphKeys.type, segments: const []),
      ]);
      final pasted = [
        TextBlock(
          id: 'p1',
          blockType: ListItemKeys.type,
          segments: [const StyledSegment('Parent')],
          children: [
            TextBlock(
              id: 'p1c',
              blockType: ListItemKeys.type,
              segments: [const StyledSegment('Child')],
            ),
          ],
        ),
        TextBlock(id: 'p2', blockType: DividerKeys.type),
        TextBlock(
          id: 'p3',
          blockType: NumberedListKeys.type,
          segments: [const StyledSegment('Number')],
        ),
      ];
      final result = PasteBlocks('a', 0, pasted).apply(doc, ctx)!;
      final flat = result.allBlocks;
      // Expect 4 flat blocks: Parent, Child, divider, Number
      expect(flat.length, 4);
      // Divider and Number should be root-level, NOT children of Parent.
      expect(
        result.blocks.length,
        3,
        reason: 'Should have 3 roots: listItem(+child), divider, numberedList',
      );
      expect(result.blocks[1].blockType, DividerKeys.type);
      expect(result.blocks[2].blockType, NumberedListKeys.type);
    });
  });

  group('DeleteRange edge cases', () {
    test('delete all content in multi-block document does not crash', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('first')],
        ),
        TextBlock(
          id: 'b',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('second')],
        ),
        TextBlock(
          id: 'c',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('third')],
        ),
      ]);
      // Delete everything: start of 'a' to end of 'c'.
      final result = DeleteRange(
        const DocPosition('a', 0),
        const DocPosition('c', 5),
      ).apply(doc, ctx)!;
      // Should not crash, should leave at least one block
      expect(result.allBlocks.isNotEmpty, isTrue);
    });
  });

  group('Tree-preserving delete and merge', () {
    test(
      'DeleteRange across root into nested child promotes surviving children',
      () {
        // H3 heading, then a list item with two children.
        // Select from mid-heading to end of first child → delete.
        // The second child (sibling of the deleted one) must survive.
        final doc = Document([
          TextBlock(
            id: 'h',
            blockType: HeadingKeys.h1,
            segments: [const StyledSegment('Heading')],
          ),
          TextBlock(
            id: 'parent',
            blockType: ListItemKeys.type,
            segments: [const StyledSegment('Parent')],
            children: [
              TextBlock(
                id: 'c1',
                blockType: ListItemKeys.type,
                segments: [const StyledSegment('Child1')],
              ),
              TextBlock(
                id: 'c2',
                blockType: ListItemKeys.type,
                segments: [const StyledSegment('Child2')],
              ),
            ],
          ),
        ]);

        // Delete from offset 3 in Heading to end of Child1 (offset 6).
        // This removes Parent and Child1 as middle/end blocks.
        final result = DeleteRange(
          const DocPosition('h', 3),
          const DocPosition('c1', 6),
        ).apply(doc, ctx)!;

        // "Heading" truncated to "Hea", Child2 should survive.
        expect(
          result.allBlocks.any((b) => b.id == 'c2'),
          isTrue,
          reason: 'Child2 must not be silently deleted',
        );
        expect(
          result.allBlocks.firstWhere((b) => b.id == 'c2').plainText,
          'Child2',
        );
      },
    );

    test('MergeBlocks promotes children of the removed block', () {
      // Two root list items, second has a child.
      // Backspace at start of second → merge into first.
      // The child should survive as a sibling.
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: ListItemKeys.type,
          segments: [const StyledSegment('first')],
        ),
        TextBlock(
          id: 'b',
          blockType: ListItemKeys.type,
          segments: [const StyledSegment('second')],
          children: [
            TextBlock(
              id: 'c',
              blockType: ListItemKeys.type,
              segments: [const StyledSegment('child')],
            ),
          ],
        ),
      ]);

      final result = MergeBlocks('b').apply(doc, ctx)!;

      // "first" + "second" merged. "child" promoted to root sibling.
      expect(result.allBlocks.length, 2);
      expect(result.allBlocks[0].plainText, 'firstsecond');
      expect(result.allBlocks[1].plainText, 'child');
    });

    test('full scenario: heading + parent with children, select across', () {
      // Exact scenario from the user's bug report.
      final doc = Document([
        TextBlock(
          id: 'h3',
          blockType: HeadingKeys.h3,
          segments: [const StyledSegment('Heading 3 example')],
        ),
        TextBlock(
          id: 'parent',
          blockType: ListItemKeys.type,
          segments: [const StyledSegment('Parent item')],
          children: [
            TextBlock(
              id: 'nested',
              blockType: ListItemKeys.type,
              segments: [const StyledSegment('Nested child')],
            ),
            TextBlock(
              id: 'tab',
              blockType: ListItemKeys.type,
              segments: [const StyledSegment('Tab to indent')],
            ),
          ],
        ),
      ]);

      // Select from mid-heading to end of "Nested child".
      final result = DeleteRange(
        const DocPosition('h3', 7),
        const DocPosition('nested', 12),
      ).apply(doc, ctx)!;

      // "Heading" truncated. "Tab to indent" must survive.
      expect(
        result.allBlocks.any((b) => b.id == 'tab'),
        isTrue,
        reason: 'Tab to indent must not be deleted',
      );
      expect(
        result.allBlocks.firstWhere((b) => b.id == 'tab').plainText,
        'Tab to indent',
      );
    });
  });
}
