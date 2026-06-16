# Editor Architecture v3 — Research Findings

Research into how to move bullet_editor beyond the single-TextField architecture (v2), motivated by: block images, image grids, tables, per-block spacing, and the accumulating sentinel/offset-mapping hacks.

All package claims below were verified against actual source: flutter_quill v11.5.1 (commit `5c96e65`, 2026-06-09), super_editor `main` (commit `068a20d`, 2026-01-28), appflowy_editor `main` (commit `6fbe7ba`, 2026-03-31), Flutter SDK 3.41.6. Research date: 2026-06-11.

---

## The Three Tiers

Every serious Flutter rich text editor falls into one of three architectures. Nobody who succeeded uses one TextField per block.

| Tier | Architecture | Who |
|------|-------------|-----|
| 1 | One linear document inside a **rented TextField**. Structure smuggled through as text (sentinels, WidgetSpans, offset mapping). | bullet_editor v2 |
| 2 | Same linear document model — one IME connection, one global plain-text offset space, one `TextSelection` — but **owned rendering**: a custom render object per line. | flutter_quill |
| 3 | **Per-node editing.** No global offset space. Selection is `(node, local offset)` pairs. Each block is an independent component. IME sees only a window around the selection. | super_editor, appflowy_editor |

The unifying observation about tier 1: every limitation we've hit — prefix sentinels, spacer lines, the empty-block char, image height clamping, contested gestures inside WidgetSpans, no per-block padding — is the *same* limitation: **all structure must be expressed as text inside one TextField.** Each workaround is rent paid on that constraint.

---

## Hard Flutter Facts (verified against SDK 3.41 source)

### Cross-field selection is impossible

