# Bullet Editor — API Design

**Status: Aspirational.** This is the target API design, not a spec. If implementation reveals that parts of this make things harder without real benefit, adjust or simplify. The architecture (editor-architecture-v2.md) is the foundation; this doc is the desired surface API on top of it.

## Design Goals

- Everything about a type in one place (rendering, parsing, codecs, input rules)
- Declarative schema — scan it and understand the whole editor
- Extensible — third parties can add block types, inline styles, and serialization formats
- Type-safe where it matters, concise where it doesn't

---

## Block Model

### Sealed base with two rendering paths

```dart
sealed class Block {
  String get type;
  String get id;
  List<Block> get children;
}

// Rendered as TextSpans in buildTextSpan()
class TextBlock extends Block {
  final TextBlockType blockType;
  final List<StyledSegment> segments;
}

// Rendered as WidgetSpan (placeholder char + widget)
class WidgetBlock extends Block {
  // Subclass for specific widget blocks
}
```

- `sealed` gives exhaustive matching — compiler forces handling both paths
- Third parties extend `TextBlock` or `WidgetBlock` (subtypes of sealed members can be in any library)
- No generic `CustomBlock` data bag — just subclass. Type safety > convenience.

---

## Schema as Configuration

The schema declares everything the editor supports. Each type bundles its behavior.

### Generic keys

The schema is generic on key types so users can use enums instead of strings. This gives type safety, IDE autocomplete, and exhaustive switch statements.

```dart
class EditorSchema<B, I> {
  final Map<B, BlockDef> blocks;
  final Map<I, InlineStyleDef> inlineStyles;
}

// User defines their types:
enum MyBlocks { paragraph, h1, h2, h3, listItem, task, codeBlock }
enum MyStyles { bold, italic, code, strikethrough, link }
```

When mixing with third-party enums, the key type widens to `Object`:

```dart
enum ThirdPartyBlocks { table, callout }

final schema = EditorSchema<Object, Object>(
  blocks: {
    ...builtInBlocks,                        // MyBlocks values
    ThirdPartyBlocks.table: BlockDef(...),   // third-party values
  },
)
```

### Full example

