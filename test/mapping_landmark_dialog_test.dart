import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ar_campus_nav/widgets/mapping_landmark_dialog.dart';

void main() {
  Future<void> open(
    WidgetTester tester,
    Completer<MappingLandmarkInput?> result,
  ) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () async {
                final input = await showDialog<MappingLandmarkInput>(
                  context: ctx,
                  builder: (_) => const MappingLandmarkDialog(),
                );
                result.complete(input);
              },
              child: const Text('Open tag dialog'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open tag dialog'));
    await tester.pumpAndSettle();

  }

  testWidgets('A real room is tagged without disposing any TextField',
      (tester) async {
    final result = Completer<MappingLandmarkInput?>();
    await open(tester, result);
    await tester.enterText(find.byType(TextFormField), 'Lab Komputer 2');
    await tester.tap(find.text('Save location'));
    await tester.pumpAndSettle();
    final tag = await result.future;
    expect(tag, isNotNull);
    expect(tag!.type, 'destination');
    expect(tag.label, 'Lab Komputer 2');
    expect(find.byType(MappingLandmarkDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('location dialog cannot silently create an unlocalized QR',
      (tester) async {
    final result = Completer<MappingLandmarkInput?>();
    await open(tester, result);
    expect(find.text('QR reference'), findsNothing);
    expect(find.textContaining('PLACE OFFLINE START CHECKPOINT'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result.future, isNull);
  });

  testWidgets('Empty destination names are rejected before closing',
      (tester) async {
    final result = Completer<MappingLandmarkInput?>();
    await open(tester, result);
    await tester.tap(find.text('Save location'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a 2–80 character location name.'), findsOneWidget);
    expect(find.byType(MappingLandmarkDialog), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result.future, isNull);
    expect(tester.takeException(), isNull);
  });
}
