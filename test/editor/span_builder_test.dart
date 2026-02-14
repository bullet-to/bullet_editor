import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('prefixBuilder receives resolved TextStyle', () {
    test('list item prefix gets the editor base style', () {
      TextStyle? capturedStyle;

      final schema = EditorSchema(
        defaultBlockType: BlockType.paragraph,
        blocks: {
          BlockType.listItem: BlockDef(
            label: 'List',
            isListLike: true,
            policies: const BlockPolicies(canBeChild: true),
            prefixBuilder: (doc, i, block, resolvedStyle) {
              capturedStyle = resolvedStyle;
              return const SizedBox(width: 24);
            },
          ),
          BlockType.paragraph: const BlockDef(label: 'Paragraph'),
        },
        inlineStyles: <Object, InlineStyleDef>{},
      );

      final doc = Document([
        TextBlock(
          id: '1',
          blockType: BlockType.listItem,
          segments: [const StyledSegment('hello')],
        ),
      ]);

      const baseStyle = TextStyle(fontSize: 16);
      buildDocumentSpan(doc, baseStyle, schema);

      expect(capturedStyle, isNotNull);
      expect(capturedStyle!.fontSize, 16);
    });

    test('heading list item prefix gets the heading base style', () {
      // Custom schema where h1 is list-like (contrived but tests the path)
      TextStyle? capturedStyle;

      final schema = EditorSchema(
        defaultBlockType: BlockType.paragraph,
        blocks: {
          BlockType.h1: BlockDef(
            label: 'H1',
            isListLike: true,
            policies: const BlockPolicies(canBeChild: true),
            baseStyle: (base) => (base ?? const TextStyle()).copyWith(
              fontSize: 32,
              fontWeight: FontWeight.bold,
            ),
            prefixBuilder: (doc, i, block, resolvedStyle) {
              capturedStyle = resolvedStyle;
              return const SizedBox(width: 24);
            },
          ),
          BlockType.paragraph: const BlockDef(label: 'Paragraph'),
        },
        inlineStyles: <Object, InlineStyleDef>{},
      );

      final doc = Document([
        TextBlock(
          id: '1',
          blockType: BlockType.h1,
          segments: [const StyledSegment('big heading')],
        ),
      ]);

      const baseStyle = TextStyle(fontSize: 14);
      buildDocumentSpan(doc, baseStyle, schema);

      expect(capturedStyle, isNotNull);
      expect(capturedStyle!.fontSize, 32,
          reason: 'prefix should get the h1 resolved style, not the base');
      expect(capturedStyle!.fontWeight, FontWeight.bold);
    });

    test('fallback to empty TextStyle when no base style provided', () {
      TextStyle? capturedStyle;

      final schema = EditorSchema(
        defaultBlockType: BlockType.paragraph,
        blocks: {
          BlockType.listItem: BlockDef(
            label: 'List',
            isListLike: true,
            policies: const BlockPolicies(canBeChild: true),
            prefixBuilder: (doc, i, block, resolvedStyle) {
              capturedStyle = resolvedStyle;
              return const SizedBox(width: 24);
            },
          ),
          BlockType.paragraph: const BlockDef(label: 'Paragraph'),
        },
        inlineStyles: <Object, InlineStyleDef>{},
      );

      final doc = Document([
        TextBlock(
          id: '1',
          blockType: BlockType.listItem,
          segments: [const StyledSegment('item')],
        ),
      ]);

      // Pass null as the base style
      buildDocumentSpan(doc, null, schema);

      expect(capturedStyle, isNotNull);
      // Should be an empty TextStyle, not null
      expect(capturedStyle, isA<TextStyle>());
    });
  });

  group('custom prefixBuilder override', () {
    test('user-supplied task prefix replaces default', () {
      Widget? capturedWidget;

      final customCheckbox = Container(
        key: const Key('custom-checkbox'),
        width: 20,
        height: 20,
      );

      final schema = EditorSchema(
        defaultBlockType: BlockType.paragraph,
        blocks: {
          BlockType.taskItem: BlockDef(
            label: 'Task',
            isListLike: true,
            splitInheritsType: true,
            policies: const BlockPolicies(canBeChild: true),
            prefixBuilder: (doc, i, block, resolvedStyle) {
              capturedWidget = customCheckbox;
              return customCheckbox;
            },
          ),
          BlockType.paragraph: const BlockDef(label: 'Paragraph'),
        },
        inlineStyles: <Object, InlineStyleDef>{},
      );

      final doc = Document([
        TextBlock(
          id: '1',
          blockType: BlockType.taskItem,
          segments: [const StyledSegment('buy milk')],
          metadata: {kCheckedKey: false},
        ),
      ]);

      final span = buildDocumentSpan(doc, const TextStyle(), schema);

      // The custom widget should have been returned
      expect(capturedWidget, isNotNull);
      expect((capturedWidget as Container).key, const Key('custom-checkbox'));

      // Verify it's in the span tree as a WidgetSpan
      final widgetSpans = span.children!.whereType<WidgetSpan>().toList();
      expect(widgetSpans, isNotEmpty);
    });

    test('user-supplied bullet prefix replaces default', () {
      final calls = <(int, double?)>[];

      final schema = EditorSchema(
        defaultBlockType: BlockType.paragraph,
        blocks: {
          BlockType.listItem: BlockDef(
            label: 'Bullet',
            isListLike: true,
            policies: const BlockPolicies(canBeChild: true),
            prefixBuilder: (doc, i, block, resolvedStyle) {
              calls.add((i, resolvedStyle.fontSize));
              return const Text('→');
            },
          ),
          BlockType.paragraph: const BlockDef(label: 'Paragraph'),
        },
        inlineStyles: <Object, InlineStyleDef>{},
      );

      final doc = Document([
        TextBlock(
          id: '1',
          blockType: BlockType.listItem,
          segments: [const StyledSegment('first')],
        ),
        TextBlock(
          id: '2',
          blockType: BlockType.listItem,
          segments: [const StyledSegment('second')],
        ),
      ]);

      buildDocumentSpan(doc, const TextStyle(fontSize: 18), schema);

      expect(calls.length, 2);
      expect(calls[0], (0, 18.0));
      expect(calls[1], (1, 18.0));
    });
  });

  group('default prefix builders scale with font size', () {
    test('bullet scales with block font size', () {
      final schema = EditorSchema.standard();
      final doc = Document([
        TextBlock(
          id: '1',
          blockType: BlockType.listItem,
          segments: [const StyledSegment('item')],
        ),
      ]);

      // Build with a large base font — bullet should not use hardcoded size
      final span = buildDocumentSpan(
        doc,
        const TextStyle(fontSize: 24),
        schema,
      );

      // Extract the WidgetSpan → find the Text widget inside the prefix
      final widgetSpan = span.children!.whereType<WidgetSpan>().first;
      final prefixText = _findTextWidget(widgetSpan.child);
      expect(prefixText, isNotNull, reason: 'bullet prefix should contain Text');
      // Bullet is fontSize * 1.2 = 28.8
      expect(prefixText!.style!.fontSize, closeTo(28.8, 0.01));
    });

    test('numbered list scales with block font size', () {
      final schema = EditorSchema.standard();
      final doc = Document([
        TextBlock(
          id: '1',
          blockType: BlockType.numberedList,
          segments: [const StyledSegment('item')],
        ),
      ]);

      final span = buildDocumentSpan(
        doc,
        const TextStyle(fontSize: 20),
        schema,
      );

      final widgetSpan = span.children!.whereType<WidgetSpan>().first;
      final prefixText = _findTextWidget(widgetSpan.child);
      expect(prefixText, isNotNull);
      expect(prefixText!.style!.fontSize, 20);
    });

    test('task checkbox scales with block font size', () {
      final schema = EditorSchema.standard();
      final doc = Document([
        TextBlock(
          id: '1',
          blockType: BlockType.taskItem,
          segments: [const StyledSegment('task')],
          metadata: {kCheckedKey: false},
        ),
      ]);

      final span = buildDocumentSpan(
        doc,
        const TextStyle(fontSize: 22),
        schema,
      );

      final widgetSpan = span.children!.whereType<WidgetSpan>().first;
      // Checkbox is now a Container, not Text. Find it and check its size.
      final container = _findContainerWidget(widgetSpan.child);
      expect(container, isNotNull, reason: 'task prefix should contain a Container');
      // Size should be fontSize * 0.85 = 18.7
      final constraints = container!.constraints;
      expect(constraints?.maxWidth, closeTo(22 * 0.85, 0.01));
    });
  });
}

/// Recursively find the first [Text] widget in a widget tree.
Text? _findTextWidget(Widget? widget) {
  if (widget == null) return null;
  if (widget is Text) return widget;
  if (widget is SizedBox) return _findTextWidget(widget.child);
  if (widget is Center) return _findTextWidget(widget.child);
  if (widget is Padding) return _findTextWidget(widget.child);
  return null;
}

/// Recursively find the first [Container] widget in a widget tree.
Container? _findContainerWidget(Widget? widget) {
  if (widget == null) return null;
  if (widget is Container) return widget;
  if (widget is SizedBox) return _findContainerWidget(widget.child);
  if (widget is Center) return _findContainerWidget(widget.child);
  if (widget is Padding) return _findContainerWidget(widget.child);
  return null;
}
