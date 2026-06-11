import 'package:flutter/material.dart';

import 'inspector.dart';

void main() => runApp(const BulletEditorExample());

/// The v3 dev harness: the inspector (editor left, debug panes right).
/// See context/v3-build-strategy.md §dev harness.
class BulletEditorExample extends StatelessWidget {
  const BulletEditorExample({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'bullet_editor inspector',
      theme: ThemeData(useMaterial3: true),
      darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: const InspectorScreen(),
    );
  }
}
