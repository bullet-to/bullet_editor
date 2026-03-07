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
  late final EditorController<BlockType, InlineStyle, InlineEntityType>
  _controller;
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
            {InlineEntityType.link},
            {'url': 'https://flutter.dev'},
          ),
          const StyledSegment('.'),
        ],
      ),
      TextBlock(
        id: 'b2a',
        blockType: BlockType.paragraph,
        segments: [
          const StyledSegment('Adjacent links: '),
          const StyledSegment(
            'alpha',
            {InlineEntityType.link},
            {'url': 'https://example.com/alpha'},
          ),
          const StyledSegment(
            'beta',
            {InlineEntityType.link},
            {'url': 'https://example.com/beta'},
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
        id: 'bh4',
        blockType: BlockType.h4,
        segments: [const StyledSegment('Heading 4 example')],
      ),
      TextBlock(
        id: 'bh5',
        blockType: BlockType.h5,
        segments: [const StyledSegment('Heading 5 example')],
      ),
      TextBlock(
        id: 'bh6',
        blockType: BlockType.h6,
        segments: [const StyledSegment('Heading 6 example')],
      ),
      TextBlock(
        id: 'bq1',
        blockType: BlockType.blockQuote,
        segments: [const StyledSegment('This is a block quote')],
      ),
      TextBlock(
        id: 'binline',
        blockType: BlockType.paragraph,
        segments: [
          const StyledSegment('Here is some '),
          const StyledSegment('inline code', {InlineStyle.code}),
          const StyledSegment(' in a paragraph.'),
        ],
      ),
      TextBlock(
        id: 'bcode',
        blockType: BlockType.codeBlock,
        segments: [const StyledSegment('void main() {\n  print("Hello!");\n}')],
        metadata: {'language': 'dart'},
      ),
      // Image disabled — needs multi-widget architecture for proper rendering.
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
      onInlineEntityTap: (entity) =>
          debugPrint('Inline entity tapped: ${entity.data}'),
      // Input rules come from the schema — no manual list needed.
    );
    _controller.addListener(() => setState(() {}));

    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _showLinkDialog() async {
    if (!_controller.value.selection.isValid) return;

    final touchedLinks = _controller.inlineEntitiesInSelection(
      type: InlineEntityType.link,
    );
    if (touchedLinks.length > 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Selection touches multiple links. Edit one link at a time.',
          ),
        ),
      );
      _focusNode.requestFocus();
      return;
    }

    final touchedLink = touchedLinks.isEmpty ? null : touchedLinks.single;
    final editInfo = touchedLink != null
        ? InlineEntityEditInfo(
            text: touchedLink.text,
            type: InlineEntityType.link,
            data: touchedLink.data,
          )
        : _controller.inlineEntityEditInfo;
    final linkData = editInfo?.type == InlineEntityType.link
        ? editInfo!.data as LinkData
        : null;
    final result = await showDialog<_LinkDialogResult>(
      context: context,
      builder: (ctx) => _LinkDialog(
        initialText: editInfo?.text ?? '',
        initialUrl: linkData?.url ?? '',
        isEditing: editInfo?.type == InlineEntityType.link,
      ),
    );

    if (!mounted || result == null) {
      _focusNode.requestFocus();
      return;
    }

    if (result.remove) {
      _selectInlineEntity(touchedLink);
      _controller.removeInlineEntity(InlineEntityType.link);
      _focusNode.requestFocus();
      return;
    }

    final url = result.url.trim();
    if (url.isEmpty) {
      _focusNode.requestFocus();
      return;
    }

    final text = result.text.trim();
    _selectInlineEntity(touchedLink);
    _controller.setInlineEntity(
      InlineEntityType.link,
      LinkData(url: url),
      text: text.isEmpty ? null : text,
    );
    _focusNode.requestFocus();
  }

  void _selectInlineEntity(InlineEntityInfo<InlineEntityType>? entity) {
    if (entity != null) {
      _controller.value = _controller.value.copyWith(
        selection: TextSelection(
          baseOffset: entity.displayStart,
          extentOffset: entity.displayEnd,
        ),
      );
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
      buf.writeln('$indent[$i] ${block.blockType}$meta: "${block.plainText}"');
      for (final segmentEntry in block.segments.asMap().entries) {
        final segment = segmentEntry.value;
        final styles = segment.styles.isEmpty ? '[]' : '${segment.styles}';
        final attributes = segment.attributes.isEmpty
            ? '{}'
            : '${segment.attributes}';
        buf.writeln(
          '$indent  - seg ${segmentEntry.key}: '
          '"${segment.text}" styles=$styles attrs=$attributes',
        );
      }
    }
    return buf.toString();
  }

  // App-level shortcuts are added via Shortcuts widget in build().

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
            Row(
              children: [
                Expanded(
                  child: EditorToolbar(
                    controller: _controller,
                    blockTypeSelector: BlockTypeSelector(
                      controller: _controller,
                      items: const [
                        BlockTypeSelectorItem(
                          type: BlockType.paragraph,
                          label: 'Paragraph',
                        ),
                        BlockTypeSelectorItem(type: BlockType.h1, label: 'H1'),
                        BlockTypeSelectorItem(type: BlockType.h2, label: 'H2'),
                        BlockTypeSelectorItem(
                          type: BlockType.listItem,
                          label: 'Bullet',
                        ),
                        BlockTypeSelectorItem(
                          type: BlockType.numberedList,
                          label: 'Numbered',
                        ),
                        BlockTypeSelectorItem(
                          type: BlockType.taskItem,
                          label: 'Task',
                        ),
                        BlockTypeSelectorItem(
                          type: BlockType.blockQuote,
                          label: 'Quote',
                        ),
                      ],
                    ),
                    styleButtons: [
                      StyleToggleButton(
                        controller: _controller,
                        style: InlineStyle.bold,
                        icon: Icons.format_bold,
                        tooltip: 'Bold',
                      ),
                      StyleToggleButton(
                        controller: _controller,
                        style: InlineStyle.italic,
                        icon: Icons.format_italic,
                        tooltip: 'Italic',
                      ),
                      StyleToggleButton(
                        controller: _controller,
                        style: InlineStyle.strikethrough,
                        icon: Icons.format_strikethrough,
                        tooltip: 'Strikethrough',
                      ),
                      StyleToggleButton(
                        controller: _controller,
                        style: InlineStyle.code,
                        icon: Icons.code,
                        tooltip: 'Code',
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: Icon(
                    Icons.link,
                    color:
                        _controller.inlineEntityEditInfo?.type ==
                            InlineEntityType.link
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  tooltip: 'Link (Cmd+K)',
                  onPressed: _showLinkDialog,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              flex: 3,
              // Cmd+K for link dialog is app-specific, so it lives here
              // rather than in BulletEditor.
              child: Shortcuts(
                shortcuts: const {
                  SingleActivator(LogicalKeyboardKey.keyK, meta: true):
                      _LinkDialogIntent(),
                },
                child: Actions(
                  actions: {
                    _LinkDialogIntent: CallbackAction<_LinkDialogIntent>(
                      onInvoke: (_) {
                        _showLinkDialog();
                        return null;
                      },
                    ),
                  },
                  child: BulletEditor(
                    controller: _controller,
                    focusNode: _focusNode,
                  ),
                ),
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

class _LinkDialogIntent extends Intent {
  const _LinkDialogIntent();
}

class _LinkDialogResult {
  const _LinkDialogResult({
    required this.text,
    required this.url,
    this.remove = false,
  });

  final String text;
  final String url;
  final bool remove;
}

class _LinkDialog extends StatefulWidget {
  const _LinkDialog({
    required this.initialText,
    required this.initialUrl,
    required this.isEditing,
  });

  final String initialText;
  final String initialUrl;
  final bool isEditing;

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late final TextEditingController _textController;
  late final TextEditingController _urlController;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.initialText);
    _urlController = TextEditingController(text: widget.initialUrl);
  }

  @override
  void dispose() {
    _textController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isEditing ? 'Edit Link' : 'Add Link'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _textController,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Text'),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _urlController,
            decoration: const InputDecoration(
              labelText: 'URL',
              hintText: 'https://example.com',
            ),
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => Navigator.of(context).pop(
              _LinkDialogResult(
                text: _textController.text,
                url: _urlController.text,
              ),
            ),
          ),
        ],
      ),
      actions: [
        if (widget.isEditing)
          TextButton(
            onPressed: () => Navigator.of(
              context,
            ).pop(const _LinkDialogResult(text: '', url: '', remove: true)),
            child: const Text('Remove'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(
            _LinkDialogResult(
              text: _textController.text,
              url: _urlController.text,
            ),
          ),
          child: Text(widget.isEditing ? 'Update' : 'Add'),
        ),
      ],
    );
  }
}
