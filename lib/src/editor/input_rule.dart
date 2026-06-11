import 'package:flutter/services.dart' show TextRange;

import '../model/block.dart';
import '../model/doc_selection.dart';
import '../model/document.dart';
import '../schema/editor_schema.dart';
import 'edit_operation.dart';

/// The outcome of an input rule: follow-up operations plus the selection to
/// land on after they apply.
class InputRuleOutcome {
  const InputRuleOutcome({required this.operations, this.selectionAfter});

  final List<EditOperation> operations;
  final DocSelection? selectionAfter;
}

/// Base type for input rules, registered on block defs / inline defs and
/// collected by the schema.
///
/// The contract is split (architecture §input rules):
/// - [PatternInputRule] — insert-pattern rules (markdown shortcuts). Run
///   AFTER an insertion has applied, against the committed text.
/// - [StructuralInputRule] — pre-application interceptors for structural
///   triggers (Enter, backspace-at-start). The escape hatch for behavior the
///   named BlockDef policies can't express; consulted first from the
///   controller's split/merge paths.
abstract class InputRule {
  const InputRule();

  /// Inline style/entity keys this rule's outcome can reference. Declared,
  /// not introspected — `EditorSchema.validate()` asserts every declared key
  /// is registered.
  Set<Object> get referencedInlineKeys => const {};
}

/// An insert-pattern rule: examines the committed text of [blockId] in the
/// post-edit document and may emit follow-up operations (which run through
/// the same batch loop as any other edit).
abstract class PatternInputRule extends InputRule {
  const PatternInputRule();

  /// [editedRange] is the block-local range the insertion covered.
  /// Return null to pass.
  InputRuleOutcome? tryTransform(
    Document docAfter,
    String blockId,
    TextRange editedRange,
    EditorSchema schema,
  );
}

/// What structural event a [StructuralInputRule] is being consulted about.
enum StructuralTriggerKind {
  /// Enter at (blockId, offset).
  split,

  /// Backspace with the caret at offset 0 of blockId.
  backspaceAtStart,
}

/// A structural trigger passed to interceptors before the controller's
/// standard policy behavior runs.
class StructuralTrigger {
  const StructuralTrigger.split(this.blockId, this.offset)
    : kind = StructuralTriggerKind.split;

  const StructuralTrigger.backspaceAtStart(this.blockId)
    : kind = StructuralTriggerKind.backspaceAtStart,
      offset = 0;

  final StructuralTriggerKind kind;
  final String blockId;
  final int offset;
}

/// A pre-application structural interceptor — the escape hatch consulted
/// first from the controller's split/merge paths, before the standard
/// `split`/`backspaceAtStart` BlockDef policies.
///
/// Return an outcome to REPLACE the standard behavior, or null to let the
/// policies run.
abstract class StructuralInputRule extends InputRule {
  const StructuralInputRule();

  InputRuleOutcome? intercept(
    StructuralTrigger trigger,
    Document doc,
    EditorSchema schema,
  );
}

/// Detects a wrap-delimiter pattern (e.g. `**text**`, `*text*`, `~~text~~`)
/// completed by the latest insertion and converts it to the corresponding
/// inline style.
class InlineWrapRule extends PatternInputRule {
  InlineWrapRule(this.delimiter, this.style, {RegExp? pattern})
    : _pattern =
          pattern ??
          RegExp('${RegExp.escape(delimiter)}(.+?)${RegExp.escape(delimiter)}');

  final String delimiter;
  final Object style;
  final RegExp _pattern;

  @override
  Set<Object> get referencedInlineKeys => {style};

  @override
  InputRuleOutcome? tryTransform(
    Document docAfter,
    String blockId,
    TextRange editedRange,
    EditorSchema schema,
  ) {
    final block = docAfter.blockById(blockId);
    if (block == null) return null;
    final text = block.plainText;
    final delimLen = delimiter.length;

    final match = _pattern
        .allMatches(text)
        .cast<RegExpMatch?>()
        .firstWhere((m) => m!.end == editedRange.end, orElse: () => null);
    if (match == null) return null;

    final fullMatchStart = match.start;
    final innerText = match.group(1)!;
    final innerEnd = fullMatchStart + delimLen + innerText.length;
    final caret = fullMatchStart + innerText.length;

    return InputRuleOutcome(
      operations: [
        DeleteText(blockId, innerEnd, delimLen), // remove closing delimiter
        DeleteText(
          blockId,
          fullMatchStart,
          delimLen,
        ), // remove opening delimiter
        ToggleStyle(blockId, fullMatchStart, caret, style),
      ],
      selectionAfter: DocSelection.collapsed(DocPosition(blockId, caret)),
    );
  }
}

