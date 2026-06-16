# Bullet Editor — Architecture Plan v2

## Goal

Replace super_editor with a custom markdown-based editor in Flutter, built on top of TextField.

## Design Principles

- Don't fight Flutter. Use TextField as the editing surface.
- Keep a structured document model as the source of truth.
- Markdown is a serialization format, not the editing model.
- Abstract the model for extensibility from day 1, even if v1 only implements text blocks.
- Model is immutable — edits produce new state, never mutate in place.
- All edits go through transactions — enables undo/redo and change observation.
- Schema validates what's allowed from day 1.

---

## Why Not super_editor

- super_editor is mid-major-refactor (flat list → tree structure), with no clear timeline. Building on it means building on shifting ground.
- Its architectural debates (generic vs typed nodes, CRDT support, ProseMirror-style schemas) are about being a general-purpose document framework. We don't need that.
- We need a notes editor with inline formatting + headings + lists. TextField covers this cleanly.
- See: https://github.com/Flutter-Bounty-Hunters/super_editor/discussions/2403

---

## Editor Modes

### Mode 1 — Plaintext Markdown Editor

- TextField shows raw markdown
- Separate preview pane renders formatted output
- Toolbar reads cursor position, detects current formatting, can toggle it
- Effort: Low. Mostly parsing logic.

### Mode 2 — Bear-Like Editor (Contextual Token Reveal)

- TextField contains raw markdown as its text
- `buildTextSpan()` renders formatted text (bold looks bold, headings are large)
- Markdown tokens (`**`, `#`, etc.) are made tiny/transparent (`fontSize: 0.01`, `Color.transparent`)
- This preserves 1:1 offset mapping (display length == raw text length)
- **Contextual reveal:** When cursor is inside/adjacent to a formatted range, tokens become visible at full size. When cursor moves away, they shrink again.
- This eliminates cursor "sticking" on invisible characters — by the time the cursor reaches them, they're visible.
- Effort: Medium. Contextual reveal + parsing is real work but bounded.

### Mode 3 — Full WYSIWYG (Markdown Hidden)

- TextField contains plain display text (no markdown tokens ever visible)
- A separate span model tracks formatting ranges over the plain text
- `buildTextSpan()` applies formatting from the span model
- User never sees markdown syntax. Toolbar and shortcuts are the only way to format.
- Markdown is only used for save/load (serialize/deserialize).
- Effort: Medium-high. Need span sync on edit + the shared model layer.

### Mode Switching (Mode 2 <-> Mode 3)

Both modes are views into the same `DocumentModel`. Switching is a one-time serialize/deserialize — not a continuous offset mapping.

- **To Mode 2:** `model → serialize to markdown → controller.text`. buildTextSpan does contextual reveal.
- **To Mode 3:** `model → serialize to plain text + span list → controller.text`. buildTextSpan applies spans.
- During editing in either mode, offsets are always 1:1 with whatever text is in the controller. The complexity only exists at the moment of switching.

---

## Document Model

