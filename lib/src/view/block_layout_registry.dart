import 'dart:ui' show BoxHeightStyle;

import 'package:flutter/rendering.dart';

/// Per-block geometry queries (GATE-L). Implemented by component States —
/// text components answer by querying the `RenderParagraph` of their
/// `RichText` child; void components use box midpoints (day 14).
///
/// All coordinates are local to [renderBox]; use it for local↔global
/// transforms.
abstract interface class BlockGeometry {
  /// Caret rect for a block-local text offset, or null while unlaid-out.
  Rect? rectForOffset(int offset);

  /// Highlight rects covering the block-local range `[start, end)`.
  ///
  /// [boxHeightStyle] controls vertical extent: [BoxHeightStyle.tight] (glyph
  /// height) by default; the selection highlight requests [BoxHeightStyle.max]
  /// so the band fills the full line (native depth), meeting the handles whose
  /// bottom-corner anchor sits at the line bottom.
  List<Rect> rectsForRange(
    int start,
    int end, {
    BoxHeightStyle boxHeightStyle = BoxHeightStyle.tight,
  });

  /// The block-local text offset nearest to a point in [renderBox] space.
  int offsetForLocalPoint(Offset point);

  /// The word boundary containing a block-local offset.
  TextRange wordBoundaryAt(int offset);

  /// The render box geometry queries are local to.
  RenderBox get renderBox;
}

/// blockId → geometry-or-null. Components register on mount and deregister
/// on dispose.
///
/// The contract for every consumer (IME caret rects, handles, context-menu
/// anchors, autoscroll): **null means "not laid out" — you may estimate or
/// scroll, never force layout** (D5: no API assumes total geometry).
class BlockLayoutRegistry {
  final Map<String, BlockGeometry> _geometries = {};

  void register(String blockId, BlockGeometry geometry) {
    _geometries[blockId] = geometry;
  }

  /// Deregisters only if [geometry] is still the registered instance — a
  /// remounted component may have re-registered before the old State's
  /// dispose runs.
  void unregister(String blockId, BlockGeometry geometry) {
    if (identical(_geometries[blockId], geometry)) {
      _geometries.remove(blockId);
    }
  }

  /// Geometry for [blockId], or null if the block is not laid out
  /// (scrolled out of the lazy viewport, or not in the document).
  BlockGeometry? geometryOf(String blockId) => _geometries[blockId];

  /// Currently laid-out block count — the inspector's laziness counter.
  int get layoutCount => _geometries.length;

  /// Currently laid-out block ids (inspector surface).
  Iterable<String> get laidOutBlockIds => _geometries.keys;
}
