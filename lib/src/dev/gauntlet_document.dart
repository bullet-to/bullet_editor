/// The gauntlet fixture document (v3-build-strategy.md §walking skeleton).
///
/// One canonical document containing every launch block type — the standing
/// answer to "did we build the easy 80% and defer the hard 20%". Every widget
/// test renders it; the dev inspector loads it by default; the day-19
/// regression walks all 15 gauntlet scenarios against it.
///
/// Deliberately NOT exported from the package barrel — this is a dev/test
/// fixture, re-exported by `test/fixtures/gauntlet_doc.dart`.
library;

import '../model/block.dart';
import '../model/document.dart';

/// Builds the gauntlet document. Ids are stable (`g-*`) so tests can address
/// blocks directly.
///
/// Contents, in order: image (first-in-document), h1, paragraph with a
/// mid-paragraph link, bullet list nested 3 deep, h3, numbered list, task
/// list (checked + unchecked), blockquote, paragraph, second image between
/// paragraphs, paragraph with mixed inline styles, code block, divider,
/// empty paragraph, and a [tailLength]-block lazy tail.
Document buildGauntletDocument({int tailLength = 200}) {
  TextBlock p(String id, String text) => TextBlock(
    id: id,
    blockType: ParagraphKeys.type,
    segments: [StyledSegment(text)],
  );

  return Document([
    // Image FIRST in document — the v2 scar scenario (exotics in the
    // skeleton from day one). Banner-thin aspect (6:1), so the skeleton
    // proves images render at intrinsic aspect, not a forced box.
    TextBlock(
      id: 'g-image-first',
      blockType: ImageKeys.type,
      segments: [const StyledSegment('A first-in-document banner image')],
      metadata: const {
        ImageKeys.url: 'https://picsum.photos/seed/banner/1200/200',
      },
    ),
    TextBlock(
      id: 'g-h1',
      blockType: HeadingKeys.h1,
      segments: [const StyledSegment('Gauntlet document')],
    ),
    TextBlock(
      id: 'g-para-link',
      blockType: ParagraphKeys.type,
      segments: [
        const StyledSegment('A paragraph with '),
        const StyledSegment(
          'a link in the middle',
          {InlineEntityKeys.link},
          {InlineEntityKeys.linkUrl: 'https://example.com/mid'},
        ),
        const StyledSegment(' of running text.'),
      ],
    ),
    // Bullet list nested 3 deep.
    TextBlock(
      id: 'g-li-1',
      blockType: ListItemKeys.type,
      segments: [const StyledSegment('Bullet depth 0')],
      children: [
        TextBlock(
          id: 'g-li-2',
          blockType: ListItemKeys.type,
          segments: [const StyledSegment('Bullet depth 1')],
          children: [
            TextBlock(
              id: 'g-li-3',
              blockType: ListItemKeys.type,
              segments: [const StyledSegment('Bullet depth 2')],
            ),
          ],
        ),
        TextBlock(
          id: 'g-li-2b',
          blockType: ListItemKeys.type,
          segments: [const StyledSegment('Second child at depth 1')],
        ),
      ],
    ),
    TextBlock(
      id: 'g-h3',
      blockType: HeadingKeys.h3,
      segments: [const StyledSegment('Lists, continued (h3 spacing)')],
    ),
    TextBlock(
      id: 'g-num-1',
      blockType: NumberedListKeys.type,
      segments: [const StyledSegment('Numbered one')],
    ),
    TextBlock(
      id: 'g-num-2',
      blockType: NumberedListKeys.type,
      segments: [const StyledSegment('Numbered two')],
    ),
    TextBlock(
      id: 'g-num-3',
      blockType: NumberedListKeys.type,
      segments: [const StyledSegment('Numbered three')],
    ),
    TextBlock(
      id: 'g-task-1',
      blockType: TaskItemKeys.type,
      segments: [const StyledSegment('An unchecked task')],
      metadata: const {TaskItemKeys.checked: false},
    ),
    TextBlock(
      id: 'g-task-2',
      blockType: TaskItemKeys.type,
      segments: [const StyledSegment('A checked task')],
      metadata: const {TaskItemKeys.checked: true},
    ),
    TextBlock(
      id: 'g-quote',
      blockType: BlockQuoteKeys.type,
      segments: [const StyledSegment('A block quote with its bar gutter.')],
    ),
    p('g-para-before-image', 'A paragraph directly above an image block.'),
    // Second image, between paragraphs — normal photo aspect (16:10).
    TextBlock(
      id: 'g-image-mid',
      blockType: ImageKeys.type,
      segments: [const StyledSegment('An image between paragraphs')],
      metadata: const {ImageKeys.url: 'https://picsum.photos/seed/mid/800/500'},
    ),
    TextBlock(
      id: 'g-para-styles',
      blockType: ParagraphKeys.type,
      segments: [
        const StyledSegment('Mixed inline styles: '),
        const StyledSegment('bold', {InlineStyleKeys.bold}),
        const StyledSegment(', '),
        const StyledSegment('italic', {InlineStyleKeys.italic}),
        const StyledSegment(', '),
        const StyledSegment('bold italic', {
          InlineStyleKeys.bold,
          InlineStyleKeys.italic,
        }),
        const StyledSegment(', '),
        const StyledSegment('struck', {InlineStyleKeys.strikethrough}),
        const StyledSegment(', and '),
        const StyledSegment('inline code', {InlineStyleKeys.code}),
        const StyledSegment('.'),
      ],
    ),
    TextBlock(
      id: 'g-code',
      blockType: CodeBlockKeys.type,
      segments: [const StyledSegment('void main() {\n  print("gauntlet");\n}')],
      metadata: const {CodeBlockKeys.language: 'dart'},
    ),
    TextBlock(id: 'g-divider', blockType: DividerKeys.type),
    TextBlock(id: 'g-empty', blockType: ParagraphKeys.type),
    // Lazy tail (D5): enough blocks that eager layout is visible in the
    // inspector's laid-out-block counter.
    for (var i = 0; i < tailLength; i++)
      p('g-tail-$i', 'Lazy tail paragraph ${i + 1} of $tailLength.'),
  ]);
}