```dart
BulletEditor(
  schema: EditorSchema<MyBlocks, MyStyles>(
    blocks: {
      MyBlocks.paragraph: BlockDef(
        buildSpan: (block) => ParagraphRenderer(block),
        policies: BlockPolicies(
          canBeChild: true,
          canHaveChildren: false,
        ),
        codecs: {
          Format.markdown: BlockCodec(
            encode: (block) => block.text,
          ),
          Format.html: BlockCodec(
            encode: (block) => '<p>${block.toHtml()}</p>',
          ),
        },
      ),
      ...headingDefs(),  // factory for h1, h2, h3 — canBeChild: false
      MyBlocks.listItem: BlockDef(
        buildSpan: (block) => ListItemRenderer(block),
        policies: BlockPolicies(
          canBeChild: true,
          canHaveChildren: true,
          allowedChildren: {'listItem'},
          maxDepth: 6,
        ),
        inputRules: [prefixRule('- '), prefixRule('* '), prefixRule('+ ')],
        codecs: {
          Format.markdown: BlockCodec(encode: (block) => '- ${block.text}'),
          Format.html: BlockCodec(encode: (block) => '<li>${block.toHtml()}</li>'),
        },
      ),
      MyBlocks.task: BlockDef(
        buildSpan: (block) => TaskRenderer(block),  // includes checkbox widget
        policies: BlockPolicies(
          canBeChild: true,
          canHaveChildren: false,
        ),
        inputRules: [prefixRule('- [ ] '), prefixRule('- [x] ')],
        codecs: {
          Format.markdown: BlockCodec(
            encode: (block) => '- [${block.checked ? "x" : " "}] ${block.text}',
          ),
        },
      ),
      MyBlocks.codeBlock: BlockDef(
        buildSpan: (block) => CodeBlockRenderer(block),
        policies: BlockPolicies(
          canBeChild: false,
          canHaveChildren: false,
          allowedInlineStyles: {},  // no formatting inside code
        ),
        codecs: {
          Format.markdown: BlockCodec(encode: (block) => '```\n${block.text}\n```'),
        },
      ),
    },
    inlineStyles: {
      MyStyles.bold: InlineStyleDef(
        buildSpan: (text) => TextSpan(
          text: text,
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        codecs: {
          Format.markdown: InlineCodec(wrap: '**'),
          Format.html: InlineCodec(tag: 'strong'),
          Format.quill: InlineCodec(attr: {'bold': true}),
        },
      ),
      MyStyles.italic: InlineStyleDef(
        buildSpan: (text) => TextSpan(
          text: text,
          style: TextStyle(fontStyle: FontStyle.italic),
        ),
        codecs: {
          Format.markdown: InlineCodec(wrap: '*'),
          Format.html: InlineCodec(tag: 'em'),
        },
      ),
      MyStyles.code: InlineStyleDef(
        buildSpan: (text) => TextSpan(
          text: text,
          style: TextStyle(fontFamily: 'monospace', backgroundColor: Colors.grey[200]),
        ),
        codecs: {
          Format.markdown: InlineCodec(wrap: '`'),
          Format.html: InlineCodec(tag: 'code'),
        },
      ),
      MyStyles.strikethrough: InlineStyleDef(
        buildSpan: (text) => TextSpan(
          text: text,
          style: TextStyle(decoration: TextDecoration.lineThrough),
        ),
        codecs: {
          Format.markdown: InlineCodec(wrap: '~~'),
          Format.html: InlineCodec(tag: 'del'),
        },
      ),
      MyStyles.link: InlineStyleDef(
        buildSpan: (text, {data}) => TextSpan(
          text: text,
          style: TextStyle(decoration: TextDecoration.underline, color: Colors.blue),
          recognizer: TapGestureRecognizer()..onTap = () => launchUrl(data['url']),
        ),
        codecs: {
          // Links need full encode/decode functions — not a simple wrap
          Format.markdown: InlineCodec(
            encode: (text, data) => '[${text}](${data["url"]})',
            decode: (raw) => ..., // parse [text](url)
          ),
          Format.html: InlineCodec(
            encode: (text, data) => '<a href="${data["url"]}">${text}</a>',
          ),
        },
      ),
      MyStyles.mention: InlineStyleDef(
        buildSpan: (text, {data}) => WidgetSpan(
          child: MentionChip(user: data['user']),
        ),
        codecs: {
          Format.markdown: InlineCodec(
            encode: (text, data) => '@${data["user"]}',
          ),
        },
      ),
    },
  ),
)
```

### Factory helpers for repetitive types

```dart
Map<String, BlockDef> headingDefs() => {
  for (final level in [1, 2, 3])
    'h$level': BlockDef(
      buildSpan: (block) => HeadingRenderer(block, level: level),
      inputRule: prefixRule('${"#" * level} '),
      codecs: {
        Format.markdown: BlockCodec(
          encode: (block) => '${"#" * level} ${block.text}',
        ),
        Format.html: BlockCodec(
          encode: (block) => '<h$level>${block.toHtml()}</h$level>',
        ),
      },
    ),
};
```

---

## Serialization Formats

### Format type (open for extension)

```dart
class Format {
  static const markdown = Format('markdown');
  static const html = Format('html');
  static const json = Format('json');
  static const quill = Format('quill');

  final String name;
  const Format(this.name);
}
```

### Document-level encode/decode

```dart
// Encode — per-block, straightforward
final markdown = doc.encode(Format.markdown, schema);
final html = doc.encode(Format.html, schema);

// Decode — document-level parser, not per-block
final doc = DocumentModel.decode(markdownString, Format.markdown, schema);
```

### Decode is different from encode

Encoding is per-block — each block calls its codec's `encode()`. Simple aggregation.

Decoding is document-level — a format-specific parser reads the full input, determines block types from grammar (`# ` = h1, `- ` = list item), then calls per-block `decode()` to parse the content. Each `Format` needs a document-level parser:

```dart
abstract class FormatParser {
  DocumentModel parse(String input, EditorSchema schema);
}

class MarkdownParser implements FormatParser { ... }
class HtmlParser implements FormatParser { ... }
```

BlockDef codecs provide the per-type `decode` as a helper — the parser dispatches to them after identifying the block type.

---

## InlineStyleDef — Three categories

`buildSpan` returns `InlineSpan` (parent of both `TextSpan` and `WidgetSpan`), covering all cases:

1. **Style-only** (bold, italic, code) — returns `TextSpan` with a `TextStyle`
2. **Style + data** (links) — returns `TextSpan` with style + tap handler + URL data
3. **Inline widgets** (@mentions) — returns `WidgetSpan` with a custom widget

`InlineCodec` has shorthand for common cases and full functions for complex ones:

```dart
// Shorthand — symmetric wrapping token, single recognized form
InlineCodec(wrap: '**')

// Multiple recognized tokens, canonical encode
InlineCodec(
  tokens: ['**', '__'],              // parser recognizes both
  encode: (text) => '**$text**',     // canonical output
)

// HTML — multiple recognized tags
InlineCodec(
  tags: ['strong', 'b'],            // parser accepts both
  encode: (text) => '<strong>$text</strong>',  // canonical
)

// Full functions — for asymmetric/data-carrying formats
InlineCodec(
  encode: (text, data) => '[${text}](${data["url"]})',
  decode: (raw) => ...,
)
```

