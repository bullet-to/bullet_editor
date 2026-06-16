import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart'
    show
        FontWeight,
        Matrix4,
        MatrixUtils,
        RenderBox,
        TextAlign,
        TextDirection,
        TextStyle;

import '../editor/editor_controller.dart';
import '../editor/text_diff.dart';
import '../model/block.dart';
import '../model/doc_selection.dart';
import '../model/document.dart';
import '../schema/editor_schema.dart';
import '../view/block_layout_registry.dart';
import 'ime_journal.dart';

/// The connection surface `ImeService` writes through — a thin seam over
/// [TextInputConnection] so the service unit-tests against a fake without a
/// platform channel. [ImeGeometryChannel] is split out so the geometry
/// reporter can hold ONLY that view: it structurally cannot call
/// [setEditingState], which is what keeps G15 true (geometry changes never
/// touch text state).
abstract interface class ImeGeometryChannel {
  void setEditableSizeAndTransform(Size editableBoxSize, Matrix4 transform);
  void setComposingRect(Rect rect);
  void setCaretRect(Rect rect);

  /// `TextInput.setStyle` — the editable's font metrics, part of the
  /// presentation channel (never text state, so it belongs on the geometry
  /// view). On web this is the ONLY styling that reaches the engine's
  /// hidden editing element after creation: the engine applies it as CSS
  /// `font` + `text-align` (engine `text_editing.dart`:
  /// `EditableTextStyle.applyToDomElement`); without it the element keeps
  /// the browser's default input font, whose DOM caret height — the box
  /// the browser hangs the IME candidate window off — does not match our
  /// rendered line (see [ImeGeometryReporter]).
  void setStyle({
    required String? fontFamily,
    required double? fontSize,
    required FontWeight? fontWeight,
    required TextDirection textDirection,
    required TextAlign textAlign,
  });
}

/// One live engine connection (see [ImeGeometryChannel] for the split).
abstract interface class ImeConnection implements ImeGeometryChannel {
  bool get attached;
  void show();
  void setEditingState(TextEditingValue value);

  /// Acknowledges a platform-initiated close ([TextInputClient]'s
  /// `connectionClosed`): the framework's `TextInput` still records this
  /// connection as current until told otherwise, and a stale current
  /// connection wedges the next attach's bookkeeping.
  void connectionClosedReceived();
  void close();
}

/// Opens a connection for [client]. Defaults to [TextInput.attach]; tests
/// inject a fake. Called once per attach AND once per Android re-attach
/// inside `terminateComposition`.
typedef ImeConnectionFactory =
    ImeConnection Function(
      DeltaTextInputClient client,
      TextInputConfiguration configuration,
    );

class _RealImeConnection implements ImeConnection {
  _RealImeConnection(this._connection);

  final TextInputConnection _connection;

  @override
  bool get attached => _connection.attached;

  @override
  void show() => _connection.show();

  @override
  void setEditingState(TextEditingValue value) =>
      _connection.setEditingState(value);

  @override
  void setEditableSizeAndTransform(Size editableBoxSize, Matrix4 transform) =>
      _connection.setEditableSizeAndTransform(editableBoxSize, transform);

  @override
  void setComposingRect(Rect rect) => _connection.setComposingRect(rect);

  @override
  void setCaretRect(Rect rect) => _connection.setCaretRect(rect);

  @override
  void setStyle({
    required String? fontFamily,
    required double? fontSize,
    required FontWeight? fontWeight,
    required TextDirection textDirection,
    required TextAlign textAlign,
  }) => _connection.setStyle(
    fontFamily: fontFamily,
    fontSize: fontSize,
    fontWeight: fontWeight,
    textDirection: textDirection,
    textAlign: textAlign,
  );

  @override
  void connectionClosedReceived() => _connection.connectionClosedReceived();

  @override
  void close() => _connection.close();
}

ImeConnection _attachRealConnection(
  DeltaTextInputClient client,
  TextInputConfiguration configuration,
) {
  return _RealImeConnection(TextInput.attach(client, configuration));
}

/// Which engine frontend feeds the shared IME core (architecture §IME: "one
/// IME strategy, two frontends, one core"). Both frontends drive the same
/// shadow-buffer + resolve-at-apply machinery through the same choke point
/// and are full peers for composing state — every composing-gated mechanism
/// (underline, G3 latch, hardware-key gate, no-echo comparison) works
/// identically behind either.
enum ImeFrontend {
  /// `TextEditingDelta` batches (`enableDeltaModel: true`) — iOS, Android,
  /// desktop.
  delta,

  /// Full [TextEditingValue] snapshots diffed against the shadow buffer
  /// (`text_diff.dart`, appflowy's `NonDeltaInputService` shape) — web
  /// engines don't deliver reliable deltas (§IME web fallback). Flippable
  /// per-platform; also the R1 mitigation for Android OEM delta breakage.
  nonDeltaDiff;

  /// The per-platform default: web takes the diff fallback, everything else
  /// the delta model.
  static ImeFrontend get platformDefault =>
      kIsWeb ? ImeFrontend.nonDeltaDiff : ImeFrontend.delta;
}

/// One block's slice of the IME buffer.
class ImeWindowSpan {
  const ImeWindowSpan({
    required this.blockId,
    required this.bufferStart,
    required this.bufferEnd,
    this.isVoid = false,
    this.isElision = false,
  });

  final String blockId;

  /// Buffer range this span occupies (`bufferEnd` exclusive). Spans are
  /// separated by one `\n` joint each. [bufferStart] is block-local offset 0
  /// — every window starts each block at its head (a G1 merge re-serializes
  /// a fresh window rather than remapping this one).
  final int bufferStart;
  final int bufferEnd;

  /// A `~` void placeholder (offset 0 at its start, 1 at its end).
  final bool isVoid;

  /// The `~` standing in for a capped window's elided interior — has no
  /// block; any delta touching it classifies as a whole-selection
  /// replacement (§buffer serialization).
  final bool isElision;
}

/// The serialized IME buffer for the block(s) under the selection: one
/// leading [sentinel], block plain texts joined with `\n`, voids as `~`
/// (architecture §buffer serialization).
class ImeWindow {
  ImeWindow({
    required this.text,
    required this.selection,
    required this.spans,
    this.elided = false,
  });

  /// Super_editor's verified constant: visible-class text the IME's word
  /// segmentation treats as a completed sentence, so autocapitalization sees
  /// a sentence start and autocorrect never binds across it. An invisible
  /// sentinel (zero-width space) is deliberately rejected — an unvalidated
  /// per-IME breakage class on Android. One constant, one place.
  static const String sentinel = '. ';

  /// Void blocks serialize as `~` (super_editor's encoding).
  static const String voidPlaceholder = '~';

  /// Window cap (§buffer serialization): selections beyond these serialize
  /// as sentinel + first block + `\n~\n` + last block, keeping payloads
  /// bounded — the quill-style whole-document failure mode stays
  /// structurally impossible.
  static const int maxWindowBlocks = 32;
  static const int maxWindowChars = 2000;

  final String text;
  final TextSelection selection;
  final List<ImeWindowSpan> spans;
  final bool elided;

  TextEditingValue toValue({TextRange composing = TextRange.empty}) =>
      TextEditingValue(text: text, selection: selection, composing: composing);

  /// Buffer offset → model position, clamping into the nearest span:
  /// offsets inside the sentinel land at the first block's start (G1's
  /// mapped form arrives through the deletion path, not here). Returns null
  /// only for the elided interior.
  DocPosition? positionForBufferOffset(int offset) {
    if (spans.isEmpty) return null;
    ImeWindowSpan? previous;
    for (final span in spans) {
      if (offset < span.bufferStart) {
        // Between spans (a `\n` joint) or inside the sentinel: clamp to the
        // earlier span's end, else the first span's start.
        final target = previous ?? span;
        if (target.isElision) return null;
        final local = identical(target, span)
            ? 0
            : target.bufferEnd - target.bufferStart;
        return DocPosition(target.blockId, local);
      }
      if (offset <= span.bufferEnd) {
        if (span.isElision) return null;
        return DocPosition(span.blockId, offset - span.bufferStart);
      }
      previous = span;
    }
    final last = spans.last;
    if (last.isElision) return null;
    return DocPosition(last.blockId, last.bufferEnd - last.bufferStart);
  }

  /// Whether the buffer range `[start, end)` touches the elided interior.
  bool touchesElision(int start, int end) {
    for (final span in spans) {
      if (span.isElision && start < span.bufferEnd && end > span.bufferStart) {
        return true;
      }
    }
    return false;
  }

  /// The span containing the whole buffer range, or null when it crosses a
  /// joint / the sentinel / a void.
  ImeWindowSpan? textSpanContaining(int start, int end) {
    for (final span in spans) {
      if (span.isVoid || span.isElision) continue;
      if (start >= span.bufferStart && end <= span.bufferEnd) return span;
    }
    return null;
  }
}

/// Serializes the window for [selection] over [doc] (architecture §buffer
/// serialization). Exposed for tests; production callers go through
/// [ImeService].
ImeWindow serializeImeWindow(
  Document doc,
  DocSelection? selection,
  EditorSchema schema,
) {
  const sentinelLength = ImeWindow.sentinel.length;
  if (selection == null) {
    return ImeWindow(
      text: ImeWindow.sentinel,
      selection: const TextSelection.collapsed(offset: sentinelLength),
      spans: const [],
    );
  }

  final (start, end) = selection.normalized(doc);
  final si = doc.idToFlatIndex[start.blockId];
  final ei = doc.idToFlatIndex[end.blockId];
  if (si == null || ei == null) {
    return ImeWindow(
      text: ImeWindow.sentinel,
      selection: const TextSelection.collapsed(offset: sentinelLength),
      spans: const [],
    );
  }

  final blocks = [for (var i = si; i <= ei; i++) doc.allBlocks[i]];
  var totalChars = 0;
  for (final b in blocks) {
    totalChars += b.length;
  }
  final elided =
      blocks.length > ImeWindow.maxWindowBlocks ||
      totalChars > ImeWindow.maxWindowChars;

  final buffer = StringBuffer(ImeWindow.sentinel);
  final spans = <ImeWindowSpan>[];
  var offset = sentinelLength;

  void addBlock(TextBlock block) {
    if (schema.isVoid(block.blockType)) {
      spans.add(
        ImeWindowSpan(
          blockId: block.id,
          bufferStart: offset,
          bufferEnd: offset + 1,
          isVoid: true,
        ),
      );
      buffer.write(ImeWindow.voidPlaceholder);
      offset += 1;
    } else {
      final text = block.plainText;
      spans.add(
        ImeWindowSpan(
          blockId: block.id,
          bufferStart: offset,
          bufferEnd: offset + text.length,
        ),
      );
      buffer.write(text);
      offset += text.length;
    }
  }

  void addJoint() {
    buffer.write('\n');
    offset += 1;
  }

  if (elided) {
    // Sentinel + first block + `\n~\n` + last block: the first block's text
    // is the type-over autocapitalization context, the edges serve
    // engine-side selection adjustments (§buffer serialization).
    addBlock(blocks.first);
    addJoint();
    spans.add(
      ImeWindowSpan(
        blockId: '',
        bufferStart: offset,
        bufferEnd: offset + 1,
        isElision: true,
      ),
    );
    buffer.write(ImeWindow.voidPlaceholder);
    offset += 1;
    addJoint();
    addBlock(blocks.last);
  } else {
    for (var i = 0; i < blocks.length; i++) {
      if (i > 0) addJoint();
      addBlock(blocks[i]);
    }
  }

  final window = ImeWindow(
    text: buffer.toString(),
    selection: const TextSelection.collapsed(offset: sentinelLength),
    spans: spans,
    elided: elided,
  );

  int bufferOffsetFor(DocPosition position) {
    for (final span in window.spans) {
      if (span.isElision || span.blockId != position.blockId) continue;
      final clamped = position.offset.clamp(
        0,
        span.bufferEnd - span.bufferStart,
      );
      return span.bufferStart + clamped;
    }
    return sentinelLength;
  }

  return ImeWindow(
    text: window.text,
    selection: TextSelection(
      baseOffset: bufferOffsetFor(selection.base),
      extentOffset: bufferOffsetFor(selection.extent),
    ),
    spans: spans,
    elided: elided,
  );
}

