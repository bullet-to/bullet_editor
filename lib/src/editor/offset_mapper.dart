import 'package:flutter/widgets.dart';

import '../model/document.dart';
import '../schema/editor_schema.dart';

/// Placeholder character used for visual-only WidgetSpan prefixes (bullets).
/// Occupies exactly 1 offset position in the display text.
const prefixChar = '\uFFFC';

/// Zero-width non-joiner used as the spacer marker in the display text.
/// Distinct from [prefixChar] so cursor-skipping logic doesn't confuse
/// a block separator \n after a prefix with a spacer line break.
const spacerChar = '\u200C';

/// Zero-width space used as a placeholder for empty blocks so they occupy
/// a visual line and the cursor has somewhere to render. Display-only — does
/// not exist in the model.
const emptyBlockChar = '\u200B';

/// Whether a block gets a visual prefix WidgetSpan (bullet, number, checkbox,
/// indent, or void block visual).
/// List-like blocks get a prefix. Nested non-list blocks get indentation.
/// Void blocks (e.g. divider) always get a prefix — it IS their visual content.
bool hasPrefix(Document doc, int flatIndex, EditorSchema schema) {
  final block = doc.allBlocks[flatIndex];
  return schema.isListLike(block.blockType) ||
      schema.isVoid(block.blockType) ||
      doc.depthOf(flatIndex) > 0 ||
      schema.blockDef(block.blockType).prefixBuilder != null;
}

/// Whether a block has a spacer line before it (display-only `\n` that
/// creates an empty line whose height is controlled by the current block's
/// `spacingBefore` value or the previous block's `spacingAfter`).
/// Always false for the first block.
bool hasSpacerBefore(Document doc, int flatIndex, EditorSchema schema) {
  if (flatIndex <= 0) return false;
  final block = doc.allBlocks[flatIndex];
  final prevBlock = doc.allBlocks[flatIndex - 1];
  return schema.blockDef(block.blockType).spacingBefore > 0 ||
      schema.blockDef(prevBlock.blockType).spacingAfter > 0;
}

/// Convert a display offset (TextField) to a model offset (Document).
/// Subtracts the prefix placeholder chars that precede this position.
int displayToModel(Document doc, int displayOffset, EditorSchema schema) {
  final flat = doc.allBlocks;
  var displayPos = 0;
  var modelPos = 0;

  for (var i = 0; i < flat.length; i++) {
    if (i > 0) {
      // \n separator — same in display and model.
      displayPos++;
      modelPos++;
    }

    // Spacer: \u200C + \n — both display only (2 chars).
    // Advance FIRST so the <= check covers both spacer characters.
    if (hasSpacerBefore(doc, i, schema)) {
      displayPos += 2;
      if (displayOffset <= displayPos) return modelPos;
    }

    if (hasPrefix(doc, i, schema)) {
      // Prefix placeholder char — display only.
      if (displayOffset <= displayPos) return modelPos;
      displayPos++;
    }

    final blockLen = flat[i].length;
    if (displayOffset <= displayPos + blockLen) {
      return modelPos + (displayOffset - displayPos);
    }

    displayPos += blockLen;
    modelPos += blockLen;

    // Empty block placeholder — display only, after the (empty) content.
    if (_needsEmptyPlaceholder(doc, i, schema)) {
      displayPos++;
      if (displayOffset <= displayPos) return modelPos;
    }
  }

  return modelPos;
}

/// Convert a model offset (Document) to a display offset (TextField).
/// Adds the prefix placeholder chars that precede this position.
int modelToDisplay(Document doc, int modelOffset, EditorSchema schema) {
  final flat = doc.allBlocks;
  var displayPos = 0;
  var modelPos = 0;

  for (var i = 0; i < flat.length; i++) {
    if (i > 0) {
      displayPos++;
      modelPos++;
    }

    // Spacer: \uFFFC + \n — both display only (2 chars).
    if (hasSpacerBefore(doc, i, schema)) {
      displayPos += 2;
    }

    if (hasPrefix(doc, i, schema)) {
      displayPos++; // prefix char in display, not in model
    }

    final blockLen = flat[i].length;
    if (modelOffset <= modelPos + blockLen) {
      return displayPos + (modelOffset - modelPos);
    }

    displayPos += blockLen;
    modelPos += blockLen;

    // Empty block placeholder — display only.
    if (_needsEmptyPlaceholder(doc, i, schema)) {
      displayPos++;
    }
  }

  return displayPos;
}

/// Convert a display TextSelection to model TextSelection.
TextSelection selectionToModel(
    Document doc, TextSelection sel, EditorSchema schema) {
  return TextSelection(
    baseOffset: displayToModel(doc, sel.baseOffset, schema),
    extentOffset: displayToModel(doc, sel.extentOffset, schema),
  );
}

