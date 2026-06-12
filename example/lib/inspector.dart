import 'dart:async';
import 'dart:convert';

import 'package:bullet_editor/bullet_editor.dart';
// The gauntlet fixture is a dev/test artifact, deliberately not in the
// package barrel; the inspector is the other sanctioned consumer.
// ignore: implementation_imports
import 'package:bullet_editor/src/dev/gauntlet_document.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'native_composing_underline.dart';

/// The v3 dev harness (v3-build-strategy.md §dev harness): editor on the
/// left, tabbed debug panes on the right.
///
/// Panes 1–3 (document tree, selection, IME window) are live; panes 4–6
/// (change stream, perf, record) land with the subsystems they inspect.
class InspectorScreen extends StatefulWidget {
  const InspectorScreen({super.key});

  @override
  State<InspectorScreen> createState() => _InspectorScreenState();
}

class _InspectorScreenState extends State<InspectorScreen> {
  late final EditorController _controller = EditorController(
    document: buildGauntletDocument(),
    schema: EditorSchema.standard(),
  );
  final GlobalKey<BulletEditorState> _editorKey = GlobalKey();
  InlineEntitySnapshot? _lastLinkTap;
  String? _lastLinkTapBlockId;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onControllerChanged() => setState(() {});

  void _reloadFixture() => _controller.setDocument(buildGauntletDocument());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('bullet_editor inspector — v3 day 8'),
        actions: [
          IconButton(
            tooltip: 'Undo',
            icon: const Icon(Icons.undo),
            onPressed: _controller.canUndo ? _controller.undo : null,
          ),
          IconButton(
            tooltip: 'Redo',
            icon: const Icon(Icons.redo),
            onPressed: _controller.canRedo ? _controller.redo : null,
          ),
          IconButton(
            tooltip: 'Reload gauntlet fixture',
            icon: const Icon(Icons.refresh),
            onPressed: _reloadFixture,
          ),
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: BulletEditor(
                key: _editorKey,
                controller: _controller,
                autofocus: true,
                // WebKit hosts: let Safari's own marked-text underline own
                // the live composition (the package never sniffs browsers;
                // the app does — see native_composing_underline.dart).
                nativeComposingUnderline: nativeComposingUnderline,
                textStyle: Theme.of(context).textTheme.bodyLarge,
                padding: const EdgeInsets.all(16),
                onLinkTap: (blockId, offset, entity) {
                  setState(() {
                    _lastLinkTap = entity;
                    _lastLinkTapBlockId = blockId;
                  });
                },
              ),
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            flex: 2,
            // SelectionArea: every pane's text is selectable/copyable —
            // shadow buffers, journal lines, delta dumps paste straight
            // into a bug report.
            child: SelectionArea(
              child: _InspectorPanes(
                controller: _controller,
                editorKey: _editorKey,
                lastLinkTap: _lastLinkTap,
                lastLinkTapBlockId: _lastLinkTapBlockId,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InspectorPanes extends StatelessWidget {
  const _InspectorPanes({
    required this.controller,
    required this.editorKey,
    required this.lastLinkTap,
    required this.lastLinkTapBlockId,
  });

  final EditorController controller;
  final GlobalKey<BulletEditorState> editorKey;
  final InlineEntitySnapshot? lastLinkTap;
  final String? lastLinkTapBlockId;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: 'Document tree'),
              Tab(text: 'Selection'),
              Tab(text: 'IME'),
              Tab(text: 'Journal'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _DocumentTreePane(
                  document: controller.document,
                  schema: controller.schema,
                ),
                _SelectionPane(
                  controller: controller,
                  lastLinkTap: lastLinkTap,
                  lastLinkTapBlockId: lastLinkTapBlockId,
                ),
                _ImePane(editorKey: editorKey),
                _ImeJournalPane(editorKey: editorKey),
              ],
            ),
          ),
          _LazinessFooter(document: controller.document, editorKey: editorKey),
        ],
      ),
    );
  }
}

/// Pane 1 — the live block tree: short ids, types, depth, metadata, segment
/// styles. (The v2 "node tree" pane that was very helpful, ported.)
class _DocumentTreePane extends StatelessWidget {
  const _DocumentTreePane({required this.document, required this.schema});

  final Document document;
  final EditorSchema schema;

