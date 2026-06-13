import 'package:flutter_test/flutter_test.dart';
import 'package:bullet_editor/bullet_editor.dart';

void main() {
  group('diffTexts', () {
    test('returns null for identical texts', () {
      expect(diffTexts('hello', 'hello'), isNull);
    });

    test('detects simple insertion', () {
      final diff = diffTexts('helo', 'hello');
      expect(diff, isNotNull);
      expect(diff!.start, 3);
      expect(diff.deletedLength, 0);
      expect(diff.insertedText, 'l');
    });

    test('detects simple deletion', () {
      final diff = diffTexts('hello', 'helo');
      expect(diff, isNotNull);
      expect(diff!.start, 3);
      expect(diff.deletedLength, 1);
      expect(diff.insertedText, '');
    });

    test('detects replacement', () {
      final diff = diffTexts('hello', 'hullo');
      expect(diff, isNotNull);
      expect(diff!.start, 1);
      expect(diff.deletedLength, 1);
      expect(diff.insertedText, 'u');
    });

    test('detects append', () {
      final diff = diffTexts('hello', 'hello world');
      expect(diff, isNotNull);
      expect(diff!.start, 5);
      expect(diff.deletedLength, 0);
      expect(diff.insertedText, ' world');
    });
  });

  group('cursor-anchored diff', () {
    test('anchors insertion to cursor position', () {
      // "abc trigger bold" → "abc trigger  bold"
      // Without cursor: diff says insert at 12 (prefix eats the space)
      // With cursor at 12: diff says insert at 11 (correct)
      final diff = diffTexts(
        'abc trigger bold',
        'abc trigger  bold',
        cursorOffset: 12,
      );
      expect(diff, isNotNull);
      expect(diff!.start, 11);
      expect(diff.insertedText, ' ');
    });

    test('anchors deletion to cursor position', () {
      // "hello  world" → "hello world", cursor at 5
      final diff = diffTexts('hello  world', 'hello world', cursorOffset: 5);
      expect(diff, isNotNull);
      expect(diff!.start, 5);
      expect(diff.deletedLength, 1);
      expect(diff.insertedText, '');
    });

    test('falls back to prefix/suffix when cursor does not match', () {
      // Cursor doesn't match a clean insert — fall back.
      final diff = diffTexts(
        'abcdef',
        'abcXYZdef',
        cursorOffset: 0, // wrong cursor
      );
      expect(diff, isNotNull);
      // Should still find the diff via prefix/suffix.
      expect(diff!.start, 3);
      expect(diff.insertedText, 'XYZ');
    });

    test('handles insert at start with cursor', () {
      final diff = diffTexts('world', 'hello world', cursorOffset: 6);
      expect(diff, isNotNull);
      expect(diff!.start, 0);
      expect(diff.insertedText, 'hello ');
    });
  });

  group('surrogate-pair safety (prefix/suffix widening)', () {
    test('an emoji variant sharing the high surrogate diffs as the whole '
        'pair, never a lone low surrogate', () {
      // 😀 (U+D83D,U+DE00) → 😁 (U+D83D,U+DE01): the code-unit prefix scan
      // eats the shared high surrogate; without widening the diff would be
      // the low surrogate alone — mid-pair offsets downstream.
      final diff = diffTexts('. 😀', '. 😁', cursorOffset: 4);
      expect(diff, isNotNull);
      expect(diff!.start, 2);
      expect(diff.deletedLength, 2);
      expect(diff.insertedText, '😁');
    });

    test('a shared low surrogate widens the suffix boundary too', () {
      // 😀 (U+D83D,U+DE00) → 🈀 (U+D83C,U+DE00) share the LOW surrogate:
      // the suffix scan keeps it and would otherwise leave a lone high
      // surrogate as the replacement.
      final diff = diffTexts('😀', '🈀');
      expect(diff, isNotNull);
      expect(diff!.start, 0);
      expect(diff.deletedLength, 2);
      expect(diff.insertedText, '🈀');
    });
  });
}
