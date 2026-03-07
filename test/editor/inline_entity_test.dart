import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

enum TestInlineEntity { mention }

enum CompatInlineStyle { token }

void main() {
  group('InlineEntityInfo', () {
    test(
      'buildStandardSchema additional inline entities render and markdown round-trip',
      () {
        final schema = buildStandardSchema(
          additionalInlineEntities: {
            InlineEntityType.link: InlineEntityDef(
              type: InlineEntityType.link,
              style: _customLinkStyle(),
              label: 'Custom Link',
              decode: _decodeCustomLink,
              encode: _encodeCustomLink,
              defaultText: _defaultCustomLinkText,
            ),
          },
        );

        final def = schema.inlineEntityDef(InlineEntityType.link);
        expect(def, isNotNull);
        expect(def!.label, 'Custom Link');
        expect(
          def.decode({'url': 'https://example.com'}),
          const LinkData(url: 'https://example.com'),
        );

        final doc = Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: [
              const StyledSegment(
                'site',
                {InlineEntityType.link},
                {'url': 'https://example.com'},
              ),
            ],
          ),
        ]);

        final span = buildDocumentSpan(
          doc,
          const TextStyle(fontSize: 16),
          schema,
        );
        final child = span.children!.single as TextSpan;
        expect(child.style?.letterSpacing, 2);

        final codec = MarkdownCodec<BlockType>(schema: schema);
        final markdown = codec.encode(doc);
        expect(markdown, '<<site|https://example.com>>');

        final decoded = codec.decode(markdown);
        expect(decoded.blocks[0].segments, doc.blocks[0].segments);
      },
    );

    test('inlinePresentationDef resolves styles, entities, and fallback', () {
      final schema = EditorSchema.standard();

      expect(schema.inlinePresentationDef(InlineStyle.bold).label, 'Bold');
      expect(schema.inlinePresentationDef(InlineEntityType.link).label, 'Link');
      expect(schema.inlinePresentationDef('missing').label, 'Unknown');
      expect(schema.isInlineStyleKey(InlineStyle.bold), isTrue);
      expect(schema.isInlineStyleKey(InlineEntityType.link), isFalse);
    });

    test('schema.inputRules includes inline entity presentation rules', () {
      final standard = buildStandardSchema();
      final mentionRule = InlineWrapRule('@@', TestInlineEntity.mention);
      final schema = EditorSchema<BlockType, InlineStyle, TestInlineEntity>(
        defaultBlockType: BlockType.paragraph,
        blocks: standard.blocks,
        inlineStyles: standard.inlineStyles,
        inlineEntities: {
          TestInlineEntity.mention: InlineEntityDef(
            type: TestInlineEntity.mention,
            style: _mentionStyle(inputRules: [mentionRule]),
            label: 'Mention',
            decode: _decodeMention,
            encode: _encodeMention,
          ),
        },
      );

      expect(schema.inputRules, contains(same(mentionRule)));
    });

    test(
      'custom entity works with markdown and rendering without inlineStyles',
      () {
        final standard = buildStandardSchema();
        final schema = EditorSchema<BlockType, InlineStyle, TestInlineEntity>(
          defaultBlockType: BlockType.paragraph,
          blocks: standard.blocks,
          inlineStyles: {},
          inlineEntities: {
            TestInlineEntity.mention: InlineEntityDef(
              type: TestInlineEntity.mention,
              style: _mentionStyle(),
              label: 'Mention',
              decode: _decodeMention,
              encode: _encodeMention,
            ),
          },
        );
        final doc = Document([
          TextBlock(
            id: 'a',
            blockType: BlockType.paragraph,
            segments: [
              const StyledSegment(
                'alice',
                {TestInlineEntity.mention},
                {'id': 'u1'},
              ),
            ],
          ),
        ]);

        final span = buildDocumentSpan(
          doc,
          const TextStyle(fontSize: 16),
          schema,
        );
        final child = span.children!.single as TextSpan;
        expect(child.style?.fontWeight, FontWeight.w600);
        expect(child.style?.color, const Color(0xFF7B3FE4));

        final codec = MarkdownCodec<BlockType>(schema: schema);
        final markdown = codec.encode(doc);
        expect(markdown, '@{alice|u1}');

        final decoded = codec.decode(markdown);
        expect(decoded.blocks[0].segments, doc.blocks[0].segments);
      },
    );

    test('inlineEntityAtCursor returns link entity info', () {
      final controller =
          EditorController<BlockType, InlineStyle, InlineEntityType>(
            schema: EditorSchema.standard(),
            document: Document([
              TextBlock(
                id: 'a',
                blockType: BlockType.paragraph,
                segments: [
                  const StyledSegment('go to '),
                  const StyledSegment(
                    'site',
                    {InlineEntityType.link},
                    {'url': 'https://example.com'},
                  ),
                ],
              ),
            ]),
          );

      final start = controller.text.indexOf('site');
      controller.value = controller.value.copyWith(
        selection: TextSelection.collapsed(offset: start + 2),
      );

      final entity = controller.inlineEntityAtCursor;
      expect(entity, isNotNull);
      expect(entity!.type, InlineEntityType.link);
      expect(entity.text, 'site');
      expect(entity.data, const LinkData(url: 'https://example.com'));
      expect(entity.displayStart, start);
      expect(entity.displayEnd, start + 4);
    });

    test('inlineEntityAtDisplayOffset finds a link at either boundary', () {
      final controller =
          EditorController<BlockType, InlineStyle, InlineEntityType>(
            schema: EditorSchema.standard(),
            document: Document([
              TextBlock(
                id: 'a',
                blockType: BlockType.paragraph,
                segments: [
                  const StyledSegment(
                    'link',
                    {InlineEntityType.link},
                    {'url': 'https://example.com'},
                  ),
                ],
              ),
            ]),
          );

      final startEntity = controller.inlineEntityAtDisplayOffset(0);
      final endEntity = controller.inlineEntityAtDisplayOffset(4);

      expect(startEntity?.type, InlineEntityType.link);
      expect(endEntity?.type, InlineEntityType.link);
      expect(startEntity?.data, const LinkData(url: 'https://example.com'));
      expect(endEntity?.data, const LinkData(url: 'https://example.com'));
    });

    test('inlineEntityAtCursor uses backward boundary semantics', () {
      final controller =
          EditorController<BlockType, InlineStyle, InlineEntityType>(
            schema: EditorSchema.standard(),
            document: Document([
              TextBlock(
                id: 'a',
                blockType: BlockType.paragraph,
                segments: [
                  const StyledSegment('go '),
                  const StyledSegment(
                    'link',
                    {InlineEntityType.link},
                    {'url': 'https://example.com'},
                  ),
                  const StyledSegment(' now'),
                ],
              ),
            ]),
          );

      final linkStart = controller.text.indexOf('link');
      final linkEnd = linkStart + 4;

      controller.value = controller.value.copyWith(
        selection: TextSelection.collapsed(offset: linkStart),
      );
      expect(controller.inlineEntityAtCursor, isNull);

      controller.value = controller.value.copyWith(
        selection: TextSelection.collapsed(offset: linkEnd),
      );
      expect(controller.inlineEntityAtCursor?.type, InlineEntityType.link);
      expect(
        controller.inlineEntityAtCursor?.data,
        const LinkData(url: 'https://example.com'),
      );
    });

    test(
      'setInlineEntity updates existing link entity at collapsed cursor',
      () {
        final controller =
            EditorController<BlockType, InlineStyle, InlineEntityType>(
              schema: EditorSchema.standard(),
              document: Document([
                TextBlock(
                  id: 'a',
                  blockType: BlockType.paragraph,
                  segments: [
                    const StyledSegment(
                      'link',
                      {InlineEntityType.link},
                      {'url': 'https://old.com'},
                    ),
                  ],
                ),
              ]),
            );

        controller.value = controller.value.copyWith(
          selection: const TextSelection.collapsed(offset: 2),
        );

        controller.setInlineEntity(
          InlineEntityType.link,
          const LinkData(url: 'https://new.com'),
          text: 'updated',
        );

        expect(controller.text, 'updated');
        expect(
          controller.inlineEntityAtDisplayOffset(2)?.type,
          InlineEntityType.link,
        );
        expect(
          controller.inlineEntityAtDisplayOffset(2)?.data,
          const LinkData(url: 'https://new.com'),
        );
      },
    );

    test('removeInlineEntity removes link at collapsed cursor', () {
      final controller =
          EditorController<BlockType, InlineStyle, InlineEntityType>(
            schema: EditorSchema.standard(),
            document: Document([
              TextBlock(
                id: 'a',
                blockType: BlockType.paragraph,
                segments: [
                  const StyledSegment(
                    'link',
                    {InlineEntityType.link},
                    {'url': 'https://old.com'},
                  ),
                ],
              ),
            ]),
          );

      controller.value = controller.value.copyWith(
        selection: const TextSelection.collapsed(offset: 2),
      );

      controller.removeInlineEntity(InlineEntityType.link);

      expect(controller.inlineEntityAtCursor, isNull);
      expect(controller.document.allBlocks[0].segments[0].styles, isEmpty);
    });

    test('activeStyles excludes entity-backed styles', () {
      final controller =
          EditorController<BlockType, InlineStyle, InlineEntityType>(
            schema: EditorSchema.standard(),
            document: Document([
              TextBlock(
                id: 'a',
                blockType: BlockType.paragraph,
                segments: [
                  const StyledSegment(
                    'link',
                    {InlineEntityType.link, InlineStyle.bold},
                    {'url': 'https://example.com'},
                  ),
                ],
              ),
            ]),
          );

      controller.value = controller.value.copyWith(
        selection: const TextSelection.collapsed(offset: 2),
      );

      expect(controller.activeStyles, {InlineStyle.bold});
    });

    test('setInlineEntity with no default text is a no-op', () {
      final standard = buildStandardSchema();
      final controller =
          EditorController<BlockType, InlineStyle, TestInlineEntity>(
            schema: EditorSchema(
              defaultBlockType: BlockType.paragraph,
              blocks: standard.blocks,
              inlineStyles: standard.inlineStyles,
              inlineEntities: {
                TestInlineEntity.mention: const InlineEntityDef(
                  type: TestInlineEntity.mention,
                  style: InlineStyleDef(
                    label: 'Mention',
                    applyStyle: _passthroughStyle,
                  ),
                  label: 'Mention',
                  decode: _decodeMention,
                  encode: _encodeMention,
                ),
              },
            ),
            document: Document([
              TextBlock(
                id: 'a',
                blockType: BlockType.paragraph,
                segments: [const StyledSegment('hello')],
              ),
            ]),
          );

      controller.value = controller.value.copyWith(
        selection: const TextSelection.collapsed(offset: 5),
      );

      controller.setInlineEntity(
        TestInlineEntity.mention,
        const TestMentionData(id: 'u1'),
      );

      expect(controller.text, 'hello');
      expect(controller.inlineEntityAtCursor, isNull);
    });

    test('activeStyles excludes legacy data-carrying inline styles', () {
      final standard = buildStandardSchema();
      final controller =
          EditorController<BlockType, CompatInlineStyle, TestInlineEntity>(
            schema: EditorSchema(
              defaultBlockType: BlockType.paragraph,
              blocks: standard.blocks,
              inlineStyles: {
                CompatInlineStyle.token: const InlineStyleDef(
                  label: 'Token',
                  isDataCarrying: true,
                  applyStyle: _passthroughStyle,
                ),
              },
              inlineEntities: const {},
            ),
            document: Document([
              TextBlock(
                id: 'a',
                blockType: BlockType.paragraph,
                segments: [
                  const StyledSegment(
                    'token',
                    {CompatInlineStyle.token},
                    {'id': 'legacy'},
                  ),
                ],
              ),
            ]),
          );

      controller.value = controller.value.copyWith(
        selection: const TextSelection.collapsed(offset: 2),
      );

      expect(controller.activeStyles, isEmpty);
    });
  });
}

