## 0.1.7

### Bug fixes
- Fix diacritics (dead keys) on Safari Web. Safari appends the resolved
  character instead of replacing the dead key during composing. The
  controller now avoids syncing back to the platform during active
  composing and rewrites the diff when an insert lands outside the
  composing range.

## 0.1.6

### Bug fixes
- Fix markdown decode depth normalization: when collapsing blocks under
  non-childable parents (headings, etc.), the entire sibling group is now
  shifted together, preserving relative relationships.

## 0.1.5

### Bug fixes
- Fix outdent reordering siblings. Outdenting a block now adopts its
  subsequent siblings as children (matching Notion/Google Docs behavior),
  preserving visual order.

## 0.1.4

### Bug fixes
- Fix keyboard shortcuts (Cmd+B, Cmd+I, Shift+Enter, etc.) not working in
  host apps. Moved all key handling from `FocusNode.onKeyEvent` (which
  `EditableText` overwrites) to `Shortcuts` + `Actions` widgets.
- Fix markdown decoder nesting indented list items under headings/paragraphs.
  Blocks whose parent type has `canHaveChildren: false` are now collapsed to
  sibling level during decode.

## 0.1.3

### Improvements
- Moved rich copy/cut business logic from `BulletEditor` widget to
  `EditorController` (`richCopy()`, `richCut()`, `deleteSelection()`).
- `deleteSelection()` resets non-default block types to paragraph when the
  selection starts at offset 0.
- Tab/Shift+Tab indent/outdent, Cmd+B/I/Shift+S inline style shortcuts, and
  rich copy/cut are now handled internally by `BulletEditor` via `Actions`
  overrides — no host-app wiring needed.

### Tests
- Added unit tests for `deleteSelection`, `richCopy`, and `richCut`.

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
