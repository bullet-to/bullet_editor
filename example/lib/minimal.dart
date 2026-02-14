import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/material.dart';

void main() => runApp(const MinimalApp());

class MinimalApp extends StatelessWidget {
  const MinimalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Minimal Tab Test')),
        body: const Padding(
          padding: EdgeInsets.all(16),
          child: MinimalEditor(),
        ),
      ),
    );
  }
}

class MinimalEditor extends StatefulWidget {
  const MinimalEditor({super.key});

  @override
  State<MinimalEditor> createState() => _MinimalEditorState();
}

class _MinimalEditorState extends State<MinimalEditor> {
  late final EditorController<BlockType, InlineStyle> _controller;

  @override
  void initState() {
    super.initState();
    _controller = EditorController(
      schema: EditorSchema.standard(),
      document: Document([
        TextBlock(
          id: 'a',
          blockType: BlockType.listItem,
          segments: [const StyledSegment('first')],
        ),
        TextBlock(
          id: 'b',
          blockType: BlockType.listItem,
          segments: [const StyledSegment('second')],
        ),
        TextBlock(
          id: 'c',
          blockType: BlockType.listItem,
          segments: [const StyledSegment('third')],
        ),
      ]),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BulletEditor(controller: _controller);
  }
}