/// One `ImeService` owning one engine connection (architecture §IME: one
/// strategy, two frontends, one core — the delta model per [frontend], or
/// the web non-delta diff fallback over the same core). Responsibilities:
///
/// - the shadow buffer — text AND selection AND composing region as last
///   pushed to or acknowledged from the engine; the no-echo comparison
///   covers all three;
/// - delta → op translation through the controller's IME surface (one
///   choke point for every mutation), fed by engine deltas or by deltas
///   synthesized from full-value diffs (§web fallback);
/// - the stale-delta guard (pre-push races) and the post-terminate echo
///   quarantine (post-push races) — complementary, neither alone suffices;
/// - [terminateComposition] — the ONE path allowed to push while the shadow
///   reports an active composition, with the Android connection re-attach
///   for every reason with a live connection;
/// - the G3 rules latch and the post-batch input-rule run path;
/// - geometry reporting through a reporter that cannot touch text state.
///
/// Extends [ChangeNotifier] purely as the inspector's debug feed.
class ImeService extends ChangeNotifier
    with TextInputClient, DeltaTextInputClient {
  ImeService({
    required this.controller,
    ImeFrontend? frontend,
    ImeConnectionFactory? connectionFactory,
    TextInputConfiguration? configuration,
    int Function()? monotonicNowMs,
  }) : assert(
         configuration == null ||
             configuration.enableDeltaModel ==
                 ((frontend ?? ImeFrontend.platformDefault) ==
                     ImeFrontend.delta),
         'configuration.enableDeltaModel must agree with the frontend: the '
         'delta frontend attaches with the delta model, the diff frontend '
         'without it (architecture §IME: one strategy, two frontends) — a '
         'mismatched declaration leaves the engine feeding the wrong client '
         'callback.',
       ),
       frontend = frontend ?? ImeFrontend.platformDefault,
       _monotonicNowMs = monotonicNowMs ?? _newStopwatchClock(),
       _connectionFactory = connectionFactory ?? _attachRealConnection,
       _configuration =
           configuration ??
           ((frontend ?? ImeFrontend.platformDefault) == ImeFrontend.delta
               ? defaultConfiguration
               : nonDeltaConfiguration) {
    controller.imeExternalChangeHandler = _onExternalChange;
  }

  /// Autocorrect IS the delta path (D8): declared here, corrected through
  /// the same delta application as typing. Cap-sentences is declared so the
  /// sentinel's autocapitalization rationale ([ImeWindow.sentinel]; the
  /// day-9 "no spurious capitalization" gate trace) actually engages —
  /// Android never enables sentence capitalization without it.
  static const TextInputConfiguration defaultConfiguration =
      TextInputConfiguration(
        inputType: TextInputType.multiline,
        inputAction: TextInputAction.newline,
        enableDeltaModel: true,
        autocorrect: true,
        enableSuggestions: true,
        textCapitalization: TextCapitalization.sentences,
      );

  /// [defaultConfiguration] minus the delta model — the [ImeFrontend
  /// .nonDeltaDiff] attach shape: the engine delivers full editing values
  /// through `updateEditingValue` and the diff frontend synthesizes the
  /// deltas itself (§IME web fallback).
  static const TextInputConfiguration nonDeltaConfiguration =
      TextInputConfiguration(
        inputType: TextInputType.multiline,
        inputAction: TextInputAction.newline,
        enableDeltaModel: false,
        autocorrect: true,
        enableSuggestions: true,
        textCapitalization: TextCapitalization.sentences,
      );

  final EditorController controller;

  /// Which frontend this service was attached as — fixed for the service's
  /// lifetime (a connection's delta-model declaration cannot change without
  /// a re-attach; the widget rebuilds the service to flip it).
  final ImeFrontend frontend;
  final ImeConnectionFactory _connectionFactory;
  final TextInputConfiguration _configuration;

  /// Monotonic elapsed-ms clock behind the commit-key suppression window —
  /// the journal's Stopwatch pattern (wall clocks can step; a window check
  /// must be monotonic), injectable so tests drive the window
  /// deterministically. Defaults to a service-lifetime [Stopwatch].
  final int Function() _monotonicNowMs;

  static int Function() _newStopwatchClock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsedMilliseconds;
  }

  /// The geometry reporter — a distinct object with no access to
  /// `setEditingState` (G15). The widget wires its lookups.
  final ImeGeometryReporter geometryReporter = ImeGeometryReporter();

  ImeConnection? _connection;

  /// The editor wants a connection (focus held) — drives the lazy re-attach
  /// after `connectionClosed`.
  bool _wantsConnection = false;

  /// The shadow buffer: the last [TextEditingValue] pushed to or
  /// acknowledged from the engine.
  TextEditingValue? _shadow;

  /// The window mapping matching [_shadow] while convergent.
  ImeWindow? _window;

  /// The shadow text the most recent NON-terminate push replaced (null when
  /// none). The diff frontend's pre-push race mitigation keys on it: a
  /// snapshot whose text equals this was computed by the browser against
  /// the window we just replaced (host-app edit → clause (a)/(b) push → the
  /// in-flight snapshot lands) and must not be diffed against the fresh
  /// shadow — see [updateEditingValue]. A dead-key rewrite's resync push
  /// arms it with the append-shaped snapshot text for the same reason
  /// ([_rewriteDeadKeyCommit]). Cleared the moment the race window
  /// provably closes: the race can only involve snapshots already in flight
  /// AT push time, so the first ACCEPTED post-push snapshot (the pure-echo
  /// acknowledgement or a successfully synthesized value) clears it —
  /// without that, the user retyping exactly what a push just deleted is
  /// indistinguishable from the race and gets eaten (the day-8 web dead-key
  /// double-cycle bug). A terminate push also clears it: the post-terminate
  /// flavor of the race is the echo quarantine's territory.
  String? _previousShadowText;

  /// The composing range whose composition the dead-key rewrite just
  /// terminated (null when none) — the diff frontend's refusal of Safari's
  /// stale composing re-arm, the rewrite's follow-up half. The engine's
  /// composition bookkeeping (composition_aware_mixin.dart: `composingText`
  /// held from every compositionupdate, `composingBase ??=` — both reset
  /// ONLY by compositionstart/compositionend) outlives the commit we
  /// rewrote: nothing we push fires a composition event, so until a real
  /// compositionend reaches the engine, every handleChange-driven snapshot
  /// (the resync push's own selectionchange echo, the user's next plain
  /// keystrokes) still reports the dead range. Re-armed into the shadow it
  /// sticks the underline over the committed character, and the very next
  /// keystroke satisfies [_rewriteDeadKeyCommit]'s guards again and
  /// replaces the é with a plain e — the "IME status gets stuck" Safari
  /// bug. v2 was immune by construction: it honored the platform's
  /// composing only as an is-composing gate and deferred its engine sync to
  /// the first non-composing frame (v0.1.7, 1abe94b — `_finalizeComposing`),
  /// never mapping the region into model state; v3's composing-complete
  /// frontend (§web fallback's full-peer contract) must refuse the dead
  /// latch explicitly instead — [_filterStaleComposing].
  ///
  /// Lifecycle: armed by the dead-key rewrite ([updateEditingValue]'s
  /// rewrite block) and by the passive reconcile push
  /// ([_absorbWhileDiverged] — the same in-flight protection for the other
  /// push that replaces a mid-composition engine window, armed with the
  /// absorbed engine range); survives every push INCLUDING terminate pushes —
  /// `setEditingState` cannot reset the browser-side latch, so the refusal
  /// must outlive anything we send. Disarmed by the first snapshot proving
  /// the engine latch dead or re-latched: one carrying no composing region
  /// (the mixin only attaches a region while it holds `composingText`, so
  /// compositionend finally reflected), one carrying a DIFFERENT range
  /// (only compositionstart re-latches the base — a new live composition),
  /// or a composition-shaped report of the same range (the freshness test
  /// in [_filterStaleComposing]); and by detach/connectionClosed (a fresh
  /// attach gets a fresh engine strategy, mixin state included).
  TextRange? _staleComposingLatch;

  /// The one-batch echo quarantine (G7/G10): the terminated composing text
  /// and the pushed-window caret it would echo back at. Armed by
  /// [terminateComposition], consumed (disarmed) by the next TEXT-bearing
  /// delta batch (a `NonTextUpdate`-only batch is pushless selection noise,
  /// not the user retyping) — and cleared by any intervening non-terminate
  /// push (spec §echo quarantine: it covers the first batch after the
  /// *terminate* push; once a newer window has been pushed, a matching
  /// insertion is genuine input against that window, not an echo). Matches
  /// only COMMIT-shaped insertions (empty composing): a matching insertion
  /// carrying a live composing region is fresh marked text (macOS dead-key
  /// recomposition), never the held-syllable re-commit the quarantine
  /// exists for.
  ({String text, int offset})? _quarantine;

  /// The G3 rules latch: insert-pattern rules are deferred, not dropped —
  /// re-evaluated when a later batch (or a `NonTextUpdate`) ends with
  /// composing cleared. Invalidated by every [terminateComposition] and by
  /// any non-IME change.
  ({String blockId, TextRange range})? _rulesLatch;

  /// The diff frontend's deferred-reconciliation flag (passive-while-
  /// composing, §web fallback): a mid-composition snapshot could not be
  /// absorbed — its structural shape moved the window away from the
  /// engine's buffer, or the composing region stopped mapping into one
  /// block — and the one legal response under the passivity invariant is to
  /// DEFER: the window mapping no longer matches the engine buffer, so
  /// applying later snapshots through it would corrupt, and pushing (even
  /// via terminate) would destroy the browser's marked region while the
  /// IME's internal buffer continues (the captured `nににhにほ…`
  /// accumulation — the web engine cannot re-mark text). While armed,
  /// snapshots acknowledge one-way into the shadow; the snapshot that ends
  /// the composition (composing live→empty) runs the one authoritative
  /// reconciliation push ([_absorbWhileDiverged]). Deliberate terminations
  /// (undo, external edits, detach) resolve it early — their authoritative
  /// push IS the reconciliation. Never armed on the delta frontend.
  bool _passiveDivergence = false;

  /// iOS sends `performAction(newline)` BEFORE the delta batch that carries
  /// the actual text changes. Keyboards that commit on Enter (Hindi
  /// transliteration: "namaste" → "नमस्ते") send the transliteration delta
  /// AFTER the action — firing `imeInsertNewline()` eagerly in performAction
  /// would reset the shadow and stale-drop the transliteration. Instead,
  /// performAction sets this flag and the flush ([_flushPendingNewline])
  /// runs at the END of the accompanying batch, after the batch's text has
  /// landed.
  ///
  /// A batch always accompanies the action on the supported platforms:
  /// macOS intercepts `insertNewline:` and reports Enter as an insertText
  /// `"\n"` delta plus the action (see [performSelector]); iOS sends the
  /// `"\n"` (or the commit-on-Enter transliteration) delta right behind the
  /// action. A bare `"\n"` delta in that batch performs the split itself and
  /// clears this flag ([_insertParts]) so the flush is a no-op — exactly one
  /// split. Tests that exercise performAction without scripting the
  /// follow-up batch fire the flush directly via [flushPendingNewline].
  bool _pendingNewlineAction = false;

  /// The one-shot commit-key suppression's arming timestamp
  /// ([_monotonicNowMs] domain; null = disarmed) — the WebKit
  /// keydown-after-compositionend compensation. Safari fires compositionend
  /// BEFORE the keydown of the key that ended the composition, so the Enter
  /// that COMMITS a Japanese conversion reaches the framework as an
  /// ordinary keydown with `controller.composing` already null — the
  /// widget's composing gate cannot defer it, and the handled key inserts a
  /// spurious paragraph (the captured Safari Japanese session: conversion
  /// display → compositionend reflected → Enter keydown 29 ms later).
  /// The ordering is NOT Enter-specific — it applies to every key the IME
  /// consumes to end a composition: a second capture (Safari, a lone
  /// composed `n` at the end of a block canceled with one Backspace) shows
  /// the composing-clear snapshot land first, the arm fire, and the
  /// trailing Backspace keydown then delete a genuine character (the
  /// block's period) because only Enter consulted the one-shot. The widget
  /// therefore consults for ALL the gated editing keys its handlers act on
  /// destructively — Enter/numpadEnter, Backspace, Tab — plus Escape,
  /// which spends the arm without handling; arrows/Home/End are not
  /// consulted (a trailing arrow only moves the caret, and the selection
  /// change it causes disarms a pending arm anyway).
  /// Chrome/Firefox fire the keydown first (keyCode 229, composition still
  /// live), so the gate covers them there. Prior art: ProseMirror's Safari
  /// workaround (prosemirror-view `input.ts`: `compositionEndedAt` recorded
  /// on compositionend, a near-composition keydown — keyCodes 13/27 —
  /// within 500 ms treated as part of the just-ended composition, the
  /// timestamp reset once consumed; our key set is broader than 13/27
  /// because, unlike ProseMirror, our hardware handlers also act on
  /// Backspace and Tab once the composition is gone).
  ///
  /// Lifecycle: armed by [_armCommitKeySuppression] when an ENGINE-reported
  /// snapshot ends a live shadow composition (the diff frontend's
  /// `updateEditingValue` — the delta frontend never arms: on the delta
  /// platforms the committing keydown precedes the composing-clear and the
  /// gate already owns it, so arming there would swallow the user's next
  /// genuine Enter after every commit). NOT armed when WE end the
  /// composition ([terminateComposition] disarms outright — the engine-side
  /// fallout of our own terminate is the echo quarantine's territory) nor
  /// off the dead-key rewrite (its snapshot still carries the live — stale
  /// — region, so the live→empty transition never matches; the late
  /// compositionend reflects against an already-empty shadow composing).
  /// Disarmed by [consumeCommitKeySuppression] (the one-shot), by
  /// [terminateComposition], and by [detach].
  int? _commitKeySuppressionArmedAtMs;

  /// Elapsed-ms timestamp of the last commit-capable keydown (Enter,
  /// Backspace, Tab) the widget's composing gate deferred to the IME (null
  /// = none) — [noteCommitKeyDeferred]. The Chrome/Firefox ordering proof:
  /// when the composition-ending keydown reached the framework BEFORE the
  /// composing-clear, the gate already consumed it, so the composition end
  /// it produces must not arm the suppression (see
  /// [_armCommitKeySuppression]).
  ///
  /// Single slot, overwritten by each deferral — one note per
  /// composition-ending event is the shape, and the broader key set keeps
  /// it: on the keydown-first platforms every press of these keys defers
  /// while the composition is live, so the note standing when the
  /// composing-clear arrives is the ending key's own (a mid-composition
  /// Backspace's note is overwritten by the canceling one). The arm
  /// consult consumes the slot unconditionally and the 500 ms window
  /// bounds staleness. Known residual, WebKit-only: a gate-deferred
  /// MID-composition Backspace (keydown-first there — only the ENDING
  /// key's ordering inverts) noted less than a window before a Safari
  /// composition end skips that arm, degrading that one press to the
  /// pre-suppression behavior — never worse than the status quo this
  /// machinery replaced, and any intervening snapshot re-scopes it.
  int? _commitKeyDeferredAtMs;

  bool get isAttached => _connection != null;

  /// Whether the ENGINE side still owns a live composition even though
  /// `controller.composing` may be null — the widget's hardware-key
  /// composing gate ORs this into its `controller.composing != null` check.
  ///
  /// The two can diverge on the diff frontend: a composition whose FIRST
  /// snapshot is already unmappable (a composing region spanning a `\n`)
  /// arms the deferred reconciliation ([_passiveDivergence]) without ever
  /// having installed a [ComposingState] — there is no mapped region to
  /// install. Gating on the model state alone would leave editing keys
  /// reaching the document mid-browser-composition: external-edit
  /// terminate → mid-composition push — exactly the corruption class the
  /// gate exists to prevent. The shadow's composing region is included
  /// alongside the passive flag because it is the engine's own report
  /// (acknowledged one-way during the passive window) and outlives the
  /// flag by nothing — both clear on the composition-ending snapshot, on
  /// every terminate, and on detach.
  bool get engineComposing => _passiveDivergence || _shadowComposing;

  // --- Inspector / debug surface (pane 3) ---

  /// The structured debug event log (see [ImeJournal] for the kinds): every
  /// inbound snapshot/batch, every filter decision, every push and
  /// terminate — plus the editor widget's hardware key events, interleaved.
  /// Debug-only by default ([ImeJournal.enabled]); a capture pastes out of
  /// the inspector's journal pane and replays as a unit test
  /// (`test/input/ime_replay.dart`).
  final ImeJournal journal = ImeJournal();

  TextEditingValue? get debugShadow => _shadow;
  List<TextEditingDelta>? debugLastDeltas;

  /// The diff frontend's last `diffTexts` result (null = the incoming value
  /// carried no text change — the NonTextUpdate analogue or a pure echo).
  /// Only meaningful when [frontend] is [ImeFrontend.nonDeltaDiff].
  TextDiff? debugLastDiff;
  String? debugLastTerminateReason;
  String? debugLastDropReason;
  String? debugLastSelector;
  String? debugLastUnhandledSelector;
  bool get debugQuarantineArmed => _quarantine != null;
  ({String text, int offset})? get debugQuarantine => _quarantine;

  /// The armed stale-composing refusal ([_staleComposingLatch]); null when
  /// disarmed. Only meaningful when [frontend] is [ImeFrontend.nonDeltaDiff].
  TextRange? get debugStaleComposingLatch => _staleComposingLatch;

  /// Whether the commit-key suppression is armed
  /// ([_commitKeySuppressionArmedAtMs]) — window expiry is checked at
  /// consumption, not here. Only meaningful when [frontend] is
  /// [ImeFrontend.nonDeltaDiff] (the delta frontend never arms).
  bool get debugCommitKeySuppressionArmed =>
      _commitKeySuppressionArmedAtMs != null;

  // --- Lifecycle ---

  /// Opens the connection and pushes the current window. Idempotent.
  /// Attached whenever the editor has focus — including when the selection
  /// is on a void block (buffer = sentinel + `~`), so an active connection
  /// exists for context menus and void-delete deltas (G9, GATE-M).
  void attach() {
    _wantsConnection = true;
    if (_connection != null) return;
    journal.record('attach', () => {'frontend': frontend.name});
    _connection = _connectionFactory(this, _configuration);
    _connection!.show();
    _pushAuthoritativeWindow();
    _scheduleGeometryReport();
    notifyListeners();
  }

  /// Closes the connection (focus lost). A live composition is simply
  /// abandoned engine-side; controller state clears with it.
  void detach() {
    _wantsConnection = false;
    if (_connection == null) return;
    journal.record('detach', () => const {});
    _connection!.close();
    _connection = null;
    _shadow = null;
    _window = null;
    _previousShadowText = null;
    _staleComposingLatch = null;
    _quarantine = null;
    _rulesLatch = null;
    _passiveDivergence = false;
    _pendingNewlineAction = false;
    _commitKeySuppressionArmedAtMs = null;
    _commitKeyDeferredAtMs = null;
    controller.imeClearComposing();
    notifyListeners();
  }

  @override
  void dispose() {
    detach();
    // Tear-offs of the same method on the same instance compare equal —
    // only unhook if a newer service hasn't replaced the registration.
    if (controller.imeExternalChangeHandler == _onExternalChange) {
      controller.imeExternalChangeHandler = null;
    }
    journal.dispose();
    super.dispose();
  }

  // --- The single push point (the no-echo invariant) ---

  bool get _shadowComposing {
    final shadow = _shadow;
    return shadow != null &&
        shadow.composing.isValid &&
        !shadow.composing.isCollapsed;
  }

  /// `setEditingState` has exactly one caller. The debug assert fires if any
  /// push happens while the shadow reports an active composition — except
  /// through [terminateComposition], the one named exemption.
  void _push(
    TextEditingValue value,
    ImeWindow window, {
    bool viaTerminate = false,
  }) {
    assert(
      viaTerminate || !_shadowComposing,
      'no-echo invariant violated: pushing editing state while the shadow '
      'reports an active composition is only legal through '
      'terminateComposition (architecture §IME choke point)',
    );
    journal.record(
      'push',
      () => {...ImeJournal.describeValue(value), 'viaTerminate': viaTerminate},
    );
    // Any push that is NOT the terminate push obsoletes the quarantine: the
    // engine now holds a newer window, so a delta matching the quarantine
    // signature would be genuine input, not the post-terminate echo.
    if (!viaTerminate) _quarantine = null;
    // The diff frontend's pre-push race drop keys on the text this push
    // replaces. A terminate push hands the race to the quarantine instead;
    // a push with UNCHANGED text (a clause-(b) selection-only push, or the
    // drop's own recovery re-push) retains the older text — the in-flight
    // snapshot it guards against can still arrive after such a push.
    if (viaTerminate) {
      _previousShadowText = null;
    } else if (_shadow?.text != value.text) {
      _previousShadowText = _shadow?.text;
    }
    _shadow = value;
    _window = window;
    _connection?.setEditingState(value);
  }

  ImeWindow _serialize() => serializeImeWindow(
    controller.document,
    controller.selection,
    controller.schema,
  );

  void _pushAuthoritativeWindow({bool viaTerminate = false}) {
    final window = _serialize();
    _push(window.toValue(), window, viaTerminate: viaTerminate);
  }

  static bool _selectionsEquivalent(TextSelection a, TextSelection b) =>
      a.start == b.start && a.end == b.end;

  // --- terminateComposition — the composition choke point ---

  /// Every termination reason routes through here: clears
  /// `controller.composing` and the G3 latch, re-serializes the window, arms
  /// the one-batch echo quarantine, and performs ONE push with empty
  /// composing. On Android, for every reason with a live connection, the
  /// push is a connection-level restart (detach + re-attach): the no-echo
  /// invariant starves the embedding of the composing-region signal its own
  /// `restartInput` defense keys on, and a bare push with empty composing
  /// does NOT trigger `restartInput` on OEM keyboards — the re-attach is the
  /// only mechanism that reliably makes an IME abandon internal composition
  /// state. `'connectionClosed'` naturally skips the push (no connection).
  void terminateComposition(String reason) {
    debugLastTerminateReason = reason;
    _rulesLatch = null; // a stale latch can never fire (G3 invalidation)
    // A deliberate termination resolves any deferred passive divergence:
    // the authoritative push below IS the reconciliation (§web fallback
    // passive-while-composing — deliberate terminations survive and push).
    _passiveDivergence = false;
    // The engine did not end this composition — we did. The commit-key
    // suppression must never arm (or stay armed) off our own terminate: the
    // engine-side fallout of a terminate push is the echo quarantine's
    // territory, and an armed one-shot here would swallow a genuine Enter.
    _commitKeySuppressionArmedAtMs = null;

    // Record the quarantine payload BEFORE clearing: the engine-side
    // composed text is what an OEM IME holding internal composition would
    // re-commit against the freshly pushed shadow.
    final shadow = _shadow;
    final composedText = _shadowComposing
        ? shadow!.composing.textInside(shadow.text)
        : null;
    journal.record(
      'terminate',
      () => {'reason': reason, 'composed': composedText},
    );

    controller.imeClearComposing();

    if (reason == 'connectionClosed' || _connection == null) {
      // Push and re-attach skipped: there is no connection. State clears so
      // the lazy re-attach starts fresh (a new attach means a new engine
      // strategy — the stale-composing refusal's engine latch died with it).
      _shadow = null;
      _window = null;
      _previousShadowText = null;
      _staleComposingLatch = null;
      _quarantine = null;
      notifyListeners();
      return;
    }

    final window = _serialize();
    final value = window.toValue();
    if (composedText != null && composedText.isNotEmpty) {
      _quarantine = (text: composedText, offset: value.selection.start);
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      // Connection-level restart for EVERY reason — no per-case exemptions,
      // no unverified claims about what IMEs commit before what (G4's
      // discipline applied to G10). A same-frame detach + re-attach does not
      // flap the keyboard: TextInput cancels the frame-end hide when a new
      // attach arrives in the same frame.
      _connection!.close();
      _connection = _connectionFactory(this, _configuration);
      _connection!.show();
    }

    _push(value, window, viaTerminate: true);
    _scheduleGeometryReport();
    notifyListeners();
  }

  // --- The commit-key suppression (Safari's keydown-after-compositionend
  // ordering — see [_commitKeySuppressionArmedAtMs] for the full story) ---

  /// How long after an engine-reported composition end a hardware
  /// commit-capable key (Enter, Backspace, Tab, Escape) still reads as the
  /// keystroke that ENDED it. ProseMirror's number:
  /// prosemirror-view treats a Safari Enter/Escape keydown within 500 ms of
  /// `compositionEndedAt` as belonging to the just-ended composition. The
  /// real gap is tens of milliseconds (29 ms in the captured session); the
  /// window only bounds how long a stray arm can linger before expiring.
  static const Duration commitKeySuppressionWindow = Duration(
    milliseconds: 500,
  );

  /// The widget's composing gate deferred a commit-capable key (Enter,
  /// Backspace, Tab) to the platform IME — the Chrome/Firefox ordering,
  /// where the composition-ending keydown reaches the framework BEFORE
  /// compositionend (keyCode 229, model composition still live). Recording
  /// it keeps [_armCommitKeySuppression] from arming off that key's own
  /// composition end: the gate already consumed the key there, and an
  /// armed one-shot would swallow the user's next genuine press (commit
  /// the conversion, Enter for a new line — the standard Japanese flow;
  /// or cancel by Backspace, Backspace again to keep deleting).
  void noteCommitKeyDeferred() {
    _commitKeyDeferredAtMs = _monotonicNowMs();
  }

  /// Consults — and disarms — the one-shot commit-key suppression: true iff
  /// a live composition ended engine-side within
  /// [commitKeySuppressionWindow] and nothing consumed the arm yet. The
  /// widget's Enter/Backspace/Tab handlers call this after the composing
  /// gate (and Escape spends it without handling): true means the keydown
  /// is Safari's post-compositionend commit/cancel key and must not edit
  /// the document — the IME already applied its effect engine-side. One
  /// consult disarms regardless of the verdict (ProseMirror's
  /// consumed-once-then-reset), so the very next press behaves normally.
  bool consumeCommitKeySuppression() {
    final armedAt = _commitKeySuppressionArmedAtMs;
    if (armedAt == null) return false;
    _commitKeySuppressionArmedAtMs = null;
    final sinceArmedMs = _monotonicNowMs() - armedAt;
    if (sinceArmedMs > commitKeySuppressionWindow.inMilliseconds) {
      journal.record(
        'commitKeySuppressionExpired',
        () => {'sinceArmedMs': sinceArmedMs},
      );
      return false;
    }
    journal.record(
      'commitKeySuppressionConsumed',
      () => {'sinceArmedMs': sinceArmedMs},
    );
    return true;
  }

  /// Arms the one-shot — called from the diff frontend's snapshot path when
  /// an accepted engine snapshot ends a live shadow composition (the
  /// composing-clear that reflects compositionend). Skipped when a
  /// gate-deferred commit-capable key (Enter/Backspace/Tab) preceded the
  /// clear within the window: that is the Chrome/Firefox keydown-first
  /// ordering, where the composition-ending key already passed through the
  /// gate ([noteCommitKeyDeferred]) and no second keydown is coming.
  void _armCommitKeySuppression() {
    final deferredAt = _commitKeyDeferredAtMs;
    _commitKeyDeferredAtMs = null;
    final now = _monotonicNowMs();
    if (deferredAt != null &&
        now - deferredAt <= commitKeySuppressionWindow.inMilliseconds) {
      journal.record(
        'commitKeySuppressionSkipped',
        () => const {'reason': 'commitKeyDeferred'},
      );
      return;
    }
    _commitKeySuppressionArmedAtMs = now;
    journal.record('commitKeySuppressionArmed', () => const {});
  }

  /// Disarms the one-shot without consuming it — the scoping half of the
  /// WebKit compensation (ProseMirror limits the whole mechanism to
  /// Safari; we cannot user-agent sniff, so the arm is scoped by traffic
  /// instead). The Safari ordering the arm exists for has NOTHING between
  /// the arming snapshot and the commit keydown (the captured 29 ms gap),
  /// so any intervening event proves the arm stale: a subsequently
  /// ACCEPTED snapshot (a click-commit's selection echo, a punctuation
  /// auto-commit's follow-up) or a non-IME edit/selection change (the
  /// tap itself). Without this, every engine-side composition end — click
  /// commits, auto-commits, Escape cancels — would swallow the user's
  /// next genuine Enter/Backspace/Tab for 500 ms.
  void _disarmCommitKeySuppression(String reason) {
    if (_commitKeySuppressionArmedAtMs == null) return;
    _commitKeySuppressionArmedAtMs = null;
    journal.record('commitKeySuppressionDisarmed', () => {'reason': reason});
  }

  // --- Non-IME changes (the no-echo clauses (a) and (b)) ---

  /// Registered as `controller.imeExternalChangeHandler`: any non-IME edit
  /// or ANY non-IME selection change — including block-local offset moves
  /// within the same window (clause (b) is deliberately broad: the engine
  /// must never hold a stale cursor, or the next delta inserts at the old
  /// caret and autocorrect targets the wrong word).
  void _onExternalChange(String reason) {
    if (_connection == null) {
      // Lazy re-attach on the next edit after connectionClosed (focus loss
      // would have detached and cleared _wantsConnection).
      if (_wantsConnection) attach();
      return;
    }
    // Any non-IME edit or selection change disarms the commit-key one-shot:
    // the arm models "the commit keydown is the very next event behind the
    // arming snapshot" (Safari's compositionend → 29 ms → Enter, nothing
    // between), so a user act landing first proves a near-future Enter is
    // the user's own — see [_disarmCommitKeySuppression]. The terminate
    // branch below clears it too; disarming here first keeps one journaled
    // decision for both paths.
    _disarmCommitKeySuppression('externalChange');
    if (_shadowComposing || controller.composing != null) {
      terminateComposition(reason);
      return;
    }
    final window = _serialize();
    final shadow = _shadow;
    if (shadow != null &&
        shadow.text == window.text &&
        _selectionsEquivalent(shadow.selection, window.selection)) {
      // Same buffer, but the mapping may have gained real spans (e.g. the
      // first selection into an empty block after a selection-less attach).
      _window = window;
      return;
    }
    _push(window.toValue(), window);
    _scheduleGeometryReport();
    notifyListeners();
  }

  // --- DeltaTextInputClient ---

  @override
  TextEditingValue? get currentTextEditingValue => _shadow;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> textEditingDeltas) {
    // Recorded raw, before every guard — the journal's job is the exact
    // inbound stream, engine confusion included.
    journal.record(
      'deltas',
      () => {
        'deltas': [
          for (final d in textEditingDeltas) ImeJournal.describeDelta(d),
        ],
      },
    );
    // Mirror of [updateEditingValue]'s frontend guard: the diff frontend
    // attaches WITHOUT the delta model, so a delta batch arriving here is
    // engine confusion (or a misuse of the test surface), never input — it
    // must not reach the batch path against the wrong declaration.
    if (frontend != ImeFrontend.delta) return;
    debugLastDeltas = textEditingDeltas;
    if (_connection == null || _shadow == null) return;
    controller.imeEdit(() => _processBatch(textEditingDeltas));
    // Hindi transliteration (and similar commit-on-Enter keyboards) sends
    // performAction(newline) BEFORE the delta batch that commits the
    // transliteration. The batch above processed the transliteration with
    // the correct (pre-split) shadow. If the flag is still live (the batch
    // had no \n), fire the deferred newline now — the transliteration has
    // landed and the split goes in the right place.
    _flushPendingNewline();
    _scheduleGeometryReport();
    notifyListeners();
  }

  /// The non-delta diff frontend (web — architecture §IME web fallback):
  /// web engines don't deliver reliable `TextEditingDelta`s, so the engine
  /// sends full [TextEditingValue] snapshots here. Each snapshot is diffed
  /// against the shadow (`text_diff.dart`, appflowy's `NonDeltaInputService`
  /// precedent) and the equivalent delta is synthesized and routed through
  /// the SAME batch path the delta client uses ([_processBatch]) — echo
  /// quarantine, sentinel decomposition (G1), the divergence rule, and the
  /// composing mapping (−2 shift, block-local, via [_finishBatch]) all
  /// apply identically; the pipeline is never forked.
  ///
  /// The stale-delta guard is the one mechanism this frontend satisfies BY
  /// CONSTRUCTION rather than exercises: [_synthesizeDelta] sets `oldText`
  /// to the very shadow text it diffed against, so the guard's mismatch can
  /// never fire on a synthesized delta. The pre-push race the guard covers
  /// on the delta path (host-app edit → clause (a)/(b) push → an in-flight
  /// engine payload computed against the replaced window) is instead caught
  /// by the previous-shadow drop below: a snapshot whose text equals the
  /// window the latest push REPLACED was computed by the browser against
  /// that older window, and diffing it against the fresh shadow would
  /// mis-read the host edit's whole window change as typed input — it is
  /// dropped and the authoritative window re-pushed (the guard's accepted
  /// loss, never corruption). The drop is scoped to the ACTUAL race
  /// window, because its text signature alone also matches the user
  /// retyping what the push just deleted (dead keys make this a two-second
  /// repro: commit é, backspace, compose-and-commit é again):
  ///
  /// - Only snapshots already in flight at push time can be stale, so the
  ///   first accepted post-push snapshot (pure echo or synthesized input)
  ///   closes the window — [_previousShadowText] clears and later matches
  ///   are genuine input.
  /// - A snapshot carrying a live composing region is exempt outright: a
  ///   non-terminate push is only legal with no live composition (the
  ///   no-echo invariant), so every snapshot computed against the replaced
  ///   window was composing-free — a composing match is fresh marked text
  ///   the browser started AFTER the push, and dropping it severs a live
  ///   browser composition mid-flight. The one window this reasoning does
  ///   NOT cover is the dead-key rewrite's own race: the window IT replaced
  ///   was mid-composition, so its in-flight snapshots can still carry the
  ///   engine's dead latched range — [_filterStaleComposing] strips exactly
  ///   that range first, so the exemption only ever sees genuinely live
  ///   regions.
  ///
  /// The residual post-terminate flavor of the race stays the echo
  /// quarantine's territory, exactly as on the delta path.
  ///
  /// A value with unchanged text is the `TextEditingDeltaNonTextUpdate`
  /// analogue (§NonTextUpdate analogue): acknowledged into the shadow so
  /// composing-only updates are never echo-pushed, and a composing-cleared
  /// value is the same G3 latch-fire trigger a `NonTextUpdate` commit is —
  /// the latch still arms only from batches that changed text. A value
  /// equal to the shadow in all three of text + selection + composing is
  /// the engine echoing our own push: acknowledged silently.
  ///
  /// A TEXT-UNCHANGED snapshot whose selection STARTS inside the sentinel
  /// zone never moves the model caret (the sub-sentinel selection
  /// invariant — the suppression block below and
  /// [_restoreSentinelSuppressedSelection]): every pushed window's
  /// selection sits at or beyond the sentinel length, so such a selection
  /// is browser bookkeeping (the captured Safari blur reset to `[0,0]`),
  /// ignored while the composing transitions process normally.
  /// Text-CHANGING snapshots are exempt: G1's sentinel-consuming edits
  /// genuinely carry sub-sentinel selections, and a text delta's selection
  /// never drives the model anyway.
  ///
  /// The delta frontend declares enableDeltaModel and never receives text
  /// through this callback; it stays a no-op there.
  @override
  void updateEditingValue(TextEditingValue value) {
    // Recorded raw, BEFORE any filtering — the journal captures the exact
    // engine snapshot (sentinel visible, offsets unshifted).
    journal.record('snapshot', () => ImeJournal.describeValue(value));
    if (frontend != ImeFrontend.nonDeltaDiff) return;
    if (_connection == null || _shadow == null) return;
    final diff = diffTexts(
      _shadow!.text,
      value.text,
      cursorOffset: value.selection.isValid
          ? value.selection.extentOffset
          : null,
    );
    debugLastDiff = diff;
    journal.record(
      'diff',
      () => diff == null
          ? const {'result': null}
          : {
              'start': diff.start,
              'deleted': diff.deletedLength,
              'inserted': diff.insertedText,
            },
    );
    // The incoming composing region passes three filters before anything
    // keys on it: the sanity boundary ([_sanitizeComposing] — a
    // mis-reported region is no state worth preserving), the stale-latch
    // refusal ([_filterStaleComposing] — the engine re-reporting the range
    // a dead-key rewrite already terminated is not a composition), and the
    // composing-birth invariant ([_suppressComposingBirth] — composing can
    // only be born from a text-changing snapshot; in that order, see the
    // method doc). The drop below and the synthesis must agree on the
    // result, so it is computed once here.
    final sanitized = _sanitizeComposing(value.composing, value.text);
    if (sanitized != value.composing) {
      journal.record(
        'composingSanitized',
        () => {
          'from': ImeJournal.describeRange(value.composing),
          'to': ImeJournal.describeRange(sanitized),
        },
      );
    }
    final unlatched = _filterStaleComposing(sanitized, diff, value.selection);
    if (unlatched != sanitized) {
      journal.record(
        'staleComposingSuppressed',
        () => {'range': ImeJournal.describeRange(sanitized)},
      );
    }
    final composing = _suppressComposingBirth(unlatched, diff);
    final composingLive = composing.isValid && !composing.isCollapsed;
    // The sub-sentinel selection invariant (the captured Safari blur
    // session: compose に, blur to the URL bar — Safari fires
    // compositionend AND resets the DOM selection to zero, arriving as
    // `{". に", sel:[0,0], composing:null}` over unchanged text): a
    // snapshot selection whose START lies inside the sentinel zone
    // `[0, sentinel.length)` cannot be a user action. Every window we push
    // carries a selection at or beyond the sentinel length
    // ([serializeImeWindow] — even the empty-document window collapses AT
    // it), and the editable is a hidden 1px sliver nothing can click, so a
    // sub-sentinel selection start is browser bookkeeping, never input.
    // Honored, the NonTextUpdate mapping clamped it to the block start —
    // the model caret jumped at blur and the follow-up push taught Safari
    // the clamped caret, stuck there on return. So the selection COMPONENT
    // is ignored: the snapshot proceeds carrying the shadow's own
    // selection, the model caret stays put, and everything else (the text
    // diff, the composing transitions — including the live→empty clear
    // that disarms the composition, and its commit-key arm) processes
    // exactly as before. A RANGE whose start is in-zone but extent beyond
    // (`[0,3]`) is the same artifact family: no pushed window ever anchors
    // inside the sentinel, and honoring a clamped half would fabricate a
    // selection the user never made. The DOM-side fallout — the browser's
    // caret genuinely moved — is [_restoreSentinelSuppressedSelection]'s
    // territory. The composing filters above deliberately see the RAW
    // selection (the stale-latch freshness test must read the snapshot the
    // engine actually sent, and an artifact selection is exactly what
    // keeps it un-fresh).
    //
    // Scoped to TEXT-UNCHANGED snapshots, deliberately: G1's
    // sentinel-consuming edits are GENUINE text-changing shapes with
    // sub-sentinel selections — backspace at block start deletes the
    // sentinel space and reports `sel:[1,1]`, select-to-line-start +
    // delete collapses the whole buffer to `sel:[0,0]` — and their
    // selection rides into the shadow verbatim (the synthesis's
    // acknowledge half), where it is harmless: a text delta's selection is
    // never applied to the model ([_applyDelta] derives the caret from the
    // edit itself), and [_finishBatch]'s push-iff-diverged already
    // re-teaches the engine the post-edit window. Only the no-diff path —
    // the NonTextUpdate analogue, the one place the engine selection
    // DRIVES the model — honors the selection, so only it needs the
    // invariant.
    final rawSelection = value.selection;
    final sentinelSelection =
        diff == null &&
        rawSelection.isValid &&
        rawSelection.start < ImeWindow.sentinel.length;
    if (sentinelSelection) {
      journal.record(
        'sentinelSelectionSuppressed',
        () => {
          'sel': [rawSelection.baseOffset, rawSelection.extentOffset],
        },
      );
      value = TextEditingValue(
        text: value.text,
        selection: _shadow!.selection,
        composing: value.composing,
      );
    }
    // Deferred reconciliation (passive-while-composing, §web fallback): a
    // prior mid-composition snapshot diverged the window unmappably, so
    // the frontend is a pure observer until the composition ends — see
    // [_passiveDivergence] for why neither applying nor pushing is legal
    // here.
    if (_passiveDivergence) {
      _absorbWhileDiverged(value, composing, composingLive: composingLive);
      return;
    }
    // The previous-shadow drop (the doc comment's pre-push race): a snapshot
    // shaped like the window the latest push replaced is stale by
    // construction — but only commit-shaped and only while the race window
    // is still open (see the doc comment's scoping). A composing-carrying
    // match is fresh marked text: the replaced window was composing-free
    // (a non-terminate push is illegal mid-composition), so no in-flight
    // stale snapshot can carry one — except the dead-key rewrite's own
    // race, whose stale latched range the filter above already stripped.
    if (value.text != _shadow!.text &&
        value.text == _previousShadowText &&
        !composingLive) {
      _recoverAuthoritative('staleSnapshot');
      _scheduleGeometryReport();
      notifyListeners();
      return;
    }
    final (:delta, :deadKeyRewrite) = _synthesizeDelta(
      _shadow!,
      value,
      diff: diff,
      composing: composing,
    );
    journal.record(
      'synthesized',
      () => {
        'delta': delta == null ? null : ImeJournal.describeDelta(delta),
        if (deadKeyRewrite) 'deadKeyRewrite': true,
      },
    );
    // Any accepted post-push snapshot closes the pre-push race window: the
    // engine is provably working from the pushed window now (the pure echo
    // acknowledges it; synthesized input is diffed against it). Cleared
    // BEFORE _processBatch so a push the batch itself triggers (rule fire,
    // recovery, terminate) opens its own fresh window.
    _previousShadowText = null;
    // An accepted snapshot also disarms a pending commit-key one-shot: the
    // arm covers only a keydown already in flight DIRECTLY behind the
    // arming snapshot (Safari's compositionend → Enter gap has nothing in
    // between), so by the time a click-commit's selection echo or an
    // auto-commit's follow-up lands, a near-future Enter is the user's own
    // and must split. Runs before the arm below, so the arming snapshot
    // never disarms itself.
    _disarmCommitKeySuppression('subsequentSnapshot');
    if (delta == null) {
      // Pure echo of our own push — except when the sub-sentinel invariant
      // above discarded the engine's selection: nothing else changed, but
      // the DOM caret genuinely sits at the artifact, so re-teach it.
      _restoreSentinelSuppressedSelection(sentinelSelection);
      return;
    }
    debugLastDeltas = [delta];
    // An engine snapshot ending a live shadow composition is compositionend
    // reflected — on WebKit the keydown of the key that ended it (the
    // commit Enter) is still in flight BEHIND this snapshot, so arm the
    // one-shot commit-key suppression (see [_commitKeySuppressionArmedAtMs]
    // for the ordering story and the scoping). Checked against the FILTERED
    // incoming region, so the dead-key rewrite never matches (its snapshot
    // still carries the live — stale — range), and armed BEFORE the batch
    // runs so a terminate the batch itself triggers disarms it.
    if (_shadowComposing && !composingLive) _armCommitKeySuppression();
    controller.imeEdit(() => _processBatch([delta]));
    if (deadKeyRewrite) {
      // The append-shaped commit was rewritten, so the BROWSER's DOM still
      // holds the stale marked char plus the appended commit while the
      // shadow now holds the corrected text — sync the corrected window
      // back (the v2 fix's `_finalizeComposing` sync, v0.1.7). Legal as a
      // plain push: the rewritten delta carried empty composing, so the
      // shadow no longer reports a composition (and _finishBatch can never
      // have terminated off it). When a rule fire already pushed inside
      // _finishBatch this re-push is an identical no-op engine-side.
      if (_connection != null && _shadow != null && !_shadowComposing) {
        _pushAuthoritativeWindow();
      }
      // Arm the previous-shadow drop with the APPEND-SHAPED text: a late
      // Safari snapshot still carrying it (computed before the resync push
      // reached the DOM, composing since cleared) is the pre-push race
      // shape exactly — diffing it against the corrected shadow would
      // resurrect the stale dead key as an insertion. Same scoping rules
      // as every other arm: the next accepted snapshot closes the window,
      // so the fix converges identically whether or not the corrective
      // arrives.
      _previousShadowText = value.text;
      // And arm the stale-composing refusal with the range the rewrite just
      // terminated (== the snapshot's own region, by the rewrite's guards):
      // the commit ended the composition only on OUR side — the engine's
      // latch holds the dead range until a real compositionend, and every
      // snapshot it decorates until then must not re-arm the underline or
      // re-enter the rewrite (see [_staleComposingLatch]'s lifecycle).
      _staleComposingLatch = composing;
    }
    _restoreSentinelSuppressedSelection(sentinelSelection);
    _flushPendingNewline();
    _scheduleGeometryReport();
    notifyListeners();
  }

  /// The corrective half of the sub-sentinel selection invariant (the
  /// suppression block in [updateEditingValue]): with the snapshot's
  /// selection component discarded, the pipeline converges with the model
  /// caret preserved — but the BROWSER's DOM selection genuinely sits where
  /// the artifact put it (Safari's blur reset parked it at zero), and a
  /// shadow that ignores that forever is exactly the stale engine cursor
  /// clause (b) of the no-echo invariant exists to prevent. One plain push
  /// re-teaches the engine the preserved window — the captured session's
  /// follow-up push (seq 31), which used to carry the sentinel-clamped
  /// `[2,2]` because the model had already moved, now carries the
  /// preserved caret. The shadow then equals what the engine holds again:
  /// no divergence lingers, and no push-fight is possible — a push of the
  /// preserved window can at most echo back as the pure-echo shape (never
  /// sub-sentinel, every pushed selection is ≥ the sentinel length), so the
  /// cycle cannot self-sustain. When [_finishBatch] already pushed (a G3
  /// latch fire on the composing-clear), this re-push is an identical
  /// no-op engine-side — the dead-key resync precedent. Skipped
  /// while a composition stays live or the passive window is armed
  /// (pushing there is the #1641 seam); those states reconcile through
  /// their own composition-end push, and a re-attach re-pushes regardless.
  void _restoreSentinelSuppressedSelection(bool suppressed) {
    if (!suppressed) return;
    if (_connection == null || _shadow == null) return;
    if (_shadowComposing || _passiveDivergence) return;
    _pushAuthoritativeWindow();
  }

  /// The deferred-reconciliation window's snapshot handling
  /// ([_passiveDivergence] armed — diff frontend only). While the engine
  /// still reports a live composition the snapshot is acknowledged one-way
  /// into the shadow (the model stays put: the window mapping is
  /// unreliable, and a push of any kind would corrupt the browser's marked
  /// region). The snapshot that ends the composition triggers the ONE
  /// authoritative reconciliation push — composing live→empty
  /// (compositionend reflected) OR the absorbed region REPLACED by one
  /// with a different start (a new compositionstart re-latched the engine
  /// base: the absorbed composition objectively ended; the captured Chrome
  /// cascade's seq-42, where staying passive kept absorbing the user's new
  /// typing into the void). The model is the authority, the composition is
  /// over, and pushing is safe again. [composing] is the caller's filtered
  /// region (sanitized + stale-latch-refused), so the liveness test and
  /// the shadow agree with the normal path's bookkeeping.
  ///
  /// In-flight protection on the reconcile push: it replaces a window the
  /// engine held MID-COMPOSITION, so — like the dead-key rewrite's resync
  /// — late snapshots can still arrive decorated with the absorbed
  /// composing range (the engine's bookkeeping racing the push). The push
  /// arms [_staleComposingLatch] with that range: the engine reported the
  /// composition ENDED (that is this branch's trigger), so a later
  /// decoration at those numbers is a dead latch by construction, and the
  /// latch's own lifecycle (disarm on no-region / different-range /
  /// fresh-same-range) releases every genuinely live follow-up. The
  /// in-flight text itself is the [_previousShadowText] drop's territory,
  /// exactly as after any other push.
  ///
  /// Web caveat ([_recoverAuthoritative]'s day-15/18 note, extended here
  /// explicitly): a deliberate TERMINATE during the passive window (undo,
  /// external edit, detach) still pushes while the browser owns its live
  /// composition — `setEditingState` cannot make a browser abandon a DOM
  /// composition, so the engine's bookkeeping can straddle the new text
  /// and in-flight snapshots can carry a GENUINELY live region the latch
  /// must not strip (the user's composition continues engine-side). That
  /// push is the quarantine's and the day-15/18 web polish pass's
  /// territory, deliberately not latch-hardened here.
  void _absorbWhileDiverged(
    TextEditingValue value,
    TextRange composing, {
    required bool composingLive,
  }) {
    // Any accepted snapshot closes the pre-push race window, exactly as on
    // the normal path.
    _previousShadowText = null;
    // The engine window being absorbed/discarded — captured before the
    // shadow is overwritten: its composing range is the region the
    // replacement test, the journal, and the in-flight refusal key on.
    final absorbedComposing = _shadow?.composing ?? TextRange.empty;
    final absorbedLive =
        absorbedComposing.isValid && !absorbedComposing.isCollapsed;
    // Passive-exit-on-region-replacement (the captured Chrome cascade's
    // seq-42): a live incoming region whose START moved off the absorbed
    // one is a NEW composition, not the absorbed one continuing — the
    // engine's `composingBase` is fixed within one composition (set
    // `??=`, reset only by compositionstart/end), so growth, candidate
    // replacement, and in-composition deletion all keep the start and move
    // only the end. The absorbed composition objectively ended; staying
    // passive here absorbs the user's NEW typing into the void (the
    // capture's lost d/だ). Reconcile exactly as live→empty: the absorbed
    // keystrokes are the accepted loss the passiveReconcile payload
    // records, and the new composition re-arrives against the fresh
    // window through subsequent snapshots.
    final regionReplaced =
        composingLive &&
        absorbedLive &&
        composing.start != absorbedComposing.start;
    if (composingLive && !regionReplaced) {
      _shadow = TextEditingValue(
        text: value.text,
        selection: value.selection,
        composing: composing,
      );
      journal.record(
        'passiveAcknowledge',
        () => ImeJournal.describeValue(value),
      );
      notifyListeners();
      return;
    }
    // live→empty (or region replacement): the engine ended the absorbed
    // composition. Arm the commit-key suppression first (WebKit's commit
    // keydown may still be in flight behind this snapshot — the same
    // ordering as the normal path), then reconcile: shadow acknowledged
    // composing-free so the authoritative push is legal as a PLAIN push,
    // never a terminate. A region REPLACEMENT must not arm the one-shot:
    // the replacing region proves the user's next composition is already
    // in flight — intervening traffic the bare compositionend→Enter gap
    // the arm models never has.
    _passiveDivergence = false;
    if (!regionReplaced && _shadowComposing) _armCommitKeySuppression();
    controller.imeSetComposing(null);
    _shadow = TextEditingValue(
      text: value.text,
      selection: value.selection,
      composing: TextRange.empty,
    );
    final window = _serialize();
    // Discarded vs pushed, on record: the absorbed engine text + composing
    // lose to the authoritative window — a live capture of a passive
    // window must show exactly what the reconcile threw away.
    journal.record(
      'passiveReconcile',
      () => {
        'trigger': regionReplaced ? 'regionReplaced' : 'compositionEnded',
        'discardedText': value.text,
        'discardedComposing': ImeJournal.describeRange(absorbedComposing),
        'pushedText': window.text,
        'pushedSelection': [
          window.selection.baseOffset,
          window.selection.extentOffset,
        ],
      },
    );
    // The in-flight-snapshot hardening (see the doc comment): the absorbed
    // range is a dead engine latch — refuse late decorations of it.
    if (absorbedComposing.isValid && !absorbedComposing.isCollapsed) {
      _staleComposingLatch = absorbedComposing;
    }
    _push(window.toValue(), window);
    _scheduleGeometryReport();
    notifyListeners();
  }

  /// Synthesizes the delta equivalent to [value] arriving over [shadow] —
  /// `oldText` is the shadow text by construction (full snapshots are
  /// diffed against the very state the guard validates), and the incoming
  /// selection/composing ride along so `delta.apply(shadow)` converges the
  /// shadow to exactly the engine's value (the acknowledge half of the
  /// no-echo triple). [diff] and [composing] are the caller's — computed
  /// once in [updateEditingValue] so the previous-shadow drop and the
  /// synthesis agree on them ([composing] is already sanitized,
  /// stale-latch-filtered, AND birth-filtered). `delta` is null when the
  /// value matches the
  /// shadow in text AND selection AND composing; `deadKeyRewrite` reports
  /// whether the append-shaped dead-key compensation
  /// ([_rewriteDeadKeyCommit]) replaced the verbatim synthesis — the caller
  /// owes the engine a resync push.
  ({TextEditingDelta? delta, bool deadKeyRewrite}) _synthesizeDelta(
    TextEditingValue shadow,
    TextEditingValue value, {
    required TextDiff? diff,
    required TextRange composing,
  }) {
    if (diff == null) {
      if (_selectionsEquivalent(value.selection, shadow.selection) &&
          composing == shadow.composing) {
        return (delta: null, deadKeyRewrite: false);
      }
      return (
        delta: TextEditingDeltaNonTextUpdate(
          oldText: shadow.text,
          selection: value.selection,
          composing: composing,
        ),
        deadKeyRewrite: false,
      );
    }
    if (diff.isInsert) {
      final rewritten = _rewriteDeadKeyCommit(shadow, diff, composing);
      if (rewritten != null) return (delta: rewritten, deadKeyRewrite: true);
      return (
        delta: TextEditingDeltaInsertion(
          oldText: shadow.text,
          textInserted: diff.insertedText,
          insertionOffset: diff.start,
          selection: value.selection,
          composing: composing,
        ),
        deadKeyRewrite: false,
      );
    }
    if (diff.isDelete) {
      return (
        delta: TextEditingDeltaDeletion(
          oldText: shadow.text,
          deletedRange: TextRange(
            start: diff.start,
            end: diff.start + diff.deletedLength,
          ),
          selection: value.selection,
          composing: composing,
        ),
        deadKeyRewrite: false,
      );
    }
    return (
      delta: TextEditingDeltaReplacement(
        oldText: shadow.text,
        replacedRange: TextRange(
          start: diff.start,
          end: diff.start + diff.deletedLength,
        ),
        replacementText: diff.insertedText,
        selection: value.selection,
        composing: composing,
      ),
      deadKeyRewrite: false,
    );
  }

  /// Safari's append-shaped dead-key commit (the v2 Safari fix, v0.1.7
  /// commits 1abe94b/8a5eb6f; §web fallback's day-15 drip row — "the v2
  /// Safari fix's scenario, carried over"): on WebKit, pressing the
  /// committing key during a dead-key composition fires the DOM input event
  /// BEFORE compositionend, with the resolved character appended AFTER the
  /// still-present marked text — the engine's latched `composingBase`
  /// (composition_aware_mixin.dart: `composingBase ??=`, reset only by
  /// compositionstart/end) therefore reports the composing range unchanged
  /// over the stale dead key. v2's recorded trace: "hello´" composing (5,6)
  /// → "hello´é" composing STILL (5,6) — and no corrective snapshot ever
  /// removes the ´. Diffed verbatim that synthesizes "insert é after the
  /// marked ´, composition continues": the user's underlined-´-plus-new-e
  /// symptom. Chrome sends the replace shape ("helloé", composing cleared)
  /// and never reaches this rule.
  ///
  /// The rule (v2's `_handleComposingEdit` rewrite, narrowed): a pure-insert
  /// diff landing at/beyond the end of a live composing region that the
  /// snapshot itself reports UNCHANGED from the shadow's is the engine
  /// saying "new committed text, stale marked text still in the buffer" —
  /// rewrite it as the commit: replace the composing range with the
  /// inserted text, composing cleared, caret after the replacement.
  ///
  /// Why this cannot misfire on multi-char IME composition (the risky CJK
  /// edge): a kana composition growing by appended characters inserts at
  /// the SAME offset (the old composing end), but every compositionupdate
  /// re-reports the region grown to cover the new character
  /// (`composingBase..composingBase + composingText.length`), so
  /// `composing != shadow.composing` and the insert lands INSIDE the
  /// incoming region — both guards fail and the snapshot flows through as
  /// ordinary composition. The same holds for Hangul syllable handoff (the
  /// new syllable's region covers the inserted jamo) and for conversion
  /// commits (replacement-shaped or zero-diff, never a pure insert). The
  /// equality guard is the narrowing over v2 (v2 checked only the incoming
  /// region): it additionally keeps a region freshly marked over
  /// pre-existing text from being collapsed by an unrelated insert.
  ///
  /// The rewrite terminates the composition only on OUR side — the engine's
  /// latch keeps reporting this range until a real compositionend, so the
  /// caller arms [_staleComposingLatch] and [_filterStaleComposing] keeps
  /// the dead range from re-arming the underline or steering a later plain
  /// keystroke back into this rule (the follow-up stuck-IME Safari bug).
  TextEditingDelta? _rewriteDeadKeyCommit(
    TextEditingValue shadow,
    TextDiff diff,
    TextRange composing,
  ) {
    if (!composing.isValid || composing.isCollapsed) return null;
    if (composing != shadow.composing) return null;
    if (diff.start < composing.end) return null;
    return TextEditingDeltaReplacement(
      oldText: shadow.text,
      replacedRange: composing,
      replacementText: diff.insertedText,
      // The snapshot's own selection indexes the append-shaped text and
      // does not survive the rewrite; the commit leaves the caret after
      // the replacement.
      selection: TextSelection.collapsed(
        offset: composing.start + diff.insertedText.length,
      ),
      composing: TextRange.empty,
    );
  }

  /// Refuses the engine's stale composing re-arm after a dead-key rewrite
  /// (the rewrite's follow-up half — see [_staleComposingLatch] for the
  /// mechanism and lifecycle; v2 provenance: 1abe94b's gate-only composing
  /// never mapped the platform region into model state, so it had nothing
  /// to refuse). Returns [composing] untouched while disarmed; otherwise:
  ///
  /// - No live region incoming ⇒ the engine latch is provably dead (the
  ///   mixin only decorates snapshots while it holds `composingText`):
  ///   disarm, pass through — Safari's compositionend corrective converges
  ///   silently through the ordinary echo path.
  /// - A DIFFERENT region ⇒ only compositionstart resets the latched base,
  ///   so different numbers are a fresh latch — a new live composition:
  ///   disarm, pass through (the immediate Option+E re-composition).
  /// - The SAME region ⇒ live only if the snapshot is composition-shaped:
  ///   a compositionupdate always changes text AND reports the region
  ///   ending at the caret (`composingBase ??= extent − composingText
  ///   .length` ⇒ end == extent on every live report — kana growth and
  ///   conversion included). Both honored: disarm, pass through, even at
  ///   the dead range's exact numbers (a re-latched ´ after the caret moved
  ///   before the é). Either failing is the dead latch decorating
  ///   non-composition input — the push-induced selectionchange echo (no
  ///   text change) or plain typing after the commit (caret beyond the dead
  ///   range's end): treated as no composition, latch kept armed for the
  ///   next snapshot. The flow therefore converges whether or not the
  ///   compositionend corrective ever arrives.
  ///
  /// Known false positive of the same-range freshness test (adjudicated,
  /// accepted): a plain character typed with the caret IMMEDIATELY BEFORE
  /// the dead range while the latch is armed produces a snapshot that is
  /// byte-for-byte the live-compositionupdate shape — text changed (diff
  /// non-null) and the insert shifts the caret to exactly `composing.end`
  /// — so the latch disarms live and the dead range re-arms ComposingState
  /// over the typed character; the NEXT keystroke then satisfies
  /// [_rewriteDeadKeyCommit]'s guards (insert at the live region's end,
  /// region unchanged from the shadow's) and replaces the typed character
  /// (the cascade). The shape is genuinely ambiguous with a re-latched
  /// dead key at the same numbers (the honored fixture), and suppressing
  /// it would eat real compositions — so the heuristic stands, and every
  /// disarm is journaled (`staleComposingLatchDisarmed`, reason `fresh` /
  /// `corrective` / `differentRange`) so a live capture of the cascade
  /// shows the decision that opened it.
  ///
  /// Division of labor with the composing-birth invariant
  /// ([_suppressComposingBirth], which runs AFTER this filter): the
  /// invariant alone covers dead decorations on text-UNCHANGED snapshots
  /// whenever this latch is disarmed — notably after blur/connectionClosed,
  /// which clear the latch with the connection (the two captured Chrome
  /// journals), so no reason-scoped latch arming is needed there. The
  /// latch stays load-bearing for text-CHANGING snapshots behind a
  /// rewrite/reconcile push (the late append-shaped Safari snapshot, the
  /// plain-keystroke-under-dead-latch é→e cascade), which the invariant
  /// deliberately does not cover; the same-range freshness test keeps its
  /// `diff != null` conjunct so the push's own text-unchanged echo leaves
  /// the latch ARMED for those, rather than disarming into shapes only the
  /// latch can refuse.
  TextRange _filterStaleComposing(
    TextRange composing,
    TextDiff? diff,
    TextSelection selection,
  ) {
    final latch = _staleComposingLatch;
    if (latch == null) return composing;
    if (!composing.isValid || composing.isCollapsed) {
      _disarmStaleComposingLatch('corrective');
      return composing;
    }
    if (composing != latch) {
      _disarmStaleComposingLatch(
        'differentRange',
        range: ImeJournal.describeRange(composing),
      );
      return composing;
    }
    final fresh =
        diff != null &&
        selection.isValid &&
        selection.extentOffset == composing.end;
    if (fresh) {
      _disarmStaleComposingLatch('fresh');
      return composing;
    }
    return TextRange.empty;
  }

  /// Disarms [_staleComposingLatch], journaling WHY (the doc comment above:
  /// the `fresh` disarm is a known-ambiguous heuristic, and a capture of
  /// its false-positive cascade needs the decision on record).
  void _disarmStaleComposingLatch(String reason, {List<int>? range}) {
    _staleComposingLatch = null;
    journal.record(
      'staleComposingLatchDisarmed',
      () => {'reason': reason, 'range': ?range},
    );
  }

  /// The composing-birth invariant (§web fallback): composing state can
  /// only be BORN from a text-CHANGING snapshot. Every genuine web
  /// composition begins with a text change — compositionstart/update always
  /// insert or replace (even a dead key inserts its `´`) — while the
  /// engine's composition latch (composition_aware_mixin.dart:
  /// `composingText` + `composingBase ??=`, reset ONLY by
  /// compositionstart/compositionend DOM events) survives blur,
  /// `connectionClosed`, re-attach, and complete window replacement, and
  /// keeps decorating snapshots with the dead range. Two captured Chrome
  /// journals pin the failure: compose → blur → return → a text-UNCHANGED
  /// snapshot decorated with the dead range re-arms shadow composing (the
  /// NonTextUpdate analogue), closing the hardware-key gate on a phantom
  /// composition; and the same dead range carried onto a DIFFERENT block's
  /// freshly pushed window after an external-edit push, cascading a
  /// deferred Enter into `performAction` and the passive window into
  /// absorbing the user's next real composition. So: with shadow composing
  /// EMPTY, a live region on a no-diff snapshot is filtered to empty
  /// (journaled `composingBirthSuppressed`). With shadow composing LIVE the
  /// region passes untouched — composing-only updates (candidate
  /// navigation, region moves, the live NonTextUpdate analogue) keep
  /// working exactly as before.
  ///
  /// Runs AFTER [_filterStaleComposing], deliberately: the latch must see
  /// the raw region first — birth-suppressing a latched dead-range echo
  /// before the latch reads it would make the echo look like a corrective
  /// (no live region ⇒ disarm), releasing the latch the dead-key rewrite /
  /// passive reconcile armed against text-CHANGING late snapshots, which
  /// this invariant deliberately does not cover.
  TextRange _suppressComposingBirth(TextRange composing, TextDiff? diff) {
    if (diff != null) return composing; // a real compositionstart/update
    if (_shadowComposing) return composing; // live: composing-only updates
    if (!composing.isValid || composing.isCollapsed) return composing;
    journal.record(
      'composingBirthSuppressed',
      () => {'range': ImeJournal.describeRange(composing)},
    );
    return TextRange.empty;
  }

  /// Engine-supplied composing ranges are sanitized before they enter the
  /// shadow: an invalid, inverted, or out-of-range region becomes
  /// [TextRange.empty] — treated as "no composition" rather than clamped,
  /// because a region the engine itself mis-reports is not state worth
  /// preserving, and one reaching the shadow unchecked blows up
  /// `composing.textInside(shadow.text)` in [terminateComposition].
  /// Sanitizing at the synthesis boundary keeps the rule in one place: the
  /// synthesized delta — and through `delta.apply`, the shadow — never
  /// carries a range its own text cannot satisfy.
  static TextRange _sanitizeComposing(TextRange composing, String text) {
    if (!composing.isValid || !composing.isNormalized) return TextRange.empty;
    if (composing.end > text.length) return TextRange.empty;
    return composing;
  }

  /// `newline` is the only action with behavior; every other
  /// [TextInputAction] (done/go/search/…) is deliberately a journaled
  /// no-op — none of them maps to an editor verb.
  @override
  void performAction(TextInputAction action) {
    journal.record('performAction', () => {'action': action.name});
    if (action != TextInputAction.newline) return;
    if (_shadow == null) return;
    // While the engine owns a composition (shadow composing live OR the
    // passive window armed) a newline action is never a commit: the
    // captured Chrome cascade's seq-35 — a gate-deferred Enter reached the
    // DOM textarea and came back as performAction(newline), and the model
    // edit it triggered diverged the window mid-"composition", arming the
    // passive absorption that swallowed the user's next real composition.
    // A GENUINE composition-committing newline arrives as a \n in the
    // engine's own delta/snapshot (G10); the bare action carries no text
    // and editing the model on it mid-composition is exactly the
    // write-while-the-browser-composes seam every web corruption traces to.
    if (engineComposing) {
      journal.record('performActionSuppressed', () => {'action': action.name});
      return;
    }
    _pendingNewlineAction = true;
  }

  /// Fires the deferred newline from [performAction]. Called at the end of
  /// each delta/snapshot batch so the split lands after the batch's text
  /// changes (Hindi transliteration commit-on-Enter). Also exposed for
  /// tests that call [performAction] without a following delta batch.
  @visibleForTesting
  void flushPendingNewline() => _flushPendingNewline();

  void _flushPendingNewline() {
    if (!_pendingNewlineAction) return;
    _pendingNewlineAction = false;
    controller.imeEdit(() {
      controller.imeInsertNewline();
      _finishBatch(editedBlockId: null, editedRange: null);
    });
    _scheduleGeometryReport();
    notifyListeners();
  }

  /// macOS editing commands (`TextInputClient.performSelector` — the
  /// macOS-only `NSStandardKeyBindingResponding` path). AppKit delivers a
  /// keystroke the IME consumed but did not turn into text as
  /// `doCommandBySelector:`; the engine forwards every selector its text
  /// input plugin doesn't implement itself to the framework
  /// (`FlutterTextInputPlugin.mm`, `TextInputClient.performSelectors`).
  /// Two verified engine contracts shape this handler:
  ///
  /// - **Ordering**: deltas are sent over the channel synchronously, but
  ///   selectors are batched into a run-loop block — a keystroke's selector
  ///   always arrives AFTER its deltas. Backspace during a dead-key marked
  ///   state therefore reaches us as `unmarkText` (a NonTextUpdate clearing
  ///   composing — the underline disappearing) followed by
  ///   `deleteBackward:`; by the time the selector lands, the marked `´`
  ///   reads as committed text and the command is a plain backspace. The
  ///   still-composing ordering is handled anyway (IME behaviors vary): the
  ///   composed text is removed and the composition terminates through
  ///   `terminateComposition('performSelector')` — the spec's reason set
  ///   gains "the platform ended the composition with an editing command".
  /// - **`insertNewline:` never actually arrives**: the engine intercepts
  ///   it in `doCommandBySelector:` and reports Enter as an
  ///   insertText `"\n"` delta plus `performAction(newline)` instead. It is
  ///   mapped here anyway so the finding is recorded executable-side.
  ///
  /// Only what dead-key editing needs is implemented — the full selector
  /// matrix (`intentForMacOSSelector`'s table: moves, word deletes,
  /// scrolls) is day-10 hardware-keys work. Unknown selectors are a safe
  /// no-op with an inspector note (pane 3), never an assert.
  @override
  void performSelector(String selectorName) {
    debugLastSelector = selectorName;
    journal.record('performSelector', () => {'selector': selectorName});
    if (_connection == null || _shadow == null) {
      notifyListeners();
      return;
    }
    switch (selectorName) {
      case 'deleteBackward:':
        _selectorDeleteBackward();
      case 'deleteForward:':
        _applySelectorVerb(controller.imeDeleteForward);
      case 'insertNewline:':
        _applySelectorVerb(controller.imeInsertNewline);
      default:
        debugLastUnhandledSelector = selectorName;
        journal.record('selectorUnhandled', () => {'selector': selectorName});
    }
    notifyListeners();
  }

  /// `deleteBackward:`'s two orderings relative to the composing state:
  /// already unmarked (the verified macOS dead-key trace) → a plain
  /// backspace; still composing → the pending composed text is removed and
  /// the composition terminates through the choke point (native dead-key
  /// backspace removes the pending accent entirely).
  void _selectorDeleteBackward() {
    final composing = controller.composing;
    if (composing == null && !_shadowComposing) {
      _applySelectorVerb(controller.imeBackspace);
      return;
    }
    controller.imeEdit(() {
      if (composing != null) {
        controller.imeSetSelection(
          DocSelection(
            base: DocPosition(composing.blockId, composing.range.start),
            extent: DocPosition(composing.blockId, composing.range.end),
          ),
        );
        controller.imeDeleteSelection();
      } else {
        // Shadow-only composition (never mapped block-locally): a plain
        // backspace, then the terminate resyncs the engine.
        controller.imeBackspace();
      }
    });
    terminateComposition('performSelector');
  }

  /// Applies one selector-mapped controller verb as an IME edit. No delta
  /// accompanies a selector, so [performAction]'s reconciliation applies:
  /// re-serialize and push iff diverged — through the choke point when the
  /// shadow reports a live composition.
  void _applySelectorVerb(void Function() verb) {
    controller.imeEdit(() {
      verb();
      _finishBatch(editedBlockId: null, editedRange: null);
    });
    _scheduleGeometryReport();
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    // iOS spacebar-drag caret: scoped day 13 (within-block floating caret +
    // edge-triggered block handoff) — the one touch-surface piece with a
    // genuine IME-client dependency.
  }

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  /// The platform closed the connection out from under us (web DOM blur,
  /// iOS first-responder resignation; the Android embedding never sends it).
  /// EditableText-style minimal handling: mark detached, terminate (push
  /// skipped), lazily re-attach + re-serialize on the next focus or edit.
  @override
  void connectionClosed() {
    journal.record('connectionClosed', () => const {});
    // Acknowledge before discarding: TextInput's current-connection
    // bookkeeping clears only through connectionClosedReceived(), and a
    // stale current connection corrupts the next attach.
    _connection?.connectionClosedReceived();
    _connection = null;
    terminateComposition('connectionClosed');
  }

  // --- Delta application (queue, shadow buffer, stale-delta guard) ---

  void _processBatch(List<TextEditingDelta> deltas) {
    // The quarantine covers exactly the FIRST text-bearing batch after a
    // terminate push, then disarms — a user genuinely retyping the syllable
    // types it in a later batch. A NonTextUpdate-only batch does NOT count
    // against that scope: it is pushless and carries no text, so it cannot
    // be the retype the one-batch budget exists for — and on web one DOM
    // selectionchange is one whole batch, so selection noise between the
    // terminate push and the held-syllable recommit would otherwise burn
    // the quarantine before the echo arrives. The other disarm trigger —
    // any non-terminate push — is [_push]'s territory.
    final quarantine = _quarantine;
    if (deltas.any((delta) => delta is! TextEditingDeltaNonTextUpdate)) {
      _quarantine = null;
    }

    // iOS Korean composing (no composing region reported) sends
    // delete-reinsert batches that overlap the sentinel: nonText →
    // delete[1,3] → insert " " → insert "하". Per-delta processing fails
    // because the G1 decomposition diverges the window from the shadow
    // (the delta removes the sentinel space; our model always preserves
    // it), killing subsequent deltas as stale. Fix: compute the batch's
    // net text effect as a single diff against the pre-batch shadow and
    // process that one synthetic delta — borrowing the diff frontend's
    // net-diff-then-synthesize strategy. See [_processSentinelOverlapBatch]
    // for why the snapshot path's composing/stale filters are not re-run.
    if (_hasSentinelOverlappingDeletion(deltas)) {
      _processSentinelOverlapBatch(deltas, quarantine);
      return;
    }

    var diverged = false;
    String? editedBlockId;
    TextRange? editedRange;

    for (final delta in deltas) {
      final shadow = _shadow!;

      // Post-terminate echo quarantine (G7/G10): an insertion that exactly
      // re-COMMITS the terminated composing text at the pushed caret is an
      // engine echo by construction (its oldText matches the fresh shadow,
      // so the stale-delta guard is structurally blind to it). Drop and
      // re-push — worst case identical to the guard's lost-delta. The
      // signature requires commit semantics (empty composing): the analyzed
      // echo pathology is an OEM IME COMMITTING its held syllable against
      // the fresh push (spec §echo quarantine — undo-mid-Hangul recommit,
      // post-split head echo). An insertion arriving WITH a live composing
      // region is new marked text from a fresh composition — a macOS dead
      // key re-typed at the terminated composition's offset matches the
      // text+offset signature exactly, and eating it wedges accent input.
      final composingDelta =
          delta.composing.isValid && !delta.composing.isCollapsed;
      if (quarantine != null &&
          !composingDelta &&
          delta is TextEditingDeltaInsertion &&
          delta.textInserted == quarantine.text &&
          delta.insertionOffset == quarantine.offset) {
        _recoverAuthoritative('echoQuarantine');
        return;
      }

      // Stale-delta guard (universal race backstop): on mismatch the engine
      // raced us — drop the remainder and re-push the authoritative window.
      // Worst case a lost autocorrect correction, never corruption.
      if (delta.oldText != shadow.text) {
        _recoverAuthoritative('staleDelta');
        return;
      }

      // A structural delta earlier in THIS batch moved the window away from
      // the engine's buffer; later text deltas reference a coordinate space
      // the document no longer matches. Same accepted loss as the guard.
      if (diverged && delta is! TextEditingDeltaNonTextUpdate) {
        _recoverAuthoritative('staleDelta');
        return;
      }

      final edited = _applyDelta(delta, diverged: diverged);
      _shadow = delta.apply(shadow);

      if (edited != null) {
        if (edited.blockId == editedBlockId && editedRange != null) {
          editedRange = TextRange(
            start: math.min(editedRange.start, edited.range.start),
            end: math.max(editedRange.end, edited.range.end),
          );
        } else {
          editedBlockId = edited.blockId;
          editedRange = edited.range;
        }
      }

      if (!diverged && delta is! TextEditingDeltaNonTextUpdate) {
        final reserialized = _serialize();
        if (reserialized.text == _shadow!.text) {
          _window = reserialized;
        } else {
          diverged = true;
        }
      }
    }

    _finishBatch(editedBlockId: editedBlockId, editedRange: editedRange);
  }

  /// Whether any deletion or replacement in [deltas] overlaps the sentinel
  /// boundary — i.e. starts before `sentinel.length` and ends beyond it.
  /// Pure-sentinel deletions (`end <= sentinel.length`) are genuine
  /// backspace-at-block-start and handled correctly by the G1 path.
  static bool _hasSentinelOverlappingDeletion(List<TextEditingDelta> deltas) {
    const len = ImeWindow.sentinel.length;
    for (final delta in deltas) {
      TextRange? range;
      if (delta is TextEditingDeltaDeletion) {
        range = delta.deletedRange;
      } else if (delta is TextEditingDeltaReplacement) {
        range = delta.replacedRange;
      }
      if (range != null && range.start < len && range.end > len) return true;
    }
    return false;
  }

  /// Reprocesses [deltas] whose per-delta application would fail because a
  /// deletion overlaps the sentinel. Walks the raw delta chain to compute
  /// the engine's final state, diffs it against the pre-batch shadow, and
  /// processes the net effect as a single synthetic delta — borrowing the
  /// diff frontend's net-diff-then-synthesize core ([diffTexts] +
  /// [_synthesizeDelta]).
  ///
  /// This is the tail of [_processBatch], which BOTH frontends share: the
  /// delta frontend arrives with raw engine deltas, the diff frontend with
  /// the single delta [updateEditingValue] already synthesized from a
  /// snapshot (the class doc's "routed through the SAME batch path"). So the
  /// snapshot path's composing/stale filters ([_filterStaleComposing],
  /// [_suppressComposingBirth], the previous-shadow drop, `deadKeyRewrite`,
  /// [_passiveDivergence]) are deliberately NOT re-run here: on the diff
  /// frontend they already ran upstream before the delta reached
  /// [_processBatch]; on the delta frontend they have no snapshot to act on.
  /// Re-running them would double-filter, not close a gap — only
  /// [_sanitizeComposing] (cheap, idempotent) and the net-insertion echo
  /// quarantine remain.
  ///
  /// The one synthesized delta is applied directly rather than routed back
  /// through [_processBatch]: the net diff of a sentinel-overlapping batch
  /// can itself be sentinel-overlapping, so re-routing would re-enter this
  /// method forever.
  void _processSentinelOverlapBatch(
    List<TextEditingDelta> deltas,
    ({String text, int offset})? quarantine,
  ) {
    final initialShadow = _shadow!;
    var current = initialShadow;
    for (final delta in deltas) {
      if (delta.oldText != current.text) {
        _recoverAuthoritative('staleDelta');
        return;
      }
      current = delta.apply(current);
    }

    final diff = diffTexts(
      initialShadow.text,
      current.text,
      cursorOffset:
          current.selection.isValid ? current.selection.extentOffset : null,
    );

    final composing = _sanitizeComposing(current.composing, current.text);

    // Echo quarantine: check against the NET insertion, not individual deltas.
    if (quarantine != null && diff != null && diff.isInsert) {
      if (diff.insertedText == quarantine.text &&
          diff.start == quarantine.offset) {
        _recoverAuthoritative('echoQuarantine');
        return;
      }
    }

    final synth = _synthesizeDelta(
      initialShadow,
      current,
      diff: diff,
      composing: composing,
    );

    if (synth.delta != null) {
      final edited = _applyDelta(synth.delta!, diverged: false);
      _shadow = current;
      _finishBatch(
        editedBlockId: edited?.blockId,
        editedRange: edited?.range,
      );
    } else {
      _shadow = current;
      _finishBatch(editedBlockId: null, editedRange: null);
    }
  }

  /// Batch-end reconciliation: re-serialize the window and compare to the
  /// post-apply shadow (text + selection + composing — the no-echo triple).
  ///
  /// - Equal with live composing — the merge-via-replacement case (G10
  ///   refined): keep ComposingState remapped block-locally, send nothing.
  /// - Equal text with live composing but a divergent shadow selection that
  ///   lies WITHIN the composing region — WebKit's transient
  ///   marked-text-selected report: adopt the engine's selection into the
  ///   model ([_adoptComposingSelection]) and keep the composition live.
  /// - Divergent with live composing — the G10 split: on the DELTA frontend
  ///   route through `terminateComposition('structuralDelta')`; on the diff
  ///   frontend ABSORB instead ([_absorbComposingDivergence] — the web
  ///   engine cannot re-mark text, so a mid-composition push of any kind is
  ///   the #1641 corruption; §web fallback passive-while-composing).
  /// - Composing empty: run the input rules (immediately with this batch's
  ///   edited range, or latch-fire on a composition commit), then push iff
  ///   anything diverged — for the diff frontend this composing-empty push
  ///   IS the reconcile-at-composition-end point: divergence accumulated
  ///   during a passive window converges here, when pushing is safe.
  void _finishBatch({
    required String? editedBlockId,
    required TextRange? editedRange,
  }) {
    final shadow = _shadow!;
    final window = _serialize();
    final shadowComposing =
        shadow.composing.isValid && !shadow.composing.isCollapsed;
    final textConverged = window.text == shadow.text;
    final selectionConverged = _selectionsEquivalent(
      window.selection,
      shadow.selection,
    );

    if (textConverged) _window = window;

    if (shadowComposing) {
      final mapped = textConverged
          ? _mapComposing(shadow.composing, window)
          : null;
      final selectionAdopted =
          !selectionConverged &&
          textConverged &&
          mapped != null &&
          _adoptComposingSelection(shadow, window);
      if (!textConverged ||
          mapped == null ||
          !(selectionConverged || selectionAdopted)) {
        // The window diverged from the shadow (split moved it to a new
        // block, G1 merged across the sentinel) — or the composing region
        // no longer maps into one block, or the selection escaped the
        // composing region.
        if (frontend == ImeFrontend.nonDeltaDiff) {
          // Passive-while-composing (§web fallback): a snapshot-shaped
          // surprise must not write to the browser mid-composition —
          // absorb one-way or defer reconciliation to composition end.
          _absorbComposingDivergence(
            shadow,
            window,
            textConverged: textConverged,
            mapped: mapped,
            editedBlockId: editedBlockId,
          );
          return;
        }
        // Delta frontend: terminating is the ONLY legal way to push here
        // (the G10 divergence rule — its ordering guarantees differ, and
        // the cross-block composing type-over trace depends on it).
        terminateComposition('structuralDelta');
        return;
      }
      // Convergent (incl. merge-via-replacement): the composition survives
      // intact precisely because nothing is pushed.
      controller.imeSetComposing(mapped);
      // G3: rules are deferred, not dropped — latch the composed range, but
      // ONLY from a batch that actually changed text. A NonTextUpdate-only
      // batch (e.g. setComposingRegion over pre-existing text) inserted
      // nothing, and a latch armed from it would fire a rule on commit with
      // zero text change — a block already reading `---` would convert
      // spontaneously. An earlier edit-armed latch stays valid as recorded.
      if (editedBlockId != null) {
        _rulesLatch = (blockId: mapped.blockId, range: mapped.range);
      }
      return;
    }

    // Composing empty.
    final hadComposing = controller.composing != null;
    controller.imeSetComposing(null);
    final latch = _rulesLatch;
    _rulesLatch = null;

    // Prefer this batch's own edit (a replacement-commit carries one); a
    // NonTextUpdate commit has none — that is what the latch records.
    final ruleBlock = editedBlockId ?? (hadComposing ? latch?.blockId : null);
    final ruleRange = editedBlockId != null
        ? editedRange
        : (hadComposing ? latch?.range : null);
    var ruleFired = false;
    if (ruleBlock != null && ruleRange != null && ruleRange.isValid) {
      ruleFired = controller.imeRunInputRules(ruleBlock, ruleRange);
    }

    if (ruleFired || !textConverged || !selectionConverged) {
      _pushAuthoritativeWindow();
    }
  }

  /// WebKit's range-selection-over-composing snapshot (the Safari Japanese
  /// capture, `test/input/ime_safari_capture_replay_test.dart`): Safari
  /// transiently reports the marked text as SELECTED — the first composing
  /// snapshot of a romaji keystroke carries `selection == composing`, a
  /// non-collapsed range, which the applied insertion's collapsed model
  /// caret can never match. That shape is NOT structural divergence: the
  /// text converged and the composing region maps cleanly into one block —
  /// only the engine's selection sits inside the marked text where our
  /// applied caret does not. Terminating there is the #1641 pathology by
  /// our own hand: the viaTerminate push de-marks Safari's live composition
  /// while the IME keeps its internal buffer, so every later
  /// compositionupdate INSERTS its full text at the caret instead of
  /// replacing the no-longer-marked range — the captured
  /// `nににhにほにほnにほんg日本語` accumulation.
  ///
  /// The rule: a shadow selection (range or collapsed) lying WITHIN the
  /// composing region is honored as the real model selection — mapped
  /// block-locally, the same mapping a `NonTextUpdate` gets. Honored as a
  /// range rather than collapsed to its downstream end, by ComposingState's
  /// lifecycle rules (architecture §Selection): composing is
  /// selection-adjacent state with NO collapsed-while-composing invariant —
  /// the controller's ime verbs accept any normalized selection, and the
  /// hardware-key composing gate / underline / geometry reporting are all
  /// indifferent to the selection's shape. Adopting the engine's selection
  /// verbatim is also what keeps the no-echo triple genuinely convergent:
  /// `window.selection` equals `shadow.selection` again, leaving no
  /// special-cased residual divergence for the next batch to re-litigate.
  ///
  /// Genuinely structural shapes keep terminating: a selection spanning
  /// blocks or escaping the window cannot lie within a composing region
  /// that mapped into a single text span (the caller checks `mapped !=
  /// null` first), and a selection outside the composing region — same
  /// block or not — stays the G10 divergence this rule deliberately does
  /// not cover. Shared `_finishBatch`, so a DELTA carrying a range
  /// selection inside its composing region survives identically.
  ///
  /// Returns whether the selection was adopted; on true the model selection
  /// mirrors [shadow]'s and the caller treats the batch as converged.
  bool _adoptComposingSelection(TextEditingValue shadow, ImeWindow window) {
    final selection = shadow.selection;
    if (!selection.isValid) return false;
    final composing = shadow.composing;
    if (selection.start < composing.start || selection.end > composing.end) {
      return false;
    }
    final mapped = _mapBufferSelection(window, selection);
    if (mapped == null) return false;
    controller.imeSetSelection(mapped);
    journal.record(
      'composingSelectionAdopted',
      () => {
        'sel': [selection.baseOffset, selection.extentOffset],
        'composing': ImeJournal.describeRange(composing),
      },
    );
    return true;
  }

  /// The diff frontend's mid-composition divergence absorption
  /// (passive-while-composing, §web fallback). Every web IME corruption
  /// this consolidates traces to one seam: writing to the browser while it
  /// owns a live composition — the web engine cannot re-mark text, so a
  /// `setEditingState` mid-composition (the old
  /// `terminateComposition('structuralDelta')` reaction included) destroys
  /// the IME's marked region while its internal buffer continues
  /// (duplication, premature commits — the captured `nににhにほ…`
  /// accumulation; v2 was immune by construction because it never synced to
  /// the platform during composition). So a snapshot shape the delta
  /// frontend would terminate on is absorbed instead:
  ///
  /// - Text converged and the composing region maps, only the selection
  ///   diverged (outside the marked text, so [_adoptComposingSelection]
  ///   declined): adopt the engine's selection one-way into the model and
  ///   keep the composition — the engine knows where its own caret is, and
  ///   nothing structural happened.
  /// - Anything else (text structurally diverged, composing unmappable —
  ///   should be impossible from a browser, guarded anyway): defer — arm
  ///   [_passiveDivergence]; the model keeps this batch's one-way
  ///   application and the existing ComposingState (the hardware-key gate
  ///   stays closed: the browser genuinely still composes), later snapshots
  ///   acknowledge into the shadow only, and the composition-ending
  ///   snapshot runs the one authoritative reconciliation push
  ///   ([_absorbWhileDiverged]). The G3 latch clears — its invalidation
  ///   rule already covers "structurally changed before the composition
  ///   ends".
  void _absorbComposingDivergence(
    TextEditingValue shadow,
    ImeWindow window, {
    required bool textConverged,
    required ComposingState? mapped,
    required String? editedBlockId,
  }) {
    if (textConverged && mapped != null) {
      final adopted = _mapBufferSelection(window, shadow.selection);
      if (adopted != null) {
        controller.imeSetSelection(adopted);
        controller.imeSetComposing(mapped);
        // Same latch rule as the convergent path: only an edit-bearing
        // batch arms it (G3 — rules deferred, not dropped).
        if (editedBlockId != null) {
          _rulesLatch = (blockId: mapped.blockId, range: mapped.range);
        }
        journal.record(
          'passiveSelectionAbsorbed',
          () => {
            'sel': [shadow.selection.baseOffset, shadow.selection.extentOffset],
            'composing': ImeJournal.describeRange(shadow.composing),
          },
        );
        return;
      }
    }
    _passiveDivergence = true;
    _rulesLatch = null;
    journal.record(
      'passiveDivergence',
      () => {'textConverged': textConverged, 'composingMapped': mapped != null},
    );
  }

  /// Drops the remainder of the batch and re-pushes the authoritative
  /// window — through the choke point when the shadow reported composition.
  /// [reason] is both the drop class the inspector reports and the
  /// termination reason when composing was live.
  ///
  /// Web caveat (day-15/18 drip row, §web fallback / the v2 Safari scar):
  /// the recovery push always carries `composing: TextRange.empty`
  /// ([ImeWindow.toValue]'s default), but `setEditingState` does not make
  /// the BROWSER abandon a live DOM composition — there is no web analogue
  /// of the Android connection restart below. A recovery push landing
  /// mid-browser-composition leaves the engine's composition bookkeeping
  /// straddling the new (possibly shorter) text, which can surface
  /// downstream as a `TextEditingValue.fromJSON` range assert when the
  /// engine reports composing past the text end. Narrowing the
  /// previous-shadow drop ([updateEditingValue]) removed the known trigger
  /// (recovery firing on a live dead-key commit); making web recovery
  /// composition-safe is engine-behavior work, deferred to the day-15/18
  /// Safari/web polish pass rather than speculatively coded here.
  void _recoverAuthoritative(String reason) {
    debugLastDropReason = reason;
    journal.record('drop', () => {'reason': reason});
    if (_shadowComposing) {
      terminateComposition(reason);
    } else {
      controller.imeSetComposing(null);
      _pushAuthoritativeWindow();
    }
  }

  // --- Delta → ops translation ---

  /// Applies one delta through the controller's IME verbs. Returns the
  /// edited (blockId, block-local range) when the delta inserted text — the
  /// input-rule trigger; null otherwise.
  ({String blockId, TextRange range})? _applyDelta(
    TextEditingDelta delta, {
    required bool diverged,
  }) {
    final window = _window!;
    switch (delta) {
      case TextEditingDeltaNonTextUpdate():
        if (!diverged) {
          final selection = _mapBufferSelection(window, delta.selection);
          if (selection != null) controller.imeSetSelection(selection);
        }
        return null;

      case TextEditingDeltaInsertion():
        return _applyInsertion(
          window,
          delta.insertionOffset,
          delta.textInserted,
        );

      case TextEditingDeltaDeletion():
        _applyDeletion(window, delta.deletedRange);
        return null;

      case TextEditingDeltaReplacement():
        return _applyReplacement(
          window,
          delta.replacedRange,
          delta.replacementText,
        );
    }
    return null; // TextEditingDelta is not sealed; unknown kinds no-op.
  }

  ({String blockId, TextRange range})? _applyInsertion(
    ImeWindow window,
    int offset,
    String text,
  ) {
    if (window.elided && window.touchesElision(offset, offset)) {
      // Insertion into the elided interior classifies as a whole-selection
      // replacement against the model selection.
      controller.imeDeleteSelection();
      return _insertParts(text);
    }
    final clamped = math.max(offset, ImeWindow.sentinel.length);
    final position = window.positionForBufferOffset(clamped);
    if (position == null) return null;
    controller.imeSetSelection(DocSelection.collapsed(position));
    return _insertParts(text);
  }

  void _applyDeletion(ImeWindow window, TextRange range) {
    if (window.elided && window.touchesElision(range.start, range.end)) {
      // Any delta touching the elided interior is a whole-selection edit.
      controller.imeDeleteSelection();
      return;
    }

    const sentinelLength = ImeWindow.sentinel.length;
    if (range.start < sentinelLength) {
      // G1: the IME cannot report a deletion before the buffer start; with
      // the sentinel it arrives intersecting [0,2). Composite deletions
      // spanning the sentinel AND real text are DECOMPOSED, never handled
      // wholesale: (1) the text half through the normal path, then (2) the
      // structural-backspace consultation — both inside one transaction,
      // one re-serialize at batch end (routed through terminateComposition
      // when the post-apply shadow reports non-empty composing, per the
      // guard).
      if (range.end > sentinelLength) {
        final start = window.positionForBufferOffset(sentinelLength);
        final end = window.positionForBufferOffset(range.end);
        if (start != null && end != null && start != end) {
          controller.imeSetSelection(DocSelection(base: start, extent: end));
          controller.imeDeleteSelection();
        }
      }
      final firstSpan = window.spans.isEmpty
          ? null
          : window.spans.firstWhere((s) => !s.isElision);
      if (firstSpan != null && !firstSpan.isVoid) {
        // Same path for EVERY block start, not just the first — one
        // mechanism, the type's declared backspaceAtStart policy.
        controller.imeStructuralBackspace(firstSpan.blockId);
      }
      return;
    }

    final start = window.positionForBufferOffset(range.start);
    final end = window.positionForBufferOffset(range.end);
    if (start == null || end == null || start == end) return;
    controller.imeSetSelection(DocSelection(base: start, extent: end));
    controller.imeDeleteSelection();
  }

  ({String blockId, TextRange range})? _applyReplacement(
    ImeWindow window,
    TextRange range,
    String text,
  ) {
    if (window.elided && window.touchesElision(range.start, range.end)) {
      // Whole-selection replacement, mapped to the model selection directly
      // (the >cap window's classified form — §buffer serialization).
      if (text.contains('\n')) {
        controller.imeDeleteSelection();
        return _insertParts(text);
      }
      controller.imeInsertText(text);
      return _editedFromCaret(text);
    }

    if (range.start < ImeWindow.sentinel.length) {
      // G1 applied to replacements — reachable by documented API shape
      // (Android's setComposingRegion(0,n) + commitText emits one
      // replacement over [0, 2+k)). Decomposed like a composite deletion,
      // never handled wholesale: clamping only the range start while
      // inserting the full replacementText would land literal sentinel text
      // in the model ('. world' instead of 'world').
      return _applySentinelReplacement(window, range, text);
    }

    final start = window.positionForBufferOffset(range.start);
    final end = window.positionForBufferOffset(range.end);
    if (start == null || end == null) return null;
    controller.imeSetSelection(DocSelection(base: start, extent: end));
    if (text.isEmpty) {
      controller.imeDeleteSelection();
      return null;
    }
    if (text.contains('\n')) {
      controller.imeDeleteSelection();
      return _insertParts(text);
    }
    controller.imeInsertText(text);
    return _editedFromCaret(text);
  }

  /// Decomposes a replacement intersecting the sentinel (G1's discipline
  /// applied to replacements): (1) the replaced range clipped to `[2, end)`
  /// deletes through the normal path; (2) the sentinel-overlap prefix is
  /// stripped from [text] when the engine echoed it back; (3) the
  /// structural-backspace consultation runs only when the deletion half
  /// warrants it — i.e. the sentinel text was genuinely consumed rather
  /// than echoed, the replacement analogue of a `[0,2)`-intersecting
  /// deletion.
  ({String blockId, TextRange range})? _applySentinelReplacement(
    ImeWindow window,
    TextRange range,
    String text,
  ) {
    const sentinelLength = ImeWindow.sentinel.length;
    final overlap = ImeWindow.sentinel.substring(
      range.start,
      math.min(range.end, sentinelLength),
    );
    final echoed = text.startsWith(overlap);
    final replacement = echoed ? text.substring(overlap.length) : text;

    // The text half: delete the clipped [2, end) range (a no-op when the
    // replacement never reaches past the sentinel), leaving the caret where
    // the stripped replacement text lands.
    final start = window.positionForBufferOffset(sentinelLength);
    final end = window.positionForBufferOffset(
      math.max(range.end, sentinelLength),
    );
    if (start == null || end == null) return null;
    if (start != end) {
      controller.imeSetSelection(DocSelection(base: start, extent: end));
      controller.imeDeleteSelection();
    } else {
      controller.imeSetSelection(DocSelection.collapsed(start));
    }

    // The structural half: only a genuinely deleted sentinel maps to
    // "backspace at block start" (same consultation as the composite
    // deletion path); an echoed prefix leaves the sentinel intact net of
    // the replacement, so no backspaceAtStart policy applies.
    if (!echoed) {
      final firstSpan = window.spans.isEmpty
          ? null
          : window.spans.firstWhere((s) => !s.isElision);
      if (firstSpan != null && !firstSpan.isVoid) {
        controller.imeStructuralBackspace(firstSpan.blockId);
      }
    }

    if (replacement.isEmpty) return null;
    if (replacement.contains('\n')) return _insertParts(replacement);
    controller.imeInsertText(replacement);
    return _editedFromCaret(replacement);
  }

  /// Inserts [text], honoring embedded `\n`s through the controller's Enter
  /// path (split policies included). The edited range reported for rules is
  /// the last plain segment; a trailing newline clears it — rules fire on
  /// typed characters, never on Enter.
  ({String blockId, TextRange range})? _insertParts(String text) {
    ({String blockId, TextRange range})? edited;
    final parts = text.split('\n');
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part.isNotEmpty) {
        controller.imeInsertText(part);
        edited = _editedFromCaret(part);
      }
      if (i < parts.length - 1) {
        // This batch carries its own `\n`, so it splits here — a deferred
        // performAction(newline) is now fulfilled; clear it so the batch-end
        // flush doesn't split a second time.
        _pendingNewlineAction = false;
        controller.imeInsertNewline();
        edited = null;
      }
    }
    return edited;
  }

  /// The block-local range [text] just landed at, derived from the
  /// post-insert caret (insertText leaves a collapsed caret after the text).
  ({String blockId, TextRange range})? _editedFromCaret(String text) {
    final selection = controller.selection;
    if (selection == null || !selection.isCollapsed) return null;
    final caret = selection.extent;
    if (caret.offset < text.length) return null;
    return (
      blockId: caret.blockId,
      range: TextRange(start: caret.offset - text.length, end: caret.offset),
    );
  }

  DocSelection? _mapBufferSelection(ImeWindow window, TextSelection selection) {
    if (!selection.isValid) return null;
    final base = window.positionForBufferOffset(
      math.max(selection.baseOffset, ImeWindow.sentinel.length),
    );
    final extent = window.positionForBufferOffset(
      math.max(selection.extentOffset, ImeWindow.sentinel.length),
    );
    if (base == null || extent == null) return null;
    return DocSelection(base: base, extent: extent);
  }

  /// Buffer composing range → block-local [ComposingState]; null when the
  /// range does not lie within a single text block's span.
  ComposingState? _mapComposing(TextRange composing, ImeWindow window) {
    final start = math.max(composing.start, ImeWindow.sentinel.length);
    final end = composing.end;
    if (end <= start) return null;
    final span = window.textSpanContaining(start, end);
    if (span == null) return null;
    return ComposingState(
      blockId: span.blockId,
      range: TextRange(
        start: start - span.bufferStart,
        end: end - span.bufferStart,
      ),
    );
  }

  // --- Geometry reporting (G15 / composing-rect rule) ---

  bool _geometryReportScheduled = false;

  /// Re-sends geometry on the next frame end. The widget calls this from
  /// its scroll notifications (the day-15 re-send note, G15's metrics
  /// analogue for scrolling viewports): the caret/composing anchor moves
  /// with every scroll tick, and the engine's hidden-input placement — on
  /// web the ONLY signal positioning the IME candidate window — does not
  /// follow by itself. Coalesced per frame; a no-op while detached.
  void scheduleGeometryReport() => _scheduleGeometryReport();

  /// Sends caret/composing rects and the editable transform after every
  /// applied delta batch that can change them — post-frame, when the caret
  /// block has laid out. Null geometry (offscreen) is tolerated per GATE-L.
  void _scheduleGeometryReport() {
    if (!geometryReporter.isWired || _geometryReportScheduled) return;
    _geometryReportScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _geometryReportScheduled = false;
      final connection = _connection;
      if (connection == null) return;
      geometryReporter.report(
        connection,
        selection: controller.selection,
        composing: controller.composing,
      );
    });
  }
}

