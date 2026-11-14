import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ar_campus_nav/widgets/mapping_landmark_dialog.dart';

void main() {
  Future<Future<MappingLandmarkInput?>> open(WidgetTester tester) async {
    final result = Completer<MappingLandmarkInput?>();
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
    return result.future;
  }

  testWidgets('A real room is tagged without disposing any TextField',
      (tester) async {
    final result = await open(tester);
    await tester.enterText(find.byType(TextFormField), 'Lab Komputer 2');
    await tester.tap(find.text('Save location'));
    await tester.pumpAndSettle();
    final tag = await result;
    expect(tag, isNotNull);
    expect(tag!.type, 'destination');
    expect(tag.label, 'Lab Komputer 2');
    expect(find.byType(MappingLandmarkDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('QR anchor is identified as reference, not spatial lock',
      (tester) async {
    final result = await open(tester);
    await tester.tap(find.text('QR reference'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Main Entrance');
    await tester.tap(find.text('Save location'));
    await tester.pumpAndSettle();
    final tag = await result;
    expect(tag!.type, 'anchor');
    expect(tag.label, 'Main Entrance');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Empty destination names are rejected before closing',
      (tester) async {
    final result = await open(tester);
    await tester.tap(find.text('Save location'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a 2–80 character location name.'), findsOneWidget);
    expect(find.byType(MappingLandmarkDialog), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result, isNull);
    expect(tester.takeException(), isNull);
  });
}
