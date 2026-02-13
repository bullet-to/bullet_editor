# Future Enhancements

Ideas discussed during architecture planning. Not in v1, but the architecture supports adding them later.

---

## Transaction: Edit Source

Tag each transaction with what caused it.

```dart
enum EditSource { keyboard, toolbar, paste, reaction, sync }

class Transaction {
  // ... existing fields ...
  final EditSource source;
}
```

**Why it matters:**
- **Reaction loop prevention:** Reactions can check `tx.source == EditSource.reaction` and skip to avoid reacting to their own output.
- **Undo grouping:** Consecutive `keyboard` transactions can be auto-merged into one undo step (undo a word, not a character).
- **Debugging/logging:** Know what triggered each change.

---

## Transaction: Undo Grouping

Typing "hello" is 5 transactions. Undo should remove the whole word, not one character at a time.

```dart
class Transaction {
  // ... existing fields ...
  final String? groupId; // null = standalone, same ID = undo together
}
```

**Grouping strategies:**
- **Time-based:** Merge consecutive transactions within ~300ms of each other. Simple, matches user expectation.
- **Explicit group ID:** Transactions with the same `groupId` undo as a unit.
- **Source-based:** Consecutive `keyboard` transactions auto-group; `toolbar` and `paste` are always standalone.
- **Hybrid:** Time-based for keyboard input, explicit for everything else. Probably the right answer.

**Implementation:** The undo stack collapses grouped transactions into a single compound undo step. `invert()` on a group inverts all transactions in reverse order.

---

## Annotation Layer (Cross-Block Ranges)

For features like comments, suggestions, or track changes that span multiple blocks. These don't fit the inline style model (which is per-block) — they're a separate layer overlaid on the document.

```dart
class Annotation {
  final String id;
  final String type;              // comment, suggestion, highlight...
  final BlockPosition start;      // blockId + offset
  final BlockPosition end;        // blockId + offset (possibly different block)
  final Map<String, dynamic> data; // comment text, author, timestamp, etc.
}
```

- Annotations live alongside the DocumentModel, not inside it.
- The model stays clean (blocks contain inline styles only).
- `buildTextSpan()` overlays annotation styling on top of the model's formatting.
- Annotations are referenced by block ID + offset, so they survive block reordering.
- Google Docs, Notion, and ProseMirror all use this pattern.

---

## BlockPolicies: Additional Fields

When new block types need them, add these fields to `BlockPolicies`:

- **`allowedChildren: Set<BlockType>?`** — Restrict which block types can be nested under this one. `null` = any, specific set = only those. Needed when e.g. blockquotes should allow paragraphs but not headings.
- **`allowedInlineStyles: Set<InlineStyle>?`** — Restrict which inline styles are valid inside this block type. `null` = all, `{}` = none. Needed for code blocks (no formatting inside).

Both are no-ops to add — just new fields on the existing class + checks in the relevant operations (`ToggleStyle` for inline styles, `IndentBlock` for allowed children).

---

## Open Block Type Keys (Custom Block Types in the Model)

Currently `TextBlock.blockType` is typed as `BlockType` (a closed enum). The schema layer (`EditorSchema.blocks`) already accepts `Object` keys, so rendering, policies, toolbar labels, and codecs can be customized. But the document model itself can't hold a custom block type — you're limited to the built-in `BlockType` values.

**To support third-party custom block types**, `TextBlock.blockType` needs to widen from `BlockType` to `Object`. This ripples through:

- `EditOperation` subclasses (`ChangeBlockType`, `SplitBlock`, etc.)
- `InputRule` subclasses (pattern matching on block types)
- `EditorController` (anywhere that checks or sets block type)
- `MarkdownCodec._decodeBlock` (currently casts decoded key to `BlockType`)

**Trade-off:** Widening to `Object` loses exhaustive `switch` on block types. Mitigation: keep the `BlockType` enum as the default key set with exhaustive switches internally, but accept `Object` at API boundaries.

**When to do it:** When shipping as a package that third parties extend without forking. Not needed while block types are added to the library directly.

---

## Nested Inline Style Decoding

The markdown codec does not recursively decode nested inline styles. For example, `**bold *italic* text**` decodes as bold text containing the literal `*italic*` markers rather than a bold segment wrapping an italic segment.

**Why:** The wrap-based regex uses non-greedy `.+?` matching with alternation. Once the outer `**...**` matches, its content is treated as a flat string — the decoder doesn't recurse into the captured group.

**Impact:** Documents authored in this editor round-trip correctly (segments are per-character, so bold+italic produces `***text***` which decodes fine). The issue only affects markdown authored externally with nested delimiters like `**bold *italic* more**`.

**Fix:** After the initial decode pass, re-run `_decodeSegments` on each segment's text to resolve inner styles. Requires care to avoid infinite recursion on malformed input.