/// Reports geometry to the engine. Holds only the [ImeGeometryChannel] view
/// of the connection — separating "report geometry" from "report text" is
/// what makes G15 (`setEditingState` never called for pure geometry changes)
/// structural rather than disciplined.
///
/// **The editable box is anchored to the composing region (or the caret),
/// not the whole editor.** The web engine consumes ONLY
/// `setEditableSizeAndTransform` — `setMarkedTextRect`/`setCaretRect` are
/// explicit no-op commands there (engine `text_editing.dart`:
/// `TextInputSetMarkedTextRect`/`TextInputSetCaretRect`) — and positions its
/// hidden input element verbatim from the reported width/height/transform
/// (`EditableTextGeometry.applyToDomElement`). The browser then anchors the
/// IME candidate window to that element. Reporting the whole editor box put
/// the hidden input over the entire viewport with its DOM caret rendering at
/// the element's first line, so the candidate window opened at the editor's
/// top-left regardless of caret position or scroll (the manual Chrome AND
/// Safari finding). Anchoring the editable at the composing/caret rect —
/// transform = editor's global transform × the rect's editor-space offset —
/// makes the hidden input (and the candidate window) track the composition;
/// the engine explicitly supports mid-composition geometry updates
/// (`updateElementPlacement` skips `placeElement` while `composingText` is
/// held, flutter#98817). Caret/composing rects are re-expressed relative to
/// the anchored box, so the platforms that DO consume them (iOS candidate
/// bar anchoring) keep resolving to the same global position. With no
/// caret/composing geometry (no selection, offscreen block) the editor box
/// is reported as before — never silence, the engine needs *some* editable.
///
/// **The anchored editable reports a minimal size — 1 logical px wide, one
/// line tall — never the composing region's real bounds** (the
/// Monaco/CodeMirror hidden-input pattern: a tiny input AT the caret, not
/// an input that pretends to BE the text). The web engine's hidden editing
/// element renders our buffer text invisibly: `color`/`caret-color`/
/// `background` are forced `transparent` once at element creation (engine
/// `text_editing.dart`: `_setStaticStyleAttributes` — which also sets
/// `overflow: hidden` and `white-space: pre-wrap`). Chromium derives its
/// IME composition underline from the element's computed text color, so it
/// inherits the transparency and disappears; WebKit paints the underlines
/// the platform IME attaches to the marked text (per-clause thick/thin,
/// blue active clause on macOS) with their OWN colors, untouched by any
/// CSS the engine can set — the entire post-create style surface is
/// `TextInput.setStyle` = font + alignment, no color, no decoration
/// control. Making that native line COINCIDE with our rendered text was
/// tried (day 8) and abandoned: the browser lays the hidden `<textarea>`'s
/// content out by its own rules (wrapping at the reported width, its own
/// line boxes), so the blue line wandered as the composition grew — under
/// に, above にほ, fragmented over にほん (the manual Safari screenshots).
/// Starving it of area instead is structural: the engine applies the
/// reported size verbatim as CSS width/height with no clamping or minimum
/// (`EditableTextGeometry.applyToDomElement`), focus never depends on size
/// (`focusWithoutScroll`; input still routes through the focused element),
/// and inside a 1px-wide `overflow: hidden` box WebKit has nowhere to draw
/// a visible underline — OUR painted composing underline (G3 visibility)
/// is the single cross-browser one. The height stays one line (the anchor
/// rect's height) rather than 1px because browsers drop the IME candidate
/// window below the focused element's caret box: a line-height-tall
/// element keeps the candidate list below the composed line instead of
/// over it.
///
/// **The reporter also sends `TextInput.setStyle` with the caret block's
/// resolved font metrics.** On web this is the only styling that reaches
/// the hidden element after creation, applied as CSS `font` + `text-align`
/// (`EditableTextStyle.fromFrameworkMessage`/`applyToDomElement`). With
/// the element shrunk to nothing it no longer needs to mirror our line
/// layout, but the metrics still size the DOM caret the browser anchors
/// the candidate window's vertical offset to — and they are what keeps a
/// future element (or a platform that grows a real style consumer)
/// honest. Cheap and cached: re-sent only when the connection or the
/// resolved metrics change.
class ImeGeometryReporter {
  /// The editor's root render box — the coordinate space the per-block
  /// rects are lifted into before anchoring.
  RenderBox? Function()? editorRenderBox;

