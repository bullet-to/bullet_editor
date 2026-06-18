import 'package:bullet_editor/bullet_editor.dart';
import 'package:bullet_editor/src/view/selection_drag.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit tests for the shared drag-time selection math extracted from the two
/// interactors (review H1–H3): document order, swept-void resolution, and the
/// orientation/never-shrink/word-snap extension. Pure functions — no rendering,
/// no live drag — so the rules both interactors depend on are pinned in one
/// place and cannot silently diverge.
void main() {
  TextBlock para(String id) => TextBlock(
    id: id,
    blockType: ParagraphKeys.type,
    segments: [const StyledSegment('xxxxx')],
  );

  // Flat order: a (0), img (1), c (2).
  final doc = Document([para('a'), para('img'), para('c')]);
  bool isVoid(String id) => id == 'img';

  group('compareInDocument', () {
    test('orders by block index, then offset', () {
      expect(
        DocPosition('a', 0).compareInDocument(DocPosition('c', 0), doc),
        isNegative,
      );
      expect(
        DocPosition('c', 0).compareInDocument(DocPosition('a', 0), doc),
        isPositive,
      );
      expect(
        DocPosition('a', 1).compareInDocument(DocPosition('a', 3), doc),
        isNegative,
      );
      expect(
        DocPosition('a', 2).compareInDocument(DocPosition('a', 2), doc),
        0,
      );
    });
  });

  group('resolveSweptVoid', () {
    test('a non-void point passes through unchanged', () {
      const p = DocPosition('c', 2);
      expect(resolveSweptVoid(p, const DocPosition('a', 0), doc, isVoid), p);
    });

    test('a void at/after the anchor resolves to its downstream edge (1)', () {
      final r = resolveSweptVoid(
        const DocPosition('img', 0),
        const DocPosition('a', 0),
        doc,
        isVoid,
      );
      expect(r, const DocPosition('img', 1));
    });

    test('a void before the anchor resolves to its upstream edge (0)', () {
      final r = resolveSweptVoid(
        const DocPosition('img', 1),
        const DocPosition('c', 0),
        doc,
        isVoid,
      );
      expect(r, const DocPosition('img', 0));
    });
  });

  group('extendSelection', () {
    test('a null anchor collapses to a caret at the point', () {
      final s = extendSelection(
        anchor: null,
        point: const DocPosition('a', 3),
        doc: doc,
        isVoid: isVoid,
      );
      expect(s.isCollapsed, isTrue);
      expect(s.extent, const DocPosition('a', 3));
    });

    test(
      'downstream extension keeps the anchor start fixed (raw, no snap)',
      () {
        const anchor = DocSelection(
          base: DocPosition('a', 1),
          extent: DocPosition('a', 3),
        );
        final s = extendSelection(
          anchor: anchor,
          point: const DocPosition('c', 2),
          doc: doc,
          isVoid: isVoid,
        );
        final (start, end) = s.normalized(doc);
        expect(start, const DocPosition('a', 1));
        expect(end, const DocPosition('c', 2));
      },
    );

    test('upstream extension keeps the anchor end fixed', () {
      const anchor = DocSelection(
        base: DocPosition('c', 1),
        extent: DocPosition('c', 3),
      );
      final s = extendSelection(
        anchor: anchor,
        point: const DocPosition('a', 0),
        doc: doc,
        isVoid: isVoid,
      );
      final (start, end) = s.normalized(doc);
      expect(start, const DocPosition('a', 0));
      expect(end, const DocPosition('c', 3));
    });

    test(
      'a point inside the anchor span returns the anchor (never shrinks)',
      () {
        const anchor = DocSelection(
          base: DocPosition('a', 1),
          extent: DocPosition('c', 3),
        );
        final s = extendSelection(
          anchor: anchor,
          point: const DocPosition('img', 0),
          doc: doc,
          isVoid: (_) => false,
        );
        expect(s, anchor);
      },
    );

    test('the snap callback word-aligns the moving end', () {
      const anchor = DocSelection(
        base: DocPosition('a', 0),
        extent: DocPosition('a', 2),
      );
      DocPosition snap(DocPosition p, {required bool toStart}) =>
          DocPosition(p.blockId, toStart ? 10 : 99);
      final s = extendSelection(
        anchor: anchor,
        point: const DocPosition('c', 1),
        doc: doc,
        isVoid: isVoid,
        snap: snap,
      );
      final (start, end) = s.normalized(doc);
      expect(start, const DocPosition('a', 0));
      expect(end, const DocPosition('c', 99)); // snapped end
    });

    test('a swept void in the drag direction is covered', () {
      const anchor = DocSelection(
        base: DocPosition('a', 0),
        extent: DocPosition('a', 2),
      );
      final s = extendSelection(
        anchor: anchor,
        point: const DocPosition('img', 0),
        doc: doc,
        isVoid: isVoid,
      );
      final (start, end) = s.normalized(doc);
      expect(start, const DocPosition('a', 0));
      expect(end, const DocPosition('img', 1)); // downstream void edge included
    });
  });
}
