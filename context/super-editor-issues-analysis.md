# super_editor Top Issues vs Our Architecture

Analysis of the most upvoted open issues on [super_editor](https://github.com/Flutter-Bounty-Hunters/super_editor) and how our bullet_editor architecture handles each.

---

## Free (inherited from TextField)

| Issue | 👍 | Why it's free |
|-------|-----|---------------|
| [#388](https://github.com/Flutter-Bounty-Hunters/super_editor/issues/388) Spell-check / auto-correct | 6 | TextField has Flutter's built-in `spellCheckConfiguration`. |
| [#743](https://github.com/Flutter-Bounty-Hunters/super_editor/issues/743) Korean text broken | 4 | super_editor IME bug. TextField handles CJK composition correctly. |
| [#492](https://github.com/Flutter-Bounty-Hunters/super_editor/issues/492) Korean language support | 4 | Same — TextField's IME handling works. |
| [#2266](https://github.com/Flutter-Bounty-Hunters/super_editor/issues/2266) Can't embed in ScrollView | 2 | Their custom SliverHybridStack broke embedding. TextField is a standard widget, embeddable anywhere. |
| [#2882](https://github.com/Flutter-Bounty-Hunters/super_editor/issues/2882) Web compatibility broken | 3 | Bug in their custom render objects. We use standard Flutter widgets. |
| [#2533](https://github.com/Flutter-Bounty-Hunters/super_editor/issues/2533) Long press paste on mobile | 2 | TextField handles this natively. |
| [#2617](https://github.com/Flutter-Bounty-Hunters/super_editor/issues/2617) CTRL+Arrow keys wrong on web | 1 | TextField handles keyboard shortcuts natively per platform. |

## Solved by design

| Issue | 👍 | How our architecture handles it |
|-------|-----|--------------------------------|
| [#67](https://github.com/Flutter-Bounty-Hunters/super_editor/issues/67) Undo/redo (SuperEditor) | 6 | Immutable model + invertible transactions with selectionBefore/After. |
| [#189](https://github.com/Flutter-Bounty-Hunters/super_editor/issues/189) Undo/redo (SuperTextField) | 7 | Same — transaction stack. Open in super_editor since 2021. |
| [#1830](https://github.com/Flutter-Bounty-Hunters/super_editor/issues/1830) JSON serialization | 3 | `toJson()`/`fromJson()` on every Block from day 1. |
| [#748](https://github.com/Flutter-Bounty-Hunters/super_editor/issues/748) Atomic commands / edit pipeline | — | Our transaction system with input rules. Single atomic edit, no split notifications. |

## Easy to build

| Issue | 👍 | Approach |
|-------|-----|---------|
| [#1](https://github.com/Flutter-Bounty-Hunters/super_editor/issues/1) HTML import/export | 9 | Another serializer on DocumentModel, same as markdown/JSON. Just a different output format. |
| [#736](https://github.com/Flutter-Bounty-Hunters/super_editor/issues/736) @mention / #hashtag popovers | 4 | Input rule detects trigger char, widget overlay shows popover. Clean separation. |
| [#2294](https://github.com/Flutter-Bounty-Hunters/super_editor/issues/2294) Image insertion | 3 | WidgetSpan blocks — `ImageBlock` as placeholder char + WidgetSpan. Already designed. |
| [#281](https://github.com/Flutter-Bounty-Hunters/super_editor/issues/281) Find and highlight words | 2 | Search block segments for text matches, apply highlight style in `buildTextSpan()`. |
| [#398](https://github.com/Flutter-Bounty-Hunters/super_editor/issues/398) Toolbar builders per platform | 2 | Toolbar is a standalone widget. Platform variants = different widget implementations. |

## Shared upstream issues

| Issue | 👍 | Notes |
|-------|-----|-------|
| [#395](https://github.com/Flutter-Bounty-Hunters/super_editor/issues/395) Cmd+V broken on Firefox | 2 | Flutter framework bug (Clipboard API). We'd hit this too. Not editor-specific. |

---

## Key takeaway

Of the top issues by votes: **7 are free** from using TextField, **4 are solved by our architecture**, **5 are easy features** to build, and **1 is an upstream Flutter bug**. The two highest-voted feature requests (undo/redo + spell-check) are respectively solved by design and free.
