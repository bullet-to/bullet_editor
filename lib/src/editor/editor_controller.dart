import 'package:flutter/widgets.dart';

import '../model/block.dart';
import '../model/document.dart';
import '../model/inline_style.dart';
import 'edit_operation.dart';
import 'input_rule.dart';
import 'text_diff.dart';
import 'transaction.dart';

/// The bridge between Flutter's TextField and our document model.
///
/// Intercepts text changes, converts them to transactions, runs input
/// rules, applies them to the model, and renders styled text.
///
/// Tracks [activeStyles] — the formatting applied to the next typed
/// character, derived from the segment at the cursor position.
class EditorController extends TextEditingController {
  EditorController({Document? document, List<InputRule>? inputRules})
    : _document = document ?? Document.empty(),
      _inputRules = inputRules ?? [] {
    _syncToTextField();
    _activeStyles = _document.stylesAt(value.selection.baseOffset);
    addListener(_onValueChanged);
  }

  Document _document;
  final List<InputRule> _inputRules;
  bool _isSyncing = false;
  TextEditingValue _previousValue = TextEditingValue.empty;
  Set<InlineStyle> _activeStyles = {};

  Document get document => _document;
  Set<InlineStyle> get activeStyles => _activeStyles;

  /// Indent the block at the current cursor position (make it a child of previous sibling).
  void indent() {
    if (!value.selection.isValid || !value.selection.isCollapsed) return;
    final pos = _document.blockAt(value.selection.baseOffset);

    _document = IndentBlock(pos.blockIndex).apply(_document);
    _syncToTextField(selection: value.selection);
    _activeStyles = _document.stylesAt(value.selection.baseOffset);
  }

  /// Outdent the block at the current cursor position (move to parent's level).
  void outdent() {
    if (!value.selection.isValid || !value.selection.isCollapsed) return;
    final pos = _document.blockAt(value.selection.baseOffset);

    _document = OutdentBlock(pos.blockIndex).apply(_document);
    _syncToTextField(selection: value.selection);
    _activeStyles = _document.stylesAt(value.selection.baseOffset);
  }

  // -- Edit pipeline --

  void _onValueChanged() {
    if (_isSyncing) return;

    // Skip IME composition — process only on final commit.
    if (value.composing.isValid &&
        value.composing.start != value.composing.end) {
      _previousValue = value;
      return;
    }

    final cursor = value.selection.isValid ? value.selection.baseOffset : null;
    final diff = diffTexts(_previousValue.text, text, cursorOffset: cursor);

    if (diff == null) {
      _activeStyles = _document.stylesAt(value.selection.baseOffset);
      _previousValue = value;
      return;
    }

    final tx = _transactionFromDiff(diff, value.selection);
    if (tx == null) {
      _previousValue = value;
      return;
    }

    // Input rules can transform the transaction before commit.
    var finalTx = tx;
    for (final rule in _inputRules) {
      final transformed = rule.tryTransform(finalTx, _document);
      if (transformed != null) {
        finalTx = transformed;
        break;
      }
    }

    _document = finalTx.apply(_document);
    _syncToTextField(selection: finalTx.selectionAfter ?? value.selection);
    _activeStyles = _document.stylesAt(value.selection.baseOffset);
  }

  // -- Transaction building --

  Transaction? _transactionFromDiff(TextDiff diff, TextSelection selection) {
    if (diff.deletedLength == 0 && diff.insertedText.isEmpty) return null;

    final deletedText = _previousValue.text.substring(
      diff.start,
      diff.start + diff.deletedLength,
    );

    // Tab character → indent/outdent list item.
    if (diff.insertedText == '\t' && diff.deletedLength == 0) {
      final pos = _document.blockAt(diff.start);
      final block = _document.allBlocks[pos.blockIndex];
      if (block.blockType == BlockType.listItem) {
        return Transaction(
          operations: [IndentBlock(pos.blockIndex)],
          selectionAfter: selection,
        );
      }
      return null; // Ignore tab on non-list blocks.
    }

    // Newline in deleted text → merge blocks.
    if (deletedText.contains('\n') && diff.insertedText.isEmpty) {
      final pos = _document.blockAt(diff.start);
      if (pos.blockIndex + 1 >= _document.allBlocks.length) return null;
      return Transaction(
        operations: [MergeBlocks(pos.blockIndex + 1)],
        selectionAfter: selection,
      );
    }

    // Newline in inserted text → split block.
    if (diff.insertedText.contains('\n') && diff.deletedLength == 0) {
      final pos = _document.blockAt(diff.start);
      return Transaction(
        operations: [SplitBlock(pos.blockIndex, pos.localOffset)],
        selectionAfter: selection,
      );
    }

    // Text change within a block.
    final pos = _document.blockAt(diff.start);
    final ops = <EditOperation>[
      if (diff.deletedLength > 0)
        DeleteText(pos.blockIndex, pos.localOffset, diff.deletedLength),
      if (diff.insertedText.isNotEmpty)
        InsertText(
          pos.blockIndex,
          pos.localOffset,
          diff.insertedText,
          styles: _activeStyles,
        ),
    ];

    return ops.isEmpty
        ? null
        : Transaction(operations: ops, selectionAfter: selection);
  }

  // -- TextField sync --

  void _syncToTextField({TextSelection? selection}) {
    _isSyncing = true;
    final newText = _document.plainText;
    final sel = selection ?? TextSelection.collapsed(offset: newText.length);
    value = TextEditingValue(
      text: newText,
      selection: TextSelection(
        baseOffset: sel.baseOffset.clamp(0, newText.length),
        extentOffset: sel.extentOffset.clamp(0, newText.length),
      ),
    );
    _previousValue = value;
    _isSyncing = false;
  }

  // -- Rendering --

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final children = <InlineSpan>[];

    final flat = _document.allBlocks;

    for (var i = 0; i < flat.length; i++) {
      if (i > 0) {
        final prevBlockStyle = _blockBaseStyle(flat[i - 1].blockType, style);
        children.add(TextSpan(text: '\n', style: prevBlockStyle));
      }

      final block = flat[i];
      final blockStyle = _blockBaseStyle(block.blockType, style);

      if (block.segments.isEmpty) {
        children.add(TextSpan(text: '', style: blockStyle));
      } else {
        for (final seg in block.segments) {
          children.add(
            TextSpan(
              text: seg.text,
              style: _resolveStyle(seg.styles, blockStyle),
            ),
          );
        }
      }
    }

    return TextSpan(style: style, children: children);
  }

  /// Base style for a block type (font size, weight, color).
  TextStyle? _blockBaseStyle(BlockType type, TextStyle? base) {
    switch (type) {
      case BlockType.h1:
        return (base ?? const TextStyle()).copyWith(
          fontSize: 24,
          fontWeight: FontWeight.bold,
          height: 1.3,
        );
      case BlockType.listItem:
        // Subtle visual distinction — no bullet prefix (would break offsets).
        return (base ?? const TextStyle()).copyWith(
          color: const Color(0xFF333333),
        );
      case BlockType.paragraph:
        return base;
    }
  }

  /// Apply inline styles on top of the block base style.
  TextStyle? _resolveStyle(Set<InlineStyle> styles, TextStyle? base) {
    if (styles.isEmpty) return base;
    var result = base ?? const TextStyle();
    if (styles.contains(InlineStyle.bold)) {
      result = result.copyWith(fontWeight: FontWeight.bold);
    }
    return result;
  }

  @override
  void dispose() {
    removeListener(_onValueChanged);
    super.dispose();
  }
}
