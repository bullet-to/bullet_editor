/// Round-trip tests driven by the CommonMark spec (spec.json).
///
/// Strategy:
/// 1. Load spec examples, filter to sections our codec handles.
/// 2. For each example: decode(markdown) must not throw.
/// 3. For clean examples: decode(encode(decode(md))) ≡ decode(md).
///    We compare block types, plain text, inline styles, and tree depth —
///    not IDs (those are generated fresh each decode).
/// 4. Additional hand-written edge-case tests beyond the spec.
library;

import 'dart:convert';
import 'dart:io';

import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Structural snapshot of a document, ignoring generated block IDs.
List<Map<String, dynamic>> _snapshot(Document doc) {
  return _snapshotBlocks(doc.blocks, 0);
}

List<Map<String, dynamic>> _snapshotBlocks(List<TextBlock> blocks, int depth) {
  final result = <Map<String, dynamic>>[];
  for (final b in blocks) {
    result.add({
      'blockType': b.blockType,
      'text': b.plainText,
      'depth': depth,
      'styles': b.segments
          .map(
            (s) => {
              'text': s.text,
              'styles': s.styles.toList()
                ..sort((a, b) => a.toString().compareTo(b.toString())),
              if (s.attributes.isNotEmpty) 'attrs': s.attributes,
            },
          )
          .toList(),
      if (b.metadata.isNotEmpty) 'metadata': b.metadata,
    });
    result.addAll(_snapshotBlocks(b.children, depth + 1));
  }
  return result;
}

/// Sections from the CommonMark spec that map to features we support.
const _supportedSections = {
  'ATX headings',
  'Paragraphs',
  'Thematic breaks',
  'Emphasis and strong emphasis',
  'Links',
  // 'List items' and 'Lists' use CommonMark list syntax which differs from
  // our simple `- ` prefix detection (continuation lines, lazy continuation,
  // etc.). We test list round-trips separately with our own examples.
};

/// Some spec examples use features we intentionally don't support (H4-H6,
/// setext, code spans inside emphasis, etc.) or rely on CommonMark nuances
/// our simple parser doesn't implement. Skip them individually.
const _skipExamples = <int>{
  // (H4-H6 now supported — example 62 removed from skip list)

  // `---` after text = setext heading, not thematic break.
  59, 96,

  // Thematic breaks in list context — our list decoder interferes.
  57, 58, 60, 61,

  // `*-*` is emphasis around `-`, not a thematic break.
  56,

  // Non-thematic-break patterns (e.g. `+++`, `===`).
  44, 45, 46, 55,

  // `----` after paragraph = setext heading context.
  49,

  // `****` thematic breaks around headings (interacts with emphasis).
  77,

  // --- Emphasis: complex nesting beyond simple regex ---
  // CommonMark's 17-rule emphasis algorithm handles deeply nested and
  // overlapping delimiter runs that our simple regex approach does not.
  393, // `*(**foo**)*` — italic wrapping bold with parens
  394, // multi-line emphasis with nested bold/italic
  410, // `*foo **bar** baz*` — italic around bold
  411, // `*foo**bar**baz*` — italic around bold, no spaces
  412, // `*foo**bar*` — ambiguous nesting
  414, // `*foo **bar***` — shared closing delimiter
  415, // `*foo**bar***` — ambiguous shared closing
  417, // `foo******bar*********baz` — 6+ star runs
  418, // `*foo **bar *baz* bim** bop*` — interleaved nesting
  427, // `**foo **bar****` — adjacent closing
  432, // multi-line interleaved emphasis
  445, // `****foo*` — mismatched opener/closer counts
  447, // `*foo****` — mismatched opener/closer counts
  464, // `****foo****` — 4-star runs
  466, // `******foo******` — 6-star runs
  // --- Links: reference-style links (not supported) ---
  // We only support inline links `[text](url)`, not reference-style
  // `[text][ref]` or `[text]` with `[ref]: /url "title"` definitions.
  527, 528, 529, 530, 531, 532, 533, 534, 535, 536, 537, 538,
  539, 540, 541, 542, 543, 544, 545, 546, 547, 548, 549, 550,
  551, 552, 553, 554, 555, 556, 557, 558, 559, 560, 561, 562,
  563, 564, 565, 566, 567, 568, 569, 570, 571,
};

// ---------------------------------------------------------------------------
// Spec-driven tests
// ---------------------------------------------------------------------------