/// Convert a model TextSelection to display TextSelection.
TextSelection selectionToDisplay(
    Document doc, TextSelection sel, EditorSchema schema) {
  return TextSelection(
    baseOffset: modelToDisplay(doc, sel.baseOffset, schema),
    extentOffset: modelToDisplay(doc, sel.extentOffset, schema),
  );
}

/// Whether [idx] in [displayText] is a display-only character the cursor
/// should skip: a prefix \uFFFC, a spacer \u200C, or the \n that follows
/// a spacer \u200C (the spacer line break).
bool _isSkipChar(String displayText, int idx) {
  final ch = displayText[idx];
  if (ch == prefixChar) return true;
  if (ch == spacerChar) return true;
  // Spacer line-break \n: immediately follows a spacerChar.
  if (ch == '\n' && idx > 0 && displayText[idx - 1] == spacerChar) return true;
  return false;
}

/// If the cursor is sitting on a display-only char (prefix \uFFFC or spacer
/// \n), nudge it past all consecutive skip-chars in the direction of movement.
/// Returns null if no adjustment needed.
TextSelection? skipPrefixChars(
  String displayText,
  TextSelection sel,
  TextSelection previousSel,
) {
  if (!sel.isValid || !sel.isCollapsed) return null;
  final offset = sel.baseOffset;
  if (offset < 0 || offset >= displayText.length) return null;
  if (!_isSkipChar(displayText, offset)) return null;

  // Determine direction from previous cursor position.
  final prevOffset = previousSel.baseOffset;
  if (offset > prevOffset) {
    // Moving right — skip past all consecutive skip-chars.
    var target = offset;
    while (
        target < displayText.length && _isSkipChar(displayText, target)) {
      target++;
    }
    return TextSelection.collapsed(offset: target);
  } else if (offset < prevOffset) {
    // Moving left — skip before all consecutive skip-chars.
    var target = offset;
    while (target > 0 && _isSkipCharLeft(displayText, target)) {
      target--;
    }
    return TextSelection.collapsed(offset: target > 0 ? target - 1 : 0);
  }

  // Same position (e.g. click) — check if there's an empty block placeholder
  // (\u200B) immediately before the skip chars. If so, snap to it so the
  // cursor lands on the empty block (whose \u200B is zero-width and otherwise
  // unclickable).
  if (offset > 0 && displayText[offset - 1] == emptyBlockChar) {
    return TextSelection.collapsed(offset: offset - 1);
  }
  // Otherwise skip forward past all consecutive skip-chars.
  var target = offset;
  while (target < displayText.length && _isSkipChar(displayText, target)) {
    target++;
  }
  return TextSelection.collapsed(
    offset: target.clamp(0, displayText.length),
  );
}

/// Check whether the character *before* [target] is a display-only char
/// the cursor should skip when moving left.
bool _isSkipCharLeft(String displayText, int target) {
  if (target <= 0) return false;
  final ch = displayText[target - 1];
  if (ch == prefixChar) return true;
  if (ch == spacerChar) return true;
  // Spacer line-break \n: preceded by a spacerChar.
  if (ch == '\n' && target >= 2 && displayText[target - 2] == spacerChar) {
    return true;
  }
  return false;
}

/// Whether an empty block needs a zero-width placeholder to give it a visual
/// line for cursor rendering. Only needed when the block has no prefix
/// (prefixed blocks already have a WidgetSpan providing layout content).
bool _needsEmptyPlaceholder(Document doc, int flatIndex, EditorSchema schema) {
  return doc.allBlocks[flatIndex].length == 0 &&
      !hasPrefix(doc, flatIndex, schema);
}

/// Build the display text: model text with prefix placeholder chars inserted
/// before each block that has a visual prefix, zero-width spaces for empty
/// non-prefixed blocks, and spacer WidgetSpan placeholders between blocks
/// with spacingBefore.
String buildDisplayText(Document doc, EditorSchema schema) {
  final flat = doc.allBlocks;
  final buf = StringBuffer();
  for (var i = 0; i < flat.length; i++) {
    if (i > 0) buf.write('\n');
    if (hasSpacerBefore(doc, i, schema)) {
      buf.write(spacerChar); // \u200C — distinct from prefix \uFFFC
      buf.write('\n'); // visual line break for the spacer line
    }
    if (hasPrefix(doc, i, schema)) buf.write(prefixChar);
    buf.write(flat[i].plainText);
    if (_needsEmptyPlaceholder(doc, i, schema)) buf.write(emptyBlockChar);
  }
  return buf.toString();
}
