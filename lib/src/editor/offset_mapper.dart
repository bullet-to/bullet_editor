import 'package:flutter/widgets.dart';

import '../model/block.dart';
import '../model/document.dart';

/// Placeholder character used for visual-only WidgetSpan prefixes (bullets).
/// Occupies exactly 1 offset position in the display text.
const prefixChar = '\uFFFC';

/// Whether a block gets a visual prefix WidgetSpan (bullet, indent, etc).
/// List items always get a bullet. Nested blocks get indentation.
bool hasPrefix(Document doc, int flatIndex) {
  final block = doc.allBlocks[flatIndex];
  return block.blockType == BlockType.listItem ||
      doc.depthOf(flatIndex) > 0;
}

/// Convert a display offset (TextField) to a model offset (Document).
/// Subtracts the prefix placeholder chars that precede this position.
int displayToModel(Document doc, int displayOffset) {
  final flat = doc.allBlocks;
  var displayPos = 0;
  var modelPos = 0;

  for (var i = 0; i < flat.length; i++) {
    if (i > 0) {
      // \n separator — same in display and model.
      displayPos++;
      modelPos++;
    }

    if (hasPrefix(doc, i)) {
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
  }

  return modelPos;
}

/// Convert a model offset (Document) to a display offset (TextField).
/// Adds the prefix placeholder chars that precede this position.
int modelToDisplay(Document doc, int modelOffset) {
  final flat = doc.allBlocks;
  var displayPos = 0;
  var modelPos = 0;

  for (var i = 0; i < flat.length; i++) {
    if (i > 0) {
      displayPos++;
      modelPos++;
    }

    if (hasPrefix(doc, i)) {
      displayPos++; // prefix char in display, not in model
    }

    final blockLen = flat[i].length;
    if (modelOffset <= modelPos + blockLen) {
      return displayPos + (modelOffset - modelPos);
    }

    displayPos += blockLen;
    modelPos += blockLen;
  }

  return displayPos;
}

/// Convert a display TextSelection to model TextSelection.
TextSelection selectionToModel(Document doc, TextSelection sel) {
  return TextSelection(
    baseOffset: displayToModel(doc, sel.baseOffset),
    extentOffset: displayToModel(doc, sel.extentOffset),
  );
}

/// Convert a model TextSelection to display TextSelection.
TextSelection selectionToDisplay(Document doc, TextSelection sel) {
  return TextSelection(
    baseOffset: modelToDisplay(doc, sel.baseOffset),
    extentOffset: modelToDisplay(doc, sel.extentOffset),
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

/// Build the display text: model text with prefix placeholder chars inserted
/// before each block that has a visual prefix.
String buildDisplayText(Document doc) {
  final flat = doc.allBlocks;
  final buf = StringBuffer();
  for (var i = 0; i < flat.length; i++) {
    if (i > 0) buf.write('\n');
    if (hasPrefix(doc, i)) buf.write(prefixChar);
    buf.write(flat[i].plainText);
  }
  return buf.toString();
}
