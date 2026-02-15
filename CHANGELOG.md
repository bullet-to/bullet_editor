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