  /// Per-block geometry lookup (the layout registry; null ⇒ not laid out).
  BlockGeometry? Function(String blockId)? blockGeometryOf;

  /// The caret block's resolved text style — the widget wires the SAME
  /// resolution the components render with (block def's `baseStyle` over
  /// the editor base style, text scaling applied), so the hidden input's
  /// DOM font matches the pixels on the canvas. Null ⇒ unknown block.
  TextStyle? Function(String blockId)? resolvedStyleOf;

  /// Ambient text direction for [ImeGeometryChannel.setStyle].
  TextDirection Function()? textDirection;

  bool get isWired => editorRenderBox != null && blockGeometryOf != null;

  // The last style actually sent, keyed to the channel it was sent over —
  // a fresh connection (attach, Android terminate re-attach) gets a fresh
  // engine element and must be re-styled.
  ({
    ImeGeometryChannel channel,
    String? fontFamily,
    double? fontSize,
    FontWeight? fontWeight,
    TextDirection textDirection,
  })?
  _sentStyle;

  void report(
    ImeGeometryChannel channel, {
    required DocSelection? selection,
    required ComposingState? composing,
  }) {
    _sendStyleIfChanged(channel, selection: selection, composing: composing);

    final editorBox = editorRenderBox?.call();
    if (editorBox == null || !editorBox.attached || !editorBox.hasSize) return;

    Rect? caretRect; // editor space
    if (selection != null && selection.isCollapsed) {
      final caret = selection.extent;
      final geometry = blockGeometryOf?.call(caret.blockId);
      final rect = geometry?.rectForOffset(caret.offset);
      if (rect != null) {
        caretRect = _toEditorSpace(rect, geometry!.renderBox, editorBox);
      }
    }

    Rect? composingRect; // editor space
    if (composing != null && composing.range.isValid) {
      final geometry = blockGeometryOf?.call(composing.blockId);
      if (geometry != null) {
        final rects = geometry.rectsForRange(
          composing.range.start,
          composing.range.end,
        );
        if (rects.isNotEmpty) {
          var bounds = rects.first;
          for (var i = 1; i < rects.length; i++) {
            bounds = bounds.expandToInclude(rects[i]);
          }
          composingRect = _toEditorSpace(bounds, geometry.renderBox, editorBox);
        }
      }
    }

    // The anchor: the composing region while a composition is live (the
    // candidate window belongs to the marked text), else the caret, else
    // the editor box itself (GATE-L: offscreen geometry is null — estimate,
    // never force layout).
    final anchor = composingRect ?? caretRect;
    if (anchor == null) {
      channel.setEditableSizeAndTransform(
        editorBox.size,
        editorBox.getTransformTo(null),
      );
      return;
    }
    // Minimal size at the anchored position (see the class doc): 1 logical
    // px wide so WebKit's native marked-text underline has no area to
    // render in, one line tall so the browser drops the candidate window
    // below the composed line. The engine applies these verbatim as CSS
    // width/height (`EditableTextGeometry.applyToDomElement` — no clamping,
    // no minimum) and nothing in the input path depends on the element's
    // size: focus is `focusWithoutScroll`, events route through the
    // focused element regardless of its box.
    channel.setEditableSizeAndTransform(
      Size(1, anchor.height),
      editorBox.getTransformTo(null)
        ..translateByDouble(anchor.left, anchor.top, 0, 1),
    );
    if (caretRect != null) {
      channel.setCaretRect(caretRect.shift(-anchor.topLeft));
    }
    if (composingRect != null) {
      channel.setComposingRect(composingRect.shift(-anchor.topLeft));
    }
  }

