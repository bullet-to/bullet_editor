# v3 Requirements

Decisions for the v3 rewrite (single TextField → per-block architecture), recorded from Q&A on 2026-06-11. Research backing these is in `editor-architecture-v3-research.md`.

Status legend: **Launch** = must work in the first release. **Designed-for, deferred** = the architecture must support it without rework, but it ships later. **Open** = not yet decided.

---

## Decisions

### 1. Tables — designed-for, deferred
Editable-cell tables are the feature that justified the per-block architecture, but they do not ship in the first release. The selection model, node tree, and component contract must support nested editable nodes (a cell = ordinary paragraph node at a real path) from day one.

### 2. Platforms — iOS, Android, web at launch
All three production-quality in the first release. macOS/Windows/Linux not required at launch (desktop keyboard support largely falls out of the web work anyway). Consequences: mobile touch selection (handles, magnifier, long-press) and mobile IME correctness are launch scope, not deferrable; web brings browser-context-menu and Safari IME quirks (already familiar from v2).

### 3. Launch content — v2 baseline + block images
The current v2 block set carries over: paragraphs, headings, bullet/numbered/task lists, quotes, code blocks, dividers, links. New at launch: **block images** (full-width, atomic selection, delete-as-unit). Not selected for launch: image galleries/grids, inline images, inline entities beyond links.

### 4. Accessibility — broad but shallow at launch
Flutter gives reading semantics nearly free (blocks render as `RichText` → static text semantics); ship that done properly at launch. Editing semantics (`isTextField`, `setSelection`, cursor-movement actions that VoiceOver/TalkBack drive) are NOT free in a custom editor — these are deferred, but the block component contract must reserve the hooks so per-block editing semantics can be added later without rearchitecting.

### 5. Document scale — lazy rendering at launch
Lazy/virtualized top-level block rendering from day one ("lazy unless it's very hard" — assessment: moderate in tier 3, since selection painting is per-block and IME only needs the caret rect; the cost is scroll plumbing — height estimation for jump-to-position, autoscroll during drag-select). No public API may assume all blocks have geometry.

### 6. Consumers — own app(s) only, break freely
No external compatibility obligations. v3 carries no shims, no deprecation cycle, no source-compat constraints. Migration is documented for ourselves only.

### 7. Type keys — drop the `<B, S, E>` generics
String type-keys + registry (appflowy-style), with **startup schema validation** replacing enum exhaustiveness as the "don't forget an item" guarantee: assert every registered block type has a component builder, codec entry, and policies. Const key holders (e.g. `ParagraphKeys.type`) for typo-safety. Rationale: in v3 nothing switches over block types — everything is a registry lookup — and open keys are what make third-party/structural block types (table, tableCell, gallery) clean.

### 8. Spell check & autocorrect — both at launch
Typing on mobile must feel native on day one. Autocorrect arrives through the IME delta path (a correctness bar on the IME layer). Spell check requires explicit work: `SpellCheckService` integration, squiggle rendering, suggestion menu (iOS/Android only).

### 9. v2 policy during the rewrite — hard stop
No v2 work at all, not even bugfixes unless the app is blocked. Maximum v3 velocity. (Implication: the strut-disabled image spike is not shipped to users; it may still be run as a throwaway experiment if it informs v3.)

### 10. Block drag-reorder — designed-for, deferred
Notion-style drag handle (grip to reorder, with children following) ships post-launch. Gesture layer and block chrome reserve room for it (hover affordance, drop indicators); keyboard-based move can cover the gap at launch.

### 11. Appetite — 20 days
First release by end of June 2026, AI-assisted development. This is a constraint, not an estimate: when something runs long, scope gets cut against the priority order in the implementation plan, not the date.

### 12. iOS context menus — native at launch
`SystemContextMenu` (iOS 16+) for the real UIKit edit menu — avoids the paste-permission popup and gets system features (Writing Tools). Flutter-drawn `AdaptiveTextSelectionToolbar` as the fallback below iOS 16 and on other platforms.

### 13. Extensibility surface — schema + change stream; interceptors deferred *(added 2026-06-11)*
Third-party **custom blocks are an explicit goal** (with custom inline styles/entities alongside). The plugin surface is two-fold and nothing more at launch: (a) **content extensions** via the schema registry — one `BlockDef`/`InlineStyleDef`/`InlineEntityDef` under a string key, checked by `validate()`, with the public default text component covering text-like blocks; (b) **reactions** via the controller's typed change stream — subscribe to applied transactions, enqueue ops in response (autosave, linkify, ToC panels, sync). **Interceptors** (pre-commit veto/transform: read-only regions, paste filters) are deliberately not built; if ever needed they are one seam — a pre-commit hook on the single-writer queue. **UI chrome** (toolbars, slash menus) is not a plugin concept: it's app-side widgets on the public API. See architecture §Extensibility surface.

### 14. Collaboration — designed-for, deferred *(added 2026-06-11)*
No convergence work in v3 (no OT/CRDT, no selective undo, no presence). But the substrate must not foreclose it; three constraints are binding now: (a) **ops stay mechanically invertible** — `AppliedChange` carries `docBefore`/`docAfter`, so inverses are always derivable from the stream; (b) **block ids are globally unique (UUIDs)** so ids never collide across replicas; (c) **the snapshot `UndoManager` stays package-private and replaceable** — only `undo()/redo()/canUndo/canRedo` are public, because collaborative undo must be op-based/selective and snapshot-restore would wipe concurrent edits. Two future targets, distinguished: multi-device sync (block-granularity merge over the change stream — comparatively cheap) vs same-block real-time co-editing (the full CRDT/OT project). See architecture §Collaboration readiness.

---

## ⚠ Flagged tension

Decisions 2 + 5 + 8 + 12 (three platforms, lazy rendering, spellcheck, native menus) against decision 11 (20 days) is a very tight fit — this combination is months of work in conventional terms. The implementation plan must therefore define an explicit **cut line**: a priority order over the launch scope such that slipping items fall off the release rather than moving the date. Suggested for the plan to resolve: which of {spellcheck squiggles, native iOS menu, web polish} are first against the wall.

## Open questions (not yet asked/decided)

- Mobile formatting toolbar (above-keyboard) — carry over v2's `editor_toolbar`, redesign, or out of scope for the package (app-side concern)?
- Markdown codec remains the canonical serialization and clipboard format? (v2 principle; presumed carried over, not explicitly re-decided.)
- Cross-cell selection behavior when tables eventually land (appflowy punts — whole-table selection for ranges; accept the same?)
- Galleries / inline images: designed-for-deferred or re-evaluate after launch?
- Scribble / stylus handwriting (iPad): explicitly out, or designed-for?
- ~~Right-to-left text and BiDi: launch bar or debt?~~ **Decided: launch.** Per-block text direction detection + RTL alignment + bidi mixing. IME input already works for Arabic/Hebrew (direct insertion, no composition); this is rendering/layout only.
