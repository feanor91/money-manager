import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:money_manager_core/data/mmex_database.dart';
import 'package:money_manager_core/data/mmex_repository.dart';
import 'package:money_manager_core/models/transaction.dart';
import 'package:money_manager/state/app_preferences.dart';
import 'package:money_manager/state/pin_lock_provider.dart';
import 'package:money_manager/widgets/nl_query_dialog.dart';

import '../test_helpers.dart';

/// Minimal in-memory AppPreferences stand-in, copied from
/// pin_lock_provider_test.dart's own _FakeCompanionPrefs - needed here too
/// so the lock/unlock regression test below can drive a real PinLockProvider
/// through PinGateStatus.locked (attachDatabase()/setPin() both require a
/// non-null companionPrefs to have anything to lock).
class _FakeCompanionPrefs implements AppPreferences {
  final Map<String, Object?> _data = {};

  @override
  String? getString(String key) => _data[key] as String?;
  @override
  Future<bool> setString(String key, String value) async {
    _data[key] = value;
    return true;
  }

  @override
  int? getInt(String key) => _data[key] as int?;
  @override
  Future<bool> setInt(String key, int value) async {
    _data[key] = value;
    return true;
  }

  @override
  List<String>? getStringList(String key) {
    final v = _data[key];
    return v is List ? v.cast<String>() : null;
  }

