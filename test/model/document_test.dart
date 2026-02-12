import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Document', () {
    test('plainText joins blocks with newline', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('hello')]),
        TextBlock(id: 'b', segments: [const StyledSegment('world')]),
      ]);
      expect(doc.plainText, 'hello\nworld');
    });

    test('blockAt maps global offset to correct block', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('abc')]), // 0-2
        TextBlock(
          id: 'b',
          segments: [const StyledSegment('de')],
        ), // 4-5 (3 is \n)
      ]);

      // Inside first block
      expect(doc.blockAt(0).blockIndex, 0);
      expect(doc.blockAt(0).localOffset, 0);
      expect(doc.blockAt(2).blockIndex, 0);
      expect(doc.blockAt(2).localOffset, 2);
      expect(doc.blockAt(3).blockIndex, 0);
      expect(doc.blockAt(3).localOffset, 3);

      // Inside second block
      expect(doc.blockAt(4).blockIndex, 1);
      expect(doc.blockAt(4).localOffset, 0);
      expect(doc.blockAt(5).blockIndex, 1);
      expect(doc.blockAt(5).localOffset, 1);
    });

    test('globalOffset reverses blockAt', () {
      final doc = Document([
        TextBlock(id: 'a', segments: [const StyledSegment('abc')]),
        TextBlock(id: 'b', segments: [const StyledSegment('de')]),
      ]);

      expect(doc.globalOffset(0, 0), 0);
      expect(doc.globalOffset(0, 3), 3);
      expect(doc.globalOffset(1, 0), 4);
      expect(doc.globalOffset(1, 2), 6);
    });
  });

  group('StyledSegment', () {
    test('equality', () {
      const a = StyledSegment('hi', {InlineStyle.bold});
      const b = StyledSegment('hi', {InlineStyle.bold});
      expect(a, equals(b));
    });
  });

  group('mergeSegments', () {
    test('merges adjacent same-style segments', () {
      final result = mergeSegments([
        const StyledSegment('hel', {InlineStyle.bold}),
        const StyledSegment('lo', {InlineStyle.bold}),
        const StyledSegment(' world'),
      ]);
      expect(result.length, 2);
      expect(result[0].text, 'hello');
      expect(result[0].styles, {InlineStyle.bold});
      expect(result[1].text, ' world');
    });

    test('drops empty segments', () {
      final result = mergeSegments([
        const StyledSegment(''),
        const StyledSegment('hi'),
        const StyledSegment(''),
      ]);
      expect(result.length, 1);
      expect(result[0].text, 'hi');
    });
  });
}
