import 'package:flutter_test/flutter_test.dart';

import 'package:money_manager/data/mmex_database.dart';
import 'package:money_manager/data/mmex_repository.dart';
import 'package:money_manager/models/transaction.dart';

import 'test_helpers.dart';

/// forecastAccountBalance's anchor is deliberately the same all-transactions
/// total accountBalance() (no asOf) returns - not capped at today - so an
/// already-recorded transaction with a future date is reflected in the
/// forecast rather than silently dropped (2026-08-03 fix: see
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

  test('a target date not in the future returns the plain current balance', () {
    repo.insertTransaction(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 50,
      date: today().add(const Duration(days: 10)),
    );
    expect(repo.forecastAccountBalance(accountId, today()), 950);
  });
}
