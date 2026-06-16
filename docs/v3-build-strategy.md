# v3 Build Strategy

How to build the architecture in `editor-architecture-v3.md` without repeating v2's two
process failures. Written 2026-06-11; companion to the 20-day plan in the architecture doc
(which owns day-by-day sequencing — this doc owns *method*: shape of the work, human
checkpoints, the dev harness, and test migration).

## The two v2 scars, and the one root cause

1. **IME shipped unexercised** — Spanish-keyboard users (dead keys: `´` + `e` → `é` runs
   through composing regions) hit breakage only after release.
2. **Exotic blocks came last** — image blocks and per-block spacing were attempted after
   everything else was built, and only then exposed architectural limits (the strut clamp,
   sentinel spacing).

Same root cause: **the riskiest architectural constraints were exercised last.** Risk order
and build order were inverted — easy/common things first, hard/exotic things last, so
discoveries arrived when they were most expensive. The whole strategy below is the inversion
of that inversion.

## Shape of the work: walking skeleton, then risk-ordered vertical slices

Neither pure breadth nor pure slices — a specific mixture:

- **Days 1–2: a walking skeleton (breadth, deliberately shallow).** One thin end-to-end
  spine: document in → lazy block list → components render → geometry registers → selection
  paints. Critically, the skeleton is **broad across block kinds, not just layers**: it
  renders the *gauntlet fixture document* (below) from the first day, which means an image
  block, a divider, nested lists, per-block spacing, and links exist in the system before
  any feature is deep. v2's scar #2 is structurally impossible to repeat if the exotic
  blocks are in the skeleton — every subsequent slice (selection, IME, gestures) must
  handle voids and spacing *as it's built*, not retrofitted.
- **Days 3–15: vertical slices in architectural-risk order, not product order.** The 20-day
  plan already encodes this: IME is the deepest unknown, so it goes first among slices
  (days 5–9) and hits a hard go/no-go gate on real devices at day 9 — before mobile
  gestures, before spellcheck, before anything cuttable. Each slice goes *all the way down*
  (model → ops → render → platform) for a narrow capability, because architecture problems
  live at the bottom of slices, never in breadth.
- **Days 16–20: breadth again (polish, integration, regression).** Once no slice has moved
  the architecture for several days, finish wide.

**The gauntlet fixture document** (`test/fixtures/gauntlet_doc.dart`, built day 1): one
canonical document containing every launch block type — paragraphs, h1/h3, bullet + numbered
+ task lists nested 3 deep, a blockquote, a code block, a divider, **two image blocks**
(one between paragraphs, one first-in-document), links mid-paragraph, blocks with
`spacingBefore/After`, an empty paragraph, and a 200-block tail for lazy testing. Every
widget test renders it; the dev harness loads it by default; the day-19 regression walks
all 15 gauntlet scenarios against it. It is the standing answer to "did we build the easy
80% and defer the hard 20%."

**Edge-case discovery protocol** ("architecture develops as you discover edge cases"):
when a discovery contradicts the architecture doc, the sequence is fixed — (1) write the
failing scenario into Appendix A as a new G# with a repro, (2) amend the architecture doc
(the way the six post-tournament amendments were done — doc first, code second), (3) then
fix the code. Cost: minutes. Benefit: the doc stays true, and an edge case found once is a
regression test forever. Discoveries that *don't* contradict the doc just become tests.

## IME: the Spanish-keyboard scar, specifically

The architecture already treats IME as the centerpiece (delta path days 5–7, day-9 device
gate). Two strategy-level additions:

- **Dead keys join the keyboard matrix** (amended into the plan's day-9 gate and day-15
  rows): Spanish/German/French dead-key input on iOS and Android, the iOS accent long-press
  popup, and the macOS/web dead-key path through the diff fallback (v2 already fixed a
  Safari dead-key bug — that scenario carries over as a web matrix row). Dead keys are
  *short-lived* composing regions with different commit patterns from CJK; they're cheap to
  test and they are the exact v2 failure.
- **Record-and-replay deltas.** The dev harness (below) logs every `TextEditingDelta`
  batch + the shadow-buffer state around it. A misbehaving keyboard session on any device
  becomes a JSON capture that replays as a unit test against `ImeService` with a fake
  platform channel. This converts scar #1's failure mode ("works on my keyboard") into a
  growing corpus of real-keyboard traces — Samsung Korean, Gboard Spanish, SwiftKey
  swipe — that runs in CI forever, no device required.

## Human checkpoints: feel-gates, not calendar intervals

Tests verify correctness; they cannot verify *feel* (caret rhythm, selection weight,
keyboard bounce, scroll behavior). You come in when a new feel-surface first exists — six
checkpoints, each with specific questions, ~20–30 minutes each:

