import 'package:ar_campus_nav/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('loads the demo venue package', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.text('AR Campus Nav'), findsOneWidget);
    expect(find.textContaining('Demo Campus'), findsWidgets);
  });
}