  /// Sends `setStyle` with the caret/composing block's resolved metrics when
  /// they differ from what this channel last received (see the class doc for
  /// why the metrics must match — the engine styles the hidden element with
  /// exactly these fields and nothing else: `EditableTextStyle
  /// .applyToDomElement` sets CSS `font` + `text-align`).
  void _sendStyleIfChanged(
    ImeGeometryChannel channel, {
    required DocSelection? selection,
    required ComposingState? composing,
  }) {
    final lookup = resolvedStyleOf;
    if (lookup == null) return;
    // The composing block wins (the marked text lives there); otherwise the
    // caret block. No selection ⇒ nothing to style against.
    final blockId = composing?.blockId ?? selection?.extent.blockId;
    if (blockId == null) return;
    final style = lookup(blockId);
    if (style == null) return;
    final direction = textDirection?.call() ?? TextDirection.ltr;
    final current = (
      channel: channel,
      fontFamily: style.fontFamily,
      fontSize: style.fontSize,
      fontWeight: style.fontWeight,
      textDirection: direction,
    );
    if (_sentStyle case final sent?
        when identical(current.channel, sent.channel) &&
            current.fontFamily == sent.fontFamily &&
            current.fontSize == sent.fontSize &&
            current.fontWeight == sent.fontWeight &&
            current.textDirection == sent.textDirection) {
      return;
    }
    _sentStyle = current;
    channel.setStyle(
      fontFamily: style.fontFamily,
      fontSize: style.fontSize,
      fontWeight: style.fontWeight,
      textDirection: direction,
      // Blocks render start-aligned (RichText's default); alignment only
      // places the DOM text within the anchored box.
      textAlign: TextAlign.start,
    );
  }

  static Rect _toEditorSpace(Rect rect, RenderBox from, RenderBox to) =>
      MatrixUtils.transformRect(from.getTransformTo(to), rect);
}
