import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One recorded [ImeJournal] entry: a monotonic [seq], an elapsed-ms
/// timestamp from the journal's own [Stopwatch] (never `DateTime.now()` —
/// wall clocks can step; ordering must be monotonic), the event [kind], and
/// a JSON-safe [payload] holding only copied-out primitives (strings, ints,
/// bools, lists) — never a framework object.
class ImeJournalEvent {
  const ImeJournalEvent({
    required this.seq,
    required this.elapsedMs,
    required this.kind,
    required this.payload,
  });

  final int seq;
  final int elapsedMs;
  final String kind;
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => {
    'seq': seq,
    'ms': elapsedMs,
    'kind': kind,
    'payload': payload,
  };
}

/// A bounded, structured debug log of everything that crosses the IME
/// boundary — the build strategy's record-and-replay seam ("a misbehaving
/// keyboard session on any device becomes a JSON capture that replays as a
/// unit test against `ImeService` with a fake platform channel").
///
/// [ImeService] records at every decision point with the RAW data (sentinel
/// visible, exact buffer offsets), and the editor widget interleaves
/// hardware key events into the same stream. The recorded kinds:
///
/// - `attach` / `detach` / `connectionClosed` — lifecycle; `attach` carries
///   the frontend mode.
/// - `snapshot` — an inbound `updateEditingValue` value, BEFORE any
///   filtering (diff frontend traffic).
/// - `deltas` — an inbound `updateEditingValueWithDeltas` batch, verbatim.
/// - `diff` — what the diff frontend's `diffTexts` produced (null result =
///   no text change).
/// - `composingSanitized` / `staleComposingSuppressed` — the composing
///   region filters changed what the synthesis sees.
/// - `staleComposingLatchDisarmed` — the stale-composing refusal released
///   its latch, with the reason (`corrective` / `differentRange` /
///   `fresh`); the `fresh` disarm is a known-ambiguous heuristic
///   (`_filterStaleComposing`), so a capture of its false-positive cascade
///   needs the decision on record.
/// - `composingSelectionAdopted` — batch-end reconciliation honored an
///   engine selection lying within the composing region instead of
///   terminating (WebKit's transient marked-text-selected report).
/// - `synthesized` — the delta synthesized from a snapshot (null = pure
///   echo of our own push); carries `deadKeyRewrite` when the append-shaped
///   commit compensation fired.
/// - `drop` — a filter/guard decision (`staleSnapshot`, `echoQuarantine`,
///   `staleDelta`).
/// - `push` — every `setEditingState` (window text, selection, composing,
///   `viaTerminate` flag).
/// - `terminate` — every `terminateComposition` (reason + the quarantined
///   composed text, when any).
/// - `performAction` / `performSelector` / `selectorUnhandled` — the
///   engine's non-delta callbacks.
/// - `commitKeySuppressionArmed` / `commitKeySuppressionSkipped` /
///   `commitKeySuppressionConsumed` / `commitKeySuppressionExpired` /
///   `commitKeySuppressionDisarmed` — the Safari post-compositionend
///   commit-key one-shot's decisions: armed when an engine snapshot ends a
///   live composition, skipped when a gate-deferred Enter proved the
///   keydown-first ordering, consumed (or expired) by the widget's
///   Enter/Escape consult, disarmed (with the reason) when a subsequently
///   accepted snapshot or a non-IME change proved the arm stale.
/// - `passiveReconcile` — the deferred reconciliation's one authoritative
///   push: what the absorbed engine window held (`discardedText` /
///   `discardedComposing`) vs the authoritative window that replaced it
///   (`pushedText` / `pushedSelection`).
/// - `key` — a hardware key event seen by the editor widget (kind, logical
///   key label, character, whether the composing gate deferred it, which
///   handler consumed it or `ignored` — `commitEnterSuppressed` names a
///   swallowed commit Enter).
///
/// Replayable kinds (`snapshot`, `deltas`, `performAction`,
/// `performSelector`, `key`) reconstruct the inbound side in a unit test —
/// see `test/input/ime_replay.dart`; the outbound kinds (`push`, `drop`,
/// `terminate`, `synthesized`) are the EXPECTED outputs a replay asserts
/// against.
///
/// Cost discipline: [record] takes the payload as a closure and returns
/// immediately while disabled ([enabled] defaults to [kDebugMode]), so
/// release builds pay one closure allocation per call site and nothing
/// else. The buffer is a ring capped at [capacity] events.
///
/// Extends [ChangeNotifier] purely as the inspector's live feed.
class ImeJournal extends ChangeNotifier {
  ImeJournal({this.capacity = 300, bool? enabled})
    : enabled = enabled ?? kDebugMode;

