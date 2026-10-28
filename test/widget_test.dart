import 'package:ar_campus_nav/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('loads the demo venue package', (tester) async {
    const native = MethodChannel('ar_campus_nav/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(native, (call) async {
      if (call.method == 'loadMapping') return null;
      throw MissingPluginException('Unexpected native call: ${call.method}');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(native, null));

    // Asset I/O must finish outside the widget test's fake clock. Otherwise
    // pumpAndSettle can time out while the loading spinner keeps animating.
    await tester.runAsync(() async {
      for (final filename in [
        'venue.json',
        'nodes.json',
        'edges.json',
        'destinations.json',
        'anchors.json',
      ]) {
        await rootBundle.loadString('assets/venues/demo_campus/$filename');
      }
    });

    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.text('AR Campus Nav'), findsOneWidget);
    expect(find.textContaining('Demo Campus'), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
