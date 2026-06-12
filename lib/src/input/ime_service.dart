import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Matrix4, MatrixUtils, RenderBox;

import '../editor/editor_controller.dart';
import '../model/block.dart';
import '../model/doc_selection.dart';
import '../model/document.dart';
import '../schema/editor_schema.dart';
import '../view/block_layout_registry.dart';

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
}

/// One live engine connection (see [ImeGeometryChannel] for the split).
abstract interface class ImeConnection implements ImeGeometryChannel {
  bool get attached;
  void show();
  void setEditingState(TextEditingValue value);
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
  void close() => _connection.close();
}

ImeConnection _attachRealConnection(
  DeltaTextInputClient client,
  TextInputConfiguration configuration,
) {
  return _RealImeConnection(TextInput.attach(client, configuration));
}

/// One block's slice of the IME buffer.
class ImeWindowSpan {
  const ImeWindowSpan({
    required this.blockId,
    required this.bufferStart,
    required this.bufferEnd,
    this.localStart = 0,
    this.isVoid = false,
    this.isElision = false,
  });

  final String blockId;

  /// Buffer range this span occupies (`bufferEnd` exclusive). Spans are
  /// separated by one `\n` joint each.
  final int bufferStart;
  final int bufferEnd;

  /// Block-local offset at [bufferStart] — 0 except after a G1 merge
  /// remap, where the window text starts mid-block.
  final int localStart;

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
            ? target.localStart
            : target.localStart + (target.bufferEnd - target.bufferStart);
        return DocPosition(target.blockId, local);
      }
      if (offset <= span.bufferEnd) {
        if (span.isElision) return null;
        return DocPosition(
          span.blockId,
          span.localStart + (offset - span.bufferStart),
        );
      }
      previous = span;
    }
    final last = spans.last;
    if (last.isElision) return null;
    return DocPosition(
      last.blockId,
      last.localStart + (last.bufferEnd - last.bufferStart),
    );
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
      final local = position.offset - span.localStart;
      final clamped = local.clamp(0, span.bufferEnd - span.bufferStart);
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

