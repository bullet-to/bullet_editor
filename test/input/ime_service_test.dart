import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Day 5–7 shadow-buffer suite (architecture §IME): sentinel window
/// serialization, delta → op translation, the stale-delta guard, the
/// post-terminate echo quarantine, the `terminateComposition` choke point
/// (incl. the Android re-attach), the structural-while-composing divergence
/// rule, the G3 latch + input-rule run path, composition-scoped undo, and
/// the spec'd trace tests (G1, G3, G7, G10).
void main() {
  TextBlock para(String id, String text) => TextBlock(
    id: id,
    blockType: ParagraphKeys.type,
    segments: [StyledSegment(text)],
  );

  TextBlock typed(
    String id,
    String type,
    String text, {
    Map<String, dynamic> metadata = const {},
  }) => TextBlock(
    id: id,
    blockType: type,
    segments: [StyledSegment(text)],
    metadata: metadata,
  );

  DocSelection caret(String blockId, int offset) =>
      DocSelection.collapsed(DocPosition(blockId, offset));

  group('window serialization (sentinel, §buffer serialization)', () {
    final schema = EditorSchema.standard();

    test('collapsed caret: sentinel + block text, selection shifted +2', () {
      final doc = Document([para('a', 'hello')]);
      final window = serializeImeWindow(doc, caret('a', 3), schema);

      expect(window.text, '. hello');
      expect(window.selection, const TextSelection.collapsed(offset: 5));
      expect(window.elided, isFalse);
    });

    test('void atomic selection: sentinel + ~ placeholder', () {
      final doc = Document([
        para('a', 'x'),
        TextBlock(id: 'img', blockType: ImageKeys.type),
      ]);
      final window = serializeImeWindow(
        doc,
        DocSelection(
          base: const DocPosition('img', 0),
          extent: const DocPosition('img', 1),
        ),
        schema,
      );

      expect(window.text, '. ~');
      expect(window.selection.start, 2);
      expect(window.selection.end, 3);
    });

    test(
      'range selection: selected blocks joined with newlines, voids as ~',
      () {
        final doc = Document([
          para('a', 'one'),
          TextBlock(id: 'img', blockType: ImageKeys.type),
          para('b', 'two'),
        ]);
        final window = serializeImeWindow(
          doc,
          DocSelection(
            base: const DocPosition('a', 1),
            extent: const DocPosition('b', 2),
          ),
          schema,
        );

        expect(window.text, '. one\n~\ntwo');
        expect(window.selection.start, 3); // (a,1) + sentinel
        expect(window.selection.end, 10); // (b,2) block-local + spans
      },
    );

    test('no selection: bare sentinel with the caret at its end', () {
      final doc = Document([para('a', 'hello')]);
      final window = serializeImeWindow(doc, null, schema);

      expect(window.text, '. ');
      expect(window.selection, const TextSelection.collapsed(offset: 2));
    });

    test('window cap: >32 blocks serialize as first + elided ~ + last', () {
      final blocks = [for (var i = 0; i < 40; i++) para('b$i', 'block $i')];
      final doc = Document(blocks);
      final window = serializeImeWindow(
        doc,
        DocSelection(
          base: const DocPosition('b0', 0),
          extent: DocPosition('b39', blocks.last.length),
        ),
        schema,
      );

      expect(window.elided, isTrue);
      expect(window.text, '. block 0\n~\nblock 39');
      expect(window.touchesElision(2, window.text.length), isTrue);
      expect(window.touchesElision(2, 9), isFalse, reason: 'first block only');
    });
  });

  group('ImeService', () {
    late EditorController controller;
    late ImeService service;
    late List<FakeImeConnection> connections;

    ImeService build(
      List<TextBlock> blocks, {
      DocSelection? selection,
      ShouldGroupUndo? grouping,
    }) {
      controller = EditorController(
        document: Document(blocks),
        schema: EditorSchema.standard(),
        // Deterministic undo: every push is its own entry, so composition
        // scoping is observable without the 300ms time merge.
        undoGrouping: grouping ?? (previous, current) => false,
      );
      if (selection != null) controller.setSelection(selection);
      connections = [];
      service = ImeService(
        controller: controller,
        connectionFactory: (client, configuration) {
          final connection = FakeImeConnection();
          connections.add(connection);
          return connection;
        },
      );
      service.attach();
      return service;
    }

    FakeImeConnection connection() => connections.last;
    TextEditingValue shadow() => service.currentTextEditingValue!;

    void sendDeltas(List<TextEditingDelta> deltas) =>
        service.updateEditingValueWithDeltas(deltas);

    void sendInsertion(
      String text, {
      int? at,
      TextRange composing = TextRange.empty,
    }) {
      final old = shadow();
      final offset = at ?? old.selection.extentOffset;
      sendDeltas([
        TextEditingDeltaInsertion(
          oldText: old.text,
          textInserted: text,
          insertionOffset: offset,
          selection: TextSelection.collapsed(offset: offset + text.length),
          composing: composing,
        ),
      ]);
    }

    void sendDeletion(
      TextRange deleted, {
      TextRange composing = TextRange.empty,
    }) {
      final old = shadow();
      sendDeltas([
        TextEditingDeltaDeletion(
          oldText: old.text,
          deletedRange: deleted,
          selection: TextSelection.collapsed(offset: deleted.start),
          composing: composing,
        ),
      ]);
    }

    void sendReplacement(
      TextRange replaced,
      String text, {
      TextRange composing = TextRange.empty,
    }) {
      final old = shadow();
      sendDeltas([
        TextEditingDeltaReplacement(
          oldText: old.text,
          replacedRange: replaced,
          replacementText: text,
          selection: TextSelection.collapsed(
            offset: replaced.start + text.length,
          ),
          composing: composing,
        ),
      ]);
    }

    void sendNonTextUpdate({
      TextSelection? selection,
      TextRange composing = TextRange.empty,
    }) {
      final old = shadow();
      sendDeltas([
        TextEditingDeltaNonTextUpdate(
          oldText: old.text,
          selection: selection ?? old.selection,
          composing: composing,
        ),
      ]);
    }

    group('attach and the no-echo invariant', () {
      test('attach opens a connection, shows it, and pushes the window', () {
        build([para('a', 'hello')], selection: caret('a', 3));

        expect(connections, hasLength(1));
        expect(connection().shown, isTrue);
        expect(connection().pushed, hasLength(1));
        expect(connection().pushed.single.text, '. hello');
        expect(
          connection().pushed.single.selection,
          const TextSelection.collapsed(offset: 5),
        );
      });

      test('an ordinary insertion delta applies and is NEVER echoed back', () {
        build([para('a', 'helo')], selection: caret('a', 3));

        sendInsertion('l');

        expect(controller.document.blockById('a')!.plainText, 'hello');
        expect(controller.selection, caret('a', 4));
        expect(
          connection().pushed,
          hasLength(1),
          reason: 'no echo (IME §no-echo)',
        );
        expect(shadow().text, '. hello');
      });

      test('a deletion delta maps to DeleteText through the batch loop', () {
        build([para('a', 'hello')], selection: caret('a', 5));

        sendDeletion(const TextRange(start: 6, end: 7));

        expect(controller.document.blockById('a')!.plainText, 'hell');
        expect(controller.selection, caret('a', 4));
        expect(connection().pushed, hasLength(1));
      });

      test('backspace over a grapheme cluster deletes the whole cluster', () {
        build([para('a', 'a👨‍👩‍👧')], selection: caret('a', 9));

        // The engine reports the exact cluster range.
        sendDeletion(const TextRange(start: 3, end: 11));

        expect(controller.document.blockById('a')!.plainText, 'a');
      });

      test('same-block tap-then-type trace: type "hello", tap before h, type x '
          '→ "xhello" (the selection re-push, spec §no-echo)', () {
        build([para('a', '')], selection: caret('a', 0));
        for (final ch in 'hello'.split('')) {
          sendInsertion(ch);
        }
        expect(controller.document.blockById('a')!.plainText, 'hello');
        final pushesBeforeTap = connection().pushed.length;

        // The tap: a non-IME selection change. The window text is
        // unchanged but the engine-side cursor MUST move (clause (b)).
        controller.setSelection(caret('a', 0));

        expect(connection().pushed.length, pushesBeforeTap + 1);
        expect(
          shadow().selection,
          const TextSelection.collapsed(offset: 2),
          reason: 'shadow re-pushed with the new caret',
        );

        sendInsertion('x');
        expect(controller.document.blockById('a')!.plainText, 'xhello');
      });

      test('a selection-only NonTextUpdate moves the model caret, no echo', () {
        build([para('a', 'hello')], selection: caret('a', 5));

        sendNonTextUpdate(selection: const TextSelection.collapsed(offset: 2));

        expect(controller.selection, caret('a', 0));
        expect(connection().pushed, hasLength(1));
      });
    });

    group('Enter (G10) and split policies', () {
      test(r'a \n insertion delta splits and pushes the new window', () {
        build([para('a', 'onetwo')], selection: caret('a', 3));

        sendInsertion('\n');

        final blocks = controller.document.allBlocks;
        expect(blocks, hasLength(2));
        expect(blocks[0].plainText, 'one');
        expect(blocks[1].plainText, 'two');
        expect(controller.selection, caret(blocks[1].id, 0));
        expect(connection().pushed.last.text, '. two');
        expect(
          connection().pushed.last.selection,
          const TextSelection.collapsed(offset: 2),
        );
      });

      test('performAction(newline) splits through the same path', () {
        build([para('a', 'onetwo')], selection: caret('a', 3));

        service.performAction(TextInputAction.newline);

        expect(controller.document.allBlocks, hasLength(2));
        expect(connection().pushed.last.text, '. two');
      });

      test('G10: split keeps checked on the original, new task unchecked', () {
        build([
          typed('t', TaskItemKeys.type, 'todo', metadata: {'checked': true}),
        ], selection: caret('t', 2));

        sendInsertion('\n');

        final blocks = controller.document.allBlocks;
        expect(blocks[0].metadata['checked'], isTrue);
        expect(blocks[1].blockType, TaskItemKeys.type, reason: 'inherit');
        expect(blocks[1].metadata['checked'], isFalse);
      });

      test(r'code block: \n inserts a literal line break, window converges, '
          'nothing pushed', () {
        build([typed('c', CodeBlockKeys.type, 'ab')], selection: caret('c', 1));

        sendInsertion('\n');

        expect(controller.document.allBlocks, hasLength(1));
        expect(controller.document.blockById('c')!.plainText, 'a\nb');
        expect(
          connection().pushed,
          hasLength(1),
          reason: 'convergent — no echo',
        );
      });

      test('Enter on an empty list item converts to the default type', () {
        build([typed('l', ListItemKeys.type, '')], selection: caret('l', 0));

        service.performAction(TextInputAction.newline);

        expect(
          controller.document.blockById('l')!.blockType,
          ParagraphKeys.type,
        );
      });

      test('G10 mid-composition: the split finishes through '
          "terminateComposition('structuralDelta'), quarantine armed", () {
        build([
          typed('t', TaskItemKeys.type, 'ab', metadata: {'checked': false}),
        ], selection: caret('t', 2));
        sendInsertion('가', composing: const TextRange(start: 4, end: 5));
        expect(controller.composing, isNotNull);

        // Samsung/Gboard Korean deliver \n while composing is non-empty —
        // no claim that Enter commits compositions first.
        sendInsertion('\n', composing: const TextRange(start: 4, end: 5));

        final blocks = controller.document.allBlocks;
        expect(blocks, hasLength(2));
        expect(
          blocks[0].plainText,
          'ab가',
          reason: 'syllable committed where it stands',
        );
        expect(controller.composing, isNull);
        expect(service.debugLastTerminateReason, 'structuralDelta');
        expect(connection().pushed.last.composing, TextRange.empty);
        expect(
          service.debugQuarantine,
          (text: '가', offset: 2),
          reason:
              'armed against the post-push syllable echo at the new '
              'block head',
        );
      });
    });

    group('G1: structural backspace through the sentinel', () {
      test('a deletion intersecting [0,2) becomes a structural backspace '
          '(merge policy)', () {
        build([
          para('a', 'prev'),
          para('b', 'hello'),
        ], selection: caret('b', 0));
        expect(shadow().text, '. hello');

        sendDeletion(const TextRange(start: 1, end: 2));

        final blocks = controller.document.allBlocks;
        expect(blocks, hasLength(1));
        expect(blocks[0].plainText, 'prevhello');
        expect(controller.selection, caret('a', 4));
        expect(connection().pushed.last.text, '. prevhello');
        expect(
          connection().pushed.last.selection,
          const TextSelection.collapsed(offset: 6),
        );
      });

      test('backspaceAtStart policy: a heading converts to default', () {
        build([
          para('a', 'prev'),
          typed('h', HeadingKeys.h1, 'title'),
        ], selection: caret('h', 0));

        sendDeletion(const TextRange(start: 1, end: 2));

        expect(controller.document.allBlocks, hasLength(2));
        expect(
          controller.document.blockById('h')!.blockType,
          ParagraphKeys.type,
        );
        expect(connection().pushed.last.text, '. title');
      });

      test('backspaceAtStart policy: a nested list item outdents', () {
        final child = typed('l2', ListItemKeys.type, 'two');
        build([
          TextBlock(
            id: 'l1',
            blockType: ListItemKeys.type,
            segments: [const StyledSegment('one')],
            children: [child],
          ),
        ], selection: caret('l2', 0));

        sendDeletion(const TextRange(start: 1, end: 2));

        expect(controller.document.depthOf(1), 0, reason: 'outdented');
        expect(
          controller.document.blockById('l2')!.blockType,
          ListItemKeys.type,
        );
      });

      test('first block of the document: structural backspace no-ops, '
          'window re-pushed', () {
        build([para('a', 'hello')], selection: caret('a', 0));

        sendDeletion(const TextRange(start: 1, end: 2));

        expect(controller.document.blockById('a')!.plainText, 'hello');
        expect(connection().pushed.last.text, '. hello');
      });

      test('composite deletion [0,7) over ". hello" at block 2 of 2: '
          'previous block merged AND "hello" removed (spec trace)', () {
        build([
          para('a', 'prev'),
          para('b', 'hello'),
        ], selection: caret('b', 5));

        sendDeletion(const TextRange(start: 0, end: 7));

        final blocks = controller.document.allBlocks;
        expect(blocks, hasLength(1));
        expect(blocks[0].plainText, 'prev');
        expect(connection().pushed.last.text, '. prev');
      });

      test('composite-while-composing fixture (G1 guard): deleteSurroundingText'
          '-shaped [0,2) with the composing word preserved → merge applied, '
          'push via terminateComposition, quarantine armed, no assert', () {
        build([para('a', 'prev'), para('b', 'word')], selection: caret('b', 4));

        // The delta preserves the block-start composing word, remapped to
        // [0,4) in its own new text (Android's deleteSurroundingText deletes
        // around the composing region while preserving it).
        sendDeltas([
          TextEditingDeltaDeletion(
            oldText: '. word',
            deletedRange: const TextRange(start: 0, end: 2),
            selection: const TextSelection.collapsed(offset: 4),
            composing: const TextRange(start: 0, end: 4),
          ),
        ]);

        final blocks = controller.document.allBlocks;
        expect(blocks, hasLength(1), reason: 'merge applied');
        expect(blocks[0].plainText, 'prevword');
        expect(service.debugLastTerminateReason, 'structuralDelta');
        expect(controller.composing, isNull);
        expect(connection().pushed.last.text, '. prevword');
        expect(connection().pushed.last.composing, TextRange.empty);
        expect(service.debugQuarantine, (text: 'word', offset: 6));
      });

      test('composite replacement [0,7) → ". world" over ". hello": the '
          'echoed sentinel is stripped — "world" lands, no merge, no '
          'sentinel text in the model (G1 decomposition for replacements)', () {
        build([
          para('a', 'prev'),
          para('b', 'hello'),
        ], selection: caret('b', 5));
        expect(shadow().text, '. hello');

        // setComposingRegion(0,7) + commitText: one replacement spanning
        // the sentinel, with the engine echoing the sentinel prefix back.
        sendReplacement(const TextRange(start: 0, end: 7), '. world');

        final blocks = controller.document.allBlocks;
        expect(blocks, hasLength(2), reason: 'echoed sentinel ⇒ no merge');
        expect(blocks[1].plainText, 'world');
        expect(shadow().text, '. world');
      });

      test('composite replacement [0,7) → "world" over ". hello": the '
          'consumed sentinel maps to structural backspace AND the '
          'replacement text lands (the deletion half warrants the merge)', () {
        build([
          para('a', 'prev'),
          para('b', 'hello'),
        ], selection: caret('b', 5));

        sendReplacement(const TextRange(start: 0, end: 7), 'world');

        final blocks = controller.document.allBlocks;
        expect(blocks, hasLength(1), reason: 'sentinel consumed ⇒ merge');
        expect(blocks.single.plainText, 'prevworld');
        expect(connection().pushed.last.text, '. prevworld');
      });

      test('G9: backspace deltas on a selected image arrive as ordinary '
          'deletions of the ~ buffer', () {
        build([
          para('a', 'x'),
          TextBlock(id: 'img', blockType: ImageKeys.type),
        ]);
        controller.setSelection(
          DocSelection(
            base: const DocPosition('img', 0),
            extent: const DocPosition('img', 1),
          ),
        );
        expect(shadow().text, '. ~');

        sendDeletion(const TextRange(start: 2, end: 3));

        expect(controller.document.allBlocks, hasLength(1));
        expect(controller.selection, caret('a', 1), reason: 'G9 caret');
        expect(connection().pushed.last.text, '. x');
      });

      test('type-over a selected image replaces it with a text block', () {
        build([
          para('a', 'x'),
          TextBlock(id: 'img', blockType: ImageKeys.type),
        ]);
        controller.setSelection(
          DocSelection(
            base: const DocPosition('img', 0),
            extent: const DocPosition('img', 1),
          ),
        );

        sendReplacement(const TextRange(start: 2, end: 3), 'y');

        final blocks = controller.document.allBlocks;
        expect(blocks, hasLength(2));
        expect(blocks[1].blockType, ParagraphKeys.type);
        expect(blocks[1].plainText, 'y');
        expect(connection().pushed, hasLength(2), reason: 'one selection push');
      });
    });

    group('stale-delta guard', () {
      test('a mismatched oldText drops the batch and re-pushes the window', () {
        build([para('a', 'hello')], selection: caret('a', 5));

        sendDeltas([
          const TextEditingDeltaInsertion(
            oldText: '. stale-buffer',
            textInserted: 'x',
            insertionOffset: 7,
            selection: TextSelection.collapsed(offset: 8),
            composing: TextRange.empty,
          ),
        ]);

        expect(
          controller.document.blockById('a')!.plainText,
          'hello',
          reason: 'worst case a lost correction, never corruption',
        );
        expect(connection().pushed.last.text, '. hello');
        expect(service.debugLastDropReason, 'staleDelta');
      });

      test('the remainder of the batch after a mismatch is dropped', () {
        build([para('a', 'hello')], selection: caret('a', 5));

        sendDeltas([
          const TextEditingDeltaInsertion(
            oldText: '. wrong',
            textInserted: 'x',
            insertionOffset: 7,
            selection: TextSelection.collapsed(offset: 8),
            composing: TextRange.empty,
          ),
          const TextEditingDeltaInsertion(
            oldText: '. wrongx',
            textInserted: 'y',
            insertionOffset: 8,
            selection: TextSelection.collapsed(offset: 9),
            composing: TextRange.empty,
          ),
        ]);

        expect(controller.document.blockById('a')!.plainText, 'hello');
      });

      test("while composing, the re-push routes through "
          "terminateComposition('staleDelta')", () {
        build([para('a', '')], selection: caret('a', 0));
        sendInsertion('k', composing: const TextRange(start: 2, end: 3));
        expect(controller.composing, isNotNull);

        sendDeltas([
          const TextEditingDeltaInsertion(
            oldText: '. mismatch',
            textInserted: 'x',
            insertionOffset: 2,
            selection: TextSelection.collapsed(offset: 3),
            composing: TextRange.empty,
          ),
        ]);

        expect(service.debugLastTerminateReason, 'staleDelta');
        expect(controller.composing, isNull);
        expect(connection().pushed.last.composing, TextRange.empty);
      });
    });

    group('G4: autocorrect replacement racing Enter (mechanical cases)', () {
      test('case 1: replacement + newline in ONE batch apply sequentially '
          'against the evolving shadow', () {
        build([para('a', 'teh')], selection: caret('a', 3));

        sendDeltas([
          const TextEditingDeltaReplacement(
            oldText: '. teh',
            replacedRange: TextRange(start: 2, end: 5),
            replacementText: 'the',
            selection: TextSelection.collapsed(offset: 5),
            composing: TextRange.empty,
          ),
          const TextEditingDeltaInsertion(
            oldText: '. the',
            textInserted: '\n',
            insertionOffset: 5,
            selection: TextSelection.collapsed(offset: 6),
            composing: TextRange.empty,
          ),
        ]);

        final blocks = controller.document.allBlocks;
        expect(blocks, hasLength(2));
        expect(blocks[0].plainText, 'the', reason: 'split sees corrected text');
        expect(blocks[1].plainText, '');
        expect(connection().pushed.last.text, '. ');
      });

      test('case 3: the action arrives first; the late replacement delta '
          'references the pre-split buffer and the guard drops it', () {
        build([para('a', 'teh')], selection: caret('a', 3));

        service.performAction(TextInputAction.newline);
        expect(controller.document.allBlocks, hasLength(2));

        // The autocorrect replacement lands after the split: its oldText is
        // the pre-split buffer, not the freshly pushed window.
        sendDeltas([
          const TextEditingDeltaReplacement(
            oldText: '. teh',
            replacedRange: TextRange(start: 2, end: 5),
            replacementText: 'the',
            selection: TextSelection.collapsed(offset: 5),
            composing: TextRange.empty,
          ),
        ]);

        // The correction is lost; the document is never corrupted.
        expect(controller.document.allBlocks[0].plainText, 'teh');
        expect(controller.document.allBlocks, hasLength(2));
        expect(service.debugLastDropReason, 'staleDelta');
        expect(connection().pushed.last.text, '. ');
      });
    });

    group('terminateComposition choke point', () {
      test('a non-IME edit while composing terminates with externalEdit', () {
        build([para('a', '')], selection: caret('a', 0));
        sendInsertion('k', composing: const TextRange(start: 2, end: 3));
        expect(controller.composing, isNotNull);

        controller.insertText('!');

        expect(controller.composing, isNull);
        expect(service.debugLastTerminateReason, 'externalEdit');
        expect(connection().pushed.last.composing, TextRange.empty);
      });

      test('a non-IME selection change while composing — tap-to-caret in the '
          'composing block itself — terminates', () {
        build([para('a', 'abc')], selection: caret('a', 3));
        sendInsertion('k', composing: const TextRange(start: 5, end: 6));
        expect(controller.composing, isNotNull);

        controller.setSelection(caret('a', 0));

        expect(controller.composing, isNull);
        expect(service.debugLastTerminateReason, 'externalEdit');
      });

      test("undo while composing terminates with reason 'undo' and arms the "
          'quarantine', () {
        build([para('a', '')], selection: caret('a', 0));
        sendInsertion('녕', composing: const TextRange(start: 2, end: 3));

        controller.undo();

        expect(service.debugLastTerminateReason, 'undo');
        expect(controller.composing, isNull);
        expect(controller.document.blockById('a')!.plainText, '');
        expect(service.debugQuarantine, (text: '녕', offset: 2));
      });

      test('Android: terminate performs a connection-level re-attach for '
          'every reason with a live connection', () {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        build([para('a', '')], selection: caret('a', 0));
        sendInsertion('k', composing: const TextRange(start: 2, end: 3));
        expect(connections, hasLength(1));

        controller.setSelection(caret('a', 0)); // externalEdit terminate

        expect(connections, hasLength(2), reason: 'detach + re-attach');
        expect(connections.first.isClosed, isTrue);
        expect(connections.last.shown, isTrue);
        expect(connections.last.pushed, isNotEmpty);
        expect(connections.last.pushed.last.composing, TextRange.empty);
      });

      test('non-Android: terminate pushes through the existing connection', () {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        build([para('a', '')], selection: caret('a', 0));
        sendInsertion('k', composing: const TextRange(start: 2, end: 3));

        controller.setSelection(caret('a', 0));

        expect(connections, hasLength(1));
        expect(connection().pushed.last.composing, TextRange.empty);
      });

      test('connectionClosed: detached, composition cleared, push skipped, '
          'lazy re-attach on the next edit', () {
        build([para('a', 'hi')], selection: caret('a', 2));
        sendInsertion('k', composing: const TextRange(start: 4, end: 5));
        final pushesBefore = connection().pushed.length;

        service.connectionClosed();

        expect(service.isAttached, isFalse);
        expect(
          connection().closedReceived,
          isTrue,
          reason:
              'the framework is told (connectionClosedReceived) so '
              "TextInput's current-connection bookkeeping clears",
        );
        expect(controller.composing, isNull);
        expect(service.debugLastTerminateReason, 'connectionClosed');
        expect(
          connection().pushed.length,
          pushesBefore,
          reason: 'push skipped',
        );

        // The next edit lazily re-attaches and re-serializes.
        controller.insertText('!');
        expect(service.isAttached, isTrue);
        expect(connections, hasLength(2));
        expect(connections.last.pushed.last.text, '. hik!');
      });
    });

    group('post-terminate echo quarantine (G7/G10)', () {
      test('undo mid-Hangul: the immediate re-commit of the held syllable is '
          'dropped; the document equals the undo snapshot', () {
        build([para('a', '')], selection: caret('a', 0));
        sendInsertion('안', composing: const TextRange(start: 2, end: 3));
        sendInsertion('녕', at: 3, composing: const TextRange(start: 3, end: 4));
        expect(controller.document.blockById('a')!.plainText, '안녕');

        controller.undo(); // terminate('undo'); quarantine = ('녕', 2)?

        // The keyboard re-commits its held syllable against the freshly
        // restored window — oldText matches the shadow exactly, so the
        // stale-delta guard is structurally blind to it.
        sendInsertion('녕', at: shadow().selection.start);

        expect(
          controller.document.blockById('a')!.plainText,
          '',
          reason: 'the echo is quarantined; undone text is not resurrected',
        );
        expect(service.debugLastDropReason, 'echoQuarantine');
        expect(service.debugQuarantineArmed, isFalse, reason: 'one batch');
      });

      test('the quarantine covers exactly ONE batch — a genuine retype in a '
          'later batch lands', () {
        build([para('a', '')], selection: caret('a', 0));
        sendInsertion('녕', composing: const TextRange(start: 2, end: 3));
        controller.undo();

        // First batch after the push: an unrelated update disarms.
        sendNonTextUpdate();
        // Second batch: the same text at the same position is a real retype.
        sendInsertion('녕', at: 2);

        expect(controller.document.blockById('a')!.plainText, '녕');
      });

      test('an intervening non-IME push disarms the quarantine: a matching '
          'insertion against the NEWER window is genuine input, not an '
          'echo, and is APPLIED', () {
        build([para('a', 'ab')], selection: caret('a', 2));
        sendInsertion('녕', composing: const TextRange(start: 4, end: 5));

        controller.undo(); // terminate('undo'); quarantine = ('녕', 4)
        expect(service.debugQuarantine, (text: '녕', offset: 4));

        // A tap elsewhere re-pushes the window (clause (b)): the engine now
        // holds newer state than the terminate push, so the quarantine
        // signature no longer identifies an echo.
        controller.setSelection(caret('a', 0));
        expect(service.debugQuarantineArmed, isFalse);

        sendInsertion('녕', at: 4);

        expect(controller.document.blockById('a')!.plainText, 'ab녕');
        expect(service.debugLastDropReason, isNot('echoQuarantine'));
      });

      test('an insertion of different text at the quarantined position is '
          'not dropped', () {
        build([para('a', '')], selection: caret('a', 0));
        sendInsertion('녕', composing: const TextRange(start: 2, end: 3));
        controller.undo();

        sendInsertion('x', at: 2);

        expect(controller.document.blockById('a')!.plainText, 'x');
      });
    });

    group('structural-while-composing divergence rule (G10 refined)', () {
      test('cross-block composing type-over trace: select across two blocks, '
          'type "ki" via composing replacements → merged block carries き '
          'with the composition intact, one undo entry', () {
        build([para('a', 'one'), para('b', 'two')]);
        controller.setSelection(
          DocSelection(
            base: const DocPosition('a', 1),
            extent: const DocPosition('b', 3),
          ),
        );
        expect(shadow().text, '. one\ntwo');
        final pushesBefore = connection().pushed.length;

        // ONE replacement delta: selection → first marked letter, composing
        // non-empty. The deletion crosses the \n joint (merge-via-
        // replacement); the post-apply window equals the shadow, so the
        // composition must survive and NOTHING may be pushed (#1641:
        // pushing mid-composition restarts composition → "kい" not き).
        sendReplacement(
          const TextRange(start: 3, end: 9),
          'k',
          composing: const TextRange(start: 3, end: 4),
        );

        expect(controller.document.allBlocks, hasLength(1));
        expect(controller.document.blockById('a')!.plainText, 'ok');
        expect(
          controller.composing,
          const ComposingState(
            blockId: 'a',
            range: TextRange(start: 1, end: 2),
          ),
          reason: 'remapped block-locally into the merged block',
        );
        expect(
          connection().pushed.length,
          pushesBefore,
          reason: 'sent nothing',
        );

        // Conversion: 'k' → 'き', still composing.
        sendReplacement(
          const TextRange(start: 3, end: 4),
          'き',
          composing: const TextRange(start: 3, end: 4),
        );
        expect(controller.document.blockById('a')!.plainText, 'oき');
        expect(controller.composing, isNotNull);
        expect(connection().pushed.length, pushesBefore);

        // Commit, then one undo restores both blocks: one undo entry.
        sendNonTextUpdate(selection: const TextSelection.collapsed(offset: 4));
        expect(controller.composing, isNull);

        controller.undo();
        expect(controller.document.allBlocks, hasLength(2));
        expect(controller.document.blockById('a')!.plainText, 'one');
        expect(controller.document.blockById('b')!.plainText, 'two');
      });

      test('type-over of a selection spanning a void: one replacement delta '
          'removes the swept void and merges the text endpoints', () {
        build([
          para('a', 'one'),
          TextBlock(id: 'img', blockType: ImageKeys.type),
          para('b', 'two'),
        ]);
        controller.setSelection(
          DocSelection(
            base: const DocPosition('a', 1),
            extent: const DocPosition('b', 2),
          ),
        );
        expect(shadow().text, '. one\n~\ntwo');

        sendReplacement(const TextRange(start: 3, end: 10), 'k');

        final blocks = controller.document.allBlocks;
        expect(blocks, hasLength(1));
        expect(blocks.single.plainText, 'oko');
        expect(controller.document.blockById('img'), isNull);
      });
    });

    group('G3: composing vs input rules (latch + run path)', () {
      test('insert-pattern rules run immediately on committed typing', () {
        build([para('a', '#')], selection: caret('a', 1));

        sendInsertion(' ');

        expect(controller.document.blockById('a')!.blockType, HeadingKeys.h1);
        expect(controller.document.blockById('a')!.plainText, '');
        expect(controller.selection, caret('a', 0));
        expect(
          connection().pushed.last.text,
          '. ',
          reason: 'the rule transform re-serializes the buffer',
        );
      });

      test('the divider rule fires through the run path', () {
        build([para('a', '--')], selection: caret('a', 2));

        sendInsertion('-');

        final blocks = controller.document.allBlocks;
        expect(blocks[0].blockType, DividerKeys.type);
        expect(blocks, hasLength(2));
        expect(controller.selection, caret(blocks[1].id, 0));
      });

      test('insert + rule transform is ONE undo entry', () {
        build([para('a', '#')], selection: caret('a', 1));

        sendInsertion(' ');
        controller.undo();

        expect(
          controller.document.blockById('a')!.blockType,
          ParagraphKeys.type,
        );
        expect(controller.document.blockById('a')!.plainText, '#');
      });

      test('mid-composition, "# " is just composing text: the rule is '
          'DEFERRED and the composing region never invalidated', () {
        build([para('a', '')], selection: caret('a', 0));

        sendInsertion('#', composing: const TextRange(start: 2, end: 3));
        sendReplacement(
          const TextRange(start: 2, end: 3),
          '# ',
          composing: const TextRange(start: 2, end: 4),
        );

        expect(
          controller.document.blockById('a')!.blockType,
          ParagraphKeys.type,
          reason: 'deferred, not fired',
        );
        expect(
          controller.composing,
          const ComposingState(
            blockId: 'a',
            range: TextRange(start: 0, end: 2),
          ),
        );
        expect(connection().pushed, hasLength(1), reason: 'nothing pushed');
      });

      test('the latch fires on a NonTextUpdate commit (no pending '
          'transaction exists — the post-state contract)', () {
        build([para('a', '')], selection: caret('a', 0));
        sendInsertion('#', composing: const TextRange(start: 2, end: 3));
        sendReplacement(
          const TextRange(start: 2, end: 3),
          '# ',
          composing: const TextRange(start: 2, end: 4),
        );

        sendNonTextUpdate(selection: const TextSelection.collapsed(offset: 4));

        expect(controller.document.blockById('a')!.blockType, HeadingKeys.h1);
        expect(controller.document.blockById('a')!.plainText, '');
        expect(connection().pushed.last.text, '. ');
      });

      test('a replacement-commit batch fires the rules with the committed '
          'range (the multi-character InsertText case)', () {
        build([para('a', '')], selection: caret('a', 0));
        sendInsertion('＃', composing: const TextRange(start: 2, end: 3));

        // The IME commits by replacing the composing region with the final
        // text, composing cleared — the edit IS the committed range.
        sendReplacement(const TextRange(start: 2, end: 3), '# ');

        expect(controller.document.blockById('a')!.blockType, HeadingKeys.h1);
      });

      test('a composing region set over pre-existing text (setComposingRegion, '
          'no edit) never arms the latch: ending the composition with zero '
          'text change does not convert', () {
        build([para('a', '---')], selection: caret('a', 3));
        expect(shadow().text, '. ---');

        // The IME marks the existing dashes for composition — a
        // NonTextUpdate-only batch, nothing inserted.
        sendNonTextUpdate(composing: const TextRange(start: 2, end: 5));
        expect(controller.composing, isNotNull);

        // The composition ends with no edit. Rules fire on typed
        // characters; with zero text change there is nothing to fire on.
        sendNonTextUpdate();

        expect(controller.composing, isNull);
        expect(
          controller.document.blockById('a')!.blockType,
          ParagraphKeys.type,
          reason: 'no spontaneous divider conversion',
        );
        expect(controller.document.blockById('a')!.plainText, '---');
      });

      test('latch invalidation: a non-IME edit before the composition ends '
          'clears the latch — it can never fire against unmatched text', () {
        build([para('a', '')], selection: caret('a', 0));
        sendInsertion('#', composing: const TextRange(start: 2, end: 3));
        sendReplacement(
          const TextRange(start: 2, end: 3),
          '# ',
          composing: const TextRange(start: 2, end: 4),
        );

        controller.insertText('!'); // terminates; latch cleared

        // A later commit-shaped update must not fire the stale latch.
        sendNonTextUpdate();
        expect(
          controller.document.blockById('a')!.blockType,
          ParagraphKeys.type,
        );
      });
    });

    group('composition-scoped undo (kana trace)', () {
      test('compose 3 kana, convert, commit, undo once → the entire word is '
          'gone, composing null, hardware Enter splits normally', () {
        build([para('a', '')], selection: caret('a', 0));

        sendInsertion('に', composing: const TextRange(start: 2, end: 3));
        sendInsertion('ほ', at: 3, composing: const TextRange(start: 2, end: 4));
        sendInsertion('ん', at: 4, composing: const TextRange(start: 2, end: 5));
        // Convert via candidate selection, then commit.
        sendReplacement(
          const TextRange(start: 2, end: 5),
          '日本',
          composing: const TextRange(start: 2, end: 4),
        );
        sendNonTextUpdate(selection: const TextSelection.collapsed(offset: 4));
        expect(controller.document.blockById('a')!.plainText, '日本');
        expect(controller.composing, isNull);

        controller.undo();

        expect(
          controller.document.blockById('a')!.plainText,
          '',
          reason: 'one undo entry for the whole composition',
        );
        expect(controller.composing, isNull);
        expect(controller.canUndo, isFalse);

        // Hardware Enter is not wedged by stale composing state.
        controller.insertNewline();
        expect(controller.document.allBlocks, hasLength(2));
      });

      test('a mid-composition batch still clears redo (it is an edit)', () {
        build([para('a', '')], selection: caret('a', 0));
        sendInsertion('x');
        controller.undo();
        expect(controller.canRedo, isTrue);

        sendInsertion('k', composing: const TextRange(start: 2, end: 3));
        sendInsertion('a', at: 3, composing: const TextRange(start: 2, end: 4));

        expect(controller.canRedo, isFalse);
      });
    });

    group('capped window (whole-selection classification)', () {
      test('a replacement touching the elided interior maps to the model '
          'selection directly', () {
        final blocks = [for (var i = 0; i < 40; i++) para('b$i', 'block $i')];
        build(blocks);
        controller.setSelection(
          DocSelection(
            base: const DocPosition('b0', 0),
            extent: DocPosition('b39', blocks.last.length),
          ),
        );
        expect(shadow().text, '. block 0\n~\nblock 39');

        sendReplacement(TextRange(start: 2, end: shadow().text.length), 'z');

        expect(controller.document.allBlocks, hasLength(1));
        expect(controller.document.allBlocks.single.plainText, 'z');
      });
    });

    group('detach / dispose', () {
      test('detach closes the connection and clears composing + shadow', () {
        build([para('a', 'hi')], selection: caret('a', 2));
        sendInsertion('k', composing: const TextRange(start: 4, end: 5));

        service.detach();

        expect(service.isAttached, isFalse);
        expect(connection().isClosed, isTrue);
        expect(controller.composing, isNull);
        expect(service.currentTextEditingValue, isNull);
      });

      test('dispose unregisters the external-change handler', () {
        build([para('a', 'hi')], selection: caret('a', 2));

        service.dispose();

        expect(controller.imeExternalChangeHandler, isNull);
        controller.insertText('!'); // must not throw into a disposed service
        expect(controller.document.blockById('a')!.plainText, 'hi!');
      });
    });
  });
}

/// A hand-rolled engine connection: records pushes and lifecycle so the
/// shadow-buffer suite asserts the no-echo invariant directly.
class FakeImeConnection implements ImeConnection {
  final List<TextEditingValue> pushed = [];
  final List<String> geometryCalls = [];
  bool shown = false;
  bool isClosed = false;
  bool closedReceived = false;

  @override
  bool get attached => !isClosed;

  @override
  void show() => shown = true;

  @override
  void connectionClosedReceived() => closedReceived = true;

  @override
  void setEditingState(TextEditingValue value) => pushed.add(value);

  @override
  void setEditableSizeAndTransform(Size editableBoxSize, Matrix4 transform) =>
      geometryCalls.add('setEditableSizeAndTransform');

  @override
  void setComposingRect(Rect rect) => geometryCalls.add('setComposingRect');

  @override
  void setCaretRect(Rect rect) => geometryCalls.add('setCaretRect');

  @override
  void close() => isClosed = true;
}
