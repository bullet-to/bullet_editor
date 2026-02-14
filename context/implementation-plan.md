# Bullet Editor — Implementation Plan

## Approach

Vertical slices. Each phase delivers a working editor with more capability. No layer is built in isolation — every phase touches model → transactions → controller → rendering.

---

## Phase 1: Minimal Vertical Slice (POC)

Prove the core loop works: type → transaction → document model → TextField renders.

- **Model:** `Block`, `TextBlock`, `StyledSegment`, `InlineStyle` (bold only)
- **Document:** `Document` holding a flat list of paragraphs (no nesting)
- **Transactions:** `Transaction` with `EditOperation` (replace text, toggle style)
- **Controller:** `EditorController` extends `TextEditingController`, owns the document, syncs `TextEditingValue` ↔ model
- **Rendering:** `buildTextSpan()` that applies bold via `TextStyle`
- **Input rule:** `**text**` wrap → toggle bold (proves the input rule pipeline)
- **Codec:** Basic markdown round-trip (paragraphs + bold)
- **UI:** Single `TextField`, no toolbar

**Key question answered:** Does the document model ↔ TextField sync actually work? Can we intercept edits, run them through transactions, and re-render without fighting Flutter?

---

## Phase 2: Block Types + Input Rules

Expand sideways with more block types and the input rule system.

- **Block types:** Headings (H1–H3), list items, blockquote
- **Input rules:** `# ` → H1, `## ` → H2, `### ` → H3, `- ` → list item, `> ` → blockquote, Enter on empty list item → paragraph
- **Inline styles:** Italic, code, strikethrough
- **Block rendering:** Font size for headings, bullet prefix for lists
- **Markdown codec:** Full round-trip for all block types + inline styles
- **Schema:** `EditorSchema` with validation (reject invalid block types, enforce allowed inline styles)

**Key question answered:** Does the input rule pipeline scale to multiple rules? Does schema validation catch bad states?

---

## Phase 3: Nesting + Tree Structure

Move from flat list to tree-structured document.

- **Tree model:** Blocks with children (nested lists, blockquotes containing paragraphs)
- **Tree operations:** Indent/outdent (Tab/Shift+Tab on list items)
- **Flatten for TextField:** `allBlocks` depth-first traversal
- **Block policies:** `canBeChild`, `canHaveChildren`, `allowedChildren`, `maxDepth`
- **Selection:** `SelectionState` with blockId + offset, cross-block selection

**Key question answered:** Does the tree ↔ flat TextField mapping hold up? Do indent/outdent feel right?

---

## Phase 4: Undo/Redo

- **Undo stack:** Push transactions on commit, pop + invert for undo
- **Selection restore:** Undo restores cursor position (selectionBefore/After on Transaction)
- **Redo stack:** Inverted transactions pushed here
- **Disable TextField's built-in undo** to avoid conflicts

**Key question answered:** Do invertible transactions produce correct undo behavior across block type changes and formatting toggles?

---

## Phase 5: Selection Operations (Cross-Block Delete/Replace)

Handle non-collapsed selections: delete a range spanning multiple blocks, replace selection with typed text.

- **Cross-block delete:** Delete from middle of block A to middle of block B → merge remaining halves, remove blocks in between
- **Replace selection:** Select text + type → delete range then insert at cursor
- **Same-block range delete:** Select within a single block + delete → already partly works, needs hardening
- **Update `_transactionFromDiff`:** Detect when the diff spans `\n` boundaries and build multi-op transactions (DeleteText + MergeBlocks sequences)
- **Input rules on selection replace:** e.g. select text, type `#` — should still work through the pipeline

**Key question answered:** Does the transaction system compose cleanly for multi-block operations?

---

## Phase 6: Toolbar + Shortcuts (was Phase 5)

- **Toolbar widget:** Reads formatting at cursor via `DocumentReader.getStylesAt()`
- **Toggle actions:** Bold, italic, code, strikethrough — create transactions
- **Keyboard shortcuts:** Cmd+B, Cmd+I, etc. via Flutter's `Shortcuts`/`Actions`
- **Block type picker:** Dropdown or segmented control for paragraph/heading/list

**Key question answered:** Does the read path (model → toolbar state) stay responsive? Does the CQRS split feel clean?

---

## Phase 7: IME / Composing Input Handling

Fix diacritics, accented characters, and other IME composing sequences (Option+E then E for é, CJK input, etc.).

- **Composing range handling:** Currently `_onValueChanged` bails early during composing (`value.composing.isValid`), but the bail is too aggressive or the composing range isn't tracked correctly across prefix chars
- **Diacritic mid-word:** Typing a dead key (Option+E) mid-word incorrectly shifts the cursor and replaces adjacent characters instead of composing in place
- **Diacritic at block boundary:** Composing at the end of a block causes the cursor to jump to the next block and merges blocks on completion
- **Root cause investigation:** The display-to-model offset translation likely doesn't account for composing ranges, and the diff algorithm may misinterpret composing state changes as edits
- **Testing:** Simulate composing sequences in unit tests (set value with composing range, then resolve)