A selection cannot span multiple TextField/EditableText widgets. Each `EditableText` owns its own `TextEditingValue`, `RenderEditable`, and `TextInputConnection` — only the focused field even has an IME connection. Open since 2017 with no movement: [#10911](https://github.com/flutter/flutter/issues/10911), [#64854](https://github.com/flutter/flutter/issues/64854), [#79629](https://github.com/flutter/flutter/issues/79629). This kills the naive "TextField per block" design: you'd have to fake cross-block selection with custom highlight painting and gesture handling while *fighting* TextField's own focus/selection behavior — worst of both worlds.

`SelectionArea`/`SelectableRegion` does cross-widget selection but is strictly read-only — no caret, no IME, no editing model. The Flutter team's direction is to rebuild `SelectableText` on it, not to make it editable ([#104547](https://github.com/flutter/flutter/issues/104547)).

### Context menus are not a blocker

- Flutter's selection toolbar was never native — it's Flutter-drawn, platform-styled. Since the 3.7 rework it's fully decoupled: any custom editor can drive `ContextMenuController` + `AdaptiveTextSelectionToolbar.buttonItems(...)` directly and get the same platform-correct menus TextField shows.
- iOS 16+: `SystemContextMenu` shows the *real* native UIKit edit menu (the only way to offer Paste without the paste-permission popup). Requires an active `TextInputConnection` — which any custom editor that talks to the IME has. Custom items supported via `IOSSystemContextMenuItemCustom`. super_editor ships this today; flutter_quill never adopted it.
- Android has no native menu to lose — Flutter always draws its own there. `ProcessTextService` exposes the "Translate/Define" ACTION_PROCESS_TEXT actions for appending to a custom toolbar.

### Why image WidgetSpans can't exceed line height in a TextField (the v2 mystery, solved)

The WidgetSpan child is actually laid out at full intrinsic height (`RenderInlineChildrenContainerDefaults.layoutInlineChildren` applies only a width constraint). The clamp happens later, in three stacked mechanisms:

1. **`EditableText` defaults to `StrutStyle.fromTextStyle(style, forceStrutHeight: true)`** — locks every line box to the base TextStyle's height, ignoring per-line content metrics. Added deliberately in [PR #27612](https://github.com/flutter/flutter/pull/27612) so fields have predictable height. A tall placeholder can't grow its line.
2. `RenderEditable` sizes itself from strut/`preferredLineHeight` math that knows nothing about placeholders, and clamps to `preferredLineHeight × maxLines` when maxLines is set.
3. Overflow is clipped: `TextField.clipBehavior` defaults to `Clip.hardEdge`.

**Workaround within tier 1: `strutStyle: StrutStyle.disabled`** (with `maxLines: null`). Lines then size to content including placeholders. Caveats: caret/selection-handle heights still come from `preferredLineHeight` (short caret next to tall image), line heights become content-dependent, and WidgetSpan-in-TextField has a history of positioning bugs ([#153005](https://github.com/flutter/flutter/issues/153005), [#102570](https://github.com/flutter/flutter/issues/102570), [#150864](https://github.com/flutter/flutter/issues/150864)). This makes block images *provable* in v2 as a cheap spike, even if v3 goes another way.

### Per-block bottom padding is architecturally impossible in tier 1

`RenderEditable` lays out one paragraph flow with no concept of per-line insets. The only fakes are spacer lines (our `‌` hack — costs a sentinel, offset mapping, cursor-skip logic, and selection highlights stretching over the gap) or per-span `TextStyle.height` (proportional leading on *every* line of the paragraph, not space after the block). In tier 2/3, spacing is just `EdgeInsets` on a line/block render object — not text, so no sentinel, cursor never visits it, highlights don't cover it.

---

## flutter_quill (tier 2) — deep dive

Sources: [repo](https://github.com/singerdmx/flutter-quill), v11.5.1. MIT. Actively maintained, with a stated policy of "bug fixes over new features."

### Rendering: no RenderEditable, no TextField

```
QuillRawEditorState
└─ SingleChildScrollView (NOT lazy)
   └─ RenderEditor (vertical stack; document-global selection/caret/handles math)
      ├─ RenderEditableTextLine   (one per line; slots: leading + body)
      │    body → RenderParagraphProxy wrapping a plain RenderParagraph
      └─ RenderEditableTextBlock  (one per list/quote/code block, containing lines)
```

- Glyph layout is Flutter's normal paragraph layout; quill only reads geometry from it.
- Bullets/numbers/checkboxes are a real `leading` layout slot beside the text — **zero characters, no offset mapping needed**.
- Vertical spacing is `EdgeInsets` padding applied in `RenderEditableTextLine.performLayout`. (But their API only exposes spacing per block *type* via theme — `DefaultStyles`/`VerticalSpacing` — plus a `line-height` attribute that only matches 4 preset values. The architecture allows per-block; the API is just stingy.)

### Sentinels: only one survives

An embed (image/video) occupies exactly one `￼` in the plain-text offset space; `\n` per line. No prefix char, no spacer char, no empty-block char — empty lines are render objects with their own `preferredLineHeight`. The display text IS the model plain text, so our entire `offset_mapper.dart` class of bugs disappears in this model.

### IME: whole-document plain text + diff

One `TextInputClient` for the entire document; the IME buffer is literally `document.toPlainText()`. On `updateEditingValue` it diffs old vs new around the cursor and converts to a controller edit; a rules engine reapplies formatting. Conceptually identical to bullet_editor v2 — and it shares the failure mode: chronic CJK/IME bugs ([#2178](https://github.com/singerdmx/flutter-quill/issues/2178), [#2710](https://github.com/singerdmx/flutter-quill/issues/2710)), and the platform payload scales with document size.

### Cross-block selection: nearly free

One global `TextSelection` in plain-text offsets. Every line render object checks intersection with its range, clamps to local coordinates, gets boxes from its `RenderParagraph`, and paints its own highlight. Handles anchored via `LeaderLayer`s from the parent. No magic — it works because it's still one logical editable.

### Tables: definitively absent, and the failure is instructive

- No table support in core or extensions as of v11.x. The v10 experimental table embed ([PR #1960](https://github.com/singerdmx/flutter-quill/pull/1960)) used debounced plain `TextFormField` cells *outside* the document's selection/IME/undo model, with a non-quill.js format. Buggy (cell deletion duplicated text, broken on web), deprecated, **removed in v11.0.0**. Open requests ([#1735](https://github.com/singerdmx/flutter-quill/issues/1735)) have no maintainer commitment.
- Root cause is architectural: **a single linear offset space over a vertical stack of lines cannot express a table** — 2-D layout containing multiple editable regions. This ceiling is shared by flutter_quill, bullet_editor v2, and any tier-1/2 design.

### Other weak points (issue-tracker evidence)

- **Accessibility effectively absent**: no semantics in the editor render objects; enabling semantics *breaks typing* ([#2531](https://github.com/singerdmx/flutter-quill/issues/2531), [#2699](https://github.com/singerdmx/flutter-quill/issues/2699), open regression). Tier 1 inherits RenderEditable's full semantics for free — this is the biggest thing v2 would give up.
- **Large-document perf**: non-lazy `SingleChildScrollView`, every keystroke rebuilds every line widget (key-less positional reconciliation), O(n) child lookups ([#997](https://github.com/singerdmx/flutter-quill/issues/997), [#2374](https://github.com/singerdmx/flutter-quill/issues/2374)). Virtualization is hard in this design because one render box must answer geometry for the whole document.
- Tracking Flutter internals requires constant patching (e.g. 11.5.1 added `TextInputClient.onFocusReceived` for Flutter 3.44).

### Size

Editor layer ~14k LOC; the irreducible core (RenderEditor + line/block render objects + IME client + selection overlay + keyboard actions) ≈ 9k LOC. Document model/controller/rules another ~5k (we already have equivalents).

---

## super_editor (tier 3) — verified deep dive

Sources: [repo](https://github.com/superlistapp/super_editor), commit `068a20d`. MIT. Active but still `0.3.0-dev.NN` prereleases after ~6 years; pub "stable" 0.2.7 is 2 years old. ~93k LOC main package. (See also `super-editor-issues-analysis.md` and the "Why Not super_editor" section of `editor-architecture-v2.md` — the decision not to *depend* on it stands; this section is about learning from its architecture.)

- **Selection** (`core/document_selection.dart`, `core/document.dart`): `DocumentSelection { base, extent }` of `DocumentPosition { nodeId, nodePosition }`. `nodePosition` is node-type-specific (`TextNodePosition` for paragraphs, `UpstreamDownstreamNodePosition` for box nodes like images/HRs). Positions aren't even orderable without the document.
- **Components**: `ComponentBuilder` registry per node type (`defaultComponentBuilders`: blockquote, paragraph, list item, images, HR). Each component's State mixes in `DocumentComponent` — the geometry contract (`getPositionAtOffset`, `getRectForPosition`, …). Text renders via their own `super_text_layout` (subclassed `RenderParagraph` with caret/selection decoration layers). **Zero hits for TextField/EditableText/RenderEditable in the editing path** (grep-verified; `SuperTextField` is a separate from-scratch widget).
- **IME** (`default_editor/document_ime/`, ~4k LOC): one document-level `DeltaTextInputClient`. `DocumentImeSerializer` sends the IME **exactly the node(s) intersected by the selection** — one node for a collapsed caret, multi-node selections joined with `\n`, non-text nodes as `~`. Prepends a `". "` placeholder so the IME can report backspace at offset 0 (always prepended since [#1641](https://github.com/superlistapp/super_editor/issues/1641) — changing the value mid-composition restarts IME composition).
- **Gestures/handles**: per-platform interactors (`DocumentMouseInteractor`, `AndroidDocumentTouchInteractor`, `IosDocumentTouchInteractor`), custom handles and magnifiers per platform (~4.4k LOC of platform infrastructure). A style-pipeline phase pushes the document selection into each component's view model; **each component paints its own selection slice** (`TextLayoutSelectionHighlight` for text, `SelectableBox` tint for box nodes).
- **Tables: read-only only.** `TableBlockNode` exists (`default_editor/tables/`) but the doc comment is explicit: "represents a read-only block table… either fully selected or not selected at all, i.e., there is no selection of individual cells." Not in the default builders. Six years in, no editable cells.
- **Known gaps**: essentially no `Semantics` (accessibility), no Scribble/stylus handwriting.

---

## appflowy_editor (tier 3) — verified deep dive

Sources: [repo](https://github.com/AppFlowy-IO/appflowy-editor), commit `6fbe7ba`. **AGPL-3.0 / MPL-2.0 dual license — reference for study, do not copy code.** ~49k LOC. v6.2.0 on pub.

- **Selection** (`core/location/position.dart`, `selection.dart`): `Selection { start, end }` of `Position { path, offset }` where `Path = List<int>` indexing into the node tree. No global character offset anywhere.
- **Components**: `standardBlockComponentBuilderMap` keyed by node `type` string → `BlockComponentBuilder` per type. Text renders via plain `RichText` (`AppFlowyRichText`, whose State mixes in `SelectableMixin`). **Zero hits for EditableText/RenderEditable** in lib/; TextField appears only in chrome (find/replace, color picker, link dialog).
- **IME** (`editor_component/service/ime/`, ~1.4k LOC — the leanest working implementation): `_getCurrentTextEditingValue` builds the IME buffer from **only the nodes inside the current selection** (one node's plain text for a collapsed caret), with node-local offsets. Re-attached on every selection change. `DeltaTextInputService` prepends a sentinel space ("the IME will not report the backspace button if the cursor is at the beginning") and shifts all incoming deltas back by 1 — the same trick as super_editor, independently invented. A `NonDeltaInputService` diff-based fallback exists for platforms where the delta model is unreliable.
- **Selection services**: separate `desktop_selection_service.dart` and `mobile_selection_service.dart`, custom drag handles (`mobile_basic_handle.dart` etc.) and magnifier. Highlights are computed per block from each block's `SelectableMixin.getRectsInSelection()` and painted by a per-block `CustomPainter` (`BlockSelectionArea`).
- **Tables: working editable cells — the only Flutter editor that has them.** `TableBlockComponentBuilder` + `TableCellBlockComponentBuilder` are in the standard map. A cell is `Node(type: tableCell, children: [paragraphNode(...)])` — an ordinary paragraph node at a real path in the tree, rendered through the normal pipeline. Cursor placement, in-cell selection, and IME work through the same machinery as any other block, **no special-casing**. Caveats: dragging a range across the table selects the whole table as one unit (no cross-cell text selection), and no merged/spanned cells.
- Known weak area historically: Android/CJK IME on the delta path.

---

## Cross-cutting findings

### The tables scoreboard (the decisive datapoint)

| Editor | Tables | Why |
|--------|--------|-----|
| flutter_quill (tier 2) | Shipped as embed islands in v10 → **deleted in v11** | Linear offset space can't express 2-D editable regions; TextFormField cells were outside the document model |
| super_editor (tier 3) | **Read-only block only**, whole-table selection | Editable cells never shipped in 6 years |
| appflowy_editor (tier 3) | **Working editable cells** | Cells are ordinary nodes at real tree paths — came almost free once blocks were first-class |

Editable-cell tables exist in exactly one Flutter editor, and only because of per-node architecture.

### The backspace sentinel is universal

Even tier-3 editors keep one sentinel: both super_editor (`". "`) and appflowy (a space) prepend an invisible placeholder to the IME buffer because the IME protocol cannot express "backspace at offset 0." The difference from v2: it lives only at the IME serialization layer, never in display text or the model.

### Inline images and grids don't force the architecture

- Truly inline images = one atomic character (`WidgetSpan` in tier 1/2, inline embed in tier 2, inline node in tier 3). Works everywhere.
- A grid/gallery should be **one block whose data is a list of images** (cf. Notion galleries), not N adjacent image blocks — real grid geometry, atomic selection, and model-level rules like auto-coalescing consecutive image inserts. Contains no editable text, so it works in every tier. Tier 1 caveat: long-press/drag gestures inside the WidgetSpan fight TextField's selection gestures; tiers 2/3 give the embed an ordinary widget subtree with unshared gestures.

### What survives from v2 in any rewrite

Of ~7.4k LOC in lib/src:

| Survives unchanged (~4-5k) | Dies or transforms (~2.5k) |
|---|---|
| `Document` / `TextBlock` / `StyledSegment` model | `offset_mapper.dart` (entirely — happily) |
| `EditOperation`s (already expressed in block terms) | `span_builder.dart` (replaced by per-block builders) |
| Undo system, input rules, schema system | `EditorController`'s `TextEditingController` inheritance and linear-offset coupling |
| Markdown codec | The three sentinels (`￼` prefix, `‌` spacer, `​` empty block) |

Notably, **our document model is already shaped like appflowy's, not quill's**: a tree of typed blocks with stable IDs, `children`, and `metadata` — vs quill's flat run of lines. And the schema system (block type → definition) maps one-to-one onto per-block component builders. The linear-offset coupling is the part that dies in *either* tier.

---

## Decision matrix: tier 2 vs tier 3

| | Tier 2 (quill-style) | Tier 3 (appflowy-style) |
|---|---|---|
| Per-block padding, block images, grids, spacing | Solved | Solved |
| Cross-block selection | Nearly free (one coordinate space) | The hard part — custom `DocumentSelection`, ordering, per-component painting |
| IME | Simple but fragile: whole-doc plaintext diff; CJK bug magnet; payload grows with doc | Harder but bounded: window around selection + deltas (appflowy: ~1.4k LOC) |
| **Tables with editable cells** | **Never, by construction** | Native fit |
| Large documents | Hard to virtualize (one render box) | Natural — blocks independent, lazy lists possible |
| Migration distance | Short: linear offsets in `EditorController` survive | Longer: everything linear-offset rewritten as `(blockId, offset)` |
| Accessibility | Build from scratch (quill's is broken) | Build from scratch (super_editor's is absent) |
| New code estimate | ~9–14k LOC | ~1.5–2.5× that |

## Recommendation

**Base v3 on the tier-3 per-block architecture, using appflowy_editor's source as the reference to study (not depend on, and not copy — AGPL/MPL).** Rationale:

1. Tables were a stated motivation for the rewrite, and the verified evidence says tier 2 can never deliver them while tier 3 gets them almost free once blocks are first-class.
2. Our document model and schema system are already tier-3-shaped; the code that dies (linear-offset coupling) dies in either tier anyway.
3. appflowy's selection services, `SelectableMixin` contract, and ~1.4k-LOC IME service are the leanest working blueprint for exactly the pieces we'd write. Budget the bulk of the time for the two genuinely hard pieces: the document selection layer (gestures, painting, handles, per-platform) and the IME window serialization.

**Flip to tier 2 only if** tables get demoted to nice-to-have and the product is bullets/outlining forever — then quill-style ships months sooner and fixes every other named frustration, with cross-block selection nearly free.

**Cheap de-risking spikes before committing:**
- In v2 today: `strutStyle: StrutStyle.disabled` + full-width image WidgetSpan to prove block images and gauge the caret/selection jank firsthand.
- For v3: a read-only prototype rendering the existing `Document` as a column of per-block widgets (`RichText` + padding) to validate look/feel — then layer in the IME client, where the real work lives.

Open accessibility note: no custom Flutter editor (any tier) has solved semantics — quill's breaks typing, super_editor's is absent. Whatever we build, a11y is on us; tier 1 was the only architecture that got it free.
