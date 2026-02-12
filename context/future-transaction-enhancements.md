# Future Transaction Enhancements

Ideas discussed during architecture planning. Not in v1, but the transaction design supports adding them later.

---

## Edit Source

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

## Undo Grouping

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