  @override
  Widget build(BuildContext context) {
    final mono = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(fontFamily: 'Menlo');
    final blocks = document.allBlocks;

    return ListView.builder(
      itemCount: blocks.length,
      itemBuilder: (context, index) {
        final block = blocks[index];
        final depth = document.depthOf(index);
        final shortId = block.id.length > 8
            ? block.id.substring(0, 8)
            : block.id;
        final def = schema.blockDef(block.blockType);

        final segmentSummary = block.segments.isEmpty
            ? (def.isVoid ? '∅ void' : '∅ empty')
            : block.segments
                  .map((s) {
                    final styles = s.styles.isEmpty
                        ? ''
                        : '{${s.styles.join(',')}}';
                    final text = s.text.length > 18
                        ? '${s.text.substring(0, 18)}…'
                        : s.text;
                    return '"$text"$styles';
                  })
                  .join(' ');

        return Padding(
          padding: EdgeInsets.only(left: 8.0 + depth * 16, right: 8),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '$shortId ',
                  style: mono?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
                TextSpan(
                  text: '${block.blockType} ',
                  style: mono?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                if (block.metadata.isNotEmpty)
                  TextSpan(
                    text: '${block.metadata} ',
                    style: mono?.copyWith(
                      color: Theme.of(context).colorScheme.tertiary,
                    ),
                  ),
                TextSpan(text: segmentSummary, style: mono),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Pane 2 — live DocSelection endpoints, ComposingState, undo state, and
/// the link-tap log. Active styles arrive with the typing-style work.
class _SelectionPane extends StatelessWidget {
  const _SelectionPane({
    required this.controller,
    required this.lastLinkTap,
    required this.lastLinkTapBlockId,
  });

  final EditorController controller;
  final InlineEntitySnapshot? lastLinkTap;
  final String? lastLinkTapBlockId;

  @override
  Widget build(BuildContext context) {
    final mono = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(fontFamily: 'Menlo');
    final selection = controller.selection;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('DocSelection', style: Theme.of(context).textTheme.titleSmall),
        Text(
          selection == null
              ? '—'
              : 'base:   ${selection.base}\n'
                    'extent: ${selection.extent}\n'
                    'collapsed: ${selection.isCollapsed}',
          style: mono,
        ),
        const SizedBox(height: 12),
        Text('Undo', style: Theme.of(context).textTheme.titleSmall),
        Text(
          'canUndo: ${controller.canUndo}  canRedo: ${controller.canRedo}',
          style: mono,
        ),
        const SizedBox(height: 12),
        Text('ComposingState', style: Theme.of(context).textTheme.titleSmall),
        Text('${controller.composing ?? '—'}', style: mono),
        const SizedBox(height: 12),
        Text('Last link tap', style: Theme.of(context).textTheme.titleSmall),
        Text(
          lastLinkTap == null ? '—' : 'block $lastLinkTapBlockId\n$lastLinkTap',
          style: mono,
        ),
      ],
    );
  }
}

/// Pane 3 — the IME window (v3-build-strategy §dev harness): the active
/// frontend (delta vs the day-8 web diff fallback), the shadow buffer as
/// the engine sees it (sentinel visible), the last received/synthesized
/// delta batch, the last value diff in web-fallback mode, the last
/// terminateComposition reason, and the quarantine state. This pane is why
/// IME bugs get diagnosed in minutes instead of days.
class _ImePane extends StatelessWidget {
  const _ImePane({required this.editorKey});

  final GlobalKey<BulletEditorState> editorKey;

  /// Sentinel/joints made visible: '·' for the sentinel space, '⏎' for
  /// block joints.
  static String visible(String text) =>
      "'${text.replaceAll(' ', '·').replaceAll('\n', '⏎')}'";

  @override
  Widget build(BuildContext context) {
    final ime = editorKey.currentState?.imeService;
    if (ime == null) return const Center(child: Text('—'));

    final mono = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(fontFamily: 'Menlo');

    return ListenableBuilder(
      listenable: ime,
      builder: (context, _) {
        final shadow = ime.debugShadow;
        final deltas = ime.debugLastDeltas;
        final isDiffFrontend = ime.frontend == ImeFrontend.nonDeltaDiff;
        final diff = ime.debugLastDiff;
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Text('Connection', style: Theme.of(context).textTheme.titleSmall),
            Text(
              '${ime.isAttached ? 'attached' : 'detached'}\n'
              'frontend: ${ime.frontend.name}'
              '${isDiffFrontend ? ' (web diff fallback)' : ' (delta model)'}',
              style: mono,
            ),
            const SizedBox(height: 12),
            if (isDiffFrontend) ...[
              Text(
                'Last value diff (web fallback)',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              Text(
                diff == null
                    ? '— (no text change: NonTextUpdate analogue or echo)'
                    : 'start: ${diff.start}  '
                          'deleted: ${diff.deletedLength}  '
                          'inserted: ${visible(diff.insertedText)}',
                style: mono,
              ),
              const SizedBox(height: 12),
            ],
            Text(
              'Shadow buffer (as the engine sees it)',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(
              shadow == null
                  ? '—'
                  : 'text:      ${visible(shadow.text)}\n'
                        'selection: ${shadow.selection.start}..'
                        '${shadow.selection.end}\n'
                        'composing: ${shadow.composing}',
              style: mono,
            ),
            const SizedBox(height: 12),
            Text(
              isDiffFrontend
                  ? 'Last delta batch (synthesized from the value diff)'
                  : 'Last delta batch',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(
              deltas == null || deltas.isEmpty
                  ? '—'
                  : deltas
                        .map(
                          (d) => '${d.runtimeType}: ${visible(d.toString())}',
                        )
                        .join('\n'),
              style: mono,
              maxLines: 12,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            Text(
              'terminateComposition',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(
              'last reason: ${ime.debugLastTerminateReason ?? '—'}\n'
              'last drop:   ${ime.debugLastDropReason ?? '—'}\n'
              'quarantine:  ${ime.debugQuarantineArmed ? ime.debugQuarantine : 'disarmed'}\n'
              'selector:    ${ime.debugLastSelector ?? '—'}'
              '${ime.debugLastUnhandledSelector == null ? '' : '\nunhandled:   ${ime.debugLastUnhandledSelector} (day-10 matrix)'}',
              style: mono,
            ),
          ],
        );
      },
    );
  }
}

/// Pane 4 — the IME journal (v3-build-strategy §record-and-replay): the
/// interleaved engine + hardware-key event stream, most-recent-last, one
/// dense line per event (`seq +ms kind: payload`). **Copy JSON** puts the
/// full one-line-per-event capture on the clipboard — paste it into a chat
/// or a test and replay it against `ImeService` with the fake connection
/// (`test/input/ime_replay.dart`). This is how a misbehaving Safari IME
/// session becomes a failing unit test in minutes.
class _ImeJournalPane extends StatelessWidget {
  const _ImeJournalPane({required this.editorKey});

  final GlobalKey<BulletEditorState> editorKey;

  @override
  Widget build(BuildContext context) {
    final ime = editorKey.currentState?.imeService;
    if (ime == null) return const Center(child: Text('—'));
    final journal = ime.journal;

    final mono = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(fontFamily: 'Menlo', fontSize: 11);

    return ListenableBuilder(
      listenable: journal,
      builder: (context, _) {
        final events = journal.events;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  Text(
                    '${events.length} events'
                    '${journal.enabled ? '' : ' (disabled: release build)'}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: events.isEmpty
                        ? null
                        : () => Clipboard.setData(
                            ClipboardData(text: journal.dump()),
                          ),
                    child: const Text('Copy JSON'),
                  ),
                  TextButton(
                    onPressed: events.isEmpty ? null : journal.clear,
                    child: const Text('Clear'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              // reverse + reversed items: most-recent-last with the view
              // pinned to the newest event as the stream grows.
              child: ListView.builder(
                reverse: true,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                itemCount: events.length,
                itemBuilder: (context, index) {
                  final e = events[events.length - 1 - index];
                  return Text(
                    '${e.seq} +${e.elapsedMs}ms ${e.kind}: '
                    '${jsonEncode(e.payload)}',
                    style: mono,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Footer — laid-out block count against the document total (validates D5
/// laziness at a glance; graduates into the full perf pane on day 10).
class _LazinessFooter extends StatefulWidget {
  const _LazinessFooter({required this.document, required this.editorKey});

  final Document document;
  final GlobalKey<BulletEditorState> editorKey;

  @override
  State<_LazinessFooter> createState() => _LazinessFooterState();
}

class _LazinessFooterState extends State<_LazinessFooter> {
  // The registry mutates as the user scrolls; poll on a coarse tick. (The
  // real perf pane with rebuild counters is booked for day 10.)
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final registry = widget.editorKey.currentState?.registry;
    final laidOut = registry?.layoutCount ?? 0;
    final total = widget.document.allBlocks.length;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Text(
        'laid out: $laidOut / $total blocks (lazy if ≪ total)',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}
