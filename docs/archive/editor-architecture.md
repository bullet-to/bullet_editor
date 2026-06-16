# Bullet Editor — Architecture Plan

## Goal

Replace super_editor with a custom markdown-based editor in Flutter, built on top of TextField.

## Design Principle

Don't fight Flutter. Use TextField as the editing surface. Keep a structured document model as the source of truth. Markdown is a serialization format, not the editing model.

---

## Editor Levels

### Level 1 — Plaintext Markdown Editor

- TextField shows raw markdown
- Separate preview pane renders formatted output
- Toolbar reads cursor position, detects current formatting, can toggle it
- Effort: Low. Mostly parsing logic.

### Level 2 — Bear-Like Editor (Contextual Token Reveal)

- TextField contains raw markdown as its text
- `buildTextSpan()` renders formatted text (bold looks bold, headings are large)
- Markdown tokens (`**`, `#`, etc.) are made tiny/transparent (`fontSize: 0.01`, `Color.transparent`)
- This preserves 1:1 offset mapping (display length == raw text length)
- **Contextual reveal:** When cursor is inside/adjacent to a formatted range, tokens become visible at full size. When cursor moves away, they shrink again.
- This eliminates cursor "sticking" on invisible characters — by the time the cursor reaches them, they're visible.
- Effort: Medium. Contextual reveal + parsing is real work but bounded.

### Level 3 — Full WYSIWYG (Markdown Hidden)

- TextField contains plain display text (no markdown tokens ever visible)
- A separate span model tracks formatting ranges over the plain text
- `buildTextSpan()` applies formatting from the span model
- User never sees markdown syntax. Toolbar and shortcuts are the only way to format.
- Markdown is only used for save/load (serialize/deserialize).
- Effort: Medium-high. Need span sync on edit + the shared model layer.

### Mode Switching (Level 2 <-> Level 3)

Both levels are views into the same `DocumentModel`. Switching is a one-time serialize/deserialize — not a continuous offset mapping.

- **To Level 2:** `model -> serialize to markdown -> controller.text`. buildTextSpan does contextual reveal.
- **To Level 3:** `model -> serialize to plain text + span list -> controller.text`. buildTextSpan applies spans.
- During editing in either mode, offsets are always 1:1 with whatever text is in the controller. The complexity only exists at the moment of switching.

---

## Document Model

Source of truth. Format-agnostic. Both editor modes are projections of it.

```dart
class DocumentModel {
  List<Block> blocks;
}

class Block {
  BlockType type; // paragraph, h1, h2, h3, listItem, numberedListItem, quote, codeBlock...
  List<StyledSegment> segments;
}

class StyledSegment {
  String text;
  Set<InlineStyle> styles; // bold, italic, code, strikethrough, link...
}
```

---

## Architecture Layers

1. **DocumentModel** — structured text representation (source of truth)
2. **Markdown parser/serializer** — markdown string <-> DocumentModel
3. **Plain text projector** — DocumentModel <-> plain text + formatting span offsets
4. **EditorController** (single, mode-aware) — extends TextEditingController. Holds a mode flag (markdown / wysiwyg). `buildTextSpan()` checks the mode:
   - **Markdown mode:** tokens are in the text, apply contextual reveal (shrink/show based on cursor proximity)
   - **WYSIWYG mode:** plain text in controller, apply formatting spans from the model
   - On mode switch: re-serialize DocumentModel into the target format, set `controller.text`
5. **Shared toolbar** — reads/writes DocumentModel, works identically in both modes

---

## Known Limitations

- **Block-level formatting in Level 3:** Headings work (fontSize on TextSpan). Lists work (bullet/number is literal text). Blockquotes, code block backgrounds, and horizontal rules push beyond what buildTextSpan can do — would need custom paint or visual compromises.
- **Inline formatting** (bold, italic, code, strikethrough, links) works cleanly in both modes.

---

## Open Questions

- Exact block types to support at launch
- Link handling UX (inline display, tap behavior)
- Image/media embedding (likely out of scope for v1)
- Undo/redo strategy (TextField's built-in vs. model-level)
- Multi-block selection behavior in Level 3
