import 'package:flutter/widgets.dart';

import '../model/doc_selection.dart';
import '../model/document.dart';

/// Shared drag-time selection plumbing used by every interactor (mouse press-
/// drag, touch long-press-drag, handle drag) so the rules live in one place and
/// cannot drift between interactors (review H1–H4). The swept-void rule and the
/// orientation/never-shrink extension math are spec'd as ONE rule across mouse,
/// touch, and keyboard (architecture §Gestures: "drag and keyboard movement
/// both override it by direction"); the post-frame re-hit-test is the one G5
/// mechanism the autoscroller's complement.

/// Resolves a swept void the moment a drag enters its box (D6, web feel),
/// resolving the void edge by drag direction against [anchorStart] so its
/// `[0, 1)` is covered — downstream (`1`) when the void sits at/after the anchor
/// (dragging down onto it), upstream (`0`) when before (dragging up). A
/// non-void [point], or a void that IS the anchor, passes through untouched.
/// The geometry's midpoint rule still answers a plain click (which normalizes
/// to the atomic selection either way).
DocPosition resolveSweptVoid(
  DocPosition point,
  DocPosition anchorStart,
  Document doc,
  bool Function(String blockId) isVoid,
) {
  if (!isVoid(point.blockId)) return point;
  final voidIndex = doc.indexOfBlock(point.blockId);
  final anchorIndex = doc.indexOfBlock(anchorStart.blockId);
  return DocPosition(point.blockId, voidIndex >= anchorIndex ? 1 : 0);
}

/// Snaps a drag point to a word/granularity edge: `toStart` ⇒ the start of the
/// span at [point], else its end. The mouse interactor lands raw (no snap); the
/// touch interactor snaps to word boundaries so a long-press drag keeps both
/// ends word-aligned.
typedef DragSnap =
    DocPosition Function(DocPosition point, {required bool toStart});

/// Extends a drag/shift selection from [anchor] to [point], oriented in
/// document order and never shrinking below the anchor's own span (native
/// multi-click / word drag). A null [anchor] collapses to a caret at [point]
/// (pre-resolution, matching both interactors' prior behavior). The moving end
/// resolves a swept void by direction, then — if [snap] is given — snaps to the
/// word edge in the drag direction; the anchor's far end stays fixed.
///
/// One implementation for both interactors: the mouse passes no [snap] (lands
/// mid-word), the touch passes its word-edge snap. The orientation and
/// never-shrink logic is therefore identical by construction (review H3).
DocSelection extendSelection({
  required DocSelection? anchor,
  required DocPosition point,
  required Document doc,
  required bool Function(String blockId) isVoid,
  DragSnap? snap,
}) {
  if (anchor == null) return DocSelection.collapsed(point);
  final (start, end) = anchor.normalized(doc);
  point = resolveSweptVoid(point, start, doc, isVoid);
  if (point.compareInDocument(start, doc) < 0) {
    final moving = snap != null ? snap(point, toStart: true) : point;
    return DocSelection(base: end, extent: moving);
  } else if (point.compareInDocument(end, doc) > 0) {
    final moving = snap != null ? snap(point, toStart: false) : point;
    return DocSelection(base: start, extent: moving);
  }
  return anchor;
}

/// Schedules a single post-frame re-hit-test of a live drag's extent after a
/// scroll committed and the sliver re-laid the revealed content — so the hit
/// always lands on laid-out content, never an estimate (architecture §Gestures
/// G5). One copy of the `_rehitScheduled`-guarded post-frame plumbing both
/// interactors used to carry (review H4); each constructs one wired to its own
/// active-drag predicate, focal-point source, and re-hit action.
class DragRehitScheduler {
  DragRehitScheduler({
    required this.isActive,
    required this.focalPointOf,
    required this.onRehit,
  });

  /// Whether a re-hit-applicable drag is live — false for a stationary
  /// long-press, so an incidental focus-driven scroll never re-extends it.
  final bool Function() isActive;

  /// The (compensated) point the extent should re-resolve under, or null when
  /// no drag is live.
  final Offset? Function() focalPointOf;

  /// Applies the re-hit at the post-frame focal point.
  final void Function(Offset focal) onRehit;

  bool _scheduled = false;

  /// Coalesced: a burst of scroll notifications in one frame re-hits once.
  void schedule() {
    if (_scheduled || !isActive() || focalPointOf() == null) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      final focal = focalPointOf();
      if (!isActive() || focal == null) return;
      onRehit(focal);
    });
  }
}
