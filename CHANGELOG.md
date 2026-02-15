## 0.1.1

### Bug fixes
- `MarkdownCodec` is now generic (`MarkdownCodec<B>`) so `decode()` returns
  `Document<B>` instead of `Document<dynamic>`. Eliminates runtime type cast
  errors when using typed schemas.

### Features
- Shift+Enter inserts a soft line break (`\n`) within a block instead of
  splitting into a new block. Works on all non-void block types.
- Markdown codec encodes/decodes CommonMark hard line breaks (`  \n` and `\\\n`).
- Paragraphs now have `spacingBefore: 0.3` for visual separation between blocks.

## 0.1.0

Initial public release.

### Block types
- Paragraph, Heading 1-6, Bullet list, Numbered list, Task item (checkbox),
  Block quote, Fenced code block, Divider

### Inline styles
- Bold, Italic, Strikethrough, Inline code, Links, Autolinks

### Editor features
- Markdown shortcuts (type `# `, `- `, `> `, `` ``` ``, `---`, etc.)
- Inline wrap shortcuts (`**`, `*`, `` ` ``, `~~`)
- Keyboard shortcuts (Cmd+B, Cmd+I, Cmd+Shift+S)
- Nested blocks via Tab/Shift+Tab
- Undo/redo with selection restoration
- Schema-driven architecture with custom block/inline support

### Markdown codec
- CommonMark-aligned decode and encode
- Backslash escape handling
- Fence-aware block splitting for code blocks
- Round-trip fidelity for ATX headings, thematic breaks, and emphasis
