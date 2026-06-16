import 'dart:ui';

import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('underline rects are level when glyph boxes have different bottoms '
      '(mixed kana + romaji)', () {
    // Simulates getBoxesForSelection returning two runs on the same line
    // with different bottoms — kana glyphs sit higher than romaji.
    final glyphRects = [
      const Rect.fromLTWH(0, 0, 30, 20), // にほ — bottom at 20
      const Rect.fromLTWH(30, 2, 10, 22), // n  — bottom at 24
    ];

    final underlines = composingUnderlineRects(glyphRects, 2.0);

    expect(underlines, hasLength(2));
    // Both underline rects must share the same top (== bottom - thickness).
    expect(
      underlines[0].top,
      underlines[1].top,
      reason: 'the underline should be continuous across mixed-script runs',
    );
  });

  test('single-run composing range passes through unchanged', () {
    final glyphRects = [const Rect.fromLTWH(0, 0, 50, 20)];
    final underlines = composingUnderlineRects(glyphRects, 2.0);

    expect(underlines, hasLength(1));
    expect(underlines[0], const Rect.fromLTWH(0, 18, 50, 2));
  });

  test('three runs with varying bottoms all share the deepest', () {
    final glyphRects = [
      const Rect.fromLTWH(0, 0, 30, 18), // bottom 18
      const Rect.fromLTWH(30, 1, 10, 22), // bottom 23
      const Rect.fromLTWH(40, 0, 20, 20), // bottom 20
    ];

    final underlines = composingUnderlineRects(glyphRects, 2.0);

    expect(underlines, hasLength(3));
    for (final r in underlines) {
      expect(r.top, 21.0); // deepest bottom (23) - thickness (2)
    }
  });

  test('empty input produces empty output', () {
    expect(composingUnderlineRects([], 2.0), isEmpty);
  });
}