void main() {
  final specFile = File('test/codec/fixtures/commonmark_spec.json');
  if (!specFile.existsSync()) {
    // CI might not have the fixture — skip gracefully.
    return;
  }

  final specJson = jsonDecode(specFile.readAsStringSync()) as List<dynamic>;
  final codec = MarkdownCodec();

  group('CommonMark spec — decode does not throw', () {
    for (final entry in specJson) {
      final example = entry as Map<String, dynamic>;
      final section = example['section'] as String;
      final num = example['example'] as int;
      if (!_supportedSections.contains(section)) continue;
      if (_skipExamples.contains(num)) continue;

      test('example $num ($section)', () {
        final md = (example['markdown'] as String).trimRight();
        // Should never throw.
        final doc = codec.decode(md);
        expect(
          doc.blocks,
          isNotEmpty,
          reason: 'Decoded document should have at least one block',
        );
      });
    }
  });

  group('CommonMark spec — idempotent round-trip', () {
    for (final entry in specJson) {
      final example = entry as Map<String, dynamic>;
      final section = example['section'] as String;
      final num = example['example'] as int;
      if (!_supportedSections.contains(section)) continue;
      if (_skipExamples.contains(num)) continue;

      test('example $num ($section)', () {
        final md = (example['markdown'] as String).trimRight();
        final first = codec.decode(md);
        final reEncoded = codec.encode(first);
        final second = codec.decode(reEncoded);

        final snap1 = _snapshot(first);
        final snap2 = _snapshot(second);

        expect(
          snap2,
          equals(snap1),
          reason:
              'decode(encode(decode(md))) should equal decode(md)\n'
              'markdown: ${json.encode(md)}\n'
              're-encoded: ${json.encode(reEncoded)}',
        );
      });
    }
  });

  // -------------------------------------------------------------------------
  // Hand-written edge-case tests
  // -------------------------------------------------------------------------

  group('Edge cases — block round-trips', () {
    test('empty string produces single empty block', () {
      final doc = codec.decode('');
      expect(doc.blocks.length, 1);
      expect(doc.blocks[0].plainText, '');
    });

    test('single paragraph round-trip', () {
      _assertRoundTrip(codec, 'Hello world');
    });

    test('multiple paragraphs', () {
      _assertRoundTrip(codec, 'First\n\nSecond\n\nThird');
    });

    test('H1 round-trip', () {
      _assertRoundTrip(codec, '# Hello');
    });

    test('H2 round-trip', () {
      _assertRoundTrip(codec, '## Hello');
    });

    test('H3 round-trip', () {
      _assertRoundTrip(codec, '### Hello');
    });

    test('divider round-trip', () {
      _assertRoundTrip(codec, '---');
    });

    test('divider between paragraphs', () {
      _assertRoundTrip(codec, 'Above\n\n---\n\nBelow');
    });

    test('bullet list round-trip', () {
      _assertRoundTrip(codec, '- first\n- second\n- third');
    });

    test('nested bullet list', () {
      _assertRoundTrip(codec, '- parent\n  - child\n  - sibling');
    });

    test('deeply nested list', () {
      _assertRoundTrip(codec, '- a\n  - b\n    - c\n      - d');
    });

    test('numbered list round-trip', () {
      _assertRoundTrip(codec, '1. first\n2. second');
    });

    test('task items round-trip', () {
      _assertRoundTrip(codec, '- [ ] todo\n- [x] done');
    });

    test('mixed block types', () {
      _assertRoundTrip(
        codec,
        '# Title\n\nParagraph\n\n- item\n\n---\n\n1. one',
      );
    });

    test('empty paragraph between blocks', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.paragraph,
          segments: [const StyledSegment('above')],
        ),
        TextBlock(id: 'b', blockType: BlockType.paragraph, segments: const []),
        TextBlock(
          id: 'c',
          blockType: BlockType.h2,
          segments: [const StyledSegment('Heading')],
        ),
      ]);
      final md = codec.encode(doc);
      final decoded = codec.decode(md);
      final reEncoded = codec.encode(decoded);
      final reParsed = codec.decode(reEncoded);
      expect(_snapshot(reParsed), equals(_snapshot(decoded)));
    });

    test('list item with paragraph child', () {
      _assertRoundTrip(codec, '- parent\n  child paragraph');
    });

    test('heading followed by list', () {
      _assertRoundTrip(codec, '# Title\n\n- one\n- two');
    });
  });

  group('Edge cases — inline round-trips', () {
    test('bold text', () {
      _assertRoundTrip(codec, 'Hello **bold** world');
    });

    test('italic text', () {
      _assertRoundTrip(codec, 'Hello *italic* world');
    });

    test('strikethrough text', () {
      _assertRoundTrip(codec, 'Hello ~~strike~~ world');
    });

    test('bold+italic combined', () {
      _assertRoundTrip(codec, '***bold italic***');
    });

    test('nested bold with italic subset', () {
      _assertRoundTrip(codec, '**1 *2* 3**');
    });

    test('link', () {
      _assertRoundTrip(codec, 'Visit [Google](https://google.com) today');
    });

    test('bold link', () {
      _assertRoundTrip(codec, 'Click **[here](https://example.com)** now');
    });

    test('multiple links in one paragraph', () {
      _assertRoundTrip(codec, '[A](url1) and [B](url2)');
    });

    test('link with special chars in URL', () {
      _assertRoundTrip(codec, '[text](https://example.com/path?q=1&r=2)');
    });

    test('adjacent styled segments', () {
      _assertRoundTrip(codec, '**bold***italic*');
    });

    test('bold in heading', () {
      _assertRoundTrip(codec, '# Hello **bold** world');
    });

    test('link in list item', () {
      _assertRoundTrip(codec, '- Click [here](url)');
    });

    test('all styles in one paragraph', () {
      _assertRoundTrip(
        codec,
        'Normal **bold** *italic* ~~strike~~ [link](url)',
      );
    });
  });

  group('Edge cases — adversarial input', () {
    test('unclosed bold delimiter treated as plain text', () {
      final doc = codec.decode('Hello **world');
      expect(doc.blocks[0].plainText, contains('Hello'));
      expect(doc.blocks[0].plainText, contains('world'));
    });

    test('unclosed italic delimiter treated as plain text', () {
      final doc = codec.decode('Hello *world');
      expect(doc.blocks[0].plainText, contains('Hello'));
      expect(doc.blocks[0].plainText, contains('world'));
    });

    test('empty bold delimiters', () {
      final doc = codec.decode('before **** after');
      // Should not crash; content preserved.
      expect(doc.blocks[0].plainText, contains('before'));
      expect(doc.blocks[0].plainText, contains('after'));
    });

    test('empty link text', () {
      final doc = codec.decode('[](https://example.com)');
      // Should decode without crashing.
      expect(doc.blocks, isNotEmpty);
    });

    test('link without URL', () {
      final doc = codec.decode('[text]()');
      expect(doc.blocks, isNotEmpty);
    });

    test('nested brackets in link text', () {
      final doc = codec.decode('[text [inner]](url)');
      expect(doc.blocks, isNotEmpty);
    });

    test('very long line does not hang', () {
      final long = 'a' * 10000;
      final doc = codec.decode(long);
      expect(doc.blocks[0].plainText.length, 10000);
    });

    test('many paragraphs does not hang', () {
      final md = List.generate(500, (i) => 'Paragraph $i').join('\n\n');
      final doc = codec.decode(md);
      expect(doc.blocks.length, 500);
    });

    test('only whitespace', () {
      final doc = codec.decode('   \n\n   \n\n   ');
      // Should not crash.
      expect(doc.blocks, isNotEmpty);
    });

    test('only newlines', () {
      final doc = codec.decode('\n\n\n\n\n');
      expect(doc.blocks, isNotEmpty);
    });

    test('hash without space is not heading', () {
      final doc = codec.decode('#hashtag');
      expect(doc.blocks[0].blockType, BlockType.paragraph);
      expect(doc.blocks[0].plainText, '#hashtag');
    });

    test('dash without space is not list', () {
      final doc = codec.decode('-no space');
      expect(doc.blocks[0].blockType, BlockType.paragraph);
    });

    test('number without dot-space is not numbered list', () {
      final doc = codec.decode('1.no space');
      expect(doc.blocks[0].blockType, BlockType.paragraph);
    });

    test('deeply nested list does not stack overflow', () {
      // 20 levels deep.
      final lines = List.generate(20, (i) => '${'  ' * i}- level$i');
      final md = lines.join('\n');
      final doc = codec.decode(md);
      expect(doc.blocks, isNotEmpty);
    });
  });

  group('Edge cases — encode specifics', () {
    test('consecutive list items use tight separator', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.listItem,
          segments: [const StyledSegment('one')],
        ),
        TextBlock(
          id: 'b',
          blockType: BlockType.listItem,
          segments: [const StyledSegment('two')],
        ),
      ]);
      expect(codec.encode(doc), '- one\n- two');
    });

    test('paragraph after list uses double newline', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.listItem,
          segments: [const StyledSegment('item')],
        ),
        TextBlock(
          id: 'b',
          blockType: BlockType.paragraph,
          segments: [const StyledSegment('para')],
        ),
      ]);
      expect(codec.encode(doc), '- item\n\npara');
    });

    test('numbered list ordinals are sequential', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.numberedList,
          segments: [const StyledSegment('a')],
        ),
        TextBlock(
          id: 'b',
          blockType: BlockType.numberedList,
          segments: [const StyledSegment('b')],
        ),
        TextBlock(
          id: 'c',
          blockType: BlockType.numberedList,
          segments: [const StyledSegment('c')],
        ),
      ]);
      expect(codec.encode(doc), '1. a\n2. b\n3. c');
    });

    test('nested list indentation uses 2 spaces', () {
      final doc = Document([
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
      ]);
      expect(codec.encode(doc), '- parent\n  - child');
    });

    test('task item checked state encodes correctly', () {
      final doc = Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.taskItem,
          segments: [const StyledSegment('a')],
          metadata: {'checked': false},
        ),
        TextBlock(
          id: 'b',
          blockType: BlockType.taskItem,
          segments: [const StyledSegment('b')],
          metadata: {'checked': true},
        ),
      ]);
      expect(codec.encode(doc), '- [ ] a\n- [x] b');
    });
  });
}

/// Assert that decode(encode(decode(md))) ≡ decode(md).
void _assertRoundTrip(MarkdownCodec codec, String md) {
  final first = codec.decode(md);
  final encoded = codec.encode(first);
  final second = codec.decode(encoded);

  final snap1 = _snapshot(first);
  final snap2 = _snapshot(second);

  expect(
    snap2,
    equals(snap1),
    reason:
        'Round-trip failed.\n'
        'Input:      ${json.encode(md)}\n'
        'Re-encoded: ${json.encode(encoded)}',
  );
}
