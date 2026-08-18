import 'package:flutter_test/flutter_test.dart';

import 'package:money_manager/data/mmex_database.dart';
import 'package:money_manager/data/mmex_repository.dart';
import 'package:money_manager/models/transaction.dart';

import 'test_helpers.dart';

/// forecastAccountBalance's anchor is the real balance as of *today*
/// (accountBalance(asOf: today)), and an already-recorded transaction with
/// a future date is added back in on its own actual date via
/// futureDailyNet - reflected in the forecast once the target date reaches
/// it, but never pulled forward into an earlier target (2026-08-18 fix: an
/// all-transactions total with no asOf, used previously, made a target
/// date *before* such a postdated entry overshoot - see
/// mmex_repository.dart's accountBalance/forecastAccountBalance doc
/// comments and forecast_chart.dart's ForecastChart._buildPoints).
void main() {
  late MmexDatabase db;
  late MmexRepository repo;
  late int accountId;
  late int payeeId;

  setUp(() async {
    db = await openBlankTestDb();
    repo = MmexRepository(db);
    accountId = repo.insertAccount(
        name: 'Compte test', type: 'Checking', initialBalance: 1000, currencyId: 2);
    payeeId = repo.insertPayee(name: 'Test');
  });

  tearDown(() {
    db.dispose();
  });

  DateTime today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  test('with no transactions at all, the forecast stays at the initial balance', () {
    final target = today().add(const Duration(days: 20));
    expect(repo.forecastAccountBalance(accountId, target), 1000);
  });

  test('an already-recorded transaction dated in the future is reflected in the forecast, '
      'not silently dropped until its date arrives', () {
    // Not tied to any recurring bill - a plain one-off the user already
    // entered ahead of time (e.g. a cheque they know will clear later).
    repo.insertTransaction(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 50,
      date: today().add(const Duration(days: 10)),
    );

    // Target date is after the postdated transaction: the forecast must
    // already count it, exactly like accountBalance() (no asOf) does -
    // never re-derived, never dropped just because it hasn't "happened" yet.
    final target = today().add(const Duration(days: 20));
    expect(repo.forecastAccountBalance(accountId, target), 950);
    expect(repo.accountBalance(accountId), 950);
  });

  test('a target date not in the future returns the real balance as of today, '
      'not counting a still-later postdated transaction', () {
    repo.insertTransaction(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 50,
      date: today().add(const Duration(days: 10)),
    );
    expect(repo.forecastAccountBalance(accountId, today()), 1000);
  });

  test('a target date between today and a postdated transaction excludes it', () {
    repo.insertTransaction(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 50,
      date: today().add(const Duration(days: 10)),
    );
    final target = today().add(const Duration(days: 5));
    expect(repo.forecastAccountBalance(accountId, target), 1000);
  });
}