### Canonical encode vs permissive decode

Markdown has multiple valid delimiters for the same thing (`**`/`__` for bold, `-`/`*`/`+` for lists, `---`/`***`/`___` for HR, etc.). The principle:

- **Encode:** opinionated — one canonical form
- **Decode/parse:** permissive — accept all valid forms

This applies at both inline and block level:

```dart
BlockDef(
  name: 'listItem',
  inputRules: [prefixRule('- '), prefixRule('* '), prefixRule('+ ')],
  codecs: {
    Format.markdown: BlockCodec(
      tokens: ['- ', '* ', '+ '],    // parser recognizes all
      encode: (block) => '- ${block.text}',  // canonical output
    ),
  },
)
```

---

## Keyboard Shortcuts

Two levels: block-specific actions on BlockDef, global shortcuts on the editor.

### Block-specific key actions (on BlockDef)

Behavior that depends on the block type. Receives the block, cursor context, and editor. Return a transaction to handle, or null to fall through.

```dart
BlockDef(
  name: 'listItem',
  keyActions: {
    LogicalKeyboardKey.tab: (block, cursor, editor) => indent(block),
    LogicalKeyboardKey.enter: (block, cursor, editor) =>
      block.isEmpty ? convertToParagraph(block) : splitBlock(block),
    LogicalKeyboardKey.backspace: (block, cursor, editor) =>
      cursor.atBlockStart ? outdent(block) : null,  // null = fall through
  },
)

BlockDef(
  name: 'h1',
  keyActions: {
    LogicalKeyboardKey.enter: (block, cursor, editor) =>
      insertParagraphAfter(block),  // Enter on heading creates paragraph, not another heading
    LogicalKeyboardKey.backspace: (block, cursor, editor) =>
      cursor.atBlockStart ? convertToParagraph(block) : null,
  },
)
```

### Global shortcuts (on BulletEditor)

Format-agnostic actions that work regardless of block type.

```dart
BulletEditor(
  schema: ...,
  shortcuts: {
    SingleActivator(LogicalKeyboardKey.keyB, meta: true): toggleBold,
    SingleActivator(LogicalKeyboardKey.keyI, meta: true): toggleItalic,
    SingleActivator(LogicalKeyboardKey.keyZ, meta: true): undo,
    SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true): redo,
  },
)
```

Uses Flutter's built-in `Shortcuts` + `Actions` system.

### Resolution order

1. Block-level `keyActions` — checked first, most specific
2. Editor-level `shortcuts` — global formatting, undo/redo
3. TextField defaults — cursor movement, selection, copy/paste

First handler to return non-null wins. Unhandled keys fall through.

---

## Block Policies

Structural rules defined per block type. Enforced during schema validation in the edit pipeline — transactions that violate policies are rejected before commit.

```dart
class BlockPolicies {
  final bool canBeChild;                  // can this block be nested under another?
  final bool canHaveChildren;             // can this block contain child blocks?
  final Set<String>? allowedChildren;     // null = any, set = only these types
  final int? maxDepth;                    // max nesting depth, null = unlimited
  final Set<String>? allowedInlineStyles; // null = all, {} = none (code blocks)
}
```

| Policy | Type | Example |
|--------|------|---------|
| `canBeChild` | bool | Headings: false, list items: true |
| `canHaveChildren` | bool | Paragraphs: false, blockquotes: true |
| `allowedChildren` | Set? | null = any, `{'listItem'}` = only list items |
| `maxDepth` | int? | List items: 6, null = unlimited |
| `allowedInlineStyles` | Set? | null = all, `{}` = none (code blocks) |

### Policy-driven key actions

Key actions read policies instead of hardcoding rules. One generic action works for any block type:

```dart
// Generic indent — works for any block, policy decides if it's allowed
indent(block, cursor, editor) {
  final policy = schema.getBlockDef(block.type).policies;
  if (!policy.canBeChild) return null;           // heading? rejected
  if (block.depth >= (policy.maxDepth ?? 999)) return null;  // too deep? rejected
  return indentTransaction(block);
}
```

Adding a new block type with different nesting rules doesn't require new key actions — just set the right policies.

