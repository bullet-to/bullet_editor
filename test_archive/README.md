# v2 test archive (not run by `flutter test`)

Migration policy (see `docs/v3-build-strategy.md` §Test migration): keep
tests by what they assert, throw by what they touch, harvest scenarios when
throwing.

## adapt_later/ — port deliberately as each layer lands

| File | Ports when | Notes |
|---|---|---|
| `editor_controller_test.dart` (4,678) | days 3–8, command by command | The crown jewels — years of command-level edge cases. Assertions survive nearly verbatim; setups change (`TextSelection` + display offsets → `DocSelection`, enum keys → strings). |
| `undo_redo_test.dart` (375) | day 3–4 controller skeleton | Snapshot undo survives; add composition-scoped grouping cases (days 5–7). |
| `inline_entity_test.dart` (517) | day 3–4 entity APIs | Drop display-offset fields; entity resolution logic survives. |

## harvest/ — the hosting layer is deleted; the scenarios are not

| File | Scenario destination |
|---|---|
| `offset_translation_test.dart` (385) | Each case (caret after checkbox, selection across spacer) re-expresses as a caret-placement/gesture scenario against the day 3–4 geometry contract. |
| `span_builder_test.dart` (304) | Prefix/style-resolution cases → component widget tests (days 1–2 / 14). |
| `bullet_editor_test.dart` (513) | Tap/entity-hit cases → interactor widget tests (days 10–13). |

Delete each file here once its port/harvest lands.
