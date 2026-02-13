import 'package:flutter/widgets.dart';

import '../model/document.dart';
import '../schema/editor_schema.dart';

/// Placeholder character used for visual-only WidgetSpan prefixes (bullets).
/// Occupies exactly 1 offset position in the display text.
const prefixChar = '\uFFFC';

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
      doc.depthOf(flatIndex) > 0;
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
      if (displayOffset <= displayPos) return modelPos;
      displayPos++;
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

/// If the cursor is sitting on a prefix char, nudge it past.
/// Returns null if no adjustment needed.
TextSelection? skipPrefixChars(
  String displayText,
  TextSelection sel,
  TextSelection previousSel,
) {
  if (!sel.isValid || !sel.isCollapsed) return null;
  final offset = sel.baseOffset;
  if (offset < 0 || offset >= displayText.length) return null;
  if (displayText[offset] != prefixChar) return null;

  // Determine direction from previous cursor position.
  final prevOffset = previousSel.baseOffset;
  if (offset > prevOffset) {
    // Moving right — skip past the prefix char.
    return TextSelection.collapsed(offset: offset + 1);
  } else if (offset < prevOffset) {
    // Moving left — skip before the prefix char (to end of previous block).
    return TextSelection.collapsed(offset: offset > 0 ? offset - 1 : 0);
  }

  // Same position (e.g. click) — skip forward.
  return TextSelection.collapsed(
    offset: (offset + 1).clamp(0, displayText.length),
  );
}

/// Whether an empty block needs a zero-width placeholder to give it a visual
/// line for cursor rendering. Only needed when the block has no prefix
/// (prefixed blocks already have a WidgetSpan providing layout content).
bool _needsEmptyPlaceholder(Document doc, int flatIndex, EditorSchema schema) {
  return doc.allBlocks[flatIndex].length == 0 &&
      !hasPrefix(doc, flatIndex, schema);
}

/// Build the display text: model text with prefix placeholder chars inserted
/// before each block that has a visual prefix, and zero-width spaces for
/// empty non-prefixed blocks.
String buildDisplayText(Document doc, EditorSchema schema) {
  final flat = doc.allBlocks;
  final buf = StringBuffer();
  for (var i = 0; i < flat.length; i++) {
    if (i > 0) buf.write('\n');
    if (hasPrefix(doc, i, schema)) buf.write(prefixChar);
    buf.write(flat[i].plainText);
    if (_needsEmptyPlaceholder(doc, i, schema)) buf.write(emptyBlockChar);
  }
  return buf.toString();
}
