import 'package:flutter_test/flutter_test.dart';
import 'package:eye_helper/main.dart';

void main() {
  testWidgets('EyeHelperApp smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const EyeHelperApp());
    expect(find.byType(EyeHelperApp), findsOneWidget);
  });
}
