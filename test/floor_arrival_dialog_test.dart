import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ar_campus_nav/widgets/floor_arrival_dialog.dart';

void main() {
  Future<void> openDialog(
    WidgetTester tester, {
    required int currentFloor,
    required ValueChanged<int?> onResult,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () async {
                  final result = await showDialog<int>(
                    context: context,
                    builder: (_) => FloorArrivalDialog(
                      currentFloor: currentFloor,
                    ),
                  );
                  onResult(result);
                },
                child: const Text('Open floor dialog'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open floor dialog'));
    await tester.pumpAndSettle();
    expect(find.byType(FloorArrivalDialog), findsOneWidget);
  }

  testWidgets('Floor 2 marker closes with no disposed controller exception',
      (tester) async {
    int? chosen;
    await openDialog(
      tester,
      currentFloor: 1,
      onResult: (value) => chosen = value,
    );
    await tester.enterText(find.byType(TextFormField), '2');
    await tester.tap(find.text('Mark landing'));
    await tester.pumpAndSettle();
    expect(chosen, 2);
    expect(find.byType(FloorArrivalDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Invalid same-floor label stays in dialog and is editable',
      (tester) async {
    int? chosen;
    await openDialog(
      tester,
      currentFloor: 1,
      onResult: (value) => chosen = value,
    );
    await tester.enterText(find.byType(TextFormField), '1');
    await tester.tap(find.text('Mark landing'));
    await tester.pumpAndSettle();
    expect(find.byType(FloorArrivalDialog), findsOneWidget);
    expect(
      find.text('Choose a different whole-number floor (-10 to 50).'),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextFormField), '2');
    await tester.tap(find.text('Mark landing'));
    await tester.pumpAndSettle();
    expect(chosen, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Cancel returns null safely without crashing the input',
      (tester) async {
    int? chosen = -99;
    await openDialog(
      tester,
      currentFloor: -1,
      onResult: (value) => chosen = value,
    );
    expect(find.text('1', findRichText: true), findsWidgets);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(chosen, isNull);
    expect(tester.takeException(), isNull);
  });
}