Source of truth. Format-agnostic. Immutable. Tree-structured (matching markdown's AST). All editor modes are projections of it.

### Core principles

- **Immutable:** Edits produce a new `DocumentModel`, never mutate the existing one. Enables undo/redo via a state stack with structural sharing (blocks that didn't change are reused, not copied).
- **Transaction-based:** All mutations go through a `Transaction` object that records what changed. Transactions are invertible (for undo) and observable (for change listeners/toolbar updates). Operations are **semantic** (e.g. "toggle bold on block X, range 5-10") not structural (e.g. "replace block at index 3"). Semantic operations map cleanly to CRDT operations if sync is added later.
- **Read/write separation (CQRS):** The model exposes separate `DocumentReader` (query) and `DocumentEditor` (mutate) interfaces. v1 implements both in one class. This costs nothing now but allows reads and writes to diverge later (e.g. reads from local cache, writes to a CRDT that syncs remotely).
- **Interface-based:** `DocumentModel` is an interface, not a concrete class. v1 uses `InMemoryDocument`. A future CRDT-backed implementation can swap in without touching controller or toolbar code.
- **Schema-validated:** A `Schema` defines valid block types, valid inline styles, and (later) content rules. Third-party block types register in the schema. Invalid states are rejected at edit time, not discovered at render time.
- **Generic serialization:** Every `Block` supports `toJson()`/`fromJson()` alongside markdown. Markdown is the primary format, but JSON means any block type can be persisted/synced without custom code.

### Interfaces

```dart
/// Read-only access to the document. Used by toolbar, buildTextSpan, serializers.
abstract class DocumentReader {
  List<Block> get rootBlocks;
  Block getBlock(String id);
  Set<InlineStyle> getStylesAt(String blockId, int offset);

  /// Depth-first traversal of the full tree, flattened. Used by the controller
  /// to map the tree to a single TextField string.
  List<Block> get allBlocks;
}

/// Mutation access. Used by edit actions, keyboard handlers.
abstract class DocumentEditor {
  DocumentModel applyTransaction(Transaction tx);
}

/// Full interface. v1 implementation implements both.
abstract class DocumentModel implements DocumentReader, DocumentEditor {}
```

### Block types — tree-structured from day 1

Blocks form a tree. Every block can have children. This matches markdown's actual AST structure (see [mdast](https://github.com/syntax-tree/mdast)). Nested lists, blockquotes containing paragraphs, and collapsible sections are all naturally represented without metadata hacks.

```dart
abstract class Block {
  String get type;
  String get id;
  List<Block> get children; // tree structure — every block can have children

  Map<String, dynamic> toJson();
  Block copyWith({List<Block>? children}); // for immutable updates
}

/// The only concrete type for v1.
/// Covers: paragraphs, headings, list items, blockquotes, code blocks.
class TextBlock extends Block {
  final TextBlockType blockType; // paragraph, h1, h2, h3, listItem, numberedListItem, quote, codeBlock
  final List<StyledSegment> segments;
  final List<Block> children; // e.g. list items nested under a list, paragraphs under a blockquote
}

class StyledSegment {
  final String text;
  final Set<InlineStyle> styles; // bold, italic, code, strikethrough, link...
}

/// v1 implementation — in-memory, implements both read and write.
class InMemoryDocument implements DocumentModel { ... }
```

### Tree examples

```
Document
├── H1 "Introduction"
│   ├── Paragraph "Some text..."
│   └── Paragraph "More text..."
├── H2 "Details"
│   ├── Paragraph "Explanation..."
│   └── Blockquote
│       └── Paragraph "A wise quote"
└── H2 "Tasks"
    └── ListItem "First task"
        ├── ListItem "Sub-task A"
        └── ListItem "Sub-task B"
```

For the TextField, `allBlocks` flattens this via depth-first traversal into a linear sequence. The tree is the model; the flat sequence is the view.

### Schema

```dart
class EditorSchema {
  /// Registered block types. Third parties add theirs here.
  final Set<String> blockTypes;

  /// Valid inline styles.
  final Set<InlineStyle> inlineStyles;

  /// Validates a block is well-formed.
  bool isValid(Block block);
}
```

v1 schema: `{paragraph, h1, h2, h3, listItem, numberedListItem, quote, codeBlock}` + `{bold, italic, code, strikethrough, link}`. Simple, but enforced.

### Transactions

A transaction is one atomic logical edit. It bundles all changes — text, formatting, block structure, AND cursor/selection state — into a single unit. This avoids the split-notification problem that plagued super_editor for years (see [#748](https://github.com/Flutter-Bounty-Hunters/super_editor/issues/748)).

```dart
class Transaction {
  final List<EditOperation> operations; // insert block, delete block, update block, toggle style, etc.
  final SelectionState? selectionBefore; // cursor/selection position before this edit
  final SelectionState? selectionAfter;  // cursor/selection position after this edit
  final DateTime timestamp;

  /// Apply to produce new DocumentModel.
  DocumentModel apply(DocumentModel model);

  /// Invert for undo. Restores both content and cursor position.
  Transaction invert();
}

class SelectionState {
  final String blockId;
  final int offset;
  final String? endBlockId; // null if no range selection
  final int? endOffset;
}
```

Undo/redo = a stack of transactions. Apply to redo, invert + apply to undo. Because selection is part of the transaction, undo restores both content and cursor position atomically. TextField's built-in undo is for text only; model-level transactions cover everything.

### Input Rules

Input rules intercept pending transactions *before* commit and can transform them. This is how markdown shortcuts work — the model goes directly from one valid state to another in a single transaction. No intermediate state, clean undo.

Inspired by [ProseMirror's input rules](https://prosemirror.net/docs/guide/#inputrules).

```dart
abstract class InputRule {
  /// Check if the pending edit matches a pattern. If so, return a modified
  /// transaction (e.g. convert paragraph to heading). If not, return null
  /// and the edit proceeds unchanged.
  Transaction? tryTransform(Transaction pending, DocumentReader doc);
}
```

**v1 input rules:**
- `# ` at line start → convert block to H1, consume the `# ` prefix
- `## ` → H2, `### ` → H3
- `- ` at line start → convert block to list item
- `> ` at line start → convert block to blockquote
- Enter at end of empty list item → convert back to paragraph

**Pipeline:** edit → input rules transform → commit → reactions observe.

Input rules = "interpret what the user meant." They keep markdown shortcut logic isolated and testable.

### Reactions

Reactions observe committed transactions *after* they're applied. They don't transform content — they handle side effects.

```dart
abstract class EditReaction {
  /// Called after a transaction is committed. For side effects only.
  void onTransactionCommitted(Transaction tx, DocumentReader doc);
}
```

**Not needed for v1.** Future uses:
- Auto-save
- Sync notifications
- Validation/linting
- Analytics
yes
### Future block types (no rewrites needed)

```dart
/// Rendered via WidgetSpan on a placeholder char (\uFFFC) in the TextField.
class TableBlock extends Block {
  final List<List<List<StyledSegment>>> cells; // row → col → segments
}

class ImageBlock extends Block {
  final String url;
  final String? altText;
}

// Third parties add their own Block subtypes + register in EditorSchema.
```

### How WidgetSpan blocks work

- Non-text blocks are represented as a single placeholder character (`\uFFFC`) in the controller's text string.
- `buildTextSpan()` emits a `WidgetSpan` at that position, rendering the block's widget.
- Cursor treats the widget as 1 character — arrow keys skip past it, selection includes it, delete removes it. All native TextField behavior.
- Offset mapping stays 1:1 (the widget is 1 char in the string).
- **Editing inside widget blocks** (e.g. typing in a table cell) requires nested focus management — the WidgetSpan's widget gets its own TextField. This is the main complexity.

#### Visual Prefix Approach (\uFFFC placeholder chars)

List items and nested blocks get a `\uFFFC` placeholder char in the display text, rendered as a WidgetSpan (bullet/indentation). This works for rendering and offset mapping, but creates an extra cursor stop at each prefix position. Arrow key interception is used to skip over prefix chars. This is a pragmatic workaround — the cleaner alternatives (custom paint, per-block rendering) are significantly more work. If the arrow key patching becomes too brittle, switch to per-block rendering.

#### WidgetSpan Probe Results (Phase 3)

Tested embedding a nested TextField inside a WidgetSpan within the outer TextField. Findings:

- **Non-interactive WidgetSpan works:** rendering, offset mapping (1 char = 1 widget), cursor stepping over the placeholder, delete removing it — all work correctly.
- **Interactive WidgetSpan does NOT work:** the outer TextField intercepts touch events before they reach the nested TextField. Both TextFields show carets simultaneously. Focus coordination via FocusNode.unfocus/requestFocus does not help because the gesture never reaches the inner widget.
- **Conclusion:** The single-TextField approach supports non-interactive embeds (images, dividers, read-only widgets). For interactive embeds (table cells, editable widgets), a per-block rendering approach is needed — each interactive block gets its own TextField widget, rendered in a Column/ListView, with focus management between them. This is the same approach super_editor uses.
- **Impact on architecture:** The model, transactions, operations, input rules, and codec are rendering-agnostic — they don't change. Only the controller/rendering layer would need a second implementation for interactive embeds. The current single-TextField renderer remains valid for text-only documents.

#### Alternative: Overlay-based Interactive Embeds

Instead of per-block rendering, use Flutter's `Overlay` to float independent TextFields on top of the main TextField at placeholder positions. The main TextField keeps `\uFFFC` + a `SizedBox` WidgetSpan to reserve space; a `CompositedTransformFollower`/`LayerLink` positions a real TextField overlay on top.

**Solves:** gesture interception (overlay gets its own hit testing), focus/caret independence.

**Still hard:** cross-widget selection (selecting from paragraph into table cell), scroll sync (overlay must track scroll position), position tracking (re-query after every layout pass), keyboard navigation between main and overlay TextFields.

**Best for:** isolated interactive blocks (tables, code blocks) where selection doesn't span across the boundary. Not suitable for inline interactive elements. Worth a probe before committing to full per-block rendering.

### Tree operations

- **Collapsible sections:** Collapse H1 = hide `h1.children`. No scanning/inference needed.
- **Nested lists:** Sub-items are children of their parent list item. No `indentLevel` hack.
- **Blockquotes:** A blockquote block contains its child paragraphs/lists. Natural nesting.
- **Flattening for TextField:** `allBlocks` does a depth-first traversal. One function, called when syncing model → controller.

---

## Edit Pipeline

### Edit flow (user → model → screen)

```
User Action (keystroke, toolbar tap, paste)
    │
    ▼
Create Transaction
    │  semantic operations + selectionBefore/After + timestamp
    │
    ▼
Input Rules
    │  each rule can transform the transaction
    │  (e.g. "# " → convert to heading)
    │
    ▼
Schema Validation
    │  reject if result would be invalid
    │
    ▼
Commit
    │  apply transaction to DocumentModel → new immutable model
    │
    ▼
Undo Stack
    │  push transaction (invertible)
    │
    ▼
Reactions (future)
    │  side effects: auto-save, sync, etc.
    │
    ▼
Sync to Controller
    │  re-serialize model → controller.text
    │  (markdown string in Mode 2, plain text in Mode 3)
    │
    ▼
Render
    buildTextSpan() reads model, applies formatting
```

### Read flow (model → UI)

```
Toolbar / buildTextSpan()
    │
    ▼
DocumentReader
    │  getStylesAt(blockId, offset) → current formatting
    │  allBlocks → flat sequence for TextField
    │
    ▼
Display
    toolbar buttons reflect active styles
    text renders with correct formatting
```

### Mode switch flow

```
User toggles mode
    │
    ▼
DocumentModel (unchanged)
    │
    ▼
Re-serialize to target format
    │  Mode 2: model → markdown string
    │  Mode 3: model → plain text + span list
    │
    ▼
Set controller.text + update mode flag
    │
    ▼
buildTextSpan() renders differently based on mode
```

### Undo flow

```
Cmd+Z
    │
    ▼
Pop transaction from undo stack
    │
    ▼
Invert transaction
    │  (reverses operations, swaps selectionBefore/After)
    │
    ▼
Apply inverted transaction → new model
    │
    ▼
Push inverted transaction to redo stack
    │
    ▼
Sync to Controller + Render
```

---

## Architecture Layers

1. **DocumentModel** — immutable block tree (source of truth). Abstract `Block` base, only `TextBlock` for v1.
2. **EditorSchema** — defines valid block types and inline styles. Validates edits. Extensible by third parties.
3. **Transaction engine** — all edits go through transactions (including selection state). Produces new immutable model. Supports undo/redo and change observation.
4. **Input rules** — intercept pending transactions before commit, transform them (markdown shortcuts → block conversions). v1 feature.
5. **Reaction system (future)** — observe committed transactions for side effects (auto-save, sync, etc.).
6. **Markdown parser/serializer** — markdown string ↔ DocumentModel. Extensible per block type.
7. **JSON serializer** — generic `toJson()`/`fromJson()` on all blocks. For persistence/sync beyond markdown.
8. **Plain text projector** — DocumentModel ↔ plain text + formatting span offsets (for Mode 3).
9. **EditorController** (single, mode-aware) — extends TextEditingController. Holds a mode flag (markdown / wysiwyg). `buildTextSpan()` checks the mode:
   - **Markdown mode:** tokens are in the text, apply contextual reveal (shrink/show based on cursor proximity)
   - **WYSIWYG mode:** plain text in controller, apply formatting spans from the model
   - **Widget blocks (future):** insert placeholder char + WidgetSpan for non-text blocks
   - On mode switch: re-serialize DocumentModel into the target format, set `controller.text`
10. **Block widget registry (future)** — `Map<String, BlockWidgetBuilder>` so third parties can register custom block types with their rendering widgets.
11. **Shared toolbar** — reads model via schema-aware queries, writes via transactions. Works in all modes.

---

## v1 Scope

- TextBlock only (paragraphs, headings, lists)
- Inline formatting: bold, italic, code, strikethrough
- EditorSchema with v1 block types + inline styles
- Immutable model + transaction engine (with selection state) + undo/redo
- Input rules for markdown shortcuts (`# `, `## `, `- `, `> `, empty list item → paragraph)
- Mode 2 (Bear-like) as the primary editing experience
- Mode 3 (WYSIWYG) as stretch goal
- Markdown + JSON serialization
- Shared toolbar with formatting detection + toggle

## Future Extensions (architecture supports without rewrite)

- WidgetSpan-based blocks (tables, images, embeds)
- Block widget registry for third-party block types
- Mode 1 (raw markdown) as a power-user option
- Collapsible headings/sections (tree structure already supports this)
- Collaborative editing (immutable model + transactions are CRDT-friendly)
- Reaction system for post-commit side effects (auto-save, sync, analytics)

---

## Known Limitations

- **Block-level visual styling:** Headings work (fontSize on TextSpan). Lists work (bullet/number is literal text). Blockquotes, code block backgrounds, and horizontal rules push beyond what buildTextSpan can do — would need custom paint or visual compromises.
- **Inline formatting** (bold, italic, code, strikethrough, links) works cleanly in both modes.
- **Nested focus for widget blocks:** Editing inside a WidgetSpan (e.g. table cells) requires nested TextFields and focus management. Needs prototyping.

---

## Open Questions

- Exact TextBlockTypes to support at launch
- Link handling UX (inline display, tap behavior)
- Multi-block selection behavior in Mode 3
- How to handle newlines — one TextBlock per line, or one TextBlock per paragraph with `\n` inside?