**Key question answered:** Does our diff + offset translation pipeline handle multi-step IME input without corrupting the document?

---

## Phase 8: Editor Modes (was Phase 6/7)

- **Mode 2 (Bear-like):** Markdown tokens in text, contextual reveal (shrink when cursor away, show when near)
- **Mode 3 (WYSIWYG):** Plain text in controller, formatting from span model only
- **Mode switching:** Re-serialize document to target format, swap controller text

**Key question answered:** Does contextual reveal work smoothly? Is mode switching fast enough to feel instant?

---

## Phase 9: Schema-as-Configuration (was Phase 7/8)

Refactor toward the aspirational API:

- **BlockDef / InlineStyleDef:** Bundle rendering, codecs, input rules, policies per type
- **Generic keys:** `EditorSchema<B, I>` with enum keys
- **Per-type codecs:** Multiple format support (markdown, HTML, JSON)
- **Block-level keyActions:** Enter, backspace, tab behavior per block type

---

## Phase 10: Copy / Paste

Rich copy/paste that preserves formatting across clipboard operations.

- **Copy:** Serialize selected range to both plain text (for external apps) and a structured format (markdown or JSON) on the clipboard. Flutter's `Clipboard` only supports plain text natively; use `ClipboardData` with a custom MIME type or embed markdown in the plain text slot.
- **Paste plain text:** Already works via TextField. Insert at cursor, inherits active styles.
- **Paste rich/markdown:** Detect markdown in clipboard content, decode via `MarkdownCodec`, splice the resulting blocks/segments into the document at the cursor position. Cross-block paste (pasting multiple paragraphs) needs a `PasteBlocks` operation that splits the current block and inserts the pasted blocks between the halves.
- **Cut:** Copy + delete selection. Should reuse the copy path + existing `DeleteRange`.
- **Paste links:** Detect URLs in pasted plain text and auto-link them (optional input rule).
- **Internal copy:** For copy within the editor, preserve the full `StyledSegment` list (with attributes) so paste is lossless.

**Key question answered:** Can we round-trip formatting through the clipboard without losing styles or attributes? Does cross-block paste compose cleanly with the existing transaction system?

---

## Phase 11: Styling

Better defaults, Notion-like nesting/indentation, and a typography system.

- **Improve defaults:** Sane out-of-the-box text styles — body size, heading scale, line height, paragraph spacing. Should look good with zero config, similar to Notion/Bear.
- **Nesting & indentation:** Fix indent rendering to match Notion — nested list items indent content (not just the bullet), consistent left padding per depth level, visual nesting cues (lighter bullets, indentation guides). Tab/Shift+Tab should feel identical to Notion.
- **Typography system:** A `Typography` config that defines the full type scale — body, H1–H3, code, blockquote. Users provide a `Typography` object (or we derive one from a base font/size) and every block type maps to it automatically.
- **Theme injection:** `InheritedWidget` or constructor param so the editor respects the host app's theme out of the box
- **Dark mode:** Light/dark variants, auto-switch with `MediaQuery.platformBrightness`
- **Toolbar styling:** Theme-aware toolbar (icon colors, active state indicators, dividers)

**Key question answered:** Can we ship defaults that look polished without config, while still letting users override everything via a typography/theme system?

---

## Phase 12: Rugged Markdown Serialization Testing

Stress-test the markdown codec to guarantee lossless round-trips across all block types, edge cases, and adversarial input.

- **Round-trip property tests:** Encode → decode → encode for every block type/inline style combination; output must be identical
- **Edge cases:** Empty blocks, blocks with only whitespace, nested styles (`***bold italic***`), adjacent styled segments, trailing newlines, leading/trailing spaces in segments
- **Ambiguous markdown:** Overlapping emphasis markers, unclosed delimiters, escaped characters (`\*`, `\[`), raw HTML fragments — codec should either round-trip or degrade gracefully
- **Multi-block structures:** Nested lists at varying depths, blockquotes containing headings/lists, mixed block types in sequence
- **Large documents:** Performance and correctness at 1k+ blocks — no silent truncation or style drift
- **Fuzz testing:** Random document generation → encode → decode → assert structural equality
- **Regression suite:** Capture every real bug as a named test case so it never recurs

**Key question answered:** Can we trust the markdown codec as the source-of-truth serialization format without silent data loss?

---

## Future Phases (unordered)

- WidgetSpan blocks (images, tables, embeds)
- Collaborative editing (CRDT-backed DocumentModel)
- Reaction system (auto-save, sync, analytics)
- Annotation layer (comments, suggestions)
- Block widget registry for third-party types
- Mode 1 (raw markdown) as power-user option
- Undo grouping (time-based, source-based)

---

## Principles

1. **Each phase is a working editor.** No phase leaves the app broken.
2. **Test each layer as you build it.** Unit tests for model/transactions, widget tests for rendering.
3. **Don't over-abstract early.** Use concrete types in early phases; extract interfaces when the pattern is clear.
4. **The POC is disposable.** If phase 1 reveals the approach doesn't work, we pivot cheaply.
