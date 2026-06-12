import 'dart:convert';

import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/services.dart';

/// Replays the INBOUND half of an [ImeJournal] capture into [service] — the
/// build strategy's record-and-replay seam: paste a journal dump out of the
/// inspector's Journal pane (Copy JSON), feed it to a fresh `ImeService`
/// wired to a `FakeImeConnection` + a controller seeded with the same
/// document/selection, and the misbehaving device session becomes a unit
/// test.
///
/// Replayed kinds (everything the engine/user originated):
///
/// - `snapshot` → [ImeService.updateEditingValue]
/// - `deltas`   → [ImeService.updateEditingValueWithDeltas]
/// - `performAction` / `performSelector` → the matching client callbacks
/// - `key` → the recorded `handler` verb on the service's controller (the
///   exact verb the widget's key dispatch ran; `ignored`/deferred keys are
///   skipped — the IME traffic they produced is in the stream already)
///
/// Everything else (`push`, `drop`, `terminate`, `diff`, `synthesized`,
/// `composingSanitized`, `staleComposingSuppressed`, lifecycle) is the
/// capture's OUTBOUND record — the EXPECTED outputs. A replay test asserts
/// against those: the fake connection's `pushed` list should match the
/// capture's `push` events, `debugLastDropReason` its `drop`s, and the
/// final document/shadow the state the session ended in.
///
/// The service must already be attached with the same [ImeFrontend] the
/// capture's `attach` event names — replay does not attach.
void replayImeJournal(ImeService service, Iterable<Object?> events) {
  for (final entry in events) {
    final event = (entry! as Map).cast<String, Object?>();
    final payload = ((event['payload'] ?? const <String, Object?>{}) as Map)
        .cast<String, Object?>();
    switch (event['kind']) {
      case 'snapshot':
        service.updateEditingValue(_value(payload));
      case 'deltas':
        service.updateEditingValueWithDeltas([
          for (final d in payload['deltas']! as List)
            _delta((d as Map).cast<String, Object?>()),
        ]);
      case 'performAction':
        service.performAction(
          TextInputAction.values.byName(payload['action']! as String),
        );
      case 'performSelector':
        service.performSelector(payload['selector']! as String);
      case 'key':
        _replayKey(service.controller, payload);
      default:
      // Outbound/expected events — not replayable, assert against them.
    }
  }
}

/// Splits a pasted [ImeJournal.dump] (one JSON object per line) back into
/// the event maps [replayImeJournal] consumes.
List<Map<String, Object?>> parseImeJournalDump(String dump) => [
  for (final line in const LineSplitter().convert(dump))
    if (line.trim().isNotEmpty)
      (json.decode(line) as Map).cast<String, Object?>(),
];

/// Runs the controller verb the widget's key dispatch recorded as `handler`
/// — keys it ignored or deferred to the IME carry no verb and are skipped,
/// as is `commitEnterSuppressed` (a swallowed commit Enter ran no verb).
void _replayKey(EditorController controller, Map<String, Object?> payload) {
  switch (payload['handler']) {
    case 'undo':
      controller.undo();
    case 'redo':
      controller.redo();
    case 'insertNewline':
      controller.insertNewline();
    case 'backspace':
      controller.backspace();
    case 'indent':
      controller.indent();
    case 'outdent':
      controller.outdent();
    case 'moveCaretBack':
      controller.moveCaret(-1);
    case 'moveCaretForward':
      controller.moveCaret(1);
  }
}

// --- Decoders (the mirror of ImeJournal's describe* encoders) ---

TextRange _range(Object? json) {
  if (json == null) return TextRange.empty;
  final list = (json as List).cast<int>();
  return TextRange(start: list[0], end: list[1]);
}

TextSelection _selection(Object? json) {
  final list = (json! as List).cast<int>();
  return TextSelection(baseOffset: list[0], extentOffset: list[1]);
}

TextEditingValue _value(Map<String, Object?> payload) => TextEditingValue(
  text: payload['text']! as String,
  selection: _selection(payload['sel']),
  composing: _range(payload['composing']),
);

TextEditingDelta _delta(Map<String, Object?> payload) {
  final oldText = payload['oldText']! as String;
  final selection = _selection(payload['sel']);
  final composing = _range(payload['composing']);
  return switch (payload['type']) {
    'insertion' => TextEditingDeltaInsertion(
      oldText: oldText,
      textInserted: payload['inserted']! as String,
      insertionOffset: payload['at']! as int,
      selection: selection,
      composing: composing,
    ),
    'deletion' => TextEditingDeltaDeletion(
      oldText: oldText,
      deletedRange: _range(payload['deleted']),
      selection: selection,
      composing: composing,
    ),
    'replacement' => TextEditingDeltaReplacement(
      oldText: oldText,
      replacedRange: _range(payload['replaced']),
      replacementText: payload['text']! as String,
      selection: selection,
      composing: composing,
    ),
    // 'nonText' and any unknown future kind: the no-text-change shape.
    _ => TextEditingDeltaNonTextUpdate(
      oldText: oldText,
      selection: selection,
      composing: composing,
    ),
  };
}
