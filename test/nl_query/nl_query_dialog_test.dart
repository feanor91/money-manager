import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:money_manager/data/mmex_database.dart';
import 'package:money_manager/data/mmex_repository.dart';
import 'package:money_manager/models/transaction.dart';
import 'package:money_manager/widgets/nl_query_dialog.dart';

import '../test_helpers.dart';

/// Widget-level tests for [NlQueryDialog] itself - unlike the pure-logic
/// tests in period_parser_test.dart/rule_based_query_parser_test.dart/
/// query_executor_test.dart/answer_formatter_test.dart, these actually pump
/// the real widget tree against a real in-memory database and drive it
/// through genuine taps/typing, the closest thing to a live manual check
/// available in this environment (no Chrome/GTK here to open a real
/// browser/desktop window - see the session notes).
///
/// KNOWN ISSUE (2026-08-03): the 3 tests below that actually tap "Demander"
/// hang on pumpAndSettle on this machine - newly exposed now that this file
/// compiles at all (it didn't before today, blocked by the unrelated
/// llama_cpp_dart removal - see ROADMAP.md), so this was never run here
/// until now. Root cause not confirmed: Platform.isWindows is true during
/// `flutter test` on this real Windows machine, so NlQueryDialog._ask()
/// really does reach the (Windows-only) local-LLM check, and the mocks
/// below are a reasonable, harmless guard against shared_preferences
/// needing a real platform channel there - but adding them did *not*
/// resolve the hang, and a print placed immediately before that check
/// never even printed, suggesting execution never gets that far in the
/// first place. Needs a real debugging session on a Windows dev machine,
/// not blind guessing from here - left failing rather than silently
/// skipped so it stays visible.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('fr_FR');
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    SharedPreferences.setMockInitialValues({});
  });

  late MmexDatabase db;
  late MmexRepository repo;

  setUp(() async {
    db = await openBlankTestDb();
    repo = MmexRepository(db);
    final accountId = repo.insertAccount(
        name: 'Compte Courant', type: 'Checking', initialBalance: 1000, currencyId: 2);
    final payeeId = repo.insertPayee(name: 'Carrefour');
    final now = DateTime.now();
    repo.insertTransaction(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 42.5,
      date: DateTime(now.year, now.month, 1),
      categoryId: 9, // "Alimentation", seeded by the blank schema
    );
  });

  tearDown(() => db.dispose());

  Future<void> pumpDialog(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('fr'),
        home: Scaffold(body: NlQueryDialog(repo: repo, forecastDay: 24)),
      ),
    );
  }

  testWidgets('starts by showing example questions, no answer yet', (tester) async {
    await pumpDialog(tester);
    expect(find.text('Exemples :'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('typing a recognized question and asking shows a real computed answer',
      (tester) async {
    await pumpDialog(tester);

    await tester.enterText(
        find.byType(TextField), 'Quelles ont été mes dépenses ce mois-ci ?');
    await tester.tap(find.widgetWithText(FilledButton, 'Demander'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Dépenses totales'), findsOneWidget);
    // No BASECURRENCYID is seeded in the blank test schema, so
    // getBaseCurrency() falls back to the first currency row (US dollar,
    // '.' decimal point) - see MmexRepository.getDefaultCurrency.
    expect(find.textContaining('42.50'), findsOneWidget);
  });

  testWidgets('tapping an example chip asks it directly', (tester) async {
    await pumpDialog(tester);

    await tester.tap(find.text('Quel est le solde de mon compte ?'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Solde de Compte Courant'), findsOneWidget);
  });

  testWidgets('an unrecognized question shows the "not understood" message', (tester) async {
    await pumpDialog(tester);

    await tester.enterText(find.byType(TextField), 'quelle heure est-il ?');
    await tester.tap(find.widgetWithText(FilledButton, 'Demander'));
    await tester.pumpAndSettle();

    expect(find.textContaining("n'ai pas compris"), findsOneWidget);
  });
}
