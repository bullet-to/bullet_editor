# bullet_editor

[![pub package](https://img.shields.io/pub/v/bullet_editor.svg)](https://pub.dev/packages/bullet_editor)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A structured rich text editor for Flutter built on a single `TextField`. Supports headings, lists, task items, code blocks, block quotes, inline styles, and full markdown round-trip serialization.

## Features

| Block types | Inline styles |
|---|---|
| Paragraph | **Bold** |
| Heading 1-6 | *Italic* |
| Bullet list | ~~Strikethrough~~ |
| Numbered list | `Inline code` |
| Task item (checkbox) | [Links](https://example.com) |
| Block quote | Autolinks |
| Fenced code block | |
| Divider | |

- Markdown shortcuts — type `# `, `- `, `1. `, `> `, `` ``` ``, `---`, etc.
- Inline formatting shortcuts — wrap text with `**`, `*`, `` ` ``, `~~`
- Keyboard shortcuts — Cmd+B, Cmd+I, Cmd+Shift+S, Tab/Shift+Tab
- Undo/redo with full selection restoration
- Nested blocks via indentation (Tab/Shift+Tab)
- Markdown codec with CommonMark-aligned parsing and round-trip fidelity
- Schema-driven architecture — add custom block types and inline styles

## Installation

```yaml
dependencies:
  bullet_editor: ^0.1.0
```

Or run:

```bash
flutter pub add bullet_editor
```

## Quick start

```dart
import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/material.dart';

class MyEditor extends StatefulWidget {
  const MyEditor({super.key});

  @override
  State<MyEditor> createState() => _MyEditorState();
}

class _MyEditorState extends State<MyEditor> {
  late final EditorController<BlockType, InlineStyle> _controller;

  @override
  void initState() {
    super.initState();
    _controller = EditorController(
      schema: EditorSchema.standard(),
      document: Document.empty(BlockType.paragraph),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BulletEditor(controller: _controller);
  }
}
```

## Markdown codec

```dart
final schema = EditorSchema.standard();
final codec = MarkdownCodec(schema);

// Decode markdown to a document
final doc = codec.decode('# Hello\n\nA **bold** paragraph.');

// Encode a document back to markdown
final markdown = codec.encode(doc);
```

## Custom schema

```dart
final schema = buildStandardSchema(
  h1: HeadingStyle(scale: 2.0, fontWeight: FontWeight.w800),
  linkColor: Colors.teal,
  bulletChar: '–',
);
```

Add custom block types or inline styles via `additionalBlocks` and `additionalInlineStyles`.

## Example

See the [example app](example/) for a full working demo with theme switching and a debug panel.

## Architecture

The editor uses a single `TextField` with a rich `TextSpan` tree. All block types are rendered inline using `WidgetSpan` prefixes (bullets, checkboxes, dividers) and styled `TextSpan` content. This gives native cursor, selection, and IME behavior for free.

The document model is immutable. All mutations go through `EditOperation` objects applied via `Transaction`, enabling undo/redo and input rule transforms.

## License

MIT — see [LICENSE](LICENSE).
