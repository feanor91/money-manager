import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_manager/widgets/searchable_select_field.dart';

void main() {
  testWidgets(
      'tapping the only remaining option in the dropdown selects it - '
      'regression test for the 2026-08-24 ROADMAP report that a single-item '
      'Tiers list could not be selected when adding a ledger transaction',
      (tester) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchableSelectField<String>(
            label: 'Tiers',
            options: const ['Seul Tiers'],
            labelOf: (s) => s,
            onSelected: (v) => selected = v,
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextFormField));
    await tester.pumpAndSettle();

    // Typing narrows the (already single-item) list down to itself, which
    // is what actually opens the options overlay - see RawAutocomplete's
    // own initState: it only listens for *changes* to the controller, so
    // focus alone (with no prior text change) never populates _options.
    await tester.enterText(find.byType(TextFormField), 'Seul');
    await tester.pumpAndSettle();

    expect(find.text('Seul Tiers'), findsWidgets);

    // The option appears both in the field (as typed text) and in the
    // dropdown's ListTile - tap the ListTile specifically.
    final listTile = find.widgetWithText(ListTile, 'Seul Tiers');
    expect(listTile, findsOneWidget);
    await tester.tap(listTile);
    await tester.pumpAndSettle();

    expect(selected, 'Seul Tiers');
  });

  testWidgets(
      'tapping the only option works even without typing first (focus-only path)',
      (tester) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchableSelectField<String>(
            label: 'Tiers',
            options: const ['Seul Tiers'],
            labelOf: (s) => s,
            onSelected: (v) => selected = v,
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextFormField));
    await tester.pumpAndSettle();

    final listTile = find.widgetWithText(ListTile, 'Seul Tiers');
    if (listTile.evaluate().isEmpty) {
      fail('Le menu déroulant ne montre jamais le seul tiers disponible '
          "tant qu'aucun caractère n'a été tapé (focus seul insuffisant).");
    }
    await tester.tap(listTile);
    await tester.pumpAndSettle();

    expect(selected, 'Seul Tiers');
  });

  testWidgets(
      'still selectable inside the real modal-bottom-sheet-plus-scroll-view '
      'shape the transaction editor actually uses (transactions_screen.dart)',
      (tester) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (context) => Padding(
                    padding: EdgeInsets.only(
                      left: 20,
                      right: 20,
                      top: 20,
                      bottom: MediaQuery.of(context).viewInsets.bottom + 20,
                    ),
                    child: Form(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SearchableSelectField<String>(
                              label: 'Tiers',
                              options: const ['Seul Tiers'],
                              labelOf: (s) => s,
                              onSelected: (v) => selected = v,
                            ),
                            const SizedBox(height: 400),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                child: const Text('Ouvrir'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Ouvrir'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TextFormField));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Seul');
    await tester.pumpAndSettle();

    final listTile = find.widgetWithText(ListTile, 'Seul Tiers');
    expect(listTile, findsOneWidget);
    await tester.tap(listTile);
    await tester.pumpAndSettle();

    expect(selected, 'Seul Tiers');
  });

  testWidgets(
      'selection survives a rebuild landing between pointer-down and '
      'pointer-up - this is the actual race searchable_select_field.dart\'s '
      'Listener.onPointerDown targets (an external ChangeNotifier, e.g. '
      'DatabaseProvider, firing mid-tap and rebuilding the option row). '
      'Confirmed causal: this test failed both against the original '
      "onTap and against an intermediate onTapDown attempt (still gated "
      'by gesture-arena resolution, which a competing ListView scroll '
      'recognizer defers to pointer-up) - only a raw pointer listener, '
      'which bypasses the arena entirely, closes the window.',
      (tester) async {
    String? selected;
    final rebuildTrigger = ValueNotifier<int>(0);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatedBuilder(
            animation: rebuildTrigger,
            builder: (context, _) => SearchableSelectField<String>(
              // A fresh key each external "notifyListeners" tick, like a
              // real widget rebuilding from watched provider state - forces
              // the option row to actually be torn down and rebuilt mid-tap
              // rather than Flutter quietly reusing the same Element.
              key: ValueKey('field-${rebuildTrigger.value}'),
              label: 'Tiers',
              options: const ['Seul Tiers'],
              labelOf: (s) => s,
              onSelected: (v) => selected = v,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextFormField));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Seul');
    await tester.pumpAndSettle();

    final listTile = find.widgetWithText(ListTile, 'Seul Tiers');
    expect(listTile, findsOneWidget);

    final gesture = await tester.startGesture(tester.getCenter(listTile));
    await tester.pump();
    // Simulates the external rebuild (a debounced save completing, etc.)
    // landing while the tap is still in flight.
    rebuildTrigger.value++;
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(selected, 'Seul Tiers');
  });
}