  /// Ring-buffer bound: the oldest event drops when a record would exceed
  /// it.
  final int capacity;

  /// Recording switch, fixed at construction. Defaults to [kDebugMode] —
  /// profile/release builds keep the journal empty.
  final bool enabled;

  final Stopwatch _clock = Stopwatch()..start();
  final ListQueue<ImeJournalEvent> _events = ListQueue<ImeJournalEvent>();
  int _nextSeq = 0;

  /// The retained events, oldest first. [seq] gaps reveal ring-buffer
  /// eviction (the sequence is monotonic across the journal's lifetime,
  /// not the buffer's).
  List<ImeJournalEvent> get events => List.unmodifiable(_events);

  /// Records one event. [payload] is deferred behind the [enabled] check;
  /// it must produce only JSON-safe copied-out values (no framework
  /// objects — encode them with [describeValue]/[describeDelta]/
  /// [describeRange]).
  void record(String kind, Map<String, Object?> Function() payload) {
    if (!enabled) return;
    _events.addLast(
      ImeJournalEvent(
        seq: _nextSeq++,
        elapsedMs: _clock.elapsedMilliseconds,
        kind: kind,
        payload: payload(),
      ),
    );
    while (_events.length > capacity) {
      _events.removeFirst();
    }
    notifyListeners();
  }

  /// Empties the buffer (the inspector's Clear). The sequence counter keeps
  /// running — post-clear events are recognizably later.
  void clear() {
    if (_events.isEmpty) return;
    _events.clear();
    notifyListeners();
  }

  /// The retained events as JSON-safe maps, oldest first — the shape
  /// `replayImeJournal` consumes.
  List<Map<String, Object?>> toJson() => [for (final e in _events) e.toJson()];

  /// Compact one-line-per-event JSON, built for paste-into-chat: each line
  /// is one `json.encode`d event, newline-joined.
  String dump() => _events.map((e) => json.encode(e.toJson())).join('\n');

  // --- Payload encoders (the copy-out boundary) ---

  /// `[start, end]`, or null for an invalid/sentinel range — raw values,
  /// never normalized or clamped (the journal records what actually
  /// arrived).
  static List<int>? describeRange(TextRange range) =>
      range.start < 0 || range.end < 0 ? null : [range.start, range.end];

  /// A [TextEditingValue] as `{text, sel: [base, extent], composing}`.
  static Map<String, Object?> describeValue(TextEditingValue value) => {
    'text': value.text,
    'sel': [value.selection.baseOffset, value.selection.extentOffset],
    'composing': describeRange(value.composing),
  };

  /// A [TextEditingDelta] with an explicit `type` tag (stable across
  /// minification, unlike `runtimeType`) plus its raw fields.
  static Map<String, Object?> describeDelta(TextEditingDelta delta) =>
      switch (delta) {
        TextEditingDeltaInsertion() => {
          'type': 'insertion',
          'oldText': delta.oldText,
          'inserted': delta.textInserted,
          'at': delta.insertionOffset,
          ..._deltaTail(delta),
        },
        TextEditingDeltaDeletion() => {
          'type': 'deletion',
          'oldText': delta.oldText,
          'deleted': [delta.deletedRange.start, delta.deletedRange.end],
          ..._deltaTail(delta),
        },
        TextEditingDeltaReplacement() => {
          'type': 'replacement',
          'oldText': delta.oldText,
          'replaced': [delta.replacedRange.start, delta.replacedRange.end],
          'text': delta.replacementText,
          ..._deltaTail(delta),
        },
        TextEditingDeltaNonTextUpdate() => {
          'type': 'nonText',
          'oldText': delta.oldText,
          ..._deltaTail(delta),
        },
        // TextEditingDelta is not sealed; an unknown kind records its name.
        _ => {
          'type': delta.runtimeType.toString(),
          'oldText': delta.oldText,
          ..._deltaTail(delta),
        },
      };

  static Map<String, Object?> _deltaTail(TextEditingDelta delta) => {
    'sel': [delta.selection.baseOffset, delta.selection.extentOffset],
    'composing': describeRange(delta.composing),
  };
}
