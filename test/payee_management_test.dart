import 'package:flutter_test/flutter_test.dart';

import 'package:money_manager/data/mmex_database.dart';
import 'package:money_manager/data/mmex_repository.dart';
import 'package:money_manager/models/recurrence.dart';
import 'package:money_manager/models/transaction.dart';

import 'test_helpers.dart';

/// Backs the "Gestion des tiers" settings screen (payees_screen.dart,
/// 2026-08-23): payeeUsageCount/renamePayee/deletePayee.
void main() {
  late MmexDatabase db;
  late MmexRepository repo;
  late int accountId;

  setUp(() async {
    db = await openBlankTestDb();
    repo = MmexRepository(db);
    accountId = repo.insertAccount(
        name: 'Compte test', type: 'Checking', initialBalance: 1000, currencyId: 2);
  });

  tearDown(() => db.dispose());

  test('a payee with no transaction or recurring bill has usage count 0', () {
    final payeeId = repo.insertPayee(name: 'Carrefour');
    expect(repo.payeeUsageCount(payeeId), 0);
  });

  test('payeeUsageCount counts real ledger transactions', () {
    final payeeId = repo.insertPayee(name: 'Carrefour');
    repo.insertTransaction(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 40,
      date: DateTime.now(),
    );
    repo.insertTransaction(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 25,
      date: DateTime.now(),
    );
    expect(repo.payeeUsageCount(payeeId), 2);
  });

  test('payeeUsageCount also counts recurring bill templates', () {
    final payeeId = repo.insertPayee(name: 'Netflix');
    repo.insertBillDeposit(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 15,
      nextOccurrence: DateTime.now(),
      period: RecurrencePeriod.monthly,
      autoExecute: RecurrenceAutoExecute.manual,
    );
    expect(repo.payeeUsageCount(payeeId), 1);
  });

  test('payeeUsageCount sums both sources together', () {
    final payeeId = repo.insertPayee(name: 'Boursorama');
    repo.insertTransaction(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 10,
      date: DateTime.now(),
    );
    repo.insertBillDeposit(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 10,
      nextOccurrence: DateTime.now(),
      period: RecurrencePeriod.monthly,
      autoExecute: RecurrenceAutoExecute.manual,
    );
    expect(repo.payeeUsageCount(payeeId), 2);
  });

  test('renamePayee updates the name in place, keeping the same id', () {
    final payeeId = repo.insertPayee(name: 'Ancien nom');
    repo.renamePayee(payeeId, 'Nouveau nom');
    final payee = repo.getPayees(onlyActive: false).firstWhere((p) => p.id == payeeId);
    expect(payee.name, 'Nouveau nom');
  });

  test('deletePayee removes an unused payee', () {
    final payeeId = repo.insertPayee(name: 'Jamais utilisé');
    repo.deletePayee(payeeId);
    expect(repo.getPayees(onlyActive: false).where((p) => p.id == payeeId), isEmpty);
  });
}
