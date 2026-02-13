import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const BulletEditorExample());
}

class BulletEditorExample extends StatelessWidget {
  const BulletEditorExample({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bullet Editor POC',
      theme: ThemeData(useMaterial3: true),
      home: const EditorScreen(),
    );
  }
}

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final EditorController _controller;
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
        segments: [
          const StyledSegment('This is a '),
          const StyledSegment('bold', {InlineStyle.bold}),
          const StyledSegment(' paragraph.'),
        ],
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
    ]);

    _controller = EditorController(
      document: doc,
      inputRules: [
        HeadingRule(),
        ListItemRule(),
        EmptyListItemRule(),
        ListItemBackspaceRule(),
        NestedBackspaceRule(),
        BoldWrapRule(),
      ],
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

  /// Intercept Tab / Shift+Tab before Flutter's focus system eats them.
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.tab) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        _controller.outdent();
      } else {
        _controller.indent();
      }
      setState(() {});
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bullet Editor POC')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The editor — wrapped in Focus to intercept Tab/Shift+Tab.
            Expanded(
              flex: 3,
              child: Focus(
                onKeyEvent: _handleKeyEvent,
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(fontSize: 16, height: 1.5),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.all(12),
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
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey[300]!),
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Document (${_controller.document.allBlocks.length} blocks, '
                        '${_controller.document.blocks.length} roots)',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ..._controller.document.allBlocks
                          .asMap()
                          .entries
                          .map((entry) {
                        final i = entry.key;
                        final block = entry.value;
                        final depth = _controller.document.depthOf(i);
                        final indent = '  ' * depth;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Text(
                            '$indent[$i] ${block.blockType.name}: "${block.plainText}"',
                            style: TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                              color: Colors.grey[800],
                            ),
                          ),
                        );
                      }),
                    ],
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
