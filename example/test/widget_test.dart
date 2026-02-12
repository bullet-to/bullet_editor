import 'package:bullet_editor_example/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App renders', (tester) async {
    await tester.pumpWidget(const BulletEditorExample());
    expect(find.text('Bullet Editor POC'), findsOneWidget);
  });
}
