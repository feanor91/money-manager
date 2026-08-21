import 'package:flutter_test/flutter_test.dart';

import 'package:money_manager/data/mmex_database.dart';
import 'package:money_manager/data/mmex_repository.dart';
import 'package:money_manager/models/recurrence.dart';
import 'package:money_manager/models/transaction.dart';

import 'test_helpers.dart';

/// restoreTransaction powers "Annuler" on TransactionEditorSheet's
/// post-delete SnackBar (2026-08-21) - recreates a deleted transaction with
/// a fresh TRANSID, since MMEX offers no way to reuse a deleted one. The
/// caller is expected to capture everything needed *before* calling
/// deleteTransaction - see the method's own doc comment for why.
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

  MoneyTransaction txById(int transId) => repo
      .getTransactionsWithRunningBalance(accountId)
      .firstWhere((t) => t.transaction.id == transId)
      .transaction;

  test('delete then restore round-trips a plain transaction back into the balance', () {
    final transId = repo.insertTransaction(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 100,
      date: DateTime(2026, 3, 1),
      notes: 'Courses',
      reconciled: true,
    );
    expect(repo.accountBalance(accountId), 900);

    final original = txById(transId);
    repo.deleteTransaction(transId);
    expect(repo.accountBalance(accountId), 1000);

    // Not asserting newId != transId: with only one row ever inserted,
    // SQLite's own rowid reuse can legitimately hand back the same id once
    // the table is empty again - restoreTransaction never relies on getting
    // a different one, only on the row's *data* being right.
    final newId = repo.restoreTransaction(original);
    expect(repo.accountBalance(accountId), 900);

    final restored = txById(newId);
    expect(restored.amount, 100);
    expect(restored.notes, 'Courses');
    expect(restored.date, DateTime(2026, 3, 1));
    expect(restored.isReconciled, isTrue);
  });

  test('restoring a paused (Void) transaction restores its pause state and exclusion', () {
    final transId = repo.insertTransaction(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 50,
      date: DateTime.now(),
      reconciled: true,
    );
    db.execute('UPDATE CHECKINGACCOUNT_V1 SET STATUS = ? WHERE TRANSID = ?', ['V', transId]);
    repo.syncPausedTracking(transId, paused: true, reconciled: true);
    final wasReconciled = repo.wasReconciledBeforePause(transId);
    expect(repo.accountBalance(accountId), 1000, reason: 'paused transactions are excluded');

    final original = txById(transId);
    repo.deleteTransaction(transId);

    final newId = repo.restoreTransaction(original, wasReconciledBeforePause: wasReconciled);

    expect(txById(newId).isVoid, isTrue);
    expect(repo.wasReconciledBeforePause(newId), isTrue);
    expect(repo.accountBalance(accountId), 1000,
        reason: 'a restored paused transaction must stay excluded from the balance');
  });

  test('restoring with a recurring-bill link re-badges it and keeps the occurrence count', () {
    final billId = repo.insertBillDeposit(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 50,
      nextOccurrence: DateTime.now(),
      period: RecurrencePeriod.monthly,
      autoExecute: RecurrenceAutoExecute.manual,
    );
    final bill = repo.getBillDeposits().firstWhere((b) => b.id == billId);
    final transId = repo.recordBillOccurrence(bill, date: DateTime.now());
    expect(repo.billIdForTransaction(transId), billId);

    final original = txById(transId);
    repo.deleteTransaction(transId);
    expect(repo.billIdForTransaction(transId), isNull);

    final newId = repo.restoreTransaction(original, billId: billId);

    expect(repo.billIdForTransaction(newId), billId);
    expect(repo.recurringTransactionIds(), contains(newId));
  });
}
