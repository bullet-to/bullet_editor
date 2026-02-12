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