---

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Block base | `sealed` (TextBlock, WidgetBlock) | Exhaustive matching + extensible via subclassing |
| Custom blocks | Subclass, no data bag | Type safety > convenience |
| Type definitions | Schema-as-configuration (BlockDef, InlineStyleDef) | Everything in one place, declarative |
| Schema keys | Generic (`EditorSchema<B, I>`) | Enums for type safety + exhaustive switches, widens to Object for third-party mixing |
| Multi-format support | Per-type codecs keyed by Format | Adding types or formats is independent |
| Encode | Per-block, one canonical form | Each block knows how to encode itself |
| Decode | Document-level parser, permissive | Accept all valid delimiter variants |
| Inline rendering | `buildSpan → InlineSpan` | Covers TextSpan, WidgetSpan, data-carrying spans |
| Similar types | Factory helpers (headingDefs, etc.) | Reduce repetition without losing clarity |
| Format type | Open class, not enum | Third parties can add formats |
| Keyboard shortcuts | Block-level keyActions + editor-level shortcuts | Block-specific behavior stays on BlockDef, globals on editor |
| Resolution order | Block → editor → TextField defaults | Most specific handler wins, unhandled falls through |
| Block policies | Per-type on BlockDef | Rules are part of what defines a type, not separate config |
| Policy enforcement | Schema validation in pipeline | Reject invalid transactions before commit |

---

## Revisions from Implementation (Post Phase 7)

Changes based on actually building the editor through Phases 1–7.

### 1. Split inputRules from keyActions on BlockDef

The original design has `inputRules` on BlockDef. In practice, two distinct things got conflated under `InputRule`:

- **Text-pattern rules** (as-you-type): `PrefixBlockRule` fires when `"# "` is typed, `InlineWrapRule` fires when `**text**` is completed. These inspect the pending transaction's text content.
- **Key-action rules**: `ListItemBackspaceRule`, `NestedBackspaceRule`, `EmptyListItemRule` fire on specific key events (backspace, enter) in specific block contexts. These inspect the pending transaction's *operations* (MergeBlocks, SplitBlock), not text patterns.

These should be two separate fields on BlockDef:

```dart
BlockDef(
  // Text patterns — "as you type" transformations
  inputRules: [prefixRule('- ')],

  // Key actions — structural behavior for specific keys
  keyActions: {
    LogicalKeyboardKey.backspace: (block, cursor, editor) =>
      cursor.atBlockStart ? outdent(block) : null,
    LogicalKeyboardKey.enter: (block, cursor, editor) =>
      block.isEmpty ? convertToParagraph(block) : splitAndInheritType(block),
  },
)
```

### 2. BlockCodec.encode needs context

Our actual encoder needs sibling context (numbered list ordinals) and parent context (indentation depth). The original `encode: (block) => '- ${block.text}'` is insufficient.

```dart
class EncodeContext {
  final int depth;
  final int siblingIndex;       // position among siblings of same type
  final int siblingCount;       // total siblings of same type in run
  final BlockType? parentType;
}

BlockCodec(
  encode: (block, context) => '${context.indent}${context.siblingIndex + 1}. ${block.text}',
)
```

### 3. FormatParser owns newline semantics

Markdown's `\n` vs `\n\n` distinction (soft break vs paragraph break, tight vs loose lists) is parser grammar, not per-block logic. The `FormatParser` must own this. Each format has fundamentally different structure rules:

- **Markdown:** `\n\n` = paragraph break, `\n` within lists = continuation, indentation = nesting
- **HTML:** Tags define structure (`<p>`, `<ul><li>`), whitespace is insignificant
- **Quill Delta:** Flat list of ops, `\n` with attributes defines block boundaries
- **JSON:** Explicit tree structure, no ambiguity

### 4. Add metadataSchema to BlockDef

Task items use `metadata['checked']` but nothing declares this. For validation, serialization round-trips, and generic sync/persistence:

```dart
BlockDef(
  metadataSchema: {
    'checked': MetaField(type: bool, defaultValue: false),
  },
)
```

Not urgent for v1 but needed before generic sync support.

### 5. Markdown-specific codec considerations

Quirks the `MarkdownParser` must handle that don't fit the per-block codec model:

- **Setext vs ATX headings:** Decode both (`# H1` and `H1\n===`), encode only ATX
- **Multiple list markers:** Decode `-`, `*`, `+`; encode only `-`
- **Ordered list numbering:** Decode any digit (`1.`, `3.`, `42.`); encode correct ordinals
- **Fenced vs indented code blocks:** Decode both; encode only fenced
- **Tight vs loose lists:** Single `\n` vs `\n\n` between list items changes rendering. Our current codec always uses `\n\n`.
- **Bold/italic delimiter variants:** `**`/`__` for bold, `*`/`_` for italic. Decode all; encode `**` and `*`.

---

## Known Concerns

- **Complex blocks make BlockDef large.** For tables, extract codec/renderer into separate classes and reference them. BlockDef is the registry entry, not the implementation.
- **Format return types differ.** Markdown → String, JSON → Map, Quill → List<Delta>. May need generics or a `DocumentOutput` wrapper. Solve when adding JSON/Quill formats.
- **InlineCodec shorthand has limits.** `wrap: '**'` works for symmetric tokens. Links, images, footnotes need full functions. The shorthand + function escape hatch pattern handles this.