/// Convenience constructors for common inline wrap rules.
/// Order matters: register BoldWrapRule before ItalicWrapRule so `**` is
/// checked before `*`.
class BoldWrapRule extends InlineWrapRule {
  BoldWrapRule() : super('**', InlineStyleKeys.bold);
}

class ItalicWrapRule extends InlineWrapRule {
  ItalicWrapRule()
    : super(
        '*',
        InlineStyleKeys.italic,
        pattern: RegExp(r'(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)'),
      );
}

class StrikethroughWrapRule extends InlineWrapRule {
  StrikethroughWrapRule() : super('~~', InlineStyleKeys.strikethrough);
}

/// Detects `[text](url)` typed inline and converts to a link.
///
/// Fires when the user types the closing `)` that completes the pattern.
/// Strips the markdown syntax, applies the link style, and sets the URL
/// attribute on the resulting text.
class LinkWrapRule extends PatternInputRule {
  static final _pattern = RegExp(r'\[([^\]]+)\]\(([^)]+)\)');

  @override
  Set<Object> get referencedInlineKeys => {InlineEntityKeys.link};

  @override
  InputRuleOutcome? tryTransform(
    Document docAfter,
    String blockId,
    TextRange editedRange,
    EditorSchema schema,
  ) {
    final block = docAfter.blockById(blockId);
    if (block == null) return null;
    final text = block.plainText;
    if (editedRange.end < 1 ||
        editedRange.end > text.length ||
        text[editedRange.end - 1] != ')') {
      return null;
    }

    final match = _pattern
        .allMatches(text)
        .cast<RegExpMatch?>()
        .firstWhere((m) => m!.end == editedRange.end, orElse: () => null);
    if (match == null) return null;

    final linkText = match.group(1)!;
    final url = match.group(2)!;
    final fullMatchStart = match.start;
    final fullMatchLength = match.end - match.start;
    final caret = fullMatchStart + linkText.length;

    return InputRuleOutcome(
      operations: [
        // Delete the entire [text](url) and replace with just the text.
        DeleteText(blockId, fullMatchStart, fullMatchLength),
        InsertText(
          blockId,
          fullMatchStart,
          linkText,
          styles: {InlineEntityKeys.link},
          attributes: {InlineEntityKeys.linkUrl: url},
        ),
      ],
      selectionAfter: DocSelection.collapsed(DocPosition(blockId, caret)),
    );
  }
}

/// Detects a prefix (e.g. "# ", "- ") typed at the start of a default-type
/// block and converts the block to [targetType].
///
/// Fires when the user types a space after the prefix character at position 0.
class PrefixBlockRule extends PatternInputRule {
  const PrefixBlockRule(this.prefix, this.targetType);

  /// The prefix before the space (e.g. "#", "-").
  final String prefix;
  final String targetType;

  @override
  InputRuleOutcome? tryTransform(
    Document docAfter,
    String blockId,
    TextRange editedRange,
    EditorSchema schema,
  ) {
    final block = docAfter.blockById(blockId);
    if (block == null) return null;
    final text = block.plainText;

    // The edit must be exactly the space typed right after the prefix.
    if (editedRange.start != prefix.length ||
        editedRange.end != prefix.length + 1) {
      return null;
    }
    if (editedRange.end > text.length ||
        text.substring(editedRange.start, editedRange.end) != ' ') {
      return null;
    }

    final fullPrefix = '$prefix ';
    if (!text.startsWith(fullPrefix) ||
        block.blockType != schema.defaultBlockType) {
      return null;
    }

    return InputRuleOutcome(
      operations: [
        DeleteText(blockId, 0, fullPrefix.length),
        ChangeBlockType(blockId, targetType),
      ],
      selectionAfter: DocSelection.collapsed(DocPosition(blockId, 0)),
    );
  }
}

/// Convenience constructors for common prefix rules.
class HeadingRule extends PrefixBlockRule {
  const HeadingRule() : super('#', HeadingKeys.h1);
}

class ListItemRule extends PrefixBlockRule {
  const ListItemRule() : super('-', ListItemKeys.type);
}

class NumberedListRule extends PrefixBlockRule {
  const NumberedListRule() : super('1.', NumberedListKeys.type);
}

/// Detects task shortcut patterns and converts to a taskItem with metadata.
///
/// Two trigger paths:
/// 1. `- [ ] ` or `- [x] ` typed on a default block type (full shortcut)
/// 2. `[ ] ` or `[x] ` typed at the start of a list item (since "- " already
///    converted it to a list item via ListItemRule)
class TaskItemRule extends PatternInputRule {
  const TaskItemRule();