TextStyle _passthroughStyle(
  TextStyle base, {
  Map<String, dynamic> attributes = const {},
}) => base;

final class TestMentionData implements InlineEntityData {
  const TestMentionData({required this.id});

  final String id;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is TestMentionData && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

InlineEntityData _decodeMention(Map<String, dynamic> attributes) =>
    TestMentionData(id: attributes['id'] as String? ?? '');

Map<String, dynamic> _encodeMention(InlineEntityData data) => {
  'id': (data as TestMentionData).id,
};

InlineStyleDef _mentionStyle({List<InputRule> inputRules = const []}) =>
    InlineStyleDef(
      label: 'Mention',
      applyStyle: (base, {attributes = const {}}) => base.copyWith(
        fontWeight: FontWeight.w600,
        color: const Color(0xFF7B3FE4),
      ),
      codecs: {
        Format.markdown: const InlineCodec(
          encode: _encodeMentionMarkdown,
          decode: _decodeMentionMarkdown,
        ),
      },
      inputRules: inputRules,
    );

InlineEntityData _decodeCustomLink(Map<String, dynamic> attributes) =>
    LinkData(url: attributes['url'] as String? ?? '');

Map<String, dynamic> _encodeCustomLink(InlineEntityData data) => {
  'url': (data as LinkData).url,
};

String? _defaultCustomLinkText(InlineEntityData data) => (data as LinkData).url;

InlineStyleDef _customLinkStyle() => InlineStyleDef(
  label: 'Custom Link',
  applyStyle: (base, {attributes = const {}}) =>
      base.copyWith(letterSpacing: 2),
  codecs: {
    Format.markdown: const InlineCodec(
      encode: _encodeCustomLinkMarkdown,
      decode: _decodeCustomLinkMarkdown,
    ),
  },
);

String _encodeMentionMarkdown(String text, Map<String, dynamic> attributes) =>
    '@{$text|${attributes['id'] ?? ''}}';

InlineDecodeMatch? _decodeMentionMarkdown(String text) {
  final match = RegExp(r'^@\{([^|}]+)\|([^}]+)\}').firstMatch(text);
  if (match == null) return null;
  return InlineDecodeMatch(
    text: match.group(1)!,
    fullMatchLength: match.end,
    attributes: {'id': match.group(2)!},
  );
}

String _encodeCustomLinkMarkdown(
  String text,
  Map<String, dynamic> attributes,
) => '<<$text|${attributes['url'] ?? ''}>>';

InlineDecodeMatch? _decodeCustomLinkMarkdown(String text) {
  final match = RegExp(r'^<<([^|>]+)\|([^>]+)>>').firstMatch(text);
  if (match == null) return null;
  return InlineDecodeMatch(
    text: match.group(1)!,
    fullMatchLength: match.end,
    attributes: {'url': match.group(2)!},
  );
}
