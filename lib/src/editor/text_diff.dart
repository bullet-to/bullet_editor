/// The result of diffing two text strings.
class TextDiff {
  const TextDiff(this.start, this.deletedLength, this.insertedText);
  final int start;
  final int deletedLength;
  final String insertedText;

  bool get isInsert => deletedLength == 0 && insertedText.isNotEmpty;
  bool get isDelete => deletedLength > 0 && insertedText.isEmpty;
  bool get isReplace => deletedLength > 0 && insertedText.isNotEmpty;
}

/// Compute the diff between [oldText] and [newText].
///
/// Uses [cursorOffset] (position in newText after the edit) to anchor the
/// diff when possible. This avoids ambiguity at style boundaries where
/// an inserted character matches adjacent text.
///
/// Returns null if the texts are identical.
TextDiff? diffTexts(String oldText, String newText, {int? cursorOffset}) {
  if (oldText == newText) return null;

  final lengthDelta = newText.length - oldText.length;

  // Try cursor-anchored diff first.
  if (cursorOffset != null) {
    final anchored = _cursorAnchored(
      oldText,
      newText,
      cursorOffset,
      lengthDelta,
    );
    if (anchored != null) return anchored;
  }

  // Fallback: prefix/suffix comparison.
  return _prefixSuffix(oldText, newText);
}

/// Cursor-anchored: the cursor tells us exactly where the edit happened.
TextDiff? _cursorAnchored(
  String oldText,
  String newText,
  int cursor,
  int lengthDelta,
) {
  if (lengthDelta > 0) {
    final start = cursor - lengthDelta;
    if (start < 0 || start > oldText.length) return null;
    if (newText.substring(0, start) != oldText.substring(0, start)) return null;
    if (newText.substring(cursor) != oldText.substring(start)) return null;
    return TextDiff(start, 0, newText.substring(start, cursor));
  }

  if (lengthDelta < 0) {
    final deleteLen = -lengthDelta;
    if (cursor + deleteLen > oldText.length) return null;
    if (newText.substring(0, cursor) != oldText.substring(0, cursor)) {
      return null;
    }
    if (newText.substring(cursor) != oldText.substring(cursor + deleteLen)) {
      return null;
    }
    return TextDiff(cursor, deleteLen, '');
  }

  return null;
}

/// Prefix/suffix: find common prefix and suffix, the middle changed.
TextDiff _prefixSuffix(String oldText, String newText) {
  var prefixLen = 0;
  final minLen = oldText.length < newText.length
      ? oldText.length
      : newText.length;
  while (prefixLen < minLen && oldText[prefixLen] == newText[prefixLen]) {
    prefixLen++;
  }

  var suffixLen = 0;
  while (suffixLen < (minLen - prefixLen) &&
      oldText[oldText.length - 1 - suffixLen] ==
          newText[newText.length - 1 - suffixLen]) {
    suffixLen++;
  }

  // Surrogate-pair safety: the scans above compare UTF-16 code units, so a
  // replacement sharing one half of a pair (😀 U+D83D,U+DE00 → 😁
  // U+D83D,U+DE01 shares the high surrogate) would otherwise yield a
  // half-pair diff and hand mid-pair offsets downstream. Widen the
  // boundaries outward to surrogate boundaries — the diff stays valid, just
  // whole-pair. The matched prefix/suffix is identical in both texts, so
  // checking oldText alone suffices.
  while (prefixLen > 0 && _isHighSurrogate(oldText.codeUnitAt(prefixLen - 1))) {
    prefixLen--;
  }
  while (suffixLen > 0 &&
      _isLowSurrogate(oldText.codeUnitAt(oldText.length - suffixLen))) {
    suffixLen--;
  }

  return TextDiff(
    prefixLen,
    oldText.length - prefixLen - suffixLen,
    newText.substring(prefixLen, newText.length - suffixLen),
  );
}

bool _isHighSurrogate(int codeUnit) => (codeUnit & 0xFC00) == 0xD800;
bool _isLowSurrogate(int codeUnit) => (codeUnit & 0xFC00) == 0xDC00;
