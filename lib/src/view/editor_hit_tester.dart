import 'package:flutter/rendering.dart';

import '../model/doc_selection.dart';
import 'block_layout_registry.dart';

/// Resolves a global point to a document position via the geometry registry:
/// the nearest laid-out block by vertical distance, with the point clamped
/// into its box, then `offsetForLocalPoint` (midpoint-resolved for voids).
///
/// Shared by every interactor (architecture §Gestures: "both interactors
/// share one hit-testing helper"). Returns null when nothing is laid out —
/// per GATE-L the caller may estimate or scroll, never force layout.
DocPosition? hitTestDocPosition(BlockLayoutRegistry registry, Offset global) {
  BlockGeometry? nearest;
  String? nearestId;
  var nearestDistance = double.infinity;

  for (final blockId in registry.laidOutBlockIds) {
    final geometry = registry.geometryOf(blockId)!;
    final box = geometry.renderBox;
    if (!box.attached || !box.hasSize) continue;

    final topLeft = box.localToGlobal(Offset.zero);
    final rect = topLeft & box.size;
    final distance = global.dy < rect.top
        ? rect.top - global.dy
        : global.dy > rect.bottom
        ? global.dy - rect.bottom
        : 0.0;

    if (distance < nearestDistance) {
      nearestDistance = distance;
      nearest = geometry;
      nearestId = blockId;
    }
    if (distance == 0.0) break; // The point is inside this block's band.
  }

  if (nearest == null) return null;

  final box = nearest.renderBox;
  final local = box.globalToLocal(global);
  final clamped = Offset(
    local.dx.clamp(0.0, box.size.width),
    local.dy.clamp(0.0, box.size.height),
  );
  return DocPosition(nearestId!, nearest.offsetForLocalPoint(clamped));
}