| # | When | You verify | Device |
|---|------|-----------|--------|
| 1 | end day 2 | Gauntlet doc renders right: spacing, gutters, images, nesting. Tap places caret sanely. The harness itself works. | desktop |
| 2 | end day 4 | First typing feel: hardware-key editing on the skeleton, Enter/backspace block behavior matches v2 muscle memory. | desktop |
| 3 | **day 9 — the gate** | On-device typing: **your Spanish keyboard scenario personally**, plus autocorrect feel, Korean if you can. This checkpoint is already the plan's go/no-go; your session is part of the pass criteria. | iPhone + Android |
| 4 | end day 13 | Mobile selection UX: handles, magnifier, long-press, toolbar position. The least testable, most feel-heavy surface in the project. | iPhone + Android |
| 5 | end day 16 | Images + clipboard vertical: paste markdown with images, copy across an image, drag-select over voids. (Scar #2's territory, fully assembled.) | desktop + phone |
| 6 | days 19–20 | Integration into your app; full gauntlet walk; release call. | all three |

Two rules: a checkpoint failure becomes a written G#-style scenario before it's fixed (so
your feel-findings turn into regression tests, same protocol as above); and between
checkpoints you stay out — the tests and the gate criteria are the watchdogs, and pulling
you in ad hoc burns the benefit of having them.

## The dev harness (the v2 "node tree" example, upgraded to an inspector)

Built **days 1–2 alongside the skeleton** — it is the vehicle for every checkpoint and the
debugging surface for the whole build. `example/lib/inspector.dart`: editor on the left,
tabbed panes on the right:

1. **Document tree** — live block tree: ids (short-form), types, depth, metadata, segment
   styles. (The v2 pane that "was very helpful," ported.)
2. **Selection + composing** — `DocSelection` endpoints live, `ComposingState`, active
   styles, the pending typing-style set.
3. **IME window** — the shadow buffer as the engine sees it (sentinel visible), last pushed
   `TextEditingValue`, last received delta batch, last `terminateComposition` reason +
   quarantine state. This pane is why IME bugs get diagnosed in minutes instead of days.
4. **Change stream** — scrolling log of `AppliedChange`s: source tag, ops, undo grouping.
   Doubles as the demo that the stream contract works.
5. **Perf** — per-block rebuild counters (validates rebuild-skip), laid-out block count
   (validates laziness against the 200-block tail).
6. **Record** — start/stop delta recording → JSON to disk for the replay corpus.

Panes 1–2 are a day; panes 3–6 are each ~half a day and land with the subsystem they
inspect (pane 3 with days 5–7, pane 4 with the stream, etc.). The harness is also the
honest answer to "how do I check without reading 10k LOC": every checkpoint above is "open
the inspector, do X, watch pane Y."

## Test migration: keep / adapt / throw, by what they assert

v2 has ~11.9k test LOC in 15 files. Rule: **keep tests by what they assert (behavior of
surviving layers), throw by what they touch (deleted layers), and when throwing, harvest
the scenario** — every weird test case exists because something broke once; the scenario
often survives the layer that hosted it.

| v2 test file (LOC) | Verdict | Why / what changes |
|---|---|---|
| markdown_codec (1,279) + commonmark_roundtrip (524) + codec_types (179) | **KEEP** | Renderer-independent gold. De-genericize keys only. Runs green from day 2. |
| document (460) + block_policies (194) | **KEEP** | Model survives; de-genericize. |
| text_diff (91) | **KEEP** | Powers the web IME fallback now. |
| editor_schema (424) | **ADAPT** | Schema survives; add `validate()` cases, policy fields (SplitPolicy/BackspaceAtStart), drop the boolean-flag asserts. |
| editor_controller (4,678) | **ADAPT — the crown jewels** | Years of command-level edge cases (toggle/indent/split/merge/entity behaviors). Assertions survive nearly verbatim; *setups* change: `TextSelection` + display offsets → `DocSelection`, enum keys → strings. Port deliberately across days 3–8 as each command lands — this file is the regression net for the surviving 4.3k LOC. |
| transaction (1,046) | **ADAPT** | Op behavioral expectations survive; op construction rewrites to id-native + `EditContext`. |
| input_rule (956) | **ADAPT** | Contract split (post-state tryTransform vs interceptors); pattern cases survive, plumbing changes. |
| undo_redo (375) | **ADAPT** | Snapshot undo survives; add composition-scoped grouping cases. |
| inline_entity (517) | **ADAPT** | Drop display-offset fields; entity resolution logic survives. |
| offset_translation (385) | **THROW + HARVEST** | Tests the deleted sentinel/offset-mapper layer. Harvest: each case (caret after checkbox, selection across spacer) re-expresses as a caret-placement/gesture scenario in the new geometry. |
| span_builder (304) | **THROW + HARVEST** | Tests the deleted span tree. Harvest: prefix/style-resolution cases → component widget tests. |
| bullet_editor widget (513) | **THROW + HARVEST** | TextField-specific. Harvest: tap/entity-hit cases → interactor tests. |

Net: ~5.5k LOC keep/adapt with mechanical changes, ~4.7k adapt-with-care (mostly the
controller file), ~1.2k throw with scenario harvest. New-test obligations are already
specified per-section in the architecture doc (the shadow-buffer suite, gauntlet traces,
matrix rows) — the fixture document and the delta-replay corpus are this doc's additions.
