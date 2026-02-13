import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/material.dart';

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
        segments: [const StyledSegment('Type # then space for a heading')],
      ),
      TextBlock(
        id: 'b4',
        blockType: BlockType.listItem,
        segments: [const StyledSegment('Type - then space for a list item')],
      ),
    ]);

    _controller = EditorController(
      document: doc,
      inputRules: [
        HeadingRule(),
        ListItemRule(),
        EmptyListItemRule(),
        BoldWrapRule(),
      ],
    );
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
            // The editor
            Expanded(
              flex: 3,
              child: TextField(
                controller: _controller,
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
            const SizedBox(height: 16),
            // Debug panel — shows the document model state
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
                        'Document Model (${_controller.document.blocks.length} blocks)',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ..._controller.document.blocks.asMap().entries.map((
                        entry,
                      ) {
                        final i = entry.key;
                        final block = entry.value;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            'Block $i [${block.blockType.name}]: ${block.segments}',
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
