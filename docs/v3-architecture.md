# bullet_editor v3 — Architecture (final)

> **Provenance.** Produced 2026-06-11 by a 5-candidate architecture tournament
> (layered-services, command-pipeline, minimal-20day, tier2-contrarian, selection-first)
> with adversarial improvement rounds, then amended through review — see git history for
> the amendment trail. Winning prior: **minimal-20day** ("smallest tier 3 that ships in
> 20 days"), with the single-writer serialization discipline grafted from the
> command-pipeline runner-up and the tests-as-milestone-artifacts discipline from the
> selection-first runner-up. Judged against `docs/v3-requirements.md` (decisions
> D1–D14) and the 15-scenario gauntlet reproduced in Appendix A (scenarios cited as
> G1–G15). Research backing: `docs/editor-architecture-v3-research.md`.

Forced prior honored throughout: every layer below exists because a requirement or gauntlet
scenario demands it. Where super_editor has a layer we don't, the omission is deliberate and
noted.

## Overview

v3 is a tier-3 per-block editor in the appflowy shape (the leanest verified working blueprint —
research §appflowy: ~1.4k LOC IME, working editable table cells), built directly on the v2
document model, which is already tier-3-shaped (research §"What survives").

The whole system is five runtime pieces wired directly together, no event bus, no style pipeline,
no view-model layer:

```
                ┌──────────────────────────────────────────────┐
                │ EditorController (ChangeNotifier)            │
                │  Document (v2) + DocSelection + UndoManager  │
                │  + InputRules (v2) + EditOperations (v2)     │
                │  + single-writer edit queue                  │
                └──────┬───────────────▲───────────────────────┘
            notifies   │               │ edits (serialized)
                       ▼               │
   ┌──────────────────────────┐   ┌────┴──────────────┐   ┌─────────────────┐
   │ BlockListView (lazy      │   │ ImeService        │   │ Gesture layer   │
   │ sliver of block          │◄──┤ (DeltaTextInput-  │   │ (mouse + touch  │
   │ components; each paints  │   │  Client, 1-block  │   │  interactors,   │
   │ its own caret/selection/ │   │  window+sentinel; │   │  per-pointer-   │
   │ squiggles/composing)     │   │  diff fallback)   │   │  kind dispatch) │
   └──────────┬───────────────┘   └───────────────────┘   └─────────────────┘
              │ registers geometry
              ▼
   ┌──────────────────────────┐
   │ BlockLayoutRegistry      │  blockId → laid-out component geometry (or null)
   └──────────────────────────┘
```

Key minimalism decisions (each defended in its section):

1. **Selection is `(blockId, offset)` pairs** — no `NodePosition` class hierarchy, no `Path =
   List<int>`. Block ids are path-agnostic, so a future table cell's paragraph is just another id
   in the tree (GATE-T) and ids survive tree mutations that would invalidate paths.
2. **Edit operations are natively id-addressed.** Every `EditOperation` names its block by
   `blockId` and resolves it against the document it receives **at apply time** — `Document?
   apply(doc, EditContext ctx)`, schema-derived behavior supplied in `ctx`, never stored in ops
   (see Operations). Mid-transaction index staleness (G13) is therefore not prevented by
   discipline — it is **unrepresentable**: ops carry no flat index to go stale, and a gone id is
   the loud residue (rejects the whole batch). There is no separate `EditIntent` vocabulary
   mirroring the ops — a 14-type 1:1 mirror whose only job is bridging ids to indices is exactly
   the layer id-native addressing deletes. Ops ARE the public vocabulary (enumerated in the API
   section, with missing-id and gate-failure semantics specified); `Transaction`s stay
   package-private purely as surface-area hygiene.
3. **One IME strategy, two frontends, one core**: buffer = the block(s) under the selection, one
   leading `". "` sentinel (super_editor's verified constant — see IME), deltas shifted by −2. The
   delta frontend serves iOS/Android; a non-delta **diff fallback** frontend (appflowy
   `NonDeltaInputService` shape, reusing `text_diff.dart`) serves web, flippable per-platform.
   Both feed the same shadow-buffer + resolve-at-apply core through the same choke point, and both
   are **full peers for composing state** (see IME §web fallback) — every composing-gated
   mechanism (underline, G3 latch, hardware-key gate, no-echo comparison) works identically behind
   either frontend.
4. **One serialization point for all mutations**: every edit — IME delta batch, `performAction`,
   hardware key, paste, undo, future a11y action — enters the controller's single-writer queue and
   executes in arrival order: the structural defense for every race in the gauntlet (G4, G7, G10),
   adopted from the command-pipeline runner-up without its request/handler indirection (queue
   entries are plain closures over controller methods). The queue's **output is first-class
   data**: every committed transaction is emitted on a typed change stream (Operations §change
   stream). Cross-cutting consumers (spellcheck range shifting, persistence/sync, a11y
   announcements) subscribe to the stream instead of being hand-wired into the notify path; a
   dispatch bus, if ever genuinely needed, layers on top without rework.
5. **Composition termination is one first-class operation.** Everything that must end a live
   composition — undo, stale-delta guard, divergent structural ops out of a composing batch,
   non-IME edits or selection moves while composing, `connectionClosed` — routes through
   `ImeService.terminateComposition(reason)`, the single assert-exempt path for pushing state
   while the shadow reports composition. It also arms the **one-batch echo quarantine** and, on
   Android, performs a connection-level re-attach for **every reason with a live connection** (IME
   §choke point) — no per-case exemptions, no unverified claims about what IMEs commit before what
   (G4's discipline applied to G10).
6. **Geometry lives only in laid-out components** (GATE-L). Anything needing geometry asks the
   registry and must tolerate `null` (offscreen). Caret, selection highlight, composing underline,
   and squiggles are painted *by the block component itself* — `CustomPaint` painter layers around
   a real `RichText` child (see Rendering; the text is NOT hand-painted, which is what keeps D4's
   reading semantics free) — so unlaid blocks cost nothing and need nothing.
7. **String type keys + registry + startup validation** (D7, GATE-K) — for block types AND inline
   styles AND inline entities. The schema's `validate()` runs in the `BulletEditor` constructor in
   debug mode; exact assertions in the API section (implementable because rules **declare** their
   keys — opaque closures cannot be introspected).

## Module breakdown

```
lib/src/
  model/        block.dart, document.dart          KEPT (de-genericized B → String;
                                                   + lazy idToFlatIndex cache — §caches)
                doc_selection.dart                 NEW  (~140 LOC)
  editor/       edit_operation.dart                SEMANTICS KEPT, addressing REWRITTEN
                                                   id-native: Document? apply(doc, ctx),
                                                   resolve-at-apply (see Operations);
                                                   + PasteBlocks re-spec (~0.5 day),
                                                   offset bounds guards, RemoveBlock
                                                   last-block fallback, op-level
                                                   indent/outdent gates, NEW MoveBlock (~60)
                transaction.dart                   KEPT; selectionAfter re-typed
                                                   (blockId, offset); package-private
                undo_manager.dart                  KEPT + composition-scoped grouping (~20)
                input_rule.dart                    KEPT, ONE contract: post-state
                                                   tryTransform + declared
                                                   referencedInlineKeys; all five structural
                                                   rules + DividerBackspaceRule die into
                                                   BlockDef policies; no rule-level
                                                   interceptors (D13). See IME §input rules
                text_diff.dart                     KEPT (web non-delta fallback)
                editor_controller.dart             REWRITTEN (~900 LOC, plain ChangeNotifier;
                                                   single-writer queue + change stream,
                                                   apply() escape hatch + EditContext,
                                                   void-endpoint normalization, typing-style
                                                   carryover/activeStyles, entity APIs,
                                                   conveniences, onPrefixTap, focus surface,
                                                   setDocument, canUndo/canRedo)
  schema/       editor_schema.dart, block_def.dart, default_schema.dart
                                                   KEPT minus <B,S,E> generics; BlockDef
                                                   gains componentBuilder (optional),
                                                   newBlockMetadata, metadataKeys,
                                                   voidBackspace, semanticsBuilder; behavior
                                                   booleans DELETED → SplitPolicy /
                                                   BackspaceAtStartPolicy (isVoid stays —
                                                   a kind fact); prefixBuilder re-signed to
                                                   (TextBlock, GutterContext, TextStyle);
                                                   + validate() (~+180 LOC delta)
  codec/        markdown_codec.dart etc.           KEPT, de-genericized (days-1–2 pass)
  view/         bullet_editor.dart                 NEW  root widget (~250)
                block_list_view.dart               NEW  lazy sliver + recursion (~250)
                block_layout_registry.dart         NEW  (~80)
                components/default_text_component.dart
                                                   NEW, PUBLIC: real RichText child +
                                                   layered decoration painters + geometry
                                                   mixin over RenderParagraph + link-span
                                                   recognizer lifecycle (~500)
                components/image_block.dart        NEW  (~150)
                components/divider_block.dart      NEW  (~40)
  input/        ime_service.dart                   NEW  (~1,260: window, delta translator,
                                                   stale-delta guard + echo quarantine,
                                                   geometry reporter, terminateComposition
                                                   (+ Android re-attach), connectionClosed,
                                                   diff fallback incl. composing mapping)
                keyboard_service.dart              NEW  hardware keys incl. Alt+↑/↓ move;
                                                   composing gate over ALL handlers (~320)
                mouse_interactor.dart              NEW  mouse-kind pointers, all platforms
                                                   (~480 incl. link hover; parallel-track
                                                   candidate, see plan)
                touch_interactor.dart              NEW  touch/stylus-kind pointers, all
                                                   platforms: handles+magnifier+pointer-route
                                                   drags+grab-offset+content-arena
                                                   recognizers+floating cursor (~1,050;
                                                   IME-independent core is a parallel-track
                                                   candidate, see plan)
  spell/        spell_check_coordinator.dart       NEW  (~300, serial fetch queue +
                                                   per-block dirty set — see Spellcheck)
  menus/        context_menus.dart                 NEW  fallback selection toolbar (never-cut,
                                                   days 11–13) + SystemContextMenu native
                                                   layer (split item set) (~300)
```

Three things super_editor has that we deliberately don't:
- **No style/presentation pipeline** — components read the controller directly and skip rebuilds
  via immutable-identity comparison plus selection-slice equality plus value-compared derived
  gutter state (Rendering §rebuild-skip). Zero LOC of pipeline; the seam stays explicit
  (components consume only the declared build-input tuple — Rendering §view-model seam), so a
  computed view-model layer can be inserted later without touching components.
- **No per-node-type NodePosition hierarchy** — void blocks (image, divider) use `offset ∈ {0, 1}`
  (upstream/downstream) inside the same `DocPosition` type, confined to transient drag endpoints
  by the void-selection normalization (see Gestures).
- **No editor-request/command indirection** — gesture and IME layers call controller methods. The
  single-writer queue gives the command pipeline's serialization guarantee at ~30 LOC instead of a
  request/handler registry; observation is not lost — committed transactions are typed data on the
  change stream (reactions subscribe to *data* instead of intercepting *dispatch*).

## Document & selection model

### Document (kept)

`TextBlock` / `Document` survive verbatim except the type parameter: `TextBlock<B>` becomes
`TextBlock` with `final String blockType` (D7, GATE-K). `BlockType` is replaced by const key
holders, and the same treatment applies to the inline enums (`InlineStyle`, `InlineEntityType`) —
D7 drops **all three** generics:

```dart
abstract final class ParagraphKeys { static const type = 'paragraph'; }
abstract final class TaskItemKeys  { static const type = 'taskItem'; static const checked = 'checked'; }
abstract final class InlineStyleKeys  { static const bold = 'bold'; static const italic = 'italic';
                                        static const code = 'code'; static const strikethrough = 'strikethrough'; }
abstract final class InlineEntityKeys { static const link = 'link'; }
```

`StyledSegment.styles` stays `Set<Object>` in the model (string keys are Objects); the schema maps
become `Map<String, BlockDef>`, `Map<String, InlineStyleDef>`, `Map<String, InlineEntityDef>`, and
the public formatting API takes `String key`. `InlineStyleDef.applyStyle`'s v3 consumer is the
default text component: it builds its `TextSpan`s by folding each segment's style keys through
`schema.inlinePresentationDef(key).applyStyle` (replacing the deleted `span_builder.dart` seam;
`validate()` covers it — see API).

`StyledSegment`, `mergeSegments`, the tree-visitor mutation helpers, `extractRange`,
`buildTreeFromPairs`, and `generateBlockId` are unchanged. One addition: `Document` gains a
`Map<String, int> idToFlatIndex` cache, making `indexOfBlock` O(1) (currently an O(n)
`indexWhere`; the IME hot path and selection normalization hit it per keystroke, and every op's
resolve-at-apply hits it per op). **Both caches are lazy** — `late final List<TextBlock>
_allBlocks` and `late final Map<String, int> idToFlatIndex` — not eager constructor builds (v2
builds `_allBlocks` eagerly). Reason: the kept ops construct multiple intermediate `Document`s per
edit (`SplitBlock` 2, `DeleteRange` over k blocks k+1, `ChangeBlockType` with c children up to
2c+1 via its `OutdentBlock` loop), and under resolve-at-apply an op resolves its ids once, against
the document it receives, before building intermediates — the intermediates **never query the id
map**, so an eager build would pay a wasted O(n) map construction per intermediate at document
scale (D5's spirit). Both are pure functions of immutable `blocks`, so semantics are unchanged; a
2-line change inside the days 1–2 sweep. (Risk note: if profiling ever shows the remaining
one-flatten-per-commit mattering, the fix is an incremental flatten in the tree visitor — not an
architecture change.) The only deletions are the global plain-text members (`plainText`,
`blockAt(globalOffset)`, `globalOffset(...)`, `segmentAt(globalOffset)`) — the linear-offset
surface dies with tier 1 (research: it dies in either tier). `segmentAt`/`stylesAt` are
re-expressed internally with `(flatIndex, localOffset)` parameters; the **public** query surface
is id-addressed `DocPosition` (`controller.stylesAt`/`entityAt` — no public API takes a flat
index).

`BlockDef`'s v2 render-era fields all have explicit v3 fates: `baseStyle` styles the default text
component; `spacingBefore`/`spacingAfter` become the component's outer padding (real `EdgeInsets`,
the whole point of tier 3); `prefixBuilder` survives **re-signed** (consistency with the id-native
rule): `Widget? Function(TextBlock block, GutterContext gutter, TextStyle resolvedStyle)`, where
`GutterContext` is exactly the derived gutter state the rebuild-skip predicate already computes —
`(int ordinal, int depth, bool isFirstInDocument, bool isLastInDocument)`. `_BlockSubtree`'s
subtree walk already produces these values as build inputs (the value-compared half of the rebuild
key — Rendering §rebuild-skip), so they are handed to the builder instead of the v2 `(Document
doc, int flatIndex)` pair: custom gutter builders never re-derive ordinals from a doc walk, and
"no public API takes a flat index" holds without exception (the v2 signature was the last one).
The builder's output feeds `_BlockSubtree`'s fixed-width leading gutter slot, as before. The
gutter slot is also a **pointer surface, not just visuals**: v2's prefix-tap surface
(`onPrefixTap`, default = task-checkbox toggle, editor_controller.dart:1956-1965 via
span_builder's gesture wrapping) is explicitly ported — see Gestures §prefix tap — because
interactors own all editor pointers in v3 and the app cannot rebuild it app-side.

`BlockDef`'s v2 **behavior booleans do NOT survive**. Convention, stated once: **behavior
variation is expressed as named policies with enumerated values, never as booleans**; booleans are
reserved for structural *kind* facts. `voidBackspace` — a named two-value policy where a `bool
deleteOnFirstBackspace` would have "worked" — is the pattern's origin; the rest of the def obeys
it. `isVoid` **stays**, because it is a kind discriminator, not a behavior toggle: selection's
`[0,1)` handling, the IME's `~` serialization, and component rendering all branch on what the
block *is*, not on what some interaction should do. `splitInheritsType`, `isHeading`, and
`isListLike` (block_def.dart:19,21-22,45-59) are **deleted**, decomposed into two named policies
plus machinery that already exists:

- **`split: SplitPolicy`** — what Enter does. Three axes: `onEnter: split | insertLineBreak` (code
  blocks insert a literal `\n` at the caret instead of splitting — this absorbs v2's
  `CodeBlockEnterRule`, the last structural rule), `newBlockType: inherit | defaultType` (list
  items inherit their type; headings and paragraphs produce the schema default), and
  `onSplitEmpty: convertToDefault | none` (an empty list item + Enter climbs the outdent-or-convert
  ladder — outdent one level if nested, convert to the default paragraph at root, the standard
  outliner escape; adopted at checkpoint 2/3 over convert-in-place, which stranded paragraphs
  mid-list; others just split). This absorbs `splitInheritsType` and the Enter-related half of
  `isListLike`.
- **`backspaceAtStart: BackspaceAtStartPolicy`** — what backspace at offset 0 does, for TEXT
  blocks (voids keep their separate `voidBackspace` policy): `merge` (default — merge with
  previous, the paragraph behavior), `convertToDefault` (headings — absorbing `isHeading`'s only
  behavior consumer), `outdentOrConvert` (list items — outdent if nested, else convert to default;
  implemented directly by the controller's structural-backspace path — see IME §G1 and §input
  rules).

The other halves of `isListLike` were already covered elsewhere — now stated explicitly: the
**nesting half** (indent/outdent eligibility) is `BlockPolicies` (`canBeChild`/`canHaveChildren`)
through the shared `canIndent` predicate, and the **gutter half** (has a bullet/number) is simply
`prefixBuilder != null`. `EditContext` loses `isListLikeFn` and gains policy lookups —
`splitPolicyOf(type)`, `backspaceAtStartOf(type)` (see Operations). The standard schema declares:
h1–h6 `backspaceAtStart: convertToDefault`; list, numbered, and task items `split: (inherit,
convertToDefault-on-empty)` + `backspaceAtStart: outdentOrConvert`; code blocks `split: (onEnter:
insertLineBreak)`; paragraphs take the defaults (`(split, defaultType, none)` + `merge`). Both
policies have total defaults, so the callout example in the API section gains no fields.

### Selection (new, ~140 LOC)

```dart
class DocPosition {
  final String blockId;
  final int offset;          // text blocks: grapheme-cluster-aligned char offset
                             // void blocks: 0 = upstream, 1 = downstream (selected = [0,1));
                             // void-edge positions exist only transiently as drag-range
                             // endpoints — setSelection normalization forbids a collapsed
                             // caret on a void (see Gestures §void selection)
  final TextAffinity affinity; // downstream default; consumed ONLY by geometry
}                              // (soft-wrap caret placement, Home/End); ignored by the
                               // model and by ops — offsets are sufficient for editing.

class DocSelection {
  final DocPosition base;    // where the gesture started
  final DocPosition extent;  // where it is now (caret end)
  bool get isCollapsed;
  // Ordering is resolved against a Document:
  (DocPosition start, DocPosition end) normalized(Document doc); // via idToFlatIndex + offset
}
```

The controller additionally tracks `ComposingState? composing` = `({String blockId, TextRange
range})` — composing is selection-adjacent state, and every hard IME question (G3, G4, G7, G10,
G15) is "how does this edit interact with the composing region?". **ComposingState has explicit
lifecycle rules**: it is set only by IME-originated input — applied delta batches, or the web diff
frontend's mapped `TextEditingValue.composing` (IME §web fallback); it is remapped block-locally
when a composing batch's structural ops leave the window equal to the shadow (the
merge-via-replacement case — IME §structural ops while composing); it is cleared by exactly one
operation, `ImeService.terminateComposition(reason)` (or by IME-originated input reporting an
empty composing region); and it is **never restored** by undo/redo — a composition cannot be
resurrected because the engine's conversion state is gone (see Undo and IME §G7).

- **GATE-T**: a table cell's paragraph is a `TextBlock` with children-position in the tree; it has
  an id, it appears in `allBlocks`, ordering and addressing work with zero new code. When tables
  land, `tableCell` is a registered type whose component recursively renders its children through
  the same `BlockComponentBuilder` map — exactly the appflowy mechanism (research §appflowy
  tables), the only verified working design.
- **G6**: triple-tap sets `base = (id, 0)`, `extent = (id, block.length)`, and the interactor
  records `expandBase = ((id,0), (id,len))` — the "original chunk". Shift-click sets `extent` to
  the hit and `base` to the end of `expandBase` *farthest* from the click, preserving
  paragraph-granularity anchoring (standard editor behavior; plain extent-replacement would shrink
  the anchor to a point). Cross-block extension is just a different `extent.blockId`. (These flows
  exist wherever a mouse-kind pointer exists — iPad trackpads, Android mice — per the per-kind
  dispatch in Gestures.) **`expandBase` has an invalidation lifecycle, mirroring the G3 latch's
  discipline** — it is latched interactor state, and queued IME deltas, an undo, or a structural
  op can shrink or delete the anchor block before the shift-click. Two rules: (1) the interactor
  clears `expandBase` whenever the anchor block's instance changes (the `identical(old, new)`
  comparison the rebuild-skip already performs) or the selection changes from a non-interactor
  source — the anchor degrades to plain extension; (2) defense in depth, useful to every selection
  producer including future a11y actions: `controller.setSelection` **clamps text-block offsets to
  `[0, block.length]`** and **rejects selections naming a gone id** (mirroring the op missing-id
  policy — a missing id cannot be clamped). Day-10 test: triple-tap, autocorrect shortens the
  block via a queued delta, shift-click → no out-of-bounds selection, anchor degrades to plain
  extension.
- **G13 (group indent)**: Tab with a selection spanning three siblings: controller takes
  `normalized(doc)`, collects the *top-level-within-selection* blocks (skip blocks whose ancestor
  is already in the set), and applies `IndentBlock` to each **through the batch loop below** (each
  op resolves its id at apply time, so earlier indents restructuring the tree can never stale
  later resolutions). **Group precondition (all-or-nothing), with the gate's target resolution
  defined:** each member's **resolved parent** is its *nearest preceding sibling NOT in the group*
  — for a contiguous run, the run's single shared target (tracing `IndentBlock.apply` under the
  loop: after member A indents under shared target Z, member B's previous sibling *is* Z, and
  `IndentBlock` appends B under Z). The gate must check the *resolved target*, not a fellow group
  member — checking `canHaveChildren` on the preceding group member (a node that is never the
  actual parent) would falsely no-op legal groups, e.g. two paragraphs selected after a list item,
  where `paragraph.canHaveChildren == false` but the real shared target is the list item. The gate
  checks `canBeChild` on the member and `canHaveChildren`/`maxDepth` against the resolved target,
  through **one shared predicate `canIndent(member, resolvedTarget, newDepth)` used by BOTH the
  controller gate and `IndentBlock.apply`** — gate-pass ⇒ op-applies *by construction*, so gate
  and op can never diverge into the partial-application trap this gate exists to kill. If any
  member fails, the whole group no-ops (Notion/standard outliner behavior). Without the gate, the
  sequential loop has a trap resolve-at-apply does *not* cover: if the first selected sibling has
  no previous sibling, its `IndentBlock` no-ops, and the re-resolved second sibling then indents
  *under the first* — one Tab silently re-parents the selection into its own first member, and
  Shift-Tab does not round-trip. Index staleness is necessary but not sufficient; group semantics
  are defined here, against the original document. **The outdent gate is symmetric and specified**
  (`OutdentBlock` carries zero policy/depth checks — it silently no-ops at root depth, so an
  ungated mixed-depth selection — nested item + following root item, reachable by an ordinary G5
  drag — would Shift-Tab *partially*): every top-level group member must have a parent (depth >
  0), else the whole group no-ops. Selection is id-based so it survives the reindex untouched. Day
  3–4 invariant tests: Tab then Shift-Tab on a 3-sibling selection whose first block is at sibling
  index 0 (some with children) is an identity on the tree shape; **two paragraphs selected after a
  list item must indent under it (not no-op)**; **Shift-Tab on a mixed-depth selection must no-op
  the whole group**.
- **G9**: deleting a selected image: caret goes to `(previousTextBlock.id, prevBlock.length)` if
  one exists, else `(nextTextBlock.id, 0)`, else the document's single empty paragraph — a real
  mechanism: v2's `RemoveBlock` refuses to remove the last block (a silent no-op), so it is
  relaxed to swap in `Document.empty`'s single empty default-type paragraph when asked to remove
  the sole remaining block (same effect as a dedicated replace-op, honest vocabulary; the schema
  invariant "document never empty" holds). The IME sees a re-serialized buffer for the new caret
  block.

### Operations and undo — id-native ops, resolve-at-apply

`EditOperation` is **rewritten id-native** in days 1–2, absorbing the de-genericization sweep into
the same pass (the `Document<B> apply<B>` signatures, `as B` casts, and `_recastBlock<B>` die with
the flat indices): every op addresses its block by `blockId: String`, and the signature becomes
`Document? apply(Document doc, EditContext ctx)`. The behavioral semantics — split-metadata
threading, merge rules, indent mechanics — survive with their tests; the addressing and
configuration plumbing do not.

**Ops are pure caller data** — ids, offsets, text, keys, blocks. Schema-dependent behavior is
never stored in an op: `apply` receives an **`EditContext`** the controller supplies
(`defaultBlockType`, the policy lookups `splitPolicyOf(type)` / `backspaceAtStartOf(type)`, the
`newBlockMetadata` policies, the `BlockPolicies` map, the shared `canIndent` predicate, `isVoid`).
This replaces v2's constructor-threading of `isListLikeFn` into the ops and is strictly cleaner: a
half-configured op is unrepresentable because ops carry no configuration at all.

**Resolve-at-apply is intrinsic (G13, G4 multi-delta, G12).** Each op resolves its own id against
the document it receives — `doc.idToFlatIndex[blockId]`, O(1) — at apply time, never earlier. Ops
that care about document order resolve it internally: `MergeBlocks` finds its merge-into-previous
target, `DeleteRange` orders its endpoints, `PasteBlocks` chains sibling insertion by the previous
inserted block's id. There is no controller-side resolve discipline left to violate — a
`SplitBlock` or `IndentBlock` mid-batch reshapes the tree, and the next op's resolution sees the
post-split document *by construction*. The controller's batch loop:

```dart
var doc = document;
for (final op in ops) {                  // ops are id-addressed, pure caller data
  final next = op.apply(doc, ctx);       // op resolves its own ids NOW (idToFlatIndex, O(1))
  if (next == null) {                    // gone id / failed gate ⇒ rejection
    return EditResult.rejected(op);      //   abort the WHOLE batch pre-commit
  }
  doc = next;                            // next op resolves against this doc
}
commit(Transaction(ops), doc);           // one atomic notify + one undo entry + one
                                         //   change-stream emission
```

This costs nothing (v2's `UndoManager` snapshots documents, never replays ops, so resolved
positions are never reused). The same loop serves IME delta batches (each delta's ops apply
against the document produced by the previous delta), multi-block Tab, and the public
`apply(List<EditOperation>)` escape hatch.

**Missing-id semantics (specified — id-addressing kills index staleness, not id staleness).** A
queued op can target a block an earlier queued edit deleted — exactly the staleness race the queue
serializes, reachable through the public `apply` escape hatch, the id-taking conveniences, and
queued hardware-key edits. In v2 the ops index `doc.allBlocks` unchecked
(`InsertText`/`DeleteText`/`ToggleStyle`/`SplitBlock`; `DeleteRange` checks only the upper bound)
— a `RangeError` mid-transaction in the single-writer queue. In v3 the miss is intrinsic to
resolution: `idToFlatIndex` has no entry for a gone id, `apply` returns **null**, and the loop
**aborts the whole batch pre-commit** (the loop builds `doc` locally and commits once, so
atomicity is natural — no partial document, consistent with the G13 all-or-nothing precedent),
reporting rejection. Gone-id is the *loud* residue of staleness — never a silent wrong block.
Offset bounds guards ride the same days 1–2 rewrite as defense in depth: a stale offset rejects
identically rather than throwing.

**Gate-failure semantics live at op level (the public surface obeys G13).** The G13 all-or-nothing
group gate lives on `controller.indent()/outdent()`, and the same gate is evaluated *inside the
ops*: `IndentBlock.apply` checks `ctx.canIndent` (the one shared predicate) and
`OutdentBlock.apply` checks depth > 0 against the document it receives, returning **null on
failure** — the same reject-whole-batch mechanism as a gone id. v2's ops signal gate failure by
silently returning the document unchanged (edit_operation.dart:571-584), so without this a
consumer batch of three `IndentBlock`s whose first member has no previous sibling would reproduce
the silent-re-parent trap through the public `apply()` — with `EditResult` reporting applied.
Op-level rejection makes the trap unreachable. This cannot regress the controller path: after the
group gate passes, each per-step `canIndent` against the evolving document passes by construction.
Day 3–4 unit test: `apply([IndentBlock(firstSibling), IndentBlock(next)])` returns rejected and
leaves the tree unchanged.

**Void-endpoint normalization (range → ops, single choke point).** The kept `DeleteRange`'s
cross-block branch always survives the START block with merged head+tail segments. With a void
start — which the G5 midpoint hit rule makes *routine* (mouse-down on the top half of an image
yields `base = (image, 0)`; same for the IME's type-over-selection replacement delta and the
elided >32-block window's whole-selection replacement) — it would graft the end paragraph's tail
text **into the image block**: an image-typed block with non-empty `plainText`, a corrupted model
the markdown codec cannot round-trip and the image component cannot render. The symmetric
`InsertText`-into-a-void case is likewise reachable. Normalization, in the controller's **range-op
builder** (the single place ranges become ops): before emitting `DeleteRange`, void endpoints are
snapped by `[0,1)` membership — a void whose `[0,1)` lies inside the range is removed whole via
`RemoveBlock` (D3 delete-as-unit); the head/tail merge runs only between **text** endpoints (void
start ⇒ the surviving block is the end block's tail; void end ⇒ vice versa; both void ⇒ no merge).
Text ops addressed to void blocks are forbidden by a debug assert in `apply` (`ctx.isVoid` is
available to every op) — which also covers a directly constructed `DeleteRange` naming void
endpoints; the snap *policy* itself stays in the range-op builder. Together with the relaxed
`RemoveBlock` last-block fallback (G9), select-all + delete on an all-void document yields the
single empty paragraph. Booked on day 14 with tests: type-over of an upward and a downward drag
that starts/ends on an image; select-all + delete on an all-void document.

Two op-vocabulary changes, owned by days 1–2 / day 10:

- **`SplitBlock` gains a `newBlockMetadata` policy.** v2 hardcodes `block.blockType ==
  BlockType.taskItem ? {checked: false} : {}` inside the op (edit_operation.dart:206-208) — an
  enum comparison that cannot survive D7. The policy moves to `BlockDef.newBlockMetadata`
  (`Map<String, dynamic> Function(TextBlock)?`, default `null` ⇒ empty map; taskItem returns
  `{TaskItemKeys.checked: false}`) and reaches `SplitBlock.apply` through `EditContext` — nothing
  is threaded at construction. The new block's *type* reaches the op the same way:
  `ctx.splitPolicyOf(block.blockType).newBlockType` — `inherit` for list items, `defaultType`
  otherwise. The `onSplitEmpty: convertToDefault` half is consulted by the controller's Enter path
  *before* an op is chosen — an empty list item emits `OutdentBlock` while nested (one level per
  Enter, the checkpoint-2/3 ladder, sharing the `backspaceAtStart: outdentOrConvert` mechanics)
  and `ChangeBlockType` to the default at root, instead of a split — so the op stays pure. `newBlockMetadata` is a *new* policy field, not pre-existing v2
  behavior. `validate()` asserts types whose declared `BlockDef.metadataKeys` is non-empty define
  it (GATE-K — the declaration field exists precisely so this is checkable).
- **`MoveBlock` is a NEW op (~60 LOC)** — it does not exist in v2 (the vocabulary is
  Insert/Delete/Toggle/Split/Merge/ChangeType/DeleteRange/Remove/Paste/SetMetadata/Indent/
  Outdent; Indent/Outdent change depth, not sibling order). It moves a block **with its subtree
  intact** one position up/down among its siblings. Launch boundary policy (recorded decision):
  movement is within the current parent only — Alt+↑ on a first sibling / Alt+↓ on a last sibling
  is a no-op; cross-parent hoisting rides the post-launch drag-reorder work. Undo is the usual
  snapshot; selection follows by id for free. This is the D10 launch-gap coverage ("keyboard-based
  move can cover the gap"), scheduled on day 10 with its Alt+↑/↓ bindings.

**Undo** (`undo_manager.dart`, 108 LOC kept + ~20 LOC grouping): snapshots are `(Document,
DocSelection)` pairs — **ComposingState is not part of the restorable snapshot** (debug-only
annotation at most, never restored). Two rules, both ported from v2's working behavior
(editor_controller.dart ~1519):

1. **Composition-scoped grouping:** on the first delta batch that opens a composing region, push
   the pre-composition snapshot once; while composing, suppress per-batch pushes; close the group
   when the composition commits. The existing 300 ms `defaultUndoGrouping` already merges fast
   batches; the composition scope additionally covers slow candidate-browsing pauses, so
   converting 日本語 is one undo entry, not one per kana.
2. **Undo/redo never restore composing state:** `controller.composing` is unconditionally set to
   null on undo/redo, and the IME push goes through `terminateComposition('undo')` (on Android a
   connection re-attach + echo quarantine armed — IME §G7). The engine's conversion state is gone;
   pretending otherwise desynchronizes controller from engine and wedges everything that reads
   composing state (the hardware-key gate, the G3 latch).

Trace test (day 5–8 suite): compose 3 kana, convert, commit, undo once → the entire word is gone,
`controller.composing == null`, hardware Enter splits normally. Block ids are stable across undo,
so selection restore is exact (G7 details in IME).

### The change stream — committed transactions as observable data

The single-writer queue's output is public, typed data. `commit()` — the one place a transaction
becomes the document — additionally emits on `controller.changes`:

```dart
class AppliedChange {
  final Transaction transaction;     // ops as applied; id-addressed, so each op is
                                     //   independently interpretable per block. The remaining
                                     //   sequencing concern is intra-block OFFSET staleness:
                                     //   an op's offsets are valid against the document
                                     //   produced by the preceding ops in the same
                                     //   transaction (inherent to any op log)
  final Document docBefore, docAfter;
  final DocSelection? selectionBefore, selectionAfter;
  final ChangeSource source;         // ime | keyboard | gesture | paste | undo | redo | api
}
// controller.changes — broadcast stream; emissions are synchronous with commit, in queue
// order: observers see exactly the serialization the queue guarantees.
```

Rules:

- **Emission order is commit order.** Emission happens after document and selection are updated,
  inside the same commit — an observer reading `controller.document` during an emission sees
  `docAfter`, never a half-applied state.
- **Observers never mutate synchronously.** An observer that wants to edit enqueues like any other
  caller; the queue serializes the re-entrancy by construction.
- **Undo/redo emit like any other commit** (`source: undo/redo`) — observers that mirror the
  document (persistence, sync) need no special-casing.

This is the deliberate replacement for super_editor's reaction layer: reactions subscribe to
*data* (what changed) instead of intercepting *dispatch* (what was requested). Launch-scope
consumers: the spell-check coordinator's G8 range shifting, app-side persistence/autosave (D6's
only consumer needs "did the note change?" with debounce; `addListener` alone cannot distinguish
selection-only notifications from edits — filtering the stream can), and the day-18 a11y pass
(change announcements). Future consumers without rework: collab/sync adapters, op-driven
reactions, and — if ever needed — a request/dispatch bus layered on top. ~30 LOC inside the day
3–4 controller skeleton.

### PasteBlocks — re-specced (real booked work, ~0.5 day on the parallel-track clipboard item)

The v2 op as written cannot deliver the promised G12 semantics; three defects, verified against
edit_operation.dart:492-518 (citations describe the v2 code the rewrite replaces):

1. **Insertion is root-only or wrong.** The primary path inserts middle+tail blocks as ROOT
   siblings (`result.blocks.indexWhere` + `newRoots.insert`) — correct only for depth-0 targets. A
   nested list item (the G12 scenario verbatim, the norm in an outliner) takes the fallback path,
   whose `insertAfter++` flat-index arithmetic breaks whenever the head block has children
   (:471-473): flat index `blockIndex+1` is then the head's FIRST CHILD in depth-first order, so
   the second middle block lands *inside the target's own subtree*. Fix: **id-chained sibling
   insertion** — each block is placed after the *previous inserted block's id*, resolved against
   the evolving document inside `apply`. Under id-native addressing this is the only natural way
   to write the op: the flat-index arithmetic cannot be expressed at all (~15 LOC).
2. **The first/last edge merges are void-blind.** The tail merge (:478-481) unconditionally grafts
   tail text into the last pasted block's type — a markdown paste ending in an image yields an
   image-typed block with grafted text segments, exactly the corrupted unroundtrippable state the
   void-endpoint normalization declares fatal; symmetrically, the head merge (:468-474) silently
   drops a leading image's metadata (`src` is never copied). Fix: **extend the void-edge no-merge
   rule to both paste edges** — a void first/last pasted block is never merged; it is inserted
   whole, metadata preserved.
3. **The tail-id result field disappears.** v2 needed `PasteBlocks` to report a generated tail id
   only because ops spoke flat indices; with id-native ops the pasted blocks' ids are caller data,
   and the last pasted block keeps its id through the tail merge — the controller places the
   post-paste caret at the end of the last pasted block by an id it already holds (G12), no result
   plumbing.

**`PasteBlocks` stays a composite op (recorded decision — not composed from `SplitBlock` +
`InsertBlocks` + `MergeBlocks`):** three reasons, each individually sufficient. (1) *The
primitives compose to the wrong tree*: `MergeBlocks` **promotes** the merging block's children to
siblings (correct for backspace-merge, test-asserted), while paste's head edge **adopts** the
first pasted block's children under the merged head (correct for pasting nested content into a
paragraph — nesting survives); composing paste from `MergeBlocks` would need a mode flag on a
shared primitive, injecting paste policy into an op every other path uses. (2) *Edge decisions are
apply-time-dependent*: "is the target empty" and the void-edge checks must be evaluated against
the document the op actually receives, not at builder time — they are op behavior consulted via
`EditContext` (the sanctioned channel; the purity rule bans *stored constructor configuration*,
which `PasteBlocks` carries none of). (3) *There is no segment-splicing primitive*: styled
single-block paste has no primitive expression without inventing one, a larger vocabulary change
than the composite. The chain-insert mechanics are shared code with `InsertBlocks` (one private
helper), so the duplication risk the v2 defects grew from is gone.

Gauntlet tests (with the clipboard pipeline's unit tests): paste 3+ blocks into a **nested list
item that has children**; paste markdown whose **first/last block is an image** into mid-paragraph
— both must produce siblings at the item's depth with no void-block text grafting. Reachability is
launch-scope: the day-16 native-copy requirement (image-spanning copy → full-fidelity markdown →
paste produces blocks) plus D3 images makes the tail corruption directly reachable.

## Rendering & layout (incl. lazy strategy)

### Widget tree

```
BulletEditor
└─ Focus + Shortcuts/Actions (hardware keys)
   └─ Listener + RawGestureDetector  (interactor dispatch by PointerDeviceKind — owns
      │                               pointers that go down on editor content; the
      │                               RawGestureDetector hosts the interactor-owned
      │                               recognizers that compete in the gesture arena (see
      │                               Gestures §content arena); overlay-originated pointers
      │                               are routed by registration and hit-test-absorbed at
      │                               the handle, see G11)
      └─ CustomScrollView
         └─ SliverList.builder over doc.blocks  (TOP-LEVEL blocks only — lazy, D5;
            │                                    keys = ValueKey(block.id) with
            │                                    findChildIndexCallback for stable
            │                                    reconciliation under reorder)
            └─ _BlockSubtree(block)             (renders gutter slot (prefixBuilder) +
                                                 block + its children Column, recursing
                                                 through componentBuilder registry)
```

Laziness is **top-level only**: a root block and its descendants are one builder item. This is the
boring choice — outliner documents are wide at the root, and it makes child indent layout trivial
(a `Padding` per depth). If a single subtree is ever pathological, that's a post-launch sliver
refactor, not an architecture change, because nothing outside `block_list_view.dart` knows the
nesting strategy.

### Geometry contract (GATE-L)

Every component State registers itself in `BlockLayoutRegistry` on mount, deregisters on dispose:

```dart
abstract interface class BlockGeometry {
  Rect? rectForOffset(int offset);            // caret rect, block-local
  List<Rect> rectsForRange(int start, int end);
  int offsetForLocalPoint(Offset p);
  TextRange wordBoundaryAt(int offset);
  RenderBox get renderBox;                    // for local↔global transforms
}
// Registry: BlockGeometry? geometryOf(String blockId)  — null ⇒ not laid out.
```

The contract for *every* consumer (IME caret rects, handles, context-menu anchors, autoscroll):
**`null` means "not laid out"; you may estimate or scroll, never force layout.** No public API
assumes total geometry (D5). Text components implement this by querying the child
`RenderParagraph` — the contract maps 1:1 onto `getOffsetForCaret`, `getBoxesForSelection`,
`getPositionForOffset`, `getWordBoundary`.

**The default text component renders an actual `RichText`/`Text.rich` child** — appflowy's
*literal* structure (research §appflowy: `AppFlowyRichText` is a plain `RichText` whose State
mixes in `SelectableMixin`, selection painted by a separate per-block `CustomPainter`,
`BlockSelectionArea`). Owning the text via `CustomPaint` + `TextPainter` is deliberately rejected:
a `CustomPaint` contributes **zero text semantics** — no attributed label, no locale/direction, no
per-link tappable semantics child nodes (`RenderParagraph.assembleSemanticsNode` builds those from
span recognizers — days of code to reproduce by hand) — forfeiting exactly the "blocks render as
`RichText` → static text semantics nearly free" premise D4's launch bar rests on, with links (D3
launch content) inaudible and un-activatable under VoiceOver. So: the `RichText` child carries
text layout and semantics; selection highlight, squiggles, composing underline, and caret are
`CustomPaint` painters layered behind/in front of it; `BlockGeometry` queries the child
`RenderParagraph`; there is no owned `TextPainter`. This keeps attributed-text and link semantics
free and shrinks the day-18 a11y pass to wiring wrappers. **Decided here, for days 1–2** (the
public component and geometry mixin are built then); retrofitting after the mixin ships is the
expensive path.

**Link spans carry real `TapGestureRecognizer`s — the recognizer IS the link activation surface
(D3, D4).** The per-link semantics claim is only true if the spans have recognizers:
`assembleSemanticsNode` splits the paragraph into per-link rect-positioned child nodes ONLY where
`InlineSpan.recognizer != null`, and the tap action requires a non-null handler — recognizer-less
link spans (the v2 habit, span_builder.dart:22-23) yield one flat text node with links inaudible
and un-activatable under VoiceOver. So the default text component attaches a
`TapGestureRecognizer` to every link span, and that recognizer — not interactor-side
disambiguation — is THE activation path on every platform:

- The handler routes to the same `onLinkTap` callback through the controller's single-writer
  queue, gated by pointer kind and modifiers (`HardwareKeyboard.instance`): on desktop-class
  input, activation requires Cmd/Ctrl-click (or plain click in read-only); on touch, a tap inside
  a link places the caret normally AND surfaces the link — the two compose because the viewport's
  raw `Listener` is arena-exempt (the G11 invariant), so caret-on-tap and recognizer-`onTap` never
  double-fire. The span recognizer's only arena competitor is the scrollable's drag — standard
  tap/drag resolution.
- The handler is gated so a long-press word-select releasing over a link does not fire `onTap`.
- **Recognizer lifecycle is owned by the component State**: cached across per-keystroke rebuilds,
  disposed on unmount (the standard `TextSpan.recognizer` obligation).
- **Screen-reader activation is free**: VoiceOver/TalkBack semantics tap actions invoke the
  recognizer's handler directly with no pointer — this is what makes D4's "links read AND
  activate" true with zero extra a11y code, and why cut-line item 7 keeps the recognizers attached
  (semantics needs only a non-null handler) with the app-level callback no-oped.

Days 1–2 test: the semantics tree for a paragraph containing a link has a child node carrying
`SemanticsAction.tap`. (Mouse hover — `SystemMouseCursors.click` over link segments — stays
interactor-side via `offsetForLocalPoint` + `segmentAt`; hover is not a recognizer concern.) No
interactor-side touch tap-disambiguation is booked — it would double-book the surface the span
recognizers own.

**Void-block hit-testing is direction-symmetric (G5):** a void component's `offsetForLocalPoint`
is **midpoint-based** — `0` (upstream) in the top half of the box, `1` (downstream) in the bottom
half: the vertical adaptation of super_editor's `UpstreamDownstreamNodePosition` resolution. A
fixed "always-downstream" rule is rejected because it is wrong for upward drags: with the base
below the image, a downstream extent `(image, 1)` normalizes to *exclude* `[0,1)`, so the image
the user is visibly sweeping over would be untinted during the drag and excluded from the final
selection. Midpoint resolution makes selection-set membership (`[0,1)` inside range ⇒ tint)
symmetric for both drag directions with no other changes. Void-edge positions are *drag-time
only*: clicks/taps on voids and final selections normalize to the `[0,1)` atomic selection
(Gestures §void selection).

### Per-block painting

Each text component paints, via painters layered around its `RichText` child, in order: selection
highlight slice → spell-check squiggles → *(the `RichText` child's text)* → **composing-region
underline** → caret (if `selection.extent.blockId == widget.block.id`). Inputs come from the
controller at build time.

**Rebuild-skip and derived gutter state (one predicate, stated precisely):** a block rebuilds only
when its block instance (`identical`), its selection slice (which includes the composing slice),
its squiggle set, **or its value-compared derived gutter inputs — numbered-list ordinal, depth,
first/last-in-document flags — changed.** The last clause is load-bearing: v2's tree-mutation
visitor returns untouched siblings *by reference*, so inserting, deleting, or
`MoveBlock`-reordering a block above a numbered sibling leaves that sibling `identical` with an
unchanged selection slice — identity-skip alone would freeze its stale ordinal in the gutter (and
break `spacingBefore`'s "not first in document" condition). `_BlockSubtree` computes the ordinal
and flags during the subtree walk already needed for numbering and passes them as build inputs, so
the comparison is O(1) — and the same values are **handed to `prefixBuilder` as its
`GutterContext` argument** (Document §BlockDef). Day-10 test: insert a block above a numbered list
→ ordinals renumber.

**The view-model seam (stated explicitly):** the rebuild-skip predicate's inputs — block instance,
selection slice (incl. composing), squiggle set, derived gutter state — plus the block's
`BlockDef` are the *entire* build input of a component: read from the controller once at build,
never queried ad hoc from inside layout or paint. That tuple is the de facto view-model. If style
composition ever outgrows direct reads (many block types, third-party theming), a computed
view-model/styler layer can be inserted that *produces this same tuple*, leaving every shipped
component untouched. The seam costs zero LOC now and is what makes the no-pipeline decision
reversible rather than load-bearing.

- **Composing underline (G3 visibility):** in Flutter the *framework* draws the composing
  underline, not the keyboard (`EditableText` styles `value.composing` itself; appflowy and
  super_editor both paint it) — since we own the decoration layers, we must too, or CJK marked
  text looks committed and a deferred input rule is indistinguishable from a swallowed one. The
  component whose id matches `ComposingState.blockId` paints a solid underline under the range;
  keyed off the same selection-slice equality, so only the composing block repaints.
- **G5** (drag across image into unlaid region): selection is model-level, so blocks laid in
  during autoscroll paint their (full-block) highlight slice on first layout — painting
  correctness never depends on having been laid out at mutation time. The image block paints a
  full-tint overlay when `[0,1)` is inside the range (super_editor's `SelectableBox` approach).
  Drag-time extent mechanics are in Gestures (post-frame re-hit-test).
- Scroll-to-position (jump to caret after undo/paste): `ensureVisible(blockId)` walks the sliver
  using a per-type estimated extent table refined by an id→measured-height cache; iterative
  scroll-and-correct loop (~60 LOC, boring).
## IME & text input

One `ImeService` owning one `TextInputConnection` with `DeltaTextInputClient` enabled
(`enableDeltaModel: true`), attached whenever the editor has focus — **including when the
selection is on a void block** (buffer = sentinel + placeholder `~`), so an active connection
exists for `SystemContextMenu` (GATE-M, D12, G14) and so delete-forward/backspace on a selected
image arrive as ordinary deltas (G9). A collapsed caret *on* a void never exists — void selection
is always the `[0,1)` atomic range — so the void buffer case is exactly one case, and typing while
a void is selected is the ordinary type-over-selection replacement path (the void is replaced per
the void-endpoint normalization in Operations).

### Buffer serialization (the appflowy window, research-verified leanest)

- Collapsed caret in a text block: buffer = `". " + block.plainText`, selection shifted +2. **The
  sentinel is super_editor's exact `". "` constant** — adopted with its verified rationale: it is
  visible-class text the IME's word segmentation treats as a completed sentence, so
  autocapitalization correctly sees a sentence start and autocorrect/word heuristics never bind
  across it. An invisible sentinel (zero-width space) is deliberately rejected: invisible
  characters in IME buffers are an unvalidated per-IME breakage class on Android, so we take the
  constant the reference editors converged on (appflowy uses a bare space; `". "` additionally
  fixes autocapitalization). One constant, `ImeWindow.sentinel`, one place.
- Range selection: buffer = sentinel + selected blocks' plain text joined with `\n`, void blocks
  as `~` (super_editor's encoding). This makes "type over a cross-block selection" a single
  replacement delta. **Window cap:** selections spanning more than 32 blocks or ~2,000 chars
  (select-all on a large doc) serialize as sentinel + first block + `\n~\n` + last block; any
  delta touching the elided interior is classified as a whole-selection replacement and mapped to
  the model selection directly. Payloads stay bounded; the quill-style whole-document failure mode
  stays structurally impossible. **Why the elided form keeps the first/last block text instead of
  collapsing to the bare void `~` form:** type-over context. The dominant edit against a capped
  selection is select-all → type, and the engine's autocapitalization/suggestion context at the
  selection start is the first block's pre-selection text; under a bare `~` the preceding context
  is the `". "` sentinel — a sentence end — so every type-over would be spuriously capitalized.
  The edge text also serves engine-side selection-edge adjustments and gives Look Up/share a real
  slice. Verification that this rationale holds on-device is a day-9 gate row (select-all →
  type-over, no spurious capital).
- All incoming delta offsets are shifted −2 and then mapped block-locally (binary search over the
  `\n` joints for the multi-block case, ~40 LOC).

**G1 (backspace at offset 0 of the first block):** the IME cannot report it; with the sentinel it
arrives as a deletion intersecting buffer range `[0,2)`. Mapped: "structural backspace at block
start" → the controller's structural-backspace path **implements the block type's declared
`backspaceAtStart` policy directly** (policies are the only structural mechanism — §input rules):
`outdentOrConvert` (list items), `convertToDefault` (headings), `merge` (the default; first
paragraph of doc → no-op, nothing to merge into). Then re-serialize and push. For a **plain
backspace** the composition is inactive when the sentinel is hit (Korean backspace decomposes jamo
*within* the composing syllable, so the composition ends before the sentinel is reachable) and the
push is a plain `setEditingState`. But that is a per-IME ordering fact about plain backspace only
— NOT promoted to an impossibility claim for the composite deletions below, which would be exactly
the class of unverified per-IME ordering assumption G4/G10 forswear. **Guard, making G1/G2 obey
the divergence rule:** if the post-apply shadow reports a **non-empty composing region**
(reachable by documented API shape — Android's `InputConnection.deleteSurroundingText` deletes
around the composing region while preserving it, so a swipe-delete/delete-to-line-start can
intersect `[0,2)` with the block-start composing word preserved), the final re-serialize routes
through `terminateComposition('structuralDelta')` — Android re-attach + echo quarantine armed —
instead of the plain push, which would otherwise fire the no-echo debug assert (or in release, a
bare push mid-composition with the quarantine disarmed — the desync class the choke point exists
to stop). Behavior is unchanged when composing is empty. Same path for *every* block start, not
just the first — one mechanism. **Composite deletions spanning the sentinel AND real text are
decomposed, never handled wholesale:** a deletion of `[0, 2+k)` (OEM delete-word /
delete-to-line-start, or a swipe-delete issuing one buffer-spanning deletion) intersects `[0,2)`
but also deletes `k` chars of real block text; handled wholesale, the structural backspace would
run and the text half would be silently dropped — and resurrected by the post-merge re-serialize,
corruption-shaped rather than the guard's benign drop (the delta's `oldText` matches the shadow,
so the guard *applies* it). Decomposition: (1) text deletion of buffer `[2, end)` through the
normal op batch path, then (2) the structural-backspace consultation — both inside one
`Transaction`, followed by one re-serialize (routed through
`terminateComposition('structuralDelta')` when the post-apply shadow reports non-empty composing,
per the guard). Shadow-buffer unit tests (day 5–7 suite): delete `[0,7)` over `". hello"` at block
2 of 2 → previous block merged *and* "hello" removed; and the **composite-while-composing
fixture** — a `deleteSurroundingText`-shaped delta deleting `[0,2)` with the block-start composing
word preserved/remapped → merge applied, push via `terminateComposition`, quarantine armed, no
assert.

**G2 (backspace at start of paragraph after a void block):** structural backspace finds the
previous block in `allBlocks` is void (`schema.isVoid`) → behavior is the previous type's
`BlockDef.voidBackspace` policy: `selectFirst` (image — selection becomes the void's `[0,1)`
range, Notion behavior; second backspace deletes via `RemoveBlock` + G9 caret placement) or
`immediateDelete` (divider — v2 behavior, deleted on first backspace). No text merge with a
non-text target is ever attempted. **Ownership decision (recorded):** void-backspace lives *only*
here, in the controller's structural-backspace path. v2's `DividerBackspaceRule`
(input_rule.dart:507-513, which deletes any void on FIRST backspace) is **deleted** — kept, it
would either fight the G2 select-first behavior or sit as dead code silently changing divider
semantics; two mechanisms must not claim the same trigger.

### Delta application — queue, shadow buffer, stale-delta guard

All IME callbacks (`updateEditingValueWithDeltas`, `performAction`) enqueue onto the controller's
single-writer queue and execute in arrival order, interleaved with hardware-key and gesture edits
in true wall-clock order. `ImeService` holds a **shadow buffer**: its own copy of the last
`TextEditingValue` it pushed or acknowledged — **text AND selection AND composing region**; the
no-echo comparison below covers all three.

`updateEditingValueWithDeltas(List<TextEditingDelta> deltas)`: apply **sequentially in platform
order** against the shadow; each delta becomes id-addressed ops (`InsertText` / `DeleteText` /
replacement = delete+insert) applied through the batch loop in one `Transaction`. A delta
inserting `\n` becomes `SplitBlock` at the mapped position.

- **Stale-delta guard (universal race backstop):** before applying, each delta's `oldText` is
  validated against the shadow buffer. On mismatch — the engine raced us (late autocorrect delta
  after a split, stale composing delta after a forced reset, OEM keyboard weirdness) — the
  remainder of the batch is **dropped** and the authoritative window re-pushed (through
  `terminateComposition('staleDelta')` if the shadow reported composition, else the plain push
  path). Worst case is a lost autocorrect correction (the user's typed text stands), never
  corruption — the standard tier-3 defense and appflowy's shipped behavior. The guard covers
  **pre-push in-flight** deltas only; the post-push echo case is covered by the quarantine below —
  complementary, and neither alone is sufficient.

- **`terminateComposition(reason)` — the composition choke point.** Clears `controller.composing`,
  clears the G3 rule latch, re-serializes the current window, **arms the one-batch echo
  quarantine**, and performs **one** state push with `composing: TextRange.empty`. On Android, for
  **every reason with a live connection**, the push is a **connection-level restart — detach +
  re-attach** (appflowy's precedent: it re-attaches on every selection change) rather than a bare
  `setEditingState`; `'connectionClosed'` naturally skips (there is no connection). Rationale,
  stated precisely and **reason-agnostic** — which is why no reason is exempt: the Android
  embedding *does* call `restartInput` when the framework clears a composing region — but only if
  the embedding's last-known framework editing state *had* a composing region, and under our
  no-echo invariant the framework never pushes mid-composition, so that state never has one: **the
  no-echo invariant starves the embedding of the signal its own built-in defense keys on**, and a
  bare push with empty composing does NOT trigger `restartInput` on OEM keyboards. A re-attach
  sets the embedding's restart-pending flag, guaranteeing `restartInput` on the next push — the
  only mechanism that reliably makes an IME abandon internal composition state. Exempting
  `'externalEdit'` or `'staleDelta'` from the re-attach is deliberately rejected: it would leave
  the most common composition-interrupting gesture on mobile — tap-to-caret mid-Hangul — with a
  bare push: Samsung/Gboard Korean keeps the held jamo and the next keypress composes against
  stale internal state at the new caret, or commits the held syllable in a second batch after the
  one-batch quarantine has disarmed; the compensating mechanisms are blind to it by this design's
  own analysis (the stale-delta guard is oldText-blind on Android, and the quarantine matches only
  the exact terminated text at the *pre-tap* caret). Flicker justification, stated because the
  re-attach runs on every termination: a same-frame detach + re-attach does not flap the keyboard
  — `TextInput` schedules the hide at frame end and cancels it when a new attach arrives in the
  same frame. `terminateComposition` is the ONLY path allowed to push while the shadow reports an
  active composition (the debug no-echo assert exempts exactly this method, nothing else). Routed
  through it (all with the Android re-attach when a connection is live):
  - undo/redo (`'undo'`),
  - the stale-delta guard's re-push when composing (`'staleDelta'` — the re-attach also closes the
    sibling failure of a repeated drop/re-push cycle: without `restartInput`, an OEM keyboard
    whose internal text diverged keeps producing mismatching deltas),
  - a structural op (`Split`/`Merge`/`Remove`) produced by a composing delta batch **whose
    post-apply window diverges from the shadow** (`'structuralDelta'`; see §structural ops while
    composing — the convergent merge-via-replacement case does NOT terminate),
  - any non-IME edit or **any non-IME selection change** while composing — tap-to-caret in any
    block *including the composing block itself*, toolbar style toggle, programmatic
    `setSelection` (`'externalEdit'`),
  - `connectionClosed` (`'connectionClosed'`, push and re-attach skipped).

  Day-9 gate trace (Korean matrix): **tap to another block mid-Hangul, then type** — the new block
  must receive a fresh syllable, not one built on the held jamo. Composition termination is policy
  — one first-class operation, not a scattering of special cases.

- **Post-terminate echo quarantine (the G7/G10 hardening).** A delta emitted against the pre-reset
  composing buffer CAN exactly match the freshly pushed shadow — guaranteed **by construction** on
  Android: the embedding's `ListenableEditingState` builds every delta's `oldText` from the
  editable's *current* text, and `setTextInputEditingState` applies our push to the editable
  *before* the IME acts — so an OEM IME holding internal composition (Samsung/Gboard Korean) that
  commits its held syllable after our push produces an insertion delta whose `oldText` exactly
  equals the freshly pushed shadow. The stale-delta guard is structurally blind to it: undone text
  is resurrected (compose 안녕 composing '녕', undo, the keyboard commits '녕' against the restored
  window — exact shadow match), and after a G10 mid-composition split the just-committed syllable
  is re-inserted at the head of the new block — the classic Samsung-Korean duplication pathology.
  Defense, at the choke point: `terminateComposition` records the terminated composing text and
  its caret position as a **one-batch quarantine**; in the *first* delta batch after the push, an
  insertion delta that exactly re-inserts that text at that position is dropped and the window
  re-pushed (worst case identical to the guard's accepted lost-delta + re-push; a user genuinely
  retyping the syllable types it in a *later* batch, which the quarantine no longer covers — one
  batch, then disarmed). The quarantine is kept **even with** the Android re-attach:
  `restartInput` is advisory to OEM IMEs (some ignore even restarts), so the quarantine is the
  IME-agnostic backstop and the re-attach is the make-it-not-happen path. Trace (day-9 gate AND
  day-15 matrix): undo mid-Hangul, IME immediately re-commits the held syllable → quarantine drops
  it, document equals the undo snapshot.

- **Structural ops while composing — terminate only on window divergence (G10 refined).** A
  blanket "any structural op in a composing batch → terminate" rule is rejected as over-broad (a
  same-block composing replacement already survives without termination), and one case breaks it
  outright: select a range spanning two blocks and start typing CJK — the IME sends ONE
  replacement delta (selection → first marked kana, composing non-empty) whose deletion crosses
  the `\n` joint and maps to `Merge`/`DeleteRange`; blanket termination pushes with empty
  composing on the very first keystroke, which (the research's #1641 fact: pushing mid-composition
  restarts composition) commits the marked 'k'/'ㄱ' as literal text — `kい` instead of き,
  deterministic wrong text. The termination is *unnecessary* exactly there: applying the
  replacement consumes the `\n`, so the post-apply re-serialized window of the merged block
  ALREADY equals the shadow (true even under the 32-block cap — the elided interior lies inside
  the replaced range), and where nothing is pushed, the composition survives intact. Rule: after
  applying a composing batch containing structural ops, **re-serialize the window and compare to
  the post-apply shadow** (machinery the no-echo invariant already has). Equal — the
  merge-via-replacement case: keep `ComposingState` (remapped block-locally into the merged block)
  and send nothing. **Equal text with a shadow selection that diverges from the applied model
  selection but lies WITHIN the composing region — adopt, don't terminate** (the adoption
  exception; WebKit provenance: Safari transiently reports the marked text as *selected* — the
  first composing snapshot of a romaji keystroke carries `selection == composing`, a non-collapsed
  range the applied insertion's collapsed caret can never match): the engine's selection is
  honored verbatim into the model, mapped block-locally with its range shape preserved (composing
  is selection-adjacent state with no collapsed-while-composing invariant), and the composition is
  kept — terminating there is the #1641 corruption by our own hand. The exception lives in the
  shared batch-end reconciliation, so both frontends honor it; a selection *outside* the composing
  region stays the divergence this rule does not cover. Divergent — the G10 split, where the
  window moves to the new block: route
  through `terminateComposition('structuralDelta')`. Trace test (day 5–7 suite): select across two
  blocks, type "ki" via composing replacement deltas → merged block ends with き composing, one
  undo entry.

- **G4 (autocorrect replace + Enter race):** *we assume nothing about channel ordering* —
  "performAction(newline) always arrives after the flushed replacement delta" is plausible but
  unverified, so the design does not rest on it. Three cases, all handled mechanically: (1) both
  arrive in one delta batch → sequential application against the shadow gets the replacement
  first, then the `\n` → split, offsets consistent because each delta applies to the evolving
  shadow + document (resolve-at-apply); (2) the replacement delta arrives, then
  `performAction(newline)` → the queue serializes them; split sees corrected text; (3) the action
  arrives *first* and the replacement delta lands after the split → its `oldText` references the
  pre-split buffer → stale-delta guard drops it and re-pushes the post-split window. The
  correction is lost, the document is never corrupted, and undo groups sanely. Case (3) is
  explicitly exercised in the device-drip script and the day-15 pass (Gboard / Samsung /
  SwiftKey).
- **G10 (Enter mid task item, including mid-composition):** `SplitBlock` (v2 op) puts text before
  the caret in the original block — which **keeps its metadata including `checked`** — and the new
  block takes the type the `split` policy declares (`newBlockType: inherit` for taskItem) plus the
  type's `newBlockMetadata` policy (taskItem → `{checked: false}`); both reach the op through
  `EditContext`. IME-wise, we make **no claim that Enter commits compositions first** — the class
  of unverified channel-ordering assumption G4 forswears — and Korean Hangul input is
  *permanently* mid-composition (per-syllable), so Samsung/Gboard Korean can and do deliver a `\n`
  insertion delta while the composing region is non-empty. Handling: `\n` (or
  `performAction(newline)`) with empty composing → split + ordinary re-serialize. With
  **non-empty** composing: apply the split through the batch loop — the window moves to the new
  block, i.e. diverges from the shadow, so this finishes through
  `terminateComposition('structuralDelta')` (Android re-attach; quarantine armed against the
  post-push syllable echo): clear ComposingState, re-serialize the new block's window, **one**
  push with composing empty. The composed-so-far syllable text is committed where it stands
  (already in the model via the applied deltas); no composition restart because there is no
  composition left to restart. Korean (Hangul) joins the device matrix — it is the IME that is
  always composing.
- **G3 (Japanese IME composing when an input rule would match):** input rules are **deferred, not
  dropped**. After each committed delta batch: composing empty → run the insert-pattern rules on
  the caret block (post-state contract, §input rules); composing active → set the latch
  `rulesPending = (blockId, editedRange)` — **the composed/edited range is recorded with the block
  id**, so latch-fire has a real `editedRange` to match against (a latch storing only a block id
  would be unfireable — see §input rules) — and re-evaluate when a later batch ends with composing
  cleared (commit) or a `TextEditingDeltaNonTextUpdate` clears it (behind the web diff frontend,
  the analogue is a value diff with unchanged text whose mapped composing clears — same trigger,
  same latch). Mid-composition, "# " is just composing text — untouched (and visibly underlined,
  per Rendering); we never invalidate the composing region. On commit the rules fire against the
  committed text and the resulting model change re-serializes the buffer with `setEditingState`,
  safe because nothing is composing. **Latch invalidation:** the pending latch is cleared if its
  block is edited by any non-IME source, structurally changed, or removed before the composition
  ends, and by every `terminateComposition` call — a stale latch can never fire against text the
  rule never matched.
- **G7 (undo right after a merge that happened mid-composition):** the merge itself was a
  structural backspace — for a plain backspace composition is inactive at the merge boundary, and
  a composite deletion with live composition finishes through
  `terminateComposition('structuralDelta')` per the G1 guard, so either way the merge commits
  cleanly; but if a composition is live anywhere when the user hits undo (hardware Cmd+Z or the
  keyboard's own undo), the controller restores the `(Document, DocSelection)` snapshot and the
  push goes through `terminateComposition('undo')`: composing is unconditionally cleared on both
  sides — controller state null, engine pushed `composing: TextRange.empty`, **via a connection
  re-attach on Android, with the echo quarantine armed** (a bare push on this path is exactly
  where Samsung/Gboard Korean re-commits the held syllable against the restored snapshot). Undo is
  a deliberate composition terminator; we deliberately do NOT attempt to resurrect the platform
  composition (both reference editors accept this), and we never restore a snapshot's composing
  state into the controller — a stale ComposingState would wedge the hardware-key composing gate
  and the G3 latch against a composition-end signal the IME will never send. Composition-scoped
  undo grouping (see Undo) additionally guarantees the restored snapshot is a pre-composition
  state, never partial kana.
- **G15 (rotation/resize during composition):** geometry callbacks (`setEditableSizeAndTransform`,
  `setCaretRect`, `setComposingRect`) are re-sent from the caret block's `didChangeMetrics`/layout
  listener; **`setEditingState` is never called for pure geometry changes**, so the composing
  region is preserved — this falls out of separating "report geometry" from "report text" (the
  geometry reporter is a distinct object inside `ImeService` with no access to `setEditingState`).
- **Composing-rect tracking (one rule, stated once):** the geometry reporter sends
  `setComposingRect` and `setCaretRect` after **every applied delta batch that changes the
  composing range or caret position** — not only after structural changes. iOS anchors its
  candidate bar / autocorrect UI from the composing rect and expects it to track the composition
  as it grows; a stale rect mis-anchors the conversion UI. (The caret block's layout listener
  fires on every text-changing delta, so this is the same tick G15 uses.)

**Input rules — two contracts (the kept v2 contract cannot be driven by the G3 latch).** The v2
`InputRule` contract is *pending-transaction interception*: every rule calls
`_findInsertOp(pending)` to locate the triggering `InsertText` and returns a `Transaction`
embedding `[...pending.operations, ...extraOps]`. Both latch-fire triggers break it: a
`NonTextUpdate` commit has **no pending transaction at all** — `_findInsertOp` returns null and
every rule silently declines, so the latched "# " heading conversion never fires after a CJK
commit ("deferred, not dropped" would be a lie); and a replacement-commit batch maps to
delete(composing range) + insert(full committed string), a multi-character `InsertText` that the
keystroke-shaped rule predicates (`text == ' '` at `offset == prefix.length`, `text == '-'`,
wrap-anchor `match.end == editEnd`) all decline — while naively passing the already-applied batch
as "pending" would double-apply its embedded operations. This is more than a mechanical sweep; the
rules are **split by kind** (~1 day across days 1–2 / 5–7, booked):

- **Insert-pattern rules** (InlineWrap ×3, LinkWrap, PrefixBlock/Heading/ListItem/ NumberedList,
  TaskItem, Divider) move to a **post-state contract**: `tryTransform(Document docAfter, String
  blockId, TextRange editedRange, EditorSchema)` returning id-addressed ops against `docAfter`
  plus a block-local `selectionAfter` — these rules already compute everything from the result
  doc, so the port is straightforward but touches each rule. They run on the post-batch path:
  immediately when composing is empty, or at latch-fire with the latch's recorded `editedRange`
  (including the `NonTextUpdate` trigger, which works because no pending transaction is needed).
- **Structural behavior is policies all the way down — there is no rule-level interceptor
  contract.** All five v2 structural rules' behaviors are *declared* by BlockDef policies and
  implemented directly by the controller's split/merge paths: HeadingBackspace →
  `backspaceAtStart: convertToDefault`; ListItemBackspace/NestedBackspace → `backspaceAtStart:
  outdentOrConvert`; EmptyListItem → `onSplitEmpty: convertToDefault`; CodeBlockEnter →
  `SplitPolicy.onEnter: insertLineBreak` (the same kind of enumerable fact as `onSplitEmpty`,
  consulted at the same place in the Enter path). All five rules are **deleted** alongside
  `DividerBackspaceRule`, the controller paths simply read the policies (no consultation order to
  specify), and `input_rule.dart` carries exactly one contract: post-state `tryTransform`.
  Consistent with D13: interceptors are NOT built at launch — the only interceptor story anywhere
  in the system is the deferred pre-commit seam on the single-writer queue, for behavior no
  enumerated policy value can express.

**Connection lifecycle (`connectionClosed`):** the platform can close the connection out from
under us — verified: the web engine sends it on DOM blur, and iOS fires it on first-responder
resignation (e.g. the iPad keyboard-dismiss key); the Android embedding never sends it
(keyboard-app switches are absorbed via `restartInput`). An `ImeService` that still believes it is
attached goes silently dead, so we handle it EditableText-style, minimally: mark detached, run
`terminateComposition('connectionClosed')` (controller state cleared; the engine push is skipped),
clear the shadow, and lazily re-attach + re-serialize on the next focus or edit. The GATE-M menu
code consults **real attachment state**, not focus, before showing `SystemContextMenu`. (~10 LOC;
appflowy ships this callback as a no-op and super_editor only logs — we do the minimal correct
thing.) `updateFloatingCursor` (iOS spacebar-drag caret) is likewise a real `TextInputClient`
member we must answer: scoped on day 13 as within-block floating caret movement with
edge-triggered block handoff via the geometry registry (small; degrades to caret-only movement
before any handle/magnifier function degrades — see R9). It is the one touch-surface piece with a
genuine IME-client dependency, which is why it stays off the parallel track (see plan).

**The no-echo invariant (single choke point):** `setEditingState` has exactly **one caller**
inside `ImeService`, invoked only when (a) the model changed from a non-IME source (undo, paste,
rules, toolbar), **(b) the selection changed from any non-IME source — including block-local
offset changes within the same window**, or (c) the stale-delta guard / echo-quarantine re-push.
Clause (b) is deliberately broad: a tap or arrow-key caret move inside the current block is the
most common gesture in the editor, and a narrower moved-to-a-different-window trigger would leave
the engine-side editable holding the old selection — the next insertion delta carries the IME's
stale cursor (its `oldText` matches the shadow exactly, so the guard is structurally blind), text
inserts at the old caret, and autocorrect/Gboard re-composition target the wrong word; appflowy
re-attaches on *every* selection change, and `EditableText` pushes selection-only changes.
Concretely: the shadow comparison covers **selection as well as text** — whenever
`controller.selection` diverges from the shadow's selection for any reason other than applying the
current delta batch, the window is (re-)pushed; if a composition is active, the push routes
through `terminateComposition('externalEdit')` as always. IME-originated edits are never echoed:
after applying a delta batch, the recomputed window (text + selection + composing) is compared to
the shadow and, when equal (the normal case), nothing is sent. A debug `assert` fires if any push
happens while the shadow reports an active composition, **except through `terminateComposition`**
— the one named exemption. Shadow-buffer trace test (day 5–7 suite): type "hello", tap before 'h',
type 'x' → document is "xhello", not "hellox".

The **web non-delta fallback** is a second *frontend* over the same core: Safari delivers full
`TextEditingValue`s; `text_diff.dart` diffs old/new around the cursor (appflowy's
`NonDeltaInputService` precedent) and emits the same id-addressed ops through the same
shadow-buffer + choke-point machinery. **It is a full peer of the delta frontend for composing —
not just for text.** The web engine reports composing ranges in its full `TextEditingValue`s
(compositionstart/update; `EditableText` paints composing underlines on web today), and the diff
frontend maps each incoming `TextEditingValue.composing` (shifted −2, block-local — machinery the
delta path already has) into `ComposingState` under the same lifecycle rules; a value with
**unchanged text but changed composing** is the `NonTextUpdate` analogue, including the latch-fire
trigger, and is acknowledged into the shadow so composing-only updates are never echo-pushed (the
no-echo triple — text + selection + composing — stays well-defined behind this frontend). Without
this mapping, `controller.composing` would be permanently null on a D2 launch platform and every
composing-gated mechanism would be dead there: the underline never paints (CJK marked text "looks
committed"), the G3 latch never arms (rules fire mid-composition and their re-serialize push
restarts a live browser composition — the #1641 pathology, deterministic wrong text for Japanese
on web), the hardware-key composing gate splits/navigates under live Safari compositions, and the
shadow comparison diverges on every composition keystroke, echo-pushing into the composition. The
frontend is an explicit day-8 deliverable whose exit criterion includes a **web CJK trace**
(Safari Japanese: compose, convert via candidate, commit, then a "# " rule fire on commit); the
same trace joins the day 19–20 gauntlet script. It is flippable per-platform — also the R1
mitigation for Android OEM delta breakage (a mitigation that only works because the fallback is a
composing-complete peer).

**Passive-while-composing (day-8 checkpoint consolidation, branch `v3/day-8-web-fallback`):**
while the engine reports a live composition the diff frontend is a one-way observer — the web
engine cannot re-mark text, so ANY mid-composition `setEditingState` (a snapshot-reactive
`terminateComposition('structuralDelta')` push included) destroys the browser's marked region
while the IME's internal buffer continues (the captured `nににhにほ…` accumulation; v2 was immune
by construction — it never synced to the platform during composition). Snapshot shapes the delta
frontend's divergence rule would terminate are ABSORBED instead: text and selection apply one-way
into the model and the composition is kept; a genuinely unmappable shape (composing across blocks
— should be impossible from a browser, guarded anyway) DEFERS reconciliation: later snapshots
acknowledge into the shadow only, and the snapshot that ends the composition (composing
live→empty) runs the one authoritative convergence push — after the composition is over, when
pushing is safe; the absorbed composing region being REPLACED by one with a different start (a new
compositionstart re-latched the engine base) reconciles identically — the absorbed composition
objectively ended, and staying passive absorbs the user's next composition into the void (the
captured Chrome blur cascade). **Composing state is only ever BORN from a text-changing snapshot:**
every genuine compositionstart/update inserts or replaces (a dead key inserts its `´`), while the
engine's composition latch (`composition_aware_mixin`, reset only by compositionstart/end DOM
events) survives blur/`connectionClosed`/re-attach and keeps decorating text-unchanged snapshots
with the dead range (two captured Chrome journals: the blur-return re-arm over an unchanged
window; the same dead range carried onto a different block's freshly pushed window) — so with
shadow composing empty, a composing decoration on a no-text-change snapshot is filtered to empty
(journaled `composingBirthSuppressed`), and composing-only updates during a live composition (the
NonTextUpdate analogue, CJK candidate navigation) pass untouched. **A text-unchanged snapshot's
selection starting inside the sentinel zone is likewise never honored:** every pushed window
carries a selection at or beyond the sentinel length and the hidden editable is unclickable, so a
sub-sentinel selection start on the no-diff path — the one place the engine selection drives the
model — is browser bookkeeping (the captured Safari blur reset — compositionend plus a DOM
selection parked at zero); the selection component is ignored (journaled
`sentinelSelectionSuppressed`) while the composing transitions process normally, and one plain
push re-teaches the engine the preserved caret (text-CHANGING snapshots are exempt: G1's
sentinel-consuming edits genuinely carry sub-sentinel selections, and a text delta's selection
never drives the model). `performAction('newline')` is
likewise ignored while the engine owns a composition (shadow composing live or the passive window
armed) — the deferred-Enter-reaching-the-DOM fallout; a genuine commit newline arrives as a `\n`
delta/snapshot (G10). Deliberate terminations are unchanged and may still push mid-composition: undo
(G7), `setDocument`/external app edits, non-IME selection moves (tap-to-another-block),
detach/`connectionClosed` — user/app acts, not snapshot reactions. The delta frontend keeps its
ordering guarantees and its structural-while-composing divergence rule as specified above, with
one deliberate shared change: the divergence rule's within-composing selection-adoption exception
(the WebKit marked-text-selected shape) lives in the shared batch-end reconciliation, so a delta
batch carrying a range selection inside its composing region survives identically on the delta
frontend — adopted, not terminated.

Hardware keyboard (`keyboard_service.dart`): `Shortcuts`/`Actions` for arrows (incl. cross-block
caret movement via geometry-x affinity — landing on a void normalizes to its `[0,1)` atomic
selection via `setSelection`), Tab/Shift-Tab (G13), **Alt+↑/↓ → `MoveBlock`** (the D10
keyboard-move coverage), Cmd/Ctrl+B/I/Z/V, Backspace/Delete on desktop where the IME doesn't own
them. **The composing gate covers ALL of keyboard_service, not just Enter/Backspace —
ignore-everything-while-composing with an explicit whitelist** *(landed day 8, pulled forward
into the editor widget's key dispatch as part of the passive-while-composing consolidation; day
10's new bindings inherit it)*: while `controller.composing` is
non-empty, every editing/navigation key handler (arrows, Home/End, Tab, Enter, Backspace, and any
selection-modifying shortcut) returns `KeyEventResult.ignored` so the IME owns the keystroke. The
whitelist of deliberate composition terminators — currently exactly Cmd/Ctrl+Z (undo deliberately
terminates composition per G7) — stays handled; the gate is a whitelist over an ignore-all
default, not a per-key blacklist, so future shortcuts cannot reintroduce the bug class. Why arrows
MUST be gated, not just Enter/Backspace: hardware keys arrive at the framework during active
composition on iPad Magic Keyboards and Android physical keyboards — D2 launch surfaces — and
Japanese hardware-keyboard conversion uses ←/→ to navigate clause segments and ↑/↓ for candidates.
An ungated arrow `Action` fires `setSelection` → `terminateComposition('externalEdit')` → the
marked text commits as-is on the first segment-navigation keystroke (multi-segment conversion
impossible), and a `handled` key is never redispatched to the platform IME, so the navigation
keystroke is also swallowed — violating G3's "we never invalidate the composing region" from
inside our own keyboard layer (Flutter's `DefaultTextEditingShortcuts` gained the same composing
gating after identical bugs). Where an IME intercepts arrows before the framework, the gate is a
harmless no-op. (The gate reads `controller.composing` — which is why its lifecycle rules matter:
a stale value here is a wedged keyboard.) Day-15 matrix row: iPad hardware keyboard, Japanese
multi-segment clause — ←/→ segment navigation + candidate selection must complete with composing
intact until commit.

## Spellcheck & autocorrect

**Autocorrect** (D8) needs no dedicated module: it *is* the IME delta path. We declare
`TextInputConfiguration(autocorrect: true, enableSuggestions: true, enableDeltaModel: true)` and
the correctness bar is the delta application above (G4, plus the no-echo selection rule — a
same-block tap must move the engine-side cursor, or autocorrect targets the wrong word).
Composing/caret rect reporting follows the one rule in the IME section, which keeps the platform's
autocorrect and candidate UI anchored.

**Spell check** (D8, iOS/Android only): `SpellCheckCoordinator` (~300 LOC):

- Debounced (400 ms) per-block: blocks that are laid out *and* changed enter a **per-block dirty
  set**, drained by a **serial fetch queue — exactly one
  `DefaultSpellCheckService.fetchSpellCheckSuggestions(locale, block.plainText)` in flight**; on
  completion the queue pops the next dirty laid-out block. Serialization is mandatory, not a
  politeness (project-verified against Flutter 3.41.6): the Android embedding's `SpellCheckPlugin`
  services exactly one request at a time — a second `SpellCheck.initiateSpellCheck` while one is
  pending is answered with an error, which `fetchSpellCheckSuggestions` catches and returns as
  null (spell_check.dart:187-197). Concurrent per-block fetches on one debounce tick (multi-block
  paste, undo of a merge, scrolling blocks into view) would silently lose N−1 results — and
  because the trigger is "changed", the dropped blocks would never be rechecked. A **null result
  therefore means "still dirty"** (retry on a later tick), with a small bounded retry count per
  block — iOS returns null for an unsupported language, and an unbounded retry would loop every
  tick. (Second project-verified fact, closing a suspected hazard: the service's
  `lastSavedResults` merge is gated on `spellCheckedText == text` (spell_check.dart:210-214), so
  interleaving different blocks' texts through one service instance can never merge results across
  unrelated texts — one shared instance is safe.) Per-visible-block keeps payloads tiny and is
  lazy-compatible (GATE-L) — offscreen blocks are simply unchecked until shown. This is in the
  day-17 spec deliberately (~20 LOC inside the booked ~300): discovered on-device it looks like a
  platform bug and burns the buffer.
- Results stored as `{blockId: (sourceText, List<SuggestionSpan>)}`.
- **G8 (offsets shift after a later edit):** the coordinator subscribes to the controller's
  **change stream** — applied operations as data, not text snapshots. Every text op carries exact
  `(blockId, offset, insLen/delLen)`; cached ranges are shifted through each individual edit as it
  commits (insert before a range → shift right; delete after → unchanged; overlap → drop the range
  — stale by definition). Because shifting is per-op, **multiple distinct edits inside one
  debounce window shift correctly** — a paint-time single-edit diff (common prefix/suffix) would
  silently mis-shift under two separated edits, which is why shifting is op-driven;
  `text_diff.dart` remains only in the web IME fallback. The debounced re-check then replaces the
  whole entry. ~50 LOC, no incremental-annotation framework.
- Squiggles: the text component's painter draws dashed underlines for the (shifted) ranges.
- Suggestions UI: tap inside a squiggle range (mobile) → the context-menu layer shows suggestions
  + "Replace" via the same toolbar plumbing as selection menus (the fallback toolbar controller,
  days 11–13, never-cut — see Context menus).
- Never check the block containing an active composing region (avoids fighting the IME).

This is the credible launch path for GATE-S: autocorrect through deltas (no extra code), spell
check through the public `SpellCheckService` API with per-block scoping.

## Gestures & selection UX (desktop, mobile, web)

Two interactors (appflowy precedent: separate desktop/mobile selection services), **both built on
all platforms and dispatched per gesture by `PointerDeviceKind`** — `kind == mouse`/trackpad →
mouse-interactor paths; touch/stylus → touch-interactor paths. Platform-at-build interactor
selection is deliberately rejected: it would leave mouse/trackpad input on iPad (Magic Keyboard)
and Android (mouse, ChromeOS) — both D2 launch platforms — with no drag-select, shift-click, or
double/triple-click at all (the touch interactor only selects via tap/long-press/handles, and a
mouse press-drag on content would be claimed by the scrollable). Flutter's own `EditableText`
branches selection gestures on event kind for exactly this case, and the design already ships
hardware-keyboard shortcuts unconditionally on those platforms. The dispatch is wiring, not new
code: the viewport raw `Listener` already owns pointer-downs, so it switches on `event.kind`; the
mouse interactor must exist anyway for web (never-cut); the hit-test helper and post-frame
autoscroll ticker are shared. Platform-at-build survives only for **chrome defaults**: handles and
magnifier are suppressed for mouse-kind pointers. Pre-registered fallback (cut-line item 5): if
days 11–13 run hot, mouse-kind on mobile degrades to caret + drag-select only — a recorded cut,
never a silent absence. *(Scoping note: the research records super_editor using per-platform
interactors — per-kind dispatch is a deliberate improvement over both references, justified by
D2's launch platforms, not an imported precedent.)*

Both interactors share one hit-testing helper: global point → registry lookup of the nearest
laid-out block (vertical scan over registered render boxes, clamping x) → `offsetForLocalPoint`
(midpoint-resolved for voids). The viewport-level `Listener` owns pointers that go down **on
editor content**; pointers that go down on overlay-hosted chrome (handles) are routed to the
interactor **by registration**, not by widget ancestry, and are **hit-test-absorbed at the
handle** — see G11; both halves of this distinction are load-bearing.

**Content-pointer arena participation — stated invariant, same standard as the handles (G11).**
Bare `Listener`s do not compete in the gesture arena, and the scrollable's
`VerticalDragGestureRecognizer`, alone in the arena, wins after touchSlop. If content pointers
were owned *only* by the raw `Listener`, then after a long-press fires (word select + handles +
magnifier — D2 launch scope) any finger drift beyond touchSlop would scroll the list under the
live selection, and long-press-then-drag extension (native on iOS/Android; super_editor and
`EditableText` both support it) would be unimplementable — a `Listener` has no way to deny an
already-accepted drag recognizer the pointer. Therefore interactors **participate in the arena via
a `RawGestureDetector` with interactor-owned recognizers** (the mechanism of Flutter's own
`TextSelectionGestureDetector`):

- a `TapGestureRecognizer` — tap-to-caret fires only when the scrollable loses the arena;
- a `LongPressGestureRecognizer` whose arena win **suppresses the scroll drag for that pointer**
  and then drives drag-extension (`onLongPressMoveUpdate`, by word) through the existing
  pointer-route plumbing;
- per-kind acceptance, so plain touch drags without a long-press still scroll, and mouse-kind
  press-drags drive selection.

The raw `Listener` stays for per-kind dispatch and pointer bookkeeping; it coexists with the
recognizers and the G11 pointer-route handle plumbing. **Pinned `dragDevices` invariant, recorded
because the framework default is silent and app-overridable:** mouse drag-select not fighting the
scrollable depends on `ScrollBehavior.dragDevices` excluding mouse-kind (the framework default
since Flutter 2.5) — an app-supplied `scrollBehavior` (common on web to enable mouse-drag
scrolling) would reintroduce the two-writers pathology. The editor-owned `CustomScrollView`
therefore **pins its own `ScrollBehavior` whose `dragDevices` exclude mouse**; it does not inherit
the app's. Widget tests (days 11–13): long-press then drift does not scroll; long-press-drag
extends the selection by word; a plain touch drag scrolls.

**Prefix tap — the gutter is a pointer surface (Decision 3: v2 baseline incl. task lists).** v2
toggles task checkboxes through a package-owned pointer surface (`onPrefixTap`,
editor_controller.dart:1956-1965, default = `toggleTaskCheckedAt`, wired through span_builder's
gesture wrapping) — and span_builder dies in v3, so the surface must be re-booked, not silently
dropped: interactors own all editor pointer-downs and the shared hit-test helper clamps x to the
nearest registered component box (only components register geometry, not the gutter), so without
this surface a tap on a checkbox would place a caret at ~offset 0 and summon the keyboard —
actively wrong, and unfixable app-side for the same reason as `onLinkTap` (bare Listeners are
arena-independent; the geometry registry is not public). Port, booked with the day-14 checkbox
work where the semantics toggle already lands:

1. `_BlockSubtree`'s gutter slot **registers its gutter rect with the hit-test helper**, so
   pointer-downs in the gutter resolve to a *prefix-tap* on that block, never to a clamped caret;
2. the controller gains **`onPrefixTap`** with the v2 default — `taskItem` →
   `setBlockMetadata(blockId, TaskItemKeys.checked, !checked)` — routed through the single-writer
   queue;
3. the interactor **suppresses caret placement and IME open** for taps consumed by the prefix
   region.

Day-14 widget test: tap a checkbox → `checked` flips, selection unchanged, keyboard not summoned.

**Void selection — one normalization rule, all platforms:** clicks and taps on void blocks
**atomic-select `[0,1)`** (Notion behavior). A desktop click-places-caret rule is deliberately
rejected: with the midpoint hit rule it would produce a collapsed `DocPosition(image, 0|1)` — a
state with **undefined rendering** (void components have no text painter and no specified
edge-caret paint: visually silent), **undefined IME buffer** (the sentinel+`~` buffer is specified
only for void *selection*), and **corrupting typing semantics** (`InsertText` splices text
segments into the image — the corruption path the void-endpoint normalization closes). The
normalization lives in `controller.setSelection`, so keyboard arrow navigation onto a void is
closed by the same rule. Void-edge positions (offset 0/1) exist **only as transient range
endpoints during drags**, and a selection that has collapsed onto a void edge at mouse-up
normalizes to the `[0,1)` atomic selection. Typing with a void selected is then the
already-specified type-over-selection path; the collapsed-caret-on-a-void rendering/IME/typing
cases need not exist at all. Day-14 tests: click an image on web → tinted border + context-menu
affordance; then type → image replaced by a paragraph containing the typed text.

**Mouse-kind pointers (`mouse_interactor.dart`, all platforms):**
- Click: place caret (voids: atomic-select). Double-click: `wordBoundaryAt`. Triple-click/tap:
  whole block, with `expandBase` recorded (G6).
- Shift-click: extend from `expandBase` (G6 cross-block extension free).
- **Links (D3 launch content — booked, not discovered on day 19):** link *activation* lives on the
  link-span `TapGestureRecognizer`s built days 1–2 (Rendering §link spans) — Cmd/Ctrl-click (and
  plain click on read-only) is the recognizer's kind/modifier gate, not interactor logic. What
  remains interactor-side is the **hover cursor**: `SystemMouseCursors.click` over link segments
  (via `offsetForLocalPoint` + `segmentAt`, primitives that exist by day 3–4) — ~100 LOC riding
  existing primitives, scheduled **day 14** when the parallel track ran (day 14 is de-loaded by
  the track's clipboard pull), else recorded as the first cut-line item-7 candidate (see plan
  §day-10 displacement). v2 history (commits 4813443 "fix inline entity tap hit testing", 09ea045
  "Refine inline entity selection APIs and link editing" — 754 insertions) proves this surface
  consumes real time when unplanned; in v3 the app *cannot* rebuild pointer surfaces app-side
  (interactors own all pointers; the geometry registry is not public), so every piece is booked in
  the package.
- Drag: pointer-move updates `extent` each frame. **Autoscroll + lazy (G5), specified tick:** when
  the pointer is in the edge zone, the `AutoScroller` runs per-frame ticks: `jumpTo(newOffset)` →
  **post-frame callback** (after the sliver has laid out the newly revealed content) → re-hit-test
  under the stationary pointer → update `extent`. Because the sliver lays out the visible viewport
  within the same frame as the scroll, the post-frame hit-test always lands on laid-out content —
  the extent is never an estimate and the under-highlight window is at most one frame of lag, the
  same lag native editors exhibit (clamping to the nearest laid block at arbitrary times would
  accept visible jitter; sequencing hit-testing after layout removes the wobble). Dragging *across
  the image* resolves via the midpoint rule — symmetric for downward and upward drags, so a swept
  image is tinted during the drag and included in the final selection regardless of direction.
  **Wheel/trackpad scroll mid-drag — the tick generalizes to every `ScrollNotification`:** a
  `PointerScrollEvent` is not a pointer move and runs no autoscroll tick, yet it is the natural
  way to traverse "paragraph 3 viewports below" on web/desktop — content would scroll under the
  stationary pressed pointer while the extent stayed frozen, and a release without moving would
  commit the stale extent. Rule: **while any drag (content or handle) is active, every
  `ScrollNotification` — not only AutoScroller ticks — schedules the same post-frame re-hit-test
  under the current (compensated) pointer position and updates the extent.** Already-built
  machinery re-keyed (~5 LOC); idempotent with autoscroll's own notifications, no feedback loop
  (extent updates never scroll), and works for handle drags via the existing compensated point.
  Final selection on mouse-up is exact by construction (void-edge collapse normalized per the rule
  above). Day-10 widget tests: downward AND upward drag-across-image; press, wheel-scroll two
  viewports, release without moving → selection ends under the pointer's final visual position.

**Touch/stylus-kind pointers (`touch_interactor.dart`, all platforms):**
- Tap: caret + open IME (voids: atomic-select `[0,1)`; gutter taps resolve to the prefix-tap
  surface — no caret, no IME). **Link tap:** a tap inside a link segment places the caret normally
  (interactor) AND surfaces the link via the link-span recognizer's `onLinkTap` callback
  (`BlockComponentContext.onLinkTap` / controller-level `onInlineEntityTap` — v2's surface, driven
  by the span recognizers from days 1–2; the two compose because the raw Listener is
  arena-exempt); whether the app opens the URL, shows an edit sheet, or does nothing is app
  policy. Long-press: word select + handles + magnifier (haptic), via the interactor's
  `LongPressGestureRecognizer` whose arena win suppresses the scroll drag.
- Handles: two `OverlayPortal` widgets positioned from `geometryOf(blockId)?.rectForOffset(...)`.
  **Visibility is a viewport predicate, not a layout predicate:** a handle shows iff
  `geometryOf(blockId) != null` AND its anchor rect (transformed to global) intersects the scroll
  viewport's visible bounds, recomputed on scroll notifications — the same tick that drives the
  G14 menu hide-on-offscreen lifecycle, so the logic is shared. Layout-keyed visibility alone is
  wrong: the sliver's `cacheExtent` (~250 px each side) keeps blocks laid out beyond the visible
  viewport while `OverlayPortal` paints in the app Overlay, which the scroll viewport does NOT
  clip — a handle keyed only to "laid out" would draw over the app bar/toolbar/keyboard accessory
  as its anchor scrolls past the edge. Selection state is unaffected either way (model-level); the
  handle reappears when its anchor scrolls back into view (G11).
- **Pointer-down exclusivity (G11) — stated invariant, not incidental hit-test opacity:** pointer
  *routes* do not participate in the gesture arena, bare `Listener`s do not compete in it,
  `RenderStack` hit-testing keeps descending unless an upper child's `hitTest` returns true, and
  `Listener`'s default `HitTestBehavior` is `deferToChild` — so without explicit absorption, a
  pointer down on the handle bulb (which hangs a full line height over editor content) would ALSO
  reach the `CustomScrollView`, whose drag recognizer would be *alone in the arena*, win after
  touchSlop, and scroll the list while the registered route simultaneously drives selection: two
  writers, visibly broken handle drags, dependent on the incidental opacity of whatever widget the
  bulb happens to be. The handle's `Listener` is therefore **`HitTestBehavior.opaque` over its
  whole hit region**: a pointer that goes down on a handle never appears in the viewport's
  hit-test path and never seeds the scrollable's recognizer — the mechanism that makes "viewport
  owns content pointers" and "overlay pointers are routed by registration" disjoint sets. Accepted
  tradeoff, recorded: the bulb steals taps from the text line it overlaps — native iOS behaves the
  same. Widget tests (days 11–13): a handle drag does not scroll the list; a handle tap does not
  place a caret in the content beneath.
- **Drag continuity (G11) — pointer routing by registration:** the handle widget is **visual-only
  and never owns the active gesture**. Flutter dispatches move/up events only along the hit-test
  path captured at pointer-*down* (GestureBinding stores the HitTestResult per pointer), and an
  overlay-hosted handle sits *above* the editor subtree — a pointer that goes down on a handle
  never includes the viewport Listener in its path ("the viewport Listener tracks that pointer id"
  is not a capability Flutter Listeners have). Instead: on the handle's (opaque) `Listener`
  pointer-down, the interactor calls
  `GestureBinding.instance.pointerRouter.addRoute(event.pointer, _onHandlePointerEvent)` — the
  exact mechanism gesture recognizers use via `startTrackingPointer` — and removes the route on
  up/cancel. The route is owned by the always-mounted interactor State, so it is independent of
  widget mounting: the `OverlayPortal` handle can unmount mid-drag (anchor scrolled away) without
  killing the gesture. ~20 LOC; the equivalent alternative is an interactor-owned
  `PanGestureRecognizer` fed by `recognizer.addPointer(event)` from the handle's down
  (super_editor's pattern). Drives selection + autoscroll exactly like a content-originated drag.
- **Grab-offset compensation:** the touchable handle bulb hangs a full line height below the text
  anchor (extent handle; above for the iOS start handle), so hit-testing the raw finger position
  would land one line away from the anchor on the first moved pixel — a visible selection jump,
  with the magnifier magnifying the wrong line. At handle-drag start the interactor records
  `fingerToAnchorDelta = anchorGlobalPosition − pointerDownGlobalPosition`; every move (and every
  post-frame autoscroll tick) hit-tests at `fingerPosition + fingerToAnchorDelta`, and the same
  compensated point is the magnifier's focal point (the framework's and super_editor's own
  pattern, ~10 LOC). **Drag-start race — handle geometry is NOT guaranteed available:** handle
  visibility is only as fresh as the last scroll notification, so a pointer-down can land on a
  handle whose anchor was unlaid in the same frame — `geometryOf` is null-checked at handle
  pointer-down and `null` ⇒ the drag is refused (the handle is about to hide anyway), consistent
  with GATE-L. Widget test: grabbing a handle without moving does not change the selection.
- The magnifier follows the *(compensated)* finger point, not the text anchor, so it survives the
  extent block leaving the viewport (G11); drag near edges drives the same post-frame autoscroll
  ticker as desktop (G5 mechanics shared).
- Drag-handle move = update `extent` (or `base` for the start handle) from the compensated finger
  position via the shared hit tester.
- Block images: tap selects `[0,1)` (atomic, D3); no text handles for void selection — a tinted
  border + the context menu instead.
- iOS floating cursor (`updateFloatingCursor`): within-block floating caret movement with
  edge-triggered block handoff via the geometry registry (day 13; see IME §connection lifecycle).

**Web:** mouse interactor + the non-delta IME fallback (day 8); browser context menu suppressed
over the editor (`BrowserContextMenu.disableContextMenu`) so our (never-cut, days-11–13) fallback
toolbar shows. Known-familiar Safari IME quirks are absorbed in the diff fallback (v2 experience
carries over).

**Drag-reorder (D10, deferred):** the gesture layer reserves the left gutter: `_BlockSubtree`
already lays out a fixed-width leading slot (bullet/checkbox/grip, via the kept `prefixBuilder`).
Post-launch the grip gets a drag recognizer + drop-indicator painter (riding the same
pointer-route drag plumbing G11 builds); nothing in the selection or component contract changes.
**Keyboard move (Alt+↑/↓ → the NEW `MoveBlock` op, day 10) covers launch** — the op does not exist
in v2; it is specified in Operations and scheduled, so D10's launch-gap coverage is real work with
a real slot, not an assumed inheritance.
## Context menus

**The Flutter-drawn fallback selection toolbar is launch-critical, never-cut, and built with the
mobile-touch work (days 11–13), not on day 16.** D2 makes Android and web production-quality at
launch, and neither has a native menu — without `ContextMenuController` +
`AdaptiveTextSelectionToolbar` there is no copy/paste/selection UI on Android at all (long-press
shows handles and then *nothing*), on web (where we suppress the browser menu precisely so our
toolbar shows), or on iOS < 16. Parking it on day 16 — after the day-15 buffer, bundled with the
*cuttable* iOS-native layer — is deliberately rejected: the plan's own expected overrun dynamics
(R2 is High) could silently take out a launch-blocking D2 deliverable appearing on neither the cut
line nor the never-cut list, and cutting the native menu couldn't free the day because the
fallback would BE most of the day. The toolbar's hard parts — geometry-registry anchor math and
the hide-on-offscreen viewport tick — are exactly the machinery handle visibility builds on days
11–13 (shared tick), so the toolbar is co-located there (its shell is also a parallel-track
candidate — it is IME-independent, depending only on selection + the geometry registry). Its
copy/cut/paste buttons are wired to controller methods at build; full markdown-fidelity wiring
completes with day 14's clipboard milestone. It joins the **never-cut list**; day 16 then contains
only the genuinely cuttable iOS-native layer, making cut-line item 6 actually free a full day.

The native iOS edit menu's **default items execute engine-side against the active
`TextInputConnection`'s buffer** — verified against framework + engine source: default
copy/cut/paste/selectAll carry no Dart callback; the engine copies/cuts the connection's text,
pastes via a plain insertion delta, and select-all selects the *buffer*. Here that buffer is the
sentinel-prefixed, possibly-elided selection window — naive native Copy on a multi-block selection
would yield plain text with `~` for images and, under the 32-block cap, silently drop the entire
interior. The item set is therefore **split by data path**:

- **Copy / Cut / Select-All are custom items** (`IOSSystemContextMenuItemCustom`), routed through
  the controller's single-writer queue: Copy → `copySelectionAsMarkdown` (clipboard *writes* never
  trigger the iOS paste-permission popup, so nothing from D12 is lost); Cut → copy +
  delete-selection; Select-All → model-level selection (which then serializes the capped window —
  the cap stays an IME payload bound, never a clipboard truncation). The windowed IME buffer is
  never the clipboard source.
- **Paste stays a native default item** — the entire rationale for D12 (no paste-permission
  popup), and it works *because* it's engine-side. Arrival path: the engine inserts the pasteboard
  string as a single insertion delta into the window. `ImeService` classifies a non-typing-sized
  or multi-line insertion delta as a paste and feeds the inserted string through the **markdown
  codec → `PasteBlocks`** path (the inserted text IS the clipboard string, so G12 fidelity is
  preserved without a `Clipboard.getData` read); a small single-line insertion that doesn't parse
  as markdown degrades to plain insertion, also correct. The codec-aware `pasteMarkdown` is
  likewise the path for the Flutter-drawn toolbar and Cmd+V.
- lookUp/share/Writing Tools remain native default items (read the window text; acceptable —
  advisory surfaces, not data paths; multi-block lookups operate on the visible window slice).

Day-16 tests: native Copy over an image-spanning selection and over a >32-block selection must
produce full-fidelity markdown on the clipboard; native Paste of multi-block markdown must produce
blocks, not literal text.

- **iOS ≥ 16 (D12):** `SystemContextMenu` — requires an **actually-attached**
  `TextInputConnection`: the menu code consults `ImeService`'s real attachment state (which
  `connectionClosed` can clear), not focus. **G14 anchor for a two-block selection:** anchor rect
  = bounding box of the selection rects of the *laid-out* blocks in the selection (first/last
  visible), transformed to global and clamped to the viewport — geometry-registry-only, lazy-safe.
  **Zero-visible-rects case** (both endpoints and the whole interior scrolled off): the bounding
  box is undefined, so the menu is **hidden** — `hideToolbar()` on the scroll tick that empties
  the visible-rect set (the same tick that drives handle visibility) — and re-shown anchored to
  the new visible slice when any selected block re-enters the viewport. This matches native
  behavior (UIKit dismisses the edit menu when its target scrolls away). Items: native
  paste/lookup/Writing Tools + custom copy/cut/select-all + ours, per the split above.
- **Everywhere else / iOS < 16:** `ContextMenuController` +
  `AdaptiveTextSelectionToolbar.buttonItems` (research: fully decoupled since Flutter 3.7) —
  **built days 11–13 (never-cut)**, same anchor computation and same hide-on-fully-offscreen rule
  (shared with handle visibility). All items are ours here, so copy/cut/paste route through the
  controller (markdown codec both ways) with no special cases. Android additionally appends
  `ProcessTextService` actions.
- Spell-check suggestions reuse the same controller with a different button set (day 17 depends on
  the days-11–13 toolbar plumbing — another reason it cannot live on day 16).

Toolbar/keyboard paste: `Clipboard.getData` → markdown codec decode → G12 path: `SplitBlock` at
the caret, insert decoded block list between the halves, merge first decoded block into the left
half when both are text-y (policy-gated, e.g. pasting into a list item keeps the item type for the
first line; subsequent blocks keep their decoded types as siblings at the item's depth), caret
collapses to the end of the last pasted block — located by that block's id, which is caller data
under id-native ops. The "siblings at the item's depth" and void-edge promises are delivered by
the re-specced `PasteBlocks` (Operations §PasteBlocks). The whole pipeline is pure model+codec
work, unit-testable with zero rendering/IME/gesture dependency, and is therefore a
**parallel-track deliverable** (see plan) rather than day-14 critical-path work — the re-spec
(~0.5 day) is booked on that track item, which has two days of slack on its only dependency edge.

## Accessibility hooks

Launch (D4 "broad but shallow"): **static reading semantics land with the components that own
them, not parked on a single late day** — parked wholesale on day 18 (the day R9 names "the first
schedule flex"), the plan's own overrun playbook would silently consume launch-binding D4 work, an
unrecorded cut in violation of D11's discipline. Split:

- **Text semantics ride the day 1–2 default text component for free** — it renders a real
  `RichText`, so `RenderParagraph` contributes the attributed label, locale/direction, and
  per-link tappable child semantics nodes — **real, not claimed: the link spans carry
  `TapGestureRecognizer`s** (Rendering §link spans; the semantics tap action invokes the
  recognizer's handler directly, so screen-reader link activation costs zero extra code). Headings
  are flagged via `BlockDef` at component construction — sourced from the def's *semantics-side*
  declaration (the same a11y-hook surface that carries `semanticsBuilder`), not inferred from a
  behavior boolean: v2's `isHeading` is deleted by the policy convention, and its behavior
  consumer is the `backspaceAtStart: convertToDefault` policy. Heading-ness is a semantics fact to
  the a11y layer and a backspace policy to the editing layer; conflating the two in one boolean
  was the v2 shape the convention removes. This is the "nearly free" premise D4 was decided on,
  made true by the RichText child and the recognizers. Days 1–2 test: paragraph-with-link
  semantics tree contains a child node carrying `SemanticsAction.tap`.
- **Image alt labels** (`Semantics(image: true, label: metadata['alt'])`) land with the day-14
  image component; **task checkboxes** become toggleable semantics nodes routed to
  `controller.setBlockMetadata(blockId, TaskItemKeys.checked, !checked)` on day 14 alongside the
  void/component work — and the **pointer path to the same toggle is the prefix-tap surface**
  (Gestures §prefix tap), booked the same day: the a11y toggle and the tap toggle are one
  mechanism with two entry points.
- The sliver gives scroll semantics for free.
- **Day 18 is a verification/wiring pass** (assert the above on all three platforms with
  VoiceOver/TalkBack/screen-reader smoke scripts) plus honest web-polish flex. Static reading
  semantics join the **never-cut list**; R9's schedule flex is narrowed to day 18's *web-polish*
  half only.

The reserved hook (GATE-A): `BlockComponentContext` passed to every builder carries

```dart
class BlockComponentContext {
  final TextBlock block;
  final int depth;
  final SelectionSlice? selection;
  final EditorController controller;            // for future a11y actions
  final void Function(String blockId, int offset, InlineEntitySnapshot entity)? onLinkTap;
                                                // link/entity tap surface (D3 — driven by the
                                                // link-span recognizers, see Rendering §link spans)
  final SemanticsConfigurationHook? semantics;  // reserved: per-block editing semantics
}
```

and `BlockDef` gains an optional `semanticsBuilder`. Post-launch, per-block editing semantics
(`isTextField: true`, `onSetSelection`, `onMoveCursor*`) are added by implementing
`semanticsBuilder` per type and routing the actions to controller methods **through the same
single-writer queue as every other input source** — the component contract and controller API
already expose everything those actions need (set selection by `(blockId, offset)`, move caret),
so no rearchitecting (precisely the hook decision D4 demands; research notes no Flutter editor has
solved *editing* semantics, so we reserve, not build).

## Public API sketch

```dart
// Setup
final schema = EditorSchema.standard();          // String-keyed; validate() per GATE-K below
final controller = EditorController(
  document: MarkdownCodec(schema).decode(source),
  schema: schema,
);

// Widget
BulletEditor(
  controller: controller,
  scrollController: ...,            // optional, editor owns one otherwise
  focusNode: ...,                   // optional, editor owns one otherwise (mirrors
                                    //   scrollController; v2's exact pattern,
                                    //   widgets/bullet_editor.dart:25-89)
  readOnly: false,
  onLinkTap: (blockId, offset, entity) { ... },  // D3 link surface (span recognizers,
                                                 //   see Rendering §link spans)
)

// Controller surface (the whole thing)
controller.document;                       // Document (v2 type)
controller.setDocument(Document d, {DocSelection? selection});
                                           // open-a-different-note: resets undo history,
                                           //   terminates any composition via the existing
                                           //   terminateComposition('externalEdit') path
controller.selection;                      // DocSelection?
controller.setSelection(DocSelection s);   // normalizes void positions to [0,1) (D3);
                                           //   clamps text offsets to [0, block.length];
                                           //   rejects gone ids (see Selection §G6)
controller.hasFocus / requestFocus() / clearFocus();
                                           // routed through the connection-lifecycle
                                           //   machinery (focus a new note, dismiss the
                                           //   keyboard on save/navigate — the internal
                                           //   Focus widget is package-private, so there
                                           //   is no app-side workaround)
controller.onPrefixTap;                    // gutter tap surface, v2 port — default:
                                           //   taskItem → checked toggle (Gestures §prefix tap)
controller.insertText(String text);        // at caret (consumes pending typing styles)
controller.toggleInlineStyle(String key, {Map<String, dynamic>? attributes});
controller.toggleInlineEntity(String key, {required Map<String, dynamic> attributes});
controller.applyLink(String url);          // convenience over toggleInlineEntity; edits the
controller.removeLink();                   //   URL in place when the selection is inside a link
controller.activeStyles;                   // Set<String>: styles at caret ∪ pending typing styles
controller.stylesAt(DocPosition p);        // id-addressed queries (re-expressed from v2
controller.entityAt(DocPosition p);        //   segmentAt; no flat indices in public API)
controller.setBlockType(String blockId, String type);
controller.setBlockMetadata(String blockId, String key, Object? value);  // checkbox toggles etc.
controller.insertBlocks(String afterBlockId, List<TextBlock> blocks);
controller.indent() / outdent();           // selection-aware, all-or-nothing group gates (G13;
                                           //   both gates specified — see Selection §G13)
controller.moveBlockUp(String blockId) / moveBlockDown(String blockId);  // MoveBlock (D10)
controller.apply(List<EditOperation> ops); // escape hatch — ops are the public vocabulary,
                                           // id-addressed; executed through the
                                           // single-writer queue + the batch loop; returns
                                           // EditResult (applied | rejected) per the
                                           // missing-id/gate-failure policy
controller.undo() / redo();
controller.canUndo / canRedo;              // one-line reads of UndoManager state (v2 had
                                           //   these, editor_controller.dart:246-247 — an
                                           //   app-side toolbar's undo/redo enablement is
                                           //   computable from nothing else)
controller.copySelectionAsMarkdown();
controller.pasteMarkdown(String md);       // G12
controller.scrollToBlock(String blockId);  // estimate-based, lazy-safe
controller.addListener(...);               // ChangeNotifier (UI rebuild signal)
controller.changes;                        // Stream<AppliedChange> — committed transactions
                                           //   as data, in queue order (Operations §change
                                           //   stream); the persistence/sync/reaction surface
```

**App-integration basics are part of the sketch by the same standard as the entity surface (D6 +
this document's own rule: the sketch is complete if the package's own consumer can ship against
it).** The focus surface, `setDocument`, and `canUndo`/`canRedo` are thin wrappers over machinery
already specified — the UndoManager getters survive from v2 verbatim,
`terminateComposition('externalEdit')` exists, and the optional `focusNode` is a ~30-line v2 port
— but absent from the surface they are discovered during app integration and land in days 19–20,
the plan's only buffer. Booked: ~quarter day inside the day 3–4 controller skeleton (which already
books "focus"). `setDocument` is the one optional member: new-controller-per-note is v2's existing
pattern and remains supported — but the choice is now a stated decision with a specified wrapper,
not an unstated gap.

**Typing-style carryover / `activeStyles` (controller state — NOT derivable from document +
selection):** toggling a style at a collapsed caret records it in a pending typing-style set
consumed by the next insertion — including the IME insert path, which threads it into
`InsertText.styles` — and the pending set resets when the selection moves by any non-typing means.
This is v2's `_typingStyles` behavior (including the carryover-reset fix of commit 178a568),
**ported, not rediscovered**, and it is the reason any app-side toolbar needs
`controller.activeStyles` (= styles of the segment at the caret ∪ the pending set) rather than
reading the document: bold-toggled-at-a-caret is observable nowhere else.

**The op vocabulary (public, enumerated — the escape hatch is checkable, not implied):** ops are
natively id-addressed, pure caller data:

```dart
InsertText(blockId, offset, text, {styles, attributes})
DeleteText(blockId, offset, length)
DeleteRange(DocPosition start, DocPosition end)  // controller's range-op builder snaps void
                                                 //   endpoints before emitting; a directly
                                                 //   constructed void endpoint trips the
                                                 //   apply debug assert (see Ops)
ToggleStyle(blockId, start, end, key, {attributes})
SplitBlock(blockId, offset)
MergeBlocks(blockId)                             // merge into previous (order resolved
                                                 //   internally from the doc)
ChangeBlockType(blockId, type)
SetMetadata(blockId, key, value)
InsertBlocks(afterBlockId, blocks)
RemoveBlock(blockId)
IndentBlock(blockId) / OutdentBlock(blockId)     // apply evaluates the G13 gate predicate
                                                 //   (ctx.canIndent / depth > 0) — failure
                                                 //   rejects the whole batch (see Operations)
MoveBlock(blockId, MoveDirection)
PasteBlocks(blockId, offset, blocks)
```

**`EditContext` (controller-supplied at `apply`; callers never supply, can never omit):**
`defaultBlockType`, the policy lookups `splitPolicyOf(type)` / `backspaceAtStartOf(type)`, the
`newBlockMetadata` policies, the `BlockPolicies` map, the shared `canIndent` predicate, `isVoid`.
Ops carry no configuration, so a half-configured op is unrepresentable; rejection is intrinsic too
(gone id or failed gate ⇒ `apply` returns null ⇒ the whole batch is rejected pre-commit).
**Caller-supplied:** ids, offsets, text, keys, attributes, blocks.

Raw `Transaction`s are **package-private purely as surface-area hygiene**: ops carry no flat
indices, so there is no stale-index footgun to contain — a transaction is just the committed batch
record. The public `apply(List<EditOperation>)` is the full expressive power; id staleness — the
residue ids don't fix — is handled by the explicit rejection policy, and the conveniences above
(`setBlockMetadata`, `insertBlocks`, `moveBlock*`, `applyLink`) close the routine gaps so the app
never *needs* the escape hatch for everyday operations. Consumers construct ops directly — and
can, safely, because ops carry no schema configuration to omit.

**`validate()` — exact assertions (GATE-K, debug-mode, `BulletEditor` constructor):**
- every registered block key: `componentBuilder != null` **or** the type is text-defaultable
  (non-void — renders via the exported default text component styled by `baseStyle`); `codecs !=
  null && codecs.containsKey(Format.markdown)` (markdown is the canonical format; other formats
  optional); `policies` present; void types declare a `voidBackspace` policy.
- every inline style/entity key **declared** by a registered input rule — via
  `InputRule.referencedInlineKeys`, a new optional getter (`Set<Object> get referencedInlineKeys
  => const {}`), overridden by the wrap/link rules to return their style key — and every key used
  by `EditorSchema.standard()` defaults, is present in `inlineStyles`/`inlineEntities`. (Rules are
  opaque `tryTransform` closures: the keys must be *declared*, not introspected. There is no codec
  clause because it would be vacuous: inline serialization lives in `InlineCodec`s registered ON
  `InlineStyleDef`/`InlineEntityDef`, i.e. inside the very maps being validated, so the codec leg
  is true by construction.)
- every type whose **declared `BlockDef.metadataKeys`** is non-empty defines `newBlockMetadata`,
  and the keys it emits are a subset of the declared set. The declaration field is new and
  load-bearing: `BlockDef` gains `Set<String> metadataKeys` (taskItem: `{TaskItemKeys.checked}`,
  default `const {}`) — without it there is nothing for this clause to read (v2 has only loose key
  consts, and a const holder is not introspectable — the same introspection-error class fixed by
  the declared `referencedInlineKeys` getter). The controller's `setBlockMetadata` debug assert
  reuses the same set for typo-safety.
- the v2 `BlockDef` constructor assert `!isVoid || prefixBuilder != null` ("it is their visual
  content") is **inverted in the days 1–2 sweep** — v3 voids render through real components
  (image/divider, day 14), so the assert would force dead `prefixBuilder`s on them; the first
  clause above (void ⇒ `componentBuilder != null`) covers the replacement guarantee in
  `validate()`. The sibling v2 asserts over the deleted behavior booleans (`!isVoid ||
  !isListLike`, `!isVoid || !splitInheritsType`, block_def.dart:31-34) die with the booleans
  themselves.
- the new `split`/`backspaceAtStart` policies add **no** clause: both have total defaults
  (`(defaultType, none)` / `merge`), so an unconfigured def is valid by construction — the
  standard schema's declarations live in `default_schema.dart`, not in `validate()`.

**Runtime half of the typo-safety guarantee:** the schema's silent unknown-key fallbacks
(`_fallbackBlockDef`, no-op `InlineStyleDef`) **remain for rendering** — deliberate forward-compat
degradation for persisted documents carrying keys from a richer schema — but the controller's
key-taking public surfaces (`setBlockType`, `toggleInlineStyle`, `toggleInlineEntity`,
`insertBlocks`, `apply`) gain **debug asserts** that every supplied block-type/style/entity key is
registered, converting a typo'd key into an immediate assert instead of silently unstyled text or
an "Unknown" block. (Not asserted at `Document` construction — the document rebuilds per keystroke
and an O(doc) walk there is the wrong altitude.) ~40 LOC inside booked work.

**Extension point — the acceptance test is that this example is complete.** A callout (a tinted
paragraph) requires no custom component, because the default text component is **public and
parameterizable** (`DefaultTextComponent`: text style, background decoration, padding, gutter
content via the existing `prefixBuilder` seam) and ships with the `BlockGeometryMixin` that
implements the geometry contract over the `RichText` child's `RenderParagraph`, the registry
lifecycle, the selection/squiggle/composing/caret painter layers, the identity+derived-state
rebuild-skip, and composing/caret-rect reporting — the ~450 hardest LOC a consumer must never
re-derive (both reference editors export exactly this piece: appflowy's
`AppFlowyRichText`+`SelectableMixin`, super_editor's `TextComponent`). v2's BlockDefs were already
declarative (`baseStyle` + `prefixBuilder`, no per-type component); v3 keeps that property:

```dart
EditorSchema(
  blocks: {
    ...EditorSchema.standard().blocks,
    'callout': BlockDef(
      label: 'Callout',
      baseStyle: const TextStyle(fontSize: 16),
      // componentBuilder omitted → default text component; or wrap it:
      componentBuilder: (ctx) => DefaultTextComponent(
        ctx,
        background: const Color(0x1AFFB300),
        padding: const EdgeInsets.all(12),
      ),
      policies: const BlockPolicies(canBeChild: true, canHaveChildren: false),
      inputRules: [],                              // e.g. a '>! ' conversion rule
      codecs: {Format.markdown: CalloutMarkdownCodec()},  // per-format codec map
      metadataKeys: const {},
      newBlockMetadata: null,
      semanticsBuilder: null,
      // split / backspaceAtStart omitted → the policy defaults: Enter produces a default
      // paragraph, backspace at start merges — exactly callout behavior (the deleted v2
      // booleans would all have been false here anyway; the example gains nothing)
    ),
  },
)
```

No API returns or accepts global character offsets, and none requires geometry of an arbitrary
block (GATE-L): everything is `(blockId, offset)` or an id-addressed op.

## Extensibility surface (D13)

"Plugins" decomposes into four categories with very different costs; v3 ships the first two,
defers the third behind a named seam, and keeps the fourth out of the core on purpose:

1. **Content extensions — the primary surface.** Custom blocks, inline styles, and inline entities
   are schema registrations under string keys (the callout example is the acceptance test). A
   text-like block is a `BlockDef` literal over the public `DefaultTextComponent`; a fully custom
   block (embed, sandbox) implements the geometry contract via the exported `BlockGeometryMixin`.
   `validate()` catches incomplete registrations at startup. This is why GATE-K exists.
   **Recorded limitation (markdown decode):** block codecs decode single lines; the only
   multi-line region shape the markdown engine recognizes is the fence (``` / ~~~), whose
   *meaning* is schema-declared (`BlockCodec.decodeFenced` — the def opts in as the fence
   target; the code block registers it) but whose *grammar* (delimiters, region splitting)
   stays in `MarkdownCodec`. Custom multi-line shapes beyond fences (front-matter, math
   environments) need a region-decode contract that is deliberately post-launch.
2. **Reactions — the change stream.** Anything that *responds* to edits (linkify-on-commit, ToC
   panels, autosave/sync adapters, word count, presence) subscribes to `controller.changes` and,
   when it wants to edit, enqueues ops like any other caller. This replaces super_editor's
   reaction layer; no registration API is needed — a plugin is `attach(controller)`/`detach()` by
   convention.
3. **Interceptors — deferred, seam named.** Pre-commit veto/transform (read-only regions, paste
   filters, validation) is NOT built: no launch requirement needs it, and wrapping the
   controller's named methods covers app-side cases. If ever genuinely needed it is one seam — a
   pre-commit hook on the single-writer queue, which every mutation already traverses — addable
   without touching any other contract.
4. **UI chrome — not a core concept.** Toolbars, slash menus, and floating format bars are
   app-side widgets over the public API: `activeStyles` + selection for state, the
   `BlockLayoutRegistry` for popover anchoring (null-tolerant per GATE-L), the change stream for
   liveness. The v2 `editor_toolbar` port is the first example, not a privileged one.

## Collaboration readiness (D14)

Collaboration is designed-for, deferred: v3 ships **no** convergence machinery (no OT/CRDT, no
selective undo, no presence), but the substrate must not foreclose it. What already serves:
id-addressed ops are exchangeable across replicas (index ops are not — flat order differs
mid-flight; an argument for the id-native design); the single-writer queue is the natural merge
point (remote ops enqueue like any caller); the change stream is the outbound feed
(`source`-tagged ops as data); per-block painting renders remote presence cursors as one more
decoration layer; `terminateComposition('externalEdit')` already defines
remote-edit-meets-local-composition. Three constraints are binding **now**:

- **Ops stay mechanically invertible** — guaranteed structurally: `AppliedChange` carries
  `docBefore`/`docAfter`, so an inverse is always derivable from the stream without any op
  carrying extra payload.
- **Block ids are UUIDs** (days 1–2, id generation): globally unique so replicas never collide;
  everything else already treats ids as opaque.
- **The snapshot `UndoManager` is package-private and replaceable.** Snapshot-restore would wipe
  concurrent remote edits, so collaborative undo must become op-based/selective — the public
  surface is only `undo()/redo()/canUndo/canRedo`, precisely so the manager can be swapped without
  API change.

Deliberately absent, each a real future project: convergence semantics (per-block text CRDT + tree
CRDT, or OT transforms), selective undo, offset rebasing generalized beyond the spellcheck
shifting machinery, and the network/presence layer (app-side). Two targets are distinguished on
purpose: **multi-device sync** (block-granularity merge over the change stream — comparatively
cheap) vs **same-block real-time co-editing** (the full CRDT/OT project).

## What survives from v2

| Piece | Fate | Change |
|---|---|---|
| `model/block.dart` (171) | kept | `<B>` → `String blockType` (D7) |
| `model/document.dart` (423) | kept | drop generics + the 4 global-offset members; + `idToFlatIndex` cache; `_allBlocks` + the map become **lazy `late final`s** (intermediate docs in op chains pay nothing — see Document §caches); tree ops, flatten, extractRange, id gen untouched |
| `editor/edit_operation.dart` (812) | **semantics kept, addressing rewritten** | behavioral semantics and tests survive; addressing/apply signature rewritten id-native (`blockId` ops, `Document? apply(doc, EditContext ctx)`, resolve-at-apply), absorbing the generic `apply<B>`/`as B`/`_recastBlock<B>` collapse into days 1–2; `SplitBlock` + `newBlockMetadata` via `EditContext` (the taskItem enum hardcode at :206 dies with D7); **`PasteBlocks` re-specced** (id-chained sibling insertion replacing the root-list/flat-index paths at :492-518; void-edge no-merge; tail-id result field deleted — ~0.5 day on the parallel-track clipboard item); **offset bounds guards on InsertText/DeleteText/ToggleStyle/SplitBlock + DeleteRange lower bound** (reject, not throw); **`RemoveBlock` last-block fallback** (G9); **`IndentBlock`/`OutdentBlock` gates via the shared `ctx.canIndent` predicate, rejection aborts the batch** (G13); + NEW `MoveBlock` (~60) |
| `editor/undo_manager.dart` (108) | kept | snapshot type `TextSelection` → `DocSelection` (composing never snapshotted/restored); + composition-scoped grouping (~20) |
| `editor/input_rule.dart` (550) | kept with **one contract** (the v2 pre-application interception contract cannot be driven by the G3 latch — IME §input rules): insert-pattern rules → post-state `tryTransform(docAfter, blockId, editedRange, schema)` with block-local `selectionAfter`; + declared `referencedInlineKeys`; enum literals → key-holder consts. ALL FIVE structural rules **deleted** into BlockDef policies (HeadingBackspace → `backspaceAtStart: convertToDefault`; ListItemBackspace/NestedBackspace → `outdentOrConvert`; EmptyListItem → `onSplitEmpty: convertToDefault`; CodeBlockEnter → `SplitPolicy.onEnter: insertLineBreak`), as is `DividerBackspaceRule` (void backspace owned by the controller — IME §G2). No rule-level interceptor contract ships (D13 — the only interceptor seam is the deferred queue-level pre-commit hook) |
| `editor/transaction.dart` (34) | kept, re-typed | `selectionAfter: TextSelection?` → `(String blockId, int offset)?` block-local caret; the controller resolves it to a `DocPosition` at commit; generic `apply<B>` collapses. Package-private in v3 (surface hygiene — a transaction is the committed batch record, no indices to go stale) |
| `editor/text_diff.dart` (78) | kept | reused once: web non-delta IME fallback frontend (squiggle shifting is op-driven) |
| `codec/*` (901) | kept, **de-genericized** | `MarkdownCodec<B extends Object>` is generic over `EditorSchema<B,Object,Object>`, has a `BlockType`-typed `standard()` factory, and compares directly against `BlockType.numberedList` — none of it compiles once the enums die. Folded into the days 1–2 sweep (~1–2 h mechanical); markdown remains the canonical clipboard format (open Q in D-doc, presumed yes) |
| `schema/*` (1257) | kept | de-genericized (B **and** S/E → String keys + holders), + `componentBuilder` (optional), `newBlockMetadata`, **declared `metadataKeys`**, `voidBackspace`, `semanticsBuilder`, `validate()`; the behavior booleans `isListLike`/`isHeading`/`splitInheritsType` (block_def.dart:19,21-22) are **deleted → named policies** `split: SplitPolicy` + `backspaceAtStart: BackspaceAtStartPolicy` (`isVoid` stays — a kind fact); the v2 constructor assert `!isVoid \|\| prefixBuilder != null` (block_def.dart:29-30) is **inverted** in the days 1–2 sweep (v3 voids render via components), and the sibling asserts over the deleted booleans (:31-34) die with them; `baseStyle`/`spacingBefore`/`spacingAfter`/`prefixBuilder` survive with stated consumers (`prefixBuilder` **re-signed** to `(TextBlock, GutterContext, TextStyle)` — Rendering §rebuild-skip) |
| `editor_controller.dart` (1986) | **rewritten** | the TextEditingController inheritance + linear offsets die (research: dies in any tier); gains the single-writer queue, `apply(List<EditOperation>)` + `EditContext` supply, void-endpoint normalization, missing-id/gate rejection policy, conveniences; **ported, not rediscovered:** composition-scoped undo (~:1519), `_typingStyles` carryover (:198-238, incl. the 178a568 reset fix), the inline-entity surface (`onInlineEntityTap`, `setLink`/`linkInfo` → `applyLink`/`removeLink`/`entityAt`, commit 09ea045), the **prefix-tap surface** (:1956-1965), `canUndo`/`canRedo` (:246-247), the optional `focusNode` pattern (widgets/bullet_editor.dart:25-89); + new `setDocument` + focus surface |
| `offset_mapper.dart` (257), `span_builder.dart` (229) | deleted | replaced by per-block components; `span_builder`'s `applyStyle` folding moves into the default text component |
| `widgets/bullet_editor.dart`, `editor_toolbar.dart` | rewritten / deferred to app | toolbar is an open question in requirements; treated as app-side at launch (the package supplies `activeStyles` + the formatting/entity APIs it needs) |

Net: ~4.3k LOC reused — most with mechanical edits, plus the **booked ~1-day rules
contract-split** (days 1–2 / 5–7; a half-day sweep would not cover the post-state port) and the
codec de-genericization folded into days 1–2; the ops file's reuse is semantic, not textual —
addressing and signatures are re-typed in place with behavior and tests surviving — and ~2.5k
deleted/rewritten; matching the research table's prediction.

## 20-day milestone plan with explicit cut line

Priority order per D11 + the flagged tension: when a day overruns, the lowest uncut item below the
line falls off the release; the date does not move. Discipline grafted from the selection-first
runner-up: **each gauntlet scenario is written as a test in the milestone that builds its layer**
(selection math as pure-Dart unit tests on days 1–4, IME traces as shadow-buffer tests on days
5–8, interactor scenarios as widget tests) — the traces are the regression suite, not
documentation.

**Device drip (amortizing the largest serial unknown):** from day 9 onward, every day ends with a
~20-minute scripted typing pass (the G1/G3/G4/G10 traces) on **one rotating physical device**, so
OEM keyboard surprises (risk R1, the register's only High-likelihood technical risk) surface
within a day of the code that caused them instead of all at once on day 15. The **full keyboard
matrix runs once at the day-9 gate itself** — Gboard, Samsung, SwiftKey, **Korean (Hangul — the
always-composing IME)**, iOS Japanese are part of the gate's pass criteria, and the gate script
includes the **undo-mid-Hangul immediate-recommit trace** (the post-terminate echo quarantine) and
the same-block tap-then-type trace. Day 15 is then a fix-and-verify buffer for accumulated
findings, not first contact.

**Parallel track (optional, AI-driven, in priority order):** from day 5 an AI-assisted track may
proceed while the maintainer's attention is on IME device behavior. It is **explicitly subordinate
to the day-9 IME gate**: abandon it instantly if the IME needs the attention (worst case equals
the serial plan). The order is **earliest-deadline-first over never-cut weight**: running the
touch core last, behind an item with explicit slack, would mean that in the likely branch where
the track runs slow or is abandoned for the IME (R1/R2 are the register's only High-likelihood
risks, so partial completion is the modal outcome) the largest never-cut chunk never builds in
parallel and days 11–13 revert to first construction of a surface super_editor needed 4.4k LOC for
— precisely what the track exists to prevent. The clipboard pipeline, by contrast, has two days of
slack on its only dependency edge (day 14 → day 16) and a fully budgeted day-14 fallback slot, so
it goes last:

1. **`mouse_interactor.dart`** — depends only on the day 3–4 geometry contract +
   `controller.setSelection`, not on the IME; its G5/G6 scenarios are independently
   widget-testable.
2. **The IME-independent core of `touch_interactor.dart`** — handles + viewport-predicate
   visibility, the `pointerRouter.addRoute` drag plumbing, grab-offset compensation, the
   opaque-handle exclusivity tests, the content-arena recognizers, the fallback-toolbar shell, and
   the "grab without move does not change selection" widget tests — all widget-testable without a
   device or an IME connection (tap merely *opens* the IME). Same dependency profile as the mouse
   track, so if AI capacity allows two concurrent items it may run alongside the mouse interactor
   from day 5; either way it is the plan's single largest never-cut chunk (1,050 LOC, G11) and
   never waits behind anything with slack. Days 11–13 then become **device integration, magnifier
   feel, and floating cursor** instead of first construction.
3. **The G12 clipboard/paste pipeline** (`copySelectionAsMarkdown`, `pasteMarkdown`, the
   re-specced `PasteBlocks` (~0.5 day), the policy-gated first-block merge, and the unit tests
   incl. paste-into-nested-child-bearing-item and image-first/last-edge) — the most
   parallelization-friendly item in the plan: pure model+codec work through the batch loop, every
   dependency complete by day 4, acceptance gate = pure-Dart tests with zero rendering/IME/gesture
   dependency. (The image type's codec/schema entry is registered on the track so the
   image-spanning copy test runs; if not, that one test waits for day-14 integration.) It starts
   whenever a slot opens; landing any time up to day 13 still pulls day 14's largest IME-unrelated
   chunk off the critical path and gives the day-14 → day-16 dependency edge (native-paste
   classification routes through this codec path) two days of slack — and if the track never
   reaches it, the day-14 fallback slot is already budgeted.

The frame-sequencing-sensitive autoscroll ticker stays on day 10, and the handle-autoscroll
coupling, magnifier polish, device integration, and `updateFloatingCursor` (a genuine IME-client
dependency) stay on days 10–13 regardless.

**Day-9 → day-10 overrun swap rule — displaces, never stacks (pre-agreed, recorded here because
the branch that triggers the swap is the same branch that most likely abandoned the parallel
track):** when the web diff fallback moves to day 10 (per the day-9 split below), day 10 does not
absorb it on top of its existing load. Instead: the web fallback + its gate take day 10;
mouse-interactor build/integration moves to day 11 with **cut-line item 5 pre-authorized**
(mouse-kind on mobile degrades to caret + drag-select — item 5 is already the days-11–13 heat
valve; note its savings are integration/test time, not build LOC, since shift/double/triple-click
code is needed for web regardless), keeping the never-cut touch block at 3 days. Independently and
in every branch, **link hover moves off day 10** — to day 14 when the parallel track ran, else
recorded as the first cut-line item-7 candidate. Without this rule, the overrun branch stacks the
web fallback + full mouse build + the day-10-pinned ticker + link work — two-plus days in one slot
— immediately upstream of the never-cut touch block, with R10's mitigations voided in exactly that
branch.

**Status — resolved at day 10 (parallel track NOT run):** the day-9 IME gate and its
device-testing consumed the full window through day 9 (the modal R1/R2 outcome this section
anticipated), so the optional parallel track never started. The conditionals below therefore
resolve to their *build / first-construction* branches: day 10 **builds** the mouse interactor
(desktop + web) rather than integrating it; days 11–13 are first construction of the touch
surface; and the G12 clipboard pipeline is built on day 14. The day-9 overrun swap did **not**
fire (the day-8 web fallback landed on schedule), so day 10 runs in its planned slot — cut-line
item 5 is **not** auto-pre-authorized.

| Days | Milestone | Gauntlet coverage |
|---|---|---|
| 1–2 | **Rewrite ops id-native** (`blockId` addressing + `Document? apply(doc, EditContext ctx)` + resolve-at-apply, absorbing the ops generic-collapse; offset bounds guards; `RemoveBlock` last-block fallback; op-level indent/outdent gates via `ctx.canIndent`); de-genericize model/schema **and rules/transaction/codec** (the booked sweep: `selectionAfter` re-typing to `(blockId, offset)`, key-holder pass incl. inline keys, `CodeBlockEnterRule` → `SplitPolicy.onEnter: insertLineBreak`, `DividerBackspaceRule` deletion, `newBlockMetadata` + **declared `metadataKeys`** + `voidBackspace` on BlockDef, **the `split`/`backspaceAtStart` policies replacing the `isListLike`/`isHeading`/`splitInheritsType` booleans (+ deleting their void asserts)**, **`prefixBuilder` re-signed to `(TextBlock, GutterContext, TextStyle)`**, **void/prefixBuilder constructor-assert inversion**, generic-collapse in `MarkdownCodec`); **input-rule contract split, part 1** (post-state `tryTransform` signatures + `referencedInlineKeys`); key holders; `validate()` (full assertion list); `idToFlatIndex` (+ both `Document` caches as **lazy `late final`s**); read-only lazy render of the **gauntlet fixture document** (every launch block kind incl. two images, a divider, 3-deep nesting, spacing, links + a 200-block lazy tail — see `v3-build-strategy.md`; exotics live in the skeleton, precluding v2's retrofit scar) (sliver + **public** default text component **rendering a real RichText child + link-span `TapGestureRecognizer`s with State-owned lifecycle** + registry) — **text reading semantics + heading flags + per-link tappable semantics land here for free**; test: paragraph-with-link semantics tree has a child node with `SemanticsAction.tap` | GATE-K, GATE-L skeleton, D4 text semantics, D3 link activation |
| 3–4 | Geometry contract over the child RenderParagraph (incl. midpoint void hit rule); tap-to-caret; caret painting; focus (**incl. the public surface: optional `focusNode`, `hasFocus`/`requestFocus`/`clearFocus`**); controller skeleton (ops/undo wired, single-writer queue, batch loop + `EditContext` supply + missing-id rejection + its unit tests, `setSelection` void normalization **+ offset clamping + gone-id rejection**, **`setDocument` + `canUndo`/`canRedo`** (~quarter day, thin wrappers), **group-indent + outdent all-or-nothing gates via the shared `canIndent` predicate + Tab/Shift-Tab tree-shape identity test + two-paragraphs-after-list-item test + mixed-depth Shift-Tab test + op-gate test (`apply([IndentBlock(firstSibling), IndentBlock(next)])` rejected, tree unchanged)**) | G13 invariant tests |
| 5–7 | **ImeService delta path**: `". "` sentinel, shadow buffer (text+selection+composing) + stale-delta guard + **post-terminate echo quarantine**, typing/backspace/Enter → Insert/Delete/Split/Merge, **G1 composite-deletion decomposition + composing guard (composite-while-composing fixture: `deleteSurroundingText`-shaped delta, post-apply composing non-empty → routed through `terminateComposition`, quarantine armed, no assert)**; `terminateComposition` choke point (+ **Android re-attach for every reason with a live connection**) + `connectionClosed`; **structural-while-composing divergence rule** (+ cross-block composing type-over trace test); composing-underline pass + composing-rect reporting; **input-rule run path** (latch with recorded editedRange, post-state run path, the controller split/merge paths implementing the `split` (incl. `onEnter`) /`backspaceAtStart` policies); composition-scoped undo (+ kana-undo trace test); **same-block tap-then-type trace test** ("hello" → tap before 'h' → 'x' → "xhello"). *(Parallel track: mouse_interactor, then the touch-interactor IME-independent core, then the G12 clipboard pipeline.)* | G1, G3, G7, G10 |
| 8 | **Web non-delta diff fallback**: diff frontend (`text_diff.dart`) over the same shadow-buffer + resolve-at-apply core through the same choke point, **incl. the composing mapping** (`TextEditingValue.composing` → ComposingState, −2 shift, block-local; composing-only updates = NonTextUpdate analogue, acknowledged into the shadow). **Exit criterion: Safari smoke test green INCLUDING the web CJK trace — Safari Japanese: compose, convert via candidate, commit, then a "# " rule fire on commit.** | R1/R7 mitigation real, G3-on-web |
| 9 | **Hard gate: "typing works on iOS + Android + web (web via the day-8 diff fallback)"** — pass criteria include the full keyboard matrix (Gboard/Samsung/SwiftKey/**Korean Hangul**/iOS Japanese/**Spanish + European dead keys incl. the iOS accent long-press popup — the v2 release scar; short-lived composing regions with non-CJK commit patterns**), the **undo-mid-Hangul immediate-recommit (quarantine) trace**, the **tap-to-another-block-mid-Hangul-then-type trace (fresh syllable, not held jamo — the all-reasons re-attach)**, the tap-then-type trace, and the **capped-selection type-over trace (select-all on a >32-block doc → type a letter → no spurious capitalization — validates the elided window's type-over-context rationale, §buffer serialization)**. Buffer/fix day. **Pre-agreed overrun split (displacing, see the swap rule above the table):** if days 5–7 ran over, day 9 gates iOS+Android delta typing only; the web fallback moves to day 10 (own gate there), mouse build/integration moves to day 11 with cut-line item 5 pre-authorized, and link hover defers per the swap rule — never stacked onto day 10. If the gate is red past day 11, the cut line executes immediately (items 1–4 cut up front) and the freed days fund the IME. Device drip starts. | go/no-go |
| 10 | Hardware keys (the **composing gate over ALL editing/navigation handlers, whitelist = Cmd/Ctrl+Z** *landed day 8 — pulled forward with the passive-while-composing consolidation; day 10 retains the full key MATRIX: ↑/↓ caret movement, Cmd+arrows, each new binding under the same gate*, **`MoveBlock` op + Alt+↑/↓** — D10 coverage); mouse-interactor **integration** (or build, if the parallel track was abandoned — and if the day-9 swap fired, this moves to day 11 per the displacement rule): drag, shift/double/triple click + `expandBase` (**+ its invalidation: stale-anchor test — triple-tap, queued-delta shortens block, shift-click → clamped, no OOB**), per-block highlight painting, shared post-frame autoscroll ticker **generalized to every ScrollNotification while a drag is active** (+ wheel-scroll-two-viewports-release test); up- and down-drag-across-image widget tests; **ordinal-renumber rebuild test**. (Link hover is day 14 / item-7 candidate per the swap rule; link activation shipped days 1–2 on the span recognizers; **mobile-pointer verification of the mouse-kind gestures → days 11–13, per the resolved-state note above the table**) | G5, G6, G13 |
| 11–13 | Mobile touch — **device integration of the parallel-track core, or first construction if it was abandoned**: long-press, handles (**viewport-predicate visibility, `HitTestBehavior.opaque` exclusivity + its two widget tests, null-geometry drag refusal**), magnifier, **pointer-route drag routing (`pointerRouter.addRoute`)**, **content-arena recognizers + their three widget tests (long-press-then-drift does not scroll; long-press-drag extends by word; plain touch drag scrolls) + the pinned `dragDevices` ScrollBehavior**, **grab-offset compensation**, handle autoscroll; **fallback selection toolbar (`ContextMenuController` + `AdaptiveTextSelectionToolbar`, controller-routed copy/cut/paste — never-cut; shares the handle-visibility anchor/offscreen tick)**; day 13: iOS **floating cursor** (within-block + edge handoff); **mobile-pointer (iPad trackpad / Android mouse) verification of the day-10 mouse-kind gestures (shift/double/triple-click + `expandBase`) — deferred here from day 10, which builds and widget-tests them desktop/web-first**. Three days, not two — this is super_editor's 4.4k-LOC surface cut to our subset, and it sits above the cut line | G11 |
| 14 | Block image + divider components; void selection + **void-endpoint range normalization + all-void-document delete test + click-image-then-type test**; structural backspace around voids (`voidBackspace` policies); image delete caret rules (incl. the last-block → empty-paragraph fallback); **image alt + checkbox toggle semantics + the prefix-tap surface (gutter rect registration, `onPrefixTap` default toggle, caret/IME suppression; widget test: tap checkbox → checked flips, selection unchanged, keyboard not summoned)**; **link hover cursor** (if the parallel track ran — else first item-7 cut candidate); clipboard **integration** (the G12 pipeline incl. the re-specced `PasteBlocks` + its nested-target and void-edge tests arrives from the parallel track; built here only if the track was abandoned) — toolbar paste buttons gain markdown fidelity | G2, G9, G12 |
| 15 | **Device-matrix fix-and-verify buffer** (accumulated drip findings): G4 case-(3) ordering, **post-terminate echo quarantine on Samsung/Gboard Korean (undo + post-split recommit)**, **tap-away-mid-Hangul re-attach**, rotation geometry, select-all window cap, **Korean `\n`-mid-composition (G10)**, **cross-block composing type-over (merge keeps composition)**, **iOS Japanese candidate-bar anchoring during multi-segment conversion**, **iPad hardware keyboard + Japanese multi-segment clause: ←/→ segment navigation and candidate selection complete with composing intact until commit (the all-handler gate)**, **dead-key drip rows: Spanish/German on Gboard + iOS, and the web diff-fallback dead-key path (the v2 Safari fix's scenario, carried over)** | G3, G4, G7, G10, G15 |
| 16 | iOS `SystemContextMenu` **native layer only** (the fallback toolbar shipped days 11–13): split item set (custom copy/cut/select-all → markdown path; native paste → delta-classified codec path, two days of slack behind it via the parallel-track pipeline), attachment-state check; tests: native copy of image-spanning and >32-block selections, native multi-block-markdown paste | G14, GATE-M, G12 |
| 17 | Spell check: coordinator with **serial fetch queue + per-block dirty set + bounded null-retry** (the Android channel is single-flight — specified here, not discovered on-device), op-driven range shifting, squiggles, suggestion menu (reuses the days-11–13 toolbar controller) | G8, GATE-S |
| 18 | **Semantics verification pass** (the static work landed days 1–2/14 — this is VoiceOver/TalkBack/screen-reader smoke verification + GATE-A hook wiring, never-cut); web: context-menu suppression, Safari IME polish pass (the fallback itself shipped day 8) — **the web-polish half is the plan's honest schedule flex** | D4 verification |
| 19–20 | Gauntlet regression days (scripted G1–G15 on all three platforms, **incl. the web CJK trace — Safari Japanese compose → convert → commit → "# " rule fire on commit**) + buffer | all |

**Cut line (lowest cut first):**
1. Spell-check **suggestion menu** (squiggles stay; tap does nothing) — day 17b
2. **Keyboard block-move** (`MoveBlock` + Alt+↑/↓) — cutting this is a **recorded scope decision
   against D10's launch-gap coverage**, not an accidental omission
3. Spell-check **squiggles** entirely (autocorrect is unaffected — it's the delta path; the
   coordinator seam ships dark so squiggles land in 0.x.1)
4. Web **polish** (Safari IME edge cases ride the day-8 diff fallback as-is; browser menu may
   appear). The fallback itself is NOT cuttable — D2 makes web typing launch scope
5. **Mouse-kind gestures on mobile** degrade to caret + drag-select only (no
   shift/double/triple-click) — a **recorded scope decision against D2's pointer-equipped
   iPad/Android coverage**; the per-kind dispatch itself is not cuttable. (Pre-authorized
   automatically by the day-9 → day-10 displacement rule; the savings are integration/test time —
   the click-gesture code itself is needed for web regardless)
6. Native iOS `SystemContextMenu` **native layer** (split item set, paste classification,
   attachment check; loses paste-without-prompt). The fallback toolbar is never-cut and already
   shipped with days 11–13, so this cut genuinely frees the full day-16 slot
7. **Link interaction** (hover cursor; app-level activation policy) — a **recorded scope decision
   against D3: links render, read, AND remain screen-reader-activatable via semantics** — the span
   `TapGestureRecognizer`s stay attached (semantics needs only a non-null handler) with the
   app-level callback no-oped; editing stays available app-side via
   `applyLink`/`removeLink`/`entityAt`/`apply`
8. Block images (degrades launch content to exact v2 parity — last resort)

Never cut (gates): lazy rendering, delta IME on mobile, the web diff fallback, mobile
handles/magnifier (incl. drag continuity), **the fallback selection toolbar
(`ContextMenuController` + `AdaptiveTextSelectionToolbar`, controller-routed copy/cut/paste — the
only selection UI on Android/web/iOS<16, D2)**, **static reading semantics (D4)**, the
component/geometry contract, schema validation.

## Risk register

| # | Risk | Likelihood | Mitigation |
|---|---|---|---|
| R1 | Android CJK/delta IME bugs (appflowy's known weak area, research §appflowy) | High | Sentinel + block-window keeps payloads tiny; stale-delta guard drops-and-resyncs rather than corrupts; `terminateComposition` handles always-composing IMEs (Korean) structurally, with the **post-terminate echo quarantine** as the IME-agnostic backstop and the **Android connection re-attach on every termination reason with a live connection** as the reliable composition-abandon mechanism (restartInput is advisory — both layers are needed); the day-8 diff fallback — a **composing-complete peer frontend** — can be flipped on per-platform; **daily device drip from day 9** (full matrix at the gate incl. the quarantine trace, rotating device after) surfaces OEM bugs within a day of cause instead of a day-15 cliff |
| R2 | Days 5–8 IME overrun (the genuinely hard part) | High | First in the plan, before any cuttable item; day-9 hard gate with pre-agreed triggers: the **displacing** web-gate split (web fallback → day 10, mouse → day 11 with item 5 pre-authorized, link hover deferred — never stacked) on small slips, cut-line execution if red past day 11; v2 diff experience reduces unknowns. An overrun reaching day 16 cannot take out launch-blocking selection UI — the fallback toolbar lives on days 11–13 and the never-cut list |
| R3 | Autoscroll + lazy drag-select edge cases (G5/G11) | Medium | Post-frame re-hit-test bounds wobble to one frame by construction; pointer-route drags are independent of widget mounting (the mechanism recognizers themselves use), so overlay unmounts can't kill them; handle pointer-downs are hit-test-opaque by stated invariant (no arena leak to the scrollable); final selection exact by construction |
| R4 | `SystemContextMenu` anchor/lifecycle across blocks (G14) | Medium | Clamp-to-viewport anchor + specified hide-on-fully-offscreen lifecycle (shared with handle visibility, built days 11–13 with the fallback toolbar); the native layer is item 6 on the cut line and genuinely frees its day |
| R5 | SpellCheckService behavior differences iOS vs Android (result granularity, locale) | Medium | Per-block scoping bounds blast radius; op-driven shifting is platform-independent; items 1/3 on cut line |
| R6 | Per-block rebuild perf on large docs (every keystroke notifies all *built* blocks) | Low | Immutable identity-skip + O(1) value-compared derived gutter inputs make non-target rebuilds O(compare); sliver keeps built count ~viewport; `findChildIndexCallback` keeps reconciliation O(1) |
| R7 | Web IME (Safari composition) regressions in the diff fallback | Medium | Fallback is a scheduled day-8 deliverable with a Safari smoke-test exit criterion **including the web CJK trace** (composing mapping is part of the deliverable, so composition is never invisible to the core), not an assumed parenthetical; direct v2 code + experience reuse (`text_diff.dart`); web *polish* is item 4 on cut line |
| R8 | Scroll-to estimate drift on image-heavy docs | Low | Measured-height cache self-corrects; only affects jump UX, never correctness |
| R9 | Mobile touch overrun despite the 3-day budget (super_editor calibration: ~4.4k LOC for the full surface) | Medium | The parallel track's **second** stage builds the IME-independent touch core (handles, routing, grab-offset, content-arena recognizers, toolbar shell) — **ordered ahead of the slack-backed clipboard item (earliest-deadline-first), and runnable concurrently with the mouse interactor from day 5 if AI capacity allows**, so a partially-completed track still delivers it; days 11–13 become integration rather than first construction — the largest never-cut chunk is not serialized behind the two High-likelihood risks NOR behind an item with two days of slack; polish degrades before function in this order: floating cursor → magnifier styling → handle animation; **day 18's web-polish half is the first schedule flex** (the static-semantics work does not live there — it lands with the components that own it and is never-cut) |
| R10 | Day-10/14 concentration upstream of the never-cut mobile block | Medium | The parallel track converts day 10 into integration + ticker AND pulls the G12 clipboard pipeline off day 14 (leaving it void components + void/range normalization + G9 + semantics/prefix-tap wiring), giving the day-14 → day-16 native-paste dependency edge two days of slack; the **day-9 → day-10 swap rule displaces rather than stacks** (web fallback → day 10, mouse → day 11 with item 5 pre-authorized, link hover off day 10 in every branch), so the overrun branch — the one where the track was most likely abandoned — does not concentrate 2–3 days of work upstream of the touch block; MoveBlock is small (snapshot undo + stable-id tree, comparable to Indent/Outdent) and is cut-line item 2 if the day runs hot |

## LOC estimate

| Area | LOC | Status |
|---|---|---|
| model + selection | ~720 | ~600 kept, ~140 new |
| ops/undo/rules/codec/diff | ~2,580 | ~2,480 kept in semantics (the ops addressing/apply signature is re-typed in place — id-native + `EditContext` — with behavior and tests surviving; **+ the booked ~1-day rules contract-split + codec de-genericization**; bounds guards, `RemoveBlock` fallback, op-level indent/outdent gates are point edits) + ~100 new (`MoveBlock`, guards, **PasteBlocks insertion rework + void-edge no-merge**) |
| schema (incl. default schema, builders wiring) | ~1,430 | ~1,250 kept + ~180 new (`validate()` incl. `referencedInlineKeys` + `metadataKeys`, `newBlockMetadata`, `voidBackspace`, `SplitPolicy`/`BackspaceAtStartPolicy` — LOC-neutral: tiny enums replacing the deleted booleans — optional `componentBuilder`) |
| controller (incl. queue + batch loop/`EditContext` supply + missing-id/gate rejection policy + void-endpoint normalization + `apply(ops)` escape hatch + typing-style carryover/activeStyles + entity APIs/conveniences + onPrefixTap + focus surface + setDocument + canUndo/canRedo) | ~850 | new (~250 of it ported v2 logic: typing styles, entity surface, prefix tap, undo getters, focusNode pattern; deleting the `EditIntent` mirror — ~14 classes + `toOp` bridging — buys back more than `EditContext` costs) |
| view (root, sliver, registry, public text component + 2 void components) | ~1,270 | new (RichText child + layered painters is LOC-neutral vs an owned TextPainter; incl. composing-underline pass + link-span recognizer lifecycle + gutter-rect registration) |
| input (IME 1,260 incl. diff fallback + terminateComposition/re-attach + echo quarantine + connectionClosed; keyboard 320; mouse 480 incl. link hover/Cmd-click; touch 1,050 incl. pointer routing, grab offset, floating cursor) | ~3,110 | new |
| spell | ~300 | new |
| menus (fallback toolbar + native split item set + paste classification) | ~300 | new (toolbar built days 11–13, native layer day 16) |
| **Total lib/src** | **~10,600** | **~4,330 kept / ~6,270 new** |

~6.3k new LOC over 20 AI-assisted days (~315/day of *hard* code, with the easy half front-loaded
by reuse and three parallel-track candidates — mouse interactor, touch core, clipboard pipeline —
explicitly schedulable off the maintainer's critical path) is aggressive but inside plausibility —
roughly half of flutter_quill's editor layer and a fraction of super_editor's 93k, because we
build exactly one selection model, one IME window strategy (two frontends, one core), two
interactors dispatched by pointer kind, and zero compatibility layers (D6). The budget
deliberately prices, up front, the correctness work the headline features depend on rather than
discovering it late: the echo quarantine and Android re-attach that R1's own Korean-IME scenario
requires, the rules contract-split the G3 latch cannot work without, the void-endpoint
normalization without which routine G5 drags corrupt the model, the diff frontend's composing
mapping that makes "two frontends, one core" actually true, the link-span recognizers without
which the claimed per-link semantics would not exist, the prefix-tap surface the onLinkTap
rationale equally demands, the PasteBlocks insertion rework the G12 promise requires, and the
app-integration members the launch app would otherwise discover missing on day 19. The id-native
design *shrinks* the estimate (−~50 net versus an id-to-index bridging design): deleting the
`EditIntent` mirror — ~14 classes plus their `toOp` bridging — buys back more than `EditContext`
and the op-level gates cost, because soundness here deletes a parallel vocabulary instead of
adding a layer.

## Appendix A — the 15-scenario gauntlet

The acceptance gauntlet the tournament candidates were judged against. Each scenario is a concrete
interaction that historically breaks per-block editors; the body sections above trace every one,
and each is booked as a real test in the milestone that builds its layer (days 1–20 table). Days
19–20 run all fifteen as a scripted regression pass on iOS, Android, and web.

- **G1 — Backspace at offset 0 of the first block (mobile IME).** The IME cannot report a deletion
  before the buffer start; with the `". "` sentinel it arrives as a deletion intersecting `[0,2)`
  and must become a structural backspace per the type's declared `backspaceAtStart` policy —
  `outdentOrConvert`/`convertToDefault`/`merge`. Includes the composite variants: an OEM
  delete-word/delete-to-line-start spanning sentinel AND real text must be decomposed (text
  deletion + structural consultation, one transaction), and a `deleteSurroundingText`-shaped
  deletion that preserves a live composing region must route its final push through
  `terminateComposition('structuralDelta')`. (IME §G1.)
- **G2 — Backspace at the start of a paragraph directly after a void block.** No text merge with a
  non-text target may ever be attempted; behavior is the void type's `BlockDef.voidBackspace`
  policy (`selectFirst` for images — Notion behavior; second backspace deletes — `immediateDelete`
  for dividers). One owner: the controller's structural-backspace path (v2's
  `DividerBackspaceRule` is deleted). (IME §G2.)
- **G3 — Japanese composition vs. an input rule.** Typing "# " inside a live composition must not
  fire the heading rule or invalidate the composing region; the composing underline must render;
  the rule is deferred via a latch carrying `(blockId, editedRange)` and fires on commit
  (including `NonTextUpdate` commits, and the web diff frontend's composing-cleared analogue). The
  hardware-key composing gate covers all editing/navigation handlers (Japanese hardware-keyboard
  clause navigation uses arrows). (IME §G3, §input rules; keyboard_service.)
- **G4 — Android autocorrect replacement racing Enter.** A replacement delta and a
  `\n`/`performAction(newline)` may arrive in one batch, sequentially, or out of order; all three
  cases must end with an uncorrupted document (sequential shadow application; queue serialization;
  stale-delta guard drops a post-split correction and re-pushes — worst case a lost correction,
  never corruption). No channel-ordering assumptions. (IME §G4.)
- **G5 — Drag-select across a block image into unlaid (lazy) blocks.** Midpoint void hit-testing
  makes the image's selection membership symmetric for upward and downward drags; autoscroll runs
  jumpTo → post-frame re-hit-test, so the extent is always computed against laid-out content;
  wheel/trackpad scroll mid-drag re-hit-tests on every `ScrollNotification`; final selection on
  release is exact by construction. (Rendering §void hit-testing; Gestures §mouse drag.)
- **G6 — Triple-click then shift-click in another block.** Triple-click selects the block and
  records `expandBase`; shift-click extends with paragraph-granularity anchoring (base = the end
  of the original chunk farthest from the click), cross-block free. `expandBase` has an
  invalidation/clamping lifecycle (queued IME deltas, undo, or structural ops shrinking/deleting
  the anchor degrade it to plain extension; `setSelection` clamps offsets and rejects gone ids).
  (Selection §G6.)
- **G7 — Undo immediately after a merge that happened mid-composition.** One undo restores the
  pre-composition `(Document, DocSelection)` snapshot; the push routes through
  `terminateComposition('undo')` (Android connection re-attach + one-batch echo quarantine armed,
  so an OEM IME re-committing its held syllable against the restored window is dropped); composing
  state is never snapshotted or resurrected. (Undo; IME §G7, §echo quarantine.)
- **G8 — Spell-check ranges after earlier edits in the same block.** Cached squiggle ranges are
  shifted op-by-op as each edit commits (insert-before shifts right, delete-after is unchanged,
  overlap drops the range), so multiple distinct edits inside one debounce window shift correctly;
  per-block scoping makes structural ops elsewhere harmless. (Spellcheck §G8.)
- **G9 — Deleting a selected block image.** Caret placement: end of the previous text block, else
  start of the next, else the document's single empty paragraph — backed by the relaxed
  `RemoveBlock` last-block fallback (swap in `Document.empty`'s paragraph; the document is never
  empty). The IME receives a re-serialized buffer for the new caret block. (Selection §G9;
  Operations.)
- **G10 — Enter mid task-item, including mid-composition.** `SplitBlock` keeps the original
  block's metadata (`checked`) and gives the new block the type's `newBlockMetadata` policy
  (`{checked: false}`). A `\n` arriving with a non-empty composing region (Korean is permanently
  composing) applies the split, detects window divergence from the shadow, and finishes through
  `terminateComposition('structuralDelta')` — one push, composed text committed where it stands;
  the convergent merge-via-replacement case keeps the composition and pushes nothing. (IME §G10,
  §structural-while-composing.)
- **G11 — Touch handle drag whose anchor leaves the viewport.** Handle pointer-downs are
  `HitTestBehavior.opaque` (never seed the scrollable's recognizer); the drag is owned by a
  pointer route (`pointerRouter.addRoute`) registered by the always-mounted interactor, so the
  overlay handle can unmount mid-drag without killing the gesture; grab-offset compensation
  anchors hit-testing; the magnifier follows the compensated finger point; handle visibility is a
  viewport predicate shared with the G14 tick. (Gestures §touch.)
- **G12 — Paste multi-block markdown into a nested list item.** Clipboard pipeline: markdown codec
  both ways; the re-specced `PasteBlocks` (id-chained sibling insertion — the natural form under
  id-native addressing — and void-edge no-merge) produces siblings at the item's depth with no
  void-block text grafting; the caret lands at the end of the last pasted block by its
  caller-known id; native iOS paste arrives as a classified insertion delta fed through the same
  codec path. (Operations §PasteBlocks; Context menus.)
- **G13 — Tab/Shift-Tab on a multi-block selection.** Group indent/outdent is all-or-nothing:
  top-level-within-selection members, resolved-target gating through the shared `canIndent`
  predicate (gate-pass ⇒ op-applies by construction), symmetric depth>0 outdent gate; id-native
  ops resolve at apply, so mid-transaction index staleness is unrepresentable;
  `IndentBlock`/`OutdentBlock` evaluate the same gate inside `apply` (failure rejects the whole
  batch), so the public escape hatch cannot partially apply. (Selection §G13; Operations.)
- **G14 — iOS `SystemContextMenu` anchored to a multi-block selection under scroll.** Anchor =
  bounding box of the laid-out selected blocks' rects, clamped to the viewport (lazy-safe); the
  menu hides when the visible-rect set empties and re-shows when any selected block re-enters
  (same tick as handle visibility); shown only against a genuinely attached `TextInputConnection`.
  (Context menus.)
- **G15 — Rotation/resize during an active composition.** Geometry callbacks
  (`setEditableSizeAndTransform`, `setCaretRect`, `setComposingRect`) are re-sent after layout
  settles; `setEditingState` is never called for pure geometry changes, so the composing region is
  preserved — the geometry reporter is a distinct object with no access to `setEditingState`. (IME
  §G15.)