  @override
  Future<bool> setStringList(String key, List<String> value) async {
    _data[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    _data.remove(key);
    return true;
  }
}

/// Widget-level tests for [NlQueryDialog] itself - unlike the pure-logic
/// tests in period_parser_test.dart/rule_based_query_parser_test.dart/
/// query_executor_test.dart/answer_formatter_test.dart, these actually pump
/// the real widget tree against a real in-memory database and drive it
/// through genuine taps/typing, the closest thing to a live manual check
/// available in this environment (no Chrome/GTK here to open a real
/// browser/desktop window - see the session notes).
void main() {
  late Directory tempPrefsDir;

  setUpAll(() async {
    await initializeDateFormatting('fr_FR');
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    SharedPreferences.setMockInitialValues({});

    // The 3 tests below that tap "Demander" reach NlQueryDialog._ask(),
    // which - Platform.isWindows is true during `flutter test` on a real
    // Windows machine - calls isLocalLlmEnabled(), which calls
    // AppPreferences.getInstance(). Without seeding it here, that method's
    // real _portableStoreFilePath() check awaits File(...).exists() against
    // a path next to flutter_tester.exe - real, uncontrolled file I/O that
    // never resolves inside pumpAndSettle's pumped/faked execution, hanging
    // every one of those 3 tests forever (confirmed 2026-08-04 by tracing
    // it with prints: execution reached the exists() call and never
    // returned from it). Seeding the singleton makes getInstance() take its
    // early cached-instance return instead, so that file check is never
    // reached - isLocalLlmEnabled() then correctly resolves to false
    // (nothing set the enabled key), exactly like a real user who never
    // opted into local AI, letting the rule-based parser take over as
    // these tests expect.
    tempPrefsDir = Directory.systemTemp.createTempSync('nl_query_dialog_test_');
    AppPreferences.debugOverrideInstance(await AppPreferences.forTestingAtPath(
        '${tempPrefsDir.path}${Platform.pathSeparator}preferences.dat'));
  });

  tearDownAll(() {
    AppPreferences.debugResetInstance();
    tempPrefsDir.deleteSync(recursive: true);
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

  Future<void> pumpDialog(WidgetTester tester, {PinLockProvider? pinLock}) async {
    await tester.pumpWidget(
      // ChangeNotifierProvider<PinLockProvider> (2026-09-10) - NlQueryDialog
      // now watches this directly (see its own doc comment on why a
      // showDialog-pushed dialog needs to check the PIN lock itself rather
      // than inheriting it structurally) - a freshly constructed
      // PinLockProvider defaults to PinGateStatus.none (never attached to
      // a database here), same "nothing to gate" behavior these tests
      // already expected before that change existed. Tests that need to
      // actually drive a lock/unlock cycle pass their own [pinLock] in.
      ChangeNotifierProvider(
        create: (_) => pinLock ?? PinLockProvider(),
        child: MaterialApp(
          locale: const Locale('fr'),
          home: Scaffold(body: NlQueryDialog(repo: repo, forecastDay: 24)),
        ),
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
    await tester.tap(find.byKey(const Key('nlQuerySendButton')));
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

  testWidgets(
      'asking a second question keeps the first exchange visible instead of replacing it - '
      'regression test for the 2026-08-23 switch to a real multi-turn chat', (tester) async {
    await pumpDialog(tester);

    await tester.enterText(find.byType(TextField), 'Quel est le solde de mon compte ?');
    await tester.tap(find.byKey(const Key('nlQuerySendButton')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Solde de Compte Courant'), findsOneWidget);
    expect(find.text('Quel est le solde de mon compte ?'), findsOneWidget);

    await tester.enterText(
        find.byType(TextField), 'Quelles ont été mes dépenses ce mois-ci ?');
    await tester.tap(find.byKey(const Key('nlQuerySendButton')));
    await tester.pumpAndSettle();

    // Both the first question/answer and the second are still on screen.
    expect(find.text('Quel est le solde de mon compte ?'), findsOneWidget);
    expect(find.textContaining('Solde de Compte Courant'), findsOneWidget);
    expect(find.text('Quelles ont été mes dépenses ce mois-ci ?'), findsOneWidget);
    expect(find.textContaining('Dépenses totales'), findsOneWidget);

    // "Nouvelle conversation" clears the whole transcript back to the
    // example chips - "Quel est le solde de mon compte ?" is itself one of
    // the example chip labels, so it's expected to still be *somewhere* on
    // screen; what must actually be gone is the real chat exchange (the
    // computed answer text, never an example chip's own label).
    await tester.tap(find.byTooltip('Nouvelle conversation'));
    await tester.pumpAndSettle();
    expect(find.text('Exemples :'), findsOneWidget);
    expect(find.textContaining('Solde de Compte Courant'), findsNothing);
    expect(find.textContaining('Dépenses totales'), findsNothing);
  });

  testWidgets(
      'locking the app while the dialog is open hides the conversation and shows the lock '
      'placeholder instead, then restores it exactly as it was on unlock - regression test '
      'for the 2026-09-10 report that this dialog stayed usable behind the PIN lock',
      (tester) async {
    final pinLock = PinLockProvider();
    final prefs = _FakeCompanionPrefs();
    pinLock.attachDatabase(databaseReady: true, companionPrefs: prefs);
    await pinLock.setPin('1234');
    expect(pinLock.status, PinGateStatus.unlocked);

    await pumpDialog(tester, pinLock: pinLock);

    await tester.tap(find.text('Quel est le solde de mon compte ?'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Solde de Compte Courant'), findsOneWidget);

    // The app locks in the background (e.g. auto-lock/inactivity) while
    // this dialog is still open - simulated directly via lockNow(), same
    // call InactivityLockWatcher itself makes.
    pinLock.lockNow();
    await tester.pump();

    expect(pinLock.status, PinGateStatus.locked);
    expect(find.text('Money Manager verrouillé'), findsOneWidget);
    // The real chat content must not still be readable behind the lock
    // placeholder - this is the actual security property. The only
    // TextField visible must be the embedded PIN form's own field, not the
    // chat's question field (still findsOneWidget, not findsNothing - see
    // the 2026-09-10 "il faut que je clique hors de cette fenêtre" report:
    // the fix is to unlock *from inside* this dialog, not to remove input
    // entirely).
    expect(find.textContaining('Solde de Compte Courant'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);

    // Unlocking through the embedded form itself - not by calling
    // pinLock.verify() directly - is exactly the path the user's report
    // says was broken (previously the only way to reach a working PIN
    // field was to tap outside the dialog's own barrier, which dismissed
    // and destroyed it). Restores the dialog's underlying State object, so
    // the prior conversation is still there exactly as left - not reset to
    // the example chips.
    await tester.enterText(find.byType(TextField), '1234');
    await tester.tap(find.text('Déverrouiller'));
    await tester.pumpAndSettle();

    expect(pinLock.status, PinGateStatus.unlocked);
    expect(find.text('Money Manager verrouillé'), findsNothing);
    expect(find.textContaining('Solde de Compte Courant'), findsOneWidget);
  });

  testWidgets('an unrecognized question shows the "not understood" message', (tester) async {
    await pumpDialog(tester);

    await tester.enterText(find.byType(TextField), 'quelle heure est-il ?');
    await tester.tap(find.byKey(const Key('nlQuerySendButton')));
    await tester.pumpAndSettle();

    expect(find.textContaining("n'ai pas compris"), findsOneWidget);
  });
}
