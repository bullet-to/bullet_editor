import 'package:bullet_editor_example/main.dart';
import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('inspector renders the gauntlet fixture', (tester) async {
    tester.view.physicalSize = const Size(2400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const BulletEditorExample());
    expect(find.text('Gauntlet document', findRichText: true), findsOneWidget);
    // Pane 1 lists block types from the tree.
    expect(find.text('Document tree'), findsOneWidget);
  });
}
