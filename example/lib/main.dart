import 'package:bullet_editor/bullet_editor.dart'
    as offsetMapper
    show displayToModel, modelToDisplay;
import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const BulletEditorExample());
}

class BulletEditorExample extends StatefulWidget {
  const BulletEditorExample({super.key});

  @override
  State<BulletEditorExample> createState() => _BulletEditorExampleState();
}

class _BulletEditorExampleState extends State<BulletEditorExample> {
  ThemeMode _themeMode = ThemeMode.light;

  void _toggleTheme() {
    setState(() {
      _themeMode = _themeMode == ThemeMode.light
          ? ThemeMode.dark
          : ThemeMode.light;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bullet Editor POC',
      theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
      darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      themeMode: _themeMode,
      home: EditorScreen(onToggleTheme: _toggleTheme),
    );
  }
}

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, this.onToggleTheme});

  final VoidCallback? onToggleTheme;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final EditorController<BlockType, InlineStyle> _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();

    final doc = Document([
      TextBlock(
        id: 'b1',
        blockType: BlockType.h1,
        segments: [const StyledSegment('Welcome to Bullet Editor')],
      ),
      TextBlock(
        id: 'b2',
        blockType: BlockType.paragraph,
        segments: [
          const StyledSegment('This is a '),
          const StyledSegment('bold', {InlineStyle.bold}),
          const StyledSegment(' paragraph with a '),
          const StyledSegment(
            'link',
            {InlineStyle.link},
            {'url': 'https://flutter.dev'},
          ),
          const StyledSegment('.'),
        ],
      ),
      TextBlock(
        id: 'bh2',
        blockType: BlockType.h2,
        segments: [const StyledSegment('Heading 2 example')],
      ),
      TextBlock(
        id: 'bh3',
        blockType: BlockType.h3,
        segments: [const StyledSegment('Heading 3 example')],
      ),
      TextBlock(
        id: 'b3',
        blockType: BlockType.listItem,
        segments: [const StyledSegment('Parent item')],
        children: [
          TextBlock(
            id: 'b3a',
            blockType: BlockType.listItem,
            segments: [const StyledSegment('Nested child')],
          ),
        ],
      ),
      TextBlock(
        id: 'b4',
        blockType: BlockType.listItem,
        segments: [const StyledSegment('Tab to indent, Shift+Tab to outdent')],
      ),
      TextBlock(id: 'bdiv', blockType: BlockType.divider),
      TextBlock(
        id: 'b5',
        blockType: BlockType.numberedList,
        segments: [const StyledSegment('First numbered item')],
      ),
      TextBlock(
        id: 'b6',
        blockType: BlockType.numberedList,
        segments: [const StyledSegment('Second numbered item')],
      ),
      TextBlock(
        id: 'b7',
        blockType: BlockType.taskItem,
        segments: [const StyledSegment('Unchecked task')],
        metadata: {'checked': false},
      ),
      TextBlock(
        id: 'b8',
        blockType: BlockType.taskItem,
        segments: [const StyledSegment('Completed task')],
        metadata: {'checked': true},
      ),
    ]);

    _controller = EditorController(
      schema: EditorSchema.standard(),
      document: doc,
      onLinkTap: (url) => debugPrint('Link tapped: $url'),
      // Input rules come from the schema — no manual list needed.
    );
    _controller.addListener(() => setState(() {}));

    _focusNode = FocusNode(onKeyEvent: _handleKeyEvent);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _showLinkDialog() {
    if (!_controller.value.selection.isValid) return;

    // If cursor is inside an existing link, pre-fill its URL.
    final existingUrl = _controller.currentAttributes['url'] as String?;
    final isEditing =
        existingUrl != null &&
        _controller.activeStyles.contains(InlineStyle.link);

    // For new links, require a selection. For editing, collapsed is fine.
    if (!isEditing && _controller.value.selection.isCollapsed) return;

    // If editing with collapsed cursor, select the entire link segment
    // so setLink replaces its URL.
    if (isEditing && _controller.value.selection.isCollapsed) {
      _selectCurrentLinkSegment();
    }

    final urlController = TextEditingController(text: existingUrl ?? '');
    showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isEditing ? 'Edit Link' : 'Insert Link'),
        content: TextField(
          controller: urlController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'https://...',
            labelText: 'URL',
          ),
          onSubmitted: (url) => Navigator.of(ctx).pop(url),
        ),
        actions: [
          if (isEditing)
            TextButton(
              onPressed: () {
                // Remove the link style.
                _controller.toggleStyle(InlineStyle.link);
                Navigator.of(ctx).pop();
              },
              child: const Text('Remove Link'),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(urlController.text),
            child: const Text('Apply'),
          ),
        ],
      ),
    ).then((url) {
      if (url == null) {
        // Cancelled — do nothing.
      } else if (url.isEmpty) {
        // Empty URL — remove the link.
        _controller.toggleStyle(InlineStyle.link);
      } else {
        _controller.setLink(url);
      }
      _focusNode.requestFocus();
    });
  }

  /// Select the full link segment at the cursor so setLink can update its URL.
  void _selectCurrentLinkSegment() {
    final sel = _controller.value.selection;
    if (!sel.isValid || !sel.isCollapsed) return;

    final offset = sel.baseOffset;

    // Walk the document model to find the link segment boundaries.
    // Link segments share the same style, so look for where the link style
    // boundary is by checking the document model.
    final doc = _controller.document;
    final schema = _controller.schema;
    final modelOffset = offsetMapper.displayToModel(doc, offset, schema);
    final pos = doc.blockAt(modelOffset);
    final block = doc.allBlocks[pos.blockIndex];

    var segStart = 0;
    for (final seg in block.segments) {
      final segEnd = segStart + seg.text.length;
      if (pos.localOffset >= segStart && pos.localOffset <= segEnd) {
        if (seg.styles.contains(InlineStyle.link)) {
          // Convert local offsets to display offsets.
          final globalStart = doc.globalOffset(pos.blockIndex, segStart);
          final globalEnd = doc.globalOffset(pos.blockIndex, segEnd);
          final displayStart = offsetMapper.modelToDisplay(
            doc,
            globalStart,
            schema,
          );
          final displayEnd = offsetMapper.modelToDisplay(
            doc,
            globalEnd,
            schema,
          );
          _controller.value = _controller.value.copyWith(
            selection: TextSelection(
              baseOffset: displayStart,
              extentOffset: displayEnd,
            ),
          );
        }
        break;
      }
      segStart = segEnd;
    }
  }

  String _buildDebugText() {
    final buf = StringBuffer();
    buf.writeln(
      'Document (${_controller.document.allBlocks.length} blocks, '
      '${_controller.document.blocks.length} roots)',
    );
    for (final entry in _controller.document.allBlocks.asMap().entries) {
      final i = entry.key;
      final block = entry.value;
      final depth = _controller.document.depthOf(i);
      final indent = '  ' * depth;
      final meta = block.metadata.isNotEmpty ? ' ${block.metadata}' : '';
      final attrs = block.segments
          .where((s) => s.attributes.isNotEmpty)
          .map((s) => s.attributes)
          .toList();
      final attrStr = attrs.isNotEmpty ? ' $attrs' : '';
      buf.writeln(
        '$indent[$i] ${block.blockType}$meta: "${block.plainText}"$attrStr',
      );
    }
    return buf.toString();
  }

  /// App-level keyboard shortcuts (copy/cut with markdown encoding).
  /// Tab, Shift+Tab, Cmd+Z, Cmd+Shift+Z are handled by BulletEditor.
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final isMeta =
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed;
    if (!isMeta) return KeyEventResult.ignored;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.keyC:
        // Rich copy: encode selection as markdown.
        final md = _controller.encodeSelection();
        if (md != null) {
          Clipboard.setData(ClipboardData(text: md));
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored; // no selection, let Flutter handle
      case LogicalKeyboardKey.keyX:
        // Rich cut: encode selection as markdown + delete selection.
        // Must handle both ourselves — returning ignored would let Flutter
        // overwrite our markdown clipboard with plain text.
        final md = _controller.encodeSelection();
        if (md != null) {
          Clipboard.setData(ClipboardData(text: md));
          // Delete the selection by simulating an empty replacement.
          final sel = _controller.value.selection;
          if (!sel.isCollapsed) {
            final start = sel.start;
            _controller.value = _controller.value.copyWith(
              text:
                  _controller.text.substring(0, sel.start) +
                  _controller.text.substring(sel.end),
              selection: TextSelection.collapsed(offset: start),
            );
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      case LogicalKeyboardKey.keyB:
        _controller.toggleStyle(InlineStyle.bold);
        setState(() {});
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyI:
        _controller.toggleStyle(InlineStyle.italic);
        setState(() {});
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyK:
        _showLinkDialog();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyS:
        if (HardwareKeyboard.instance.isShiftPressed) {
          _controller.toggleStyle(InlineStyle.strikethrough);
          setState(() {});
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      default:
        return KeyEventResult.ignored;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bullet Editor POC'),
        actions: [
          IconButton(
            icon: Icon(
              Theme.of(context).brightness == Brightness.dark
                  ? Icons.light_mode
                  : Icons.dark_mode,
            ),
            tooltip: 'Toggle dark mode',
            onPressed: widget.onToggleTheme,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Toolbar.
            // Row(
            //   children: [
            //     Expanded(
            //       child: EditorToolbar(
            //         controller: _controller,
            //         editorFocusNode: _focusNode,
            //       ),
            //     ),
            //     const SizedBox(width: 8),
            //     IconButton(
            //       icon: Icon(
            //         Icons.link,
            //         color: _controller.activeStyles.contains(InlineStyle.link)
            //             ? Theme.of(context).colorScheme.primary
            //             : null,
            //       ),
            //       tooltip: 'Link (Cmd+K)',
            //       onPressed: _showLinkDialog,
            //     ),
            //   ],
            // ),
            const SizedBox(height: 8),
            Expanded(
              flex: 3,
              child: BulletEditor(
                controller: _controller,
                focusNode: _focusNode,
              ),
            ),
            const SizedBox(height: 16),
            // Debug panel — shows allBlocks with depth.
            Expanded(
              flex: 2,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _buildDebugText(),
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