  @override
  InputRuleOutcome? tryTransform(
    Document docAfter,
    String blockId,
    TextRange editedRange,
    EditorSchema schema,
  ) {
    final block = docAfter.blockById(blockId);
    if (block == null) return null;
    final text = block.plainText;

    // The edit must be exactly a typed space.
    if (editedRange.end != editedRange.start + 1 ||
        editedRange.end > text.length ||
        text.substring(editedRange.start, editedRange.end) != ' ') {
      return null;
    }

    bool? checked;
    int prefixLen;

    if (block.blockType == schema.defaultBlockType) {
      if (text.startsWith('- [ ] ')) {
        checked = false;
        prefixLen = 6;
      } else if (text.startsWith('- [x] ')) {
        checked = true;
        prefixLen = 6;
      } else if (text.startsWith('[ ] ')) {
        checked = false;
        prefixLen = 4;
      } else if (text.startsWith('[x] ')) {
        checked = true;
        prefixLen = 4;
      } else {
        return null;
      }
    } else if (block.blockType == ListItemKeys.type) {
      // Path 2: "[ ] " at start of a list item (user typed "- [ ] ",
      // ListItemRule ate the "- ", leaving "[ ] " on a listItem).
      if (text.startsWith('[ ] ')) {
        checked = false;
        prefixLen = 4;
      } else if (text.startsWith('[x] ')) {
        checked = true;
        prefixLen = 4;
      } else {
        return null;
      }
    } else {
      return null;
    }

    // The typed space must be the one completing the prefix.
    if (editedRange.end != prefixLen) return null;

    return InputRuleOutcome(
      operations: [
        DeleteText(blockId, 0, prefixLen),
        ChangeBlockType(blockId, TaskItemKeys.type),
        SetMetadata(blockId, TaskItemKeys.checked, checked),
      ],
      selectionAfter: DocSelection.collapsed(DocPosition(blockId, 0)),
    );
  }
}

/// Detects `---` typed on an empty default block type and converts it to a
/// divider block.
///
/// Fires when the third `-` is inserted, making the block text exactly `---`.
/// The text is cleared, the block type is changed to divider, and a new empty
/// block is inserted after for the cursor to land on.
class DividerRule extends PatternInputRule {
  const DividerRule();

  @override
  InputRuleOutcome? tryTransform(
    Document docAfter,
    String blockId,
    TextRange editedRange,
    EditorSchema schema,
  ) {
    final block = docAfter.blockById(blockId);
    if (block == null) return null;
    final text = block.plainText;

    // The edit must be exactly a typed '-' completing '---'.
    if (editedRange.end != editedRange.start + 1 ||
        editedRange.end > text.length ||
        text.substring(editedRange.start, editedRange.end) != '-') {
      return null;
    }
    if (block.blockType != schema.defaultBlockType || text != '---') {
      return null;
    }

    final trailing = TextBlock(
      id: generateBlockId(),
      blockType: schema.defaultBlockType,
    );
    return InputRuleOutcome(
      operations: [
        DeleteText(blockId, 0, 3),
        ChangeBlockType(blockId, DividerKeys.type),
        // A new block after the divider for the cursor.
        InsertBlocks(blockId, [trailing]),
      ],
      selectionAfter: DocSelection.collapsed(DocPosition(trailing.id, 0)),
    );
  }
}

/// Enter inside a code block inserts a literal newline instead of splitting.
///
/// Code blocks store multi-line content as a single block with embedded `\n`.
/// This structural interceptor replaces the standard split behavior.
class CodeBlockEnterRule extends StructuralInputRule {
  const CodeBlockEnterRule({this.typeKey = CodeBlockKeys.type});

  /// The block type this rule fires for — defaults to the built-in code
  /// block; custom code-like types pass their own key.
  final String typeKey;

  @override
  InputRuleOutcome? intercept(
    StructuralTrigger trigger,
    Document doc,
    EditorSchema schema,
  ) {
    if (trigger.kind != StructuralTriggerKind.split) return null;
    final block = doc.blockById(trigger.blockId);
    if (block == null || block.blockType != typeKey) return null;

    return InputRuleOutcome(
      operations: [InsertText(trigger.blockId, trigger.offset, '\n')],
      selectionAfter: DocSelection.collapsed(
        DocPosition(trigger.blockId, trigger.offset + 1),
      ),
    );
  }
}
