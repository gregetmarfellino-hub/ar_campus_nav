import 'package:ar_campus_nav/main.dart';
import 'package:ar_campus_nav/services/venue_loader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('loads the demo venue package', (tester) async {
    // Verify the actual bundled venue data directly, independent of ongoing
    // home-screen animations or asynchronous platform startup.
    final venue = await tester.runAsync(
      () => const VenueLoader().loadBundled('assets/venues/demo_campus'),
    );

    expect(venue, isNotNull);
    expect(venue!.id, 'demo_campus_engineering');
    expect(venue.name, contains('Demo Campus'));
    expect(venue.nodes, isNotEmpty);
    expect(venue.edges, isNotEmpty);
    expect(venue.destinations, isNotEmpty);
    expect(venue.anchors, isNotEmpty);
    expect(
      venue.nodes.any((node) => node.id == venue.defaultStartNodeId),
      isTrue,
    );
  });

  testWidgets('renders the app shell', (tester) async {
    await tester.pumpWidget(const MyApp());

    // First frame only: the home screen can keep loading asynchronously,
    // so pumpAndSettle is not an appropriate assertion here.
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(Scaffold), findsWidgets);
  });
}
