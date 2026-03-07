import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

enum TestInlineStyle { mention }

enum TestInlineEntity { mention }

void main() {
  group('InlineEntityInfo', () {
    test('buildStandardSchema merges additional inline entities', () {
      final schema = buildStandardSchema(
        additionalInlineEntities: {
          InlineEntityType.link: const InlineEntityDef(
            type: InlineEntityType.link,
            style: InlineStyle.link,
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
    });

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
                    {InlineStyle.link},
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
                    {InlineStyle.link},
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
                    {InlineStyle.link},
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
                      {InlineStyle.link},
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
                    {InlineStyle.link},
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
                    {InlineStyle.link, InlineStyle.bold},
                    {'url': 'https://example.com'},
                  ),
                ],
              ),
            ]),
          );

      controller.value = controller.value.copyWith(
        selection: const TextSelection.collapsed(offset: 2),
      );

      expect(controller.activeStyles, contains(InlineStyle.bold));
      expect(controller.activeStyles, isNot(contains(InlineStyle.link)));
    });

    test('setInlineEntity with no default text is a no-op', () {
      final standard = buildStandardSchema();
      final controller =
          EditorController<BlockType, TestInlineStyle, TestInlineEntity>(
            schema: EditorSchema(
              defaultBlockType: BlockType.paragraph,
              blocks: standard.blocks,
              inlineStyles: {
                TestInlineStyle.mention: const InlineStyleDef(
                  label: 'Mention',
                  isDataCarrying: true,
                  applyStyle: _passthroughStyle,
                ),
              },
              inlineEntities: {
                TestInlineEntity.mention: const InlineEntityDef(
                  type: TestInlineEntity.mention,
                  style: TestInlineStyle.mention,
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

InlineEntityData _decodeCustomLink(Map<String, dynamic> attributes) =>
    LinkData(url: attributes['url'] as String? ?? '');

Map<String, dynamic> _encodeCustomLink(InlineEntityData data) => {
  'url': (data as LinkData).url,
};

String? _defaultCustomLinkText(InlineEntityData data) => (data as LinkData).url;