/// One `ImeService` owning one engine connection with the delta model
/// enabled (architecture §IME). Responsibilities:
///
/// - the shadow buffer — text AND selection AND composing region as last
///   pushed to or acknowledged from the engine; the no-echo comparison
///   covers all three;
/// - delta → op translation through the controller's IME surface (one
///   choke point for every mutation);
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
    ImeConnectionFactory? connectionFactory,
    TextInputConfiguration? configuration,
  }) : _connectionFactory = connectionFactory ?? _attachRealConnection,
       _configuration = configuration ?? defaultConfiguration {
    controller.imeExternalChangeHandler = _onExternalChange;
  }

  /// Autocorrect IS the delta path (D8): declared here, corrected through
  /// the same delta application as typing.
  static const TextInputConfiguration defaultConfiguration =
      TextInputConfiguration(
        inputType: TextInputType.multiline,
        inputAction: TextInputAction.newline,
        enableDeltaModel: true,
        autocorrect: true,
        enableSuggestions: true,
      );

  final EditorController controller;
  final ImeConnectionFactory _connectionFactory;
  final TextInputConfiguration _configuration;

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

  /// The one-batch echo quarantine (G7/G10): the terminated composing text
  /// and the pushed-window caret it would echo back at. Armed by
  /// [terminateComposition], consumed (disarmed) by the next delta batch.
  ({String text, int offset})? _quarantine;

  /// The G3 rules latch: insert-pattern rules are deferred, not dropped —
  /// re-evaluated when a later batch (or a `NonTextUpdate`) ends with
  /// composing cleared. Invalidated by every [terminateComposition] and by
  /// any non-IME change.
  ({String blockId, TextRange range})? _rulesLatch;

  bool get isAttached => _connection != null;

  // --- Inspector / debug surface (pane 3) ---

  TextEditingValue? get debugShadow => _shadow;
  List<TextEditingDelta>? debugLastDeltas;
  String? debugLastTerminateReason;
  String? debugLastDropReason;
  bool get debugQuarantineArmed => _quarantine != null;
  ({String text, int offset})? get debugQuarantine => _quarantine;

  // --- Lifecycle ---

  /// Opens the connection and pushes the current window. Idempotent.
  /// Attached whenever the editor has focus — including when the selection
  /// is on a void block (buffer = sentinel + `~`), so an active connection
  /// exists for context menus and void-delete deltas (G9, GATE-M).
  void attach() {
    _wantsConnection = true;
    if (_connection != null) return;
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
    _connection!.close();
    _connection = null;
    _shadow = null;
    _window = null;
    _quarantine = null;
    _rulesLatch = null;
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

    // Record the quarantine payload BEFORE clearing: the engine-side
    // composed text is what an OEM IME holding internal composition would
    // re-commit against the freshly pushed shadow.
    final shadow = _shadow;
    final composedText = _shadowComposing
        ? shadow!.composing.textInside(shadow.text)
        : null;

    controller.imeClearComposing();

    if (reason == 'connectionClosed' || _connection == null) {
      // Push and re-attach skipped: there is no connection. State clears so
      // the lazy re-attach starts fresh.
      _shadow = null;
      _window = null;
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
    debugLastDeltas = textEditingDeltas;
    if (_connection == null || _shadow == null) return;
    controller.imeEdit(() => _processBatch(textEditingDeltas));
    _scheduleGeometryReport();
    notifyListeners();
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    // Non-delta values arrive only behind the day-8 web diff frontend
    // (`text_diff.dart` over the same shadow-buffer core); the delta
    // frontend declares enableDeltaModel and ignores this callback.
  }

  @override
  void performAction(TextInputAction action) {
    if (action != TextInputAction.newline) return;
    if (_shadow == null) return;
    controller.imeEdit(() {
      controller.imeInsertNewline();
      // No delta accompanies an action: re-serialize and reconcile — a
      // split diverges the window (push; through the choke point if a
      // composition is live, G10), a code block's literal \n also
      // re-serializes divergent from the unchanged shadow.
      _finishBatch(editedBlockId: null, editedRange: null);
    });
    _scheduleGeometryReport();
    notifyListeners();
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
    _connection = null;
    terminateComposition('connectionClosed');
  }

  // --- Delta application (queue, shadow buffer, stale-delta guard) ---

  void _processBatch(List<TextEditingDelta> deltas) {
    // The quarantine covers exactly the FIRST batch after a terminate push,
    // then disarms — a user genuinely retyping the syllable types it in a
    // later batch.
    final quarantine = _quarantine;
    _quarantine = null;

    var diverged = false;
    String? editedBlockId;
    TextRange? editedRange;

    for (final delta in deltas) {
      final shadow = _shadow!;

      // Post-terminate echo quarantine (G7/G10): an insertion that exactly
      // re-inserts the terminated composing text at the pushed caret is an
      // engine echo by construction (its oldText matches the fresh shadow,
      // so the stale-delta guard is structurally blind to it). Drop and
      // re-push — worst case identical to the guard's lost-delta.
      if (quarantine != null &&
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

  /// Batch-end reconciliation: re-serialize the window and compare to the
  /// post-apply shadow (text + selection + composing — the no-echo triple).
  ///
  /// - Equal with live composing — the merge-via-replacement case (G10
  ///   refined): keep ComposingState remapped block-locally, send nothing.
  /// - Divergent with live composing — the G10 split: route through
  ///   `terminateComposition('structuralDelta')`.
  /// - Composing empty: run the input rules (immediately with this batch's
  ///   edited range, or latch-fire on a composition commit), then push iff
  ///   anything diverged.
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
      if (!textConverged || mapped == null || !selectionConverged) {
        // The window diverged from the shadow (split moved it to a new
        // block, G1 merged across the sentinel) — or the composing region
        // no longer maps into one block. Terminating is the ONLY legal way
        // to push here.
        terminateComposition('structuralDelta');
        return;
      }
      // Convergent (incl. merge-via-replacement): the composition survives
      // intact precisely because nothing is pushed.
      controller.imeSetComposing(mapped);
      // G3: rules are deferred, not dropped — latch the composed range.
      _rulesLatch = (blockId: mapped.blockId, range: mapped.range);
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

  /// Drops the remainder of the batch and re-pushes the authoritative
  /// window — through the choke point when the shadow reported composition.
  void _recoverAuthoritative(String debugReason) {
    debugLastDropReason = debugReason;
    if (_shadowComposing) {
      terminateComposition('staleDelta');
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

    final start = window.positionForBufferOffset(
      math.max(range.start, ImeWindow.sentinel.length),
    );
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
        start: span.localStart + (start - span.bufferStart),
        end: span.localStart + (end - span.bufferStart),
      ),
    );
  }

  // --- Geometry reporting (G15 / composing-rect rule) ---

  bool _geometryReportScheduled = false;

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
class ImeGeometryReporter {
  /// The editor's root render box — the editable the engine anchors to.
  RenderBox? Function()? editorRenderBox;

  /// Per-block geometry lookup (the layout registry; null ⇒ not laid out).
  BlockGeometry? Function(String blockId)? blockGeometryOf;

  bool get isWired => editorRenderBox != null && blockGeometryOf != null;

  void report(
    ImeGeometryChannel channel, {
    required DocSelection? selection,
    required ComposingState? composing,
  }) {
    final editorBox = editorRenderBox?.call();
    if (editorBox == null || !editorBox.attached || !editorBox.hasSize) return;
    channel.setEditableSizeAndTransform(
      editorBox.size,
      editorBox.getTransformTo(null),
    );

    if (selection != null && selection.isCollapsed) {
      final caret = selection.extent;
      final geometry = blockGeometryOf?.call(caret.blockId);
      final rect = geometry?.rectForOffset(caret.offset);
      if (rect != null) {
        channel.setCaretRect(
          _toEditorSpace(rect, geometry!.renderBox, editorBox),
        );
      }
    }

    if (composing != null && composing.range.isValid) {
      final geometry = blockGeometryOf?.call(composing.blockId);
      if (geometry != null) {
        final rects = geometry.rectsForRange(
          composing.range.start,
          composing.range.end,
        );
        if (rects.isNotEmpty) {
          var bounds = rects.first;
          for (final r in rects.skip(1)) {
            bounds = bounds.expandToInclude(r);
          }
          channel.setComposingRect(
            _toEditorSpace(bounds, geometry.renderBox, editorBox),
          );
        }
      }
    }
  }

  static Rect _toEditorSpace(Rect rect, RenderBox from, RenderBox to) =>
      MatrixUtils.transformRect(from.getTransformTo(to), rect);
}
