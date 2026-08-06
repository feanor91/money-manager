import 'package:flutter_test/flutter_test.dart';

import 'package:money_manager/data/mmex_database.dart';
import 'package:money_manager/data/mmex_repository.dart';
import 'package:money_manager/models/recurrence.dart';
import 'package:money_manager/models/transaction.dart';

import 'test_helpers.dart';

/// "Pausing" a transaction (2026-08-06) reuses MMEX's own Void status ('V')
/// rather than a new app-owned exclusion filter - accountBalance already
/// excludes it for free. APP_PAUSED_TRANSACTIONS only remembers whether it
/// was reconciled right before pausing, since Void/Reconciled share one
/// STATUS field - see mmex_repository.dart's syncPausedTracking/
/// wasReconciledBeforePause and TransactionEditorSheet._save.
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

  /// Builds exactly the MoneyTransaction TransactionEditorSheet._save
  /// constructs for an existing-transaction edit, then saves it the same
  /// way - through repo.updateTransaction, never raw SQL. Deliberate: an
  /// earlier version of this test file wrote STATUS via db.execute()
  /// directly "to mirror the save", which inadvertently bypassed
  /// updateTransaction entirely and hid a real bug where it never included
  /// STATUS in its SET clause at all (found 2026-08-06 testing this live -
  /// pausing/"Pointée" silently did nothing when saved through the full
  /// edit form). Going through the real method is the whole point now.
  MoneyTransaction savedAs(MoneyTransaction original, {required String status}) {
    final tx = MoneyTransaction(
      id: original.id,
      accountId: original.accountId,
      toAccountId: original.toAccountId,
      payeeId: original.payeeId,
      transCode: original.transCode,
      amount: original.amount,
      toAmount: original.toAmount,
      status: status,
      date: original.date,
      categoryId: original.categoryId,
      notes: original.notes,
    );
    repo.updateTransaction(tx);
    return tx;
  }

  MoneyTransaction txById(int transId) => repo
      .getTransactionsWithRunningBalance(accountId)
      .firstWhere((t) => t.transaction.id == transId)
      .transaction;

  test('pausing (Void) via the real save path excludes the transaction from accountBalance', () {
    final transId = repo.insertTransaction(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 100,
      date: DateTime.now(),
    );
    expect(repo.accountBalance(accountId), 900);

    // Mirrors exactly what TransactionEditorSheet._save does when the user
    // checks "En pause": save with STATUS='V' through updateTransaction,
    // then sync the tracking table separately (never a second STATUS
    // write from that call).
    savedAs(txById(transId), status: 'V');
    repo.syncPausedTracking(transId, paused: true, reconciled: false);

    expect(txById(transId).isVoid, isTrue);
    expect(repo.accountBalance(accountId), 1000,
        reason: 'a paused (Void) transaction must not count toward the balance');
  });

  test('un-pausing restores the balance and, when it was reconciled, "Pointée" too', () {
    final transId = repo.insertTransaction(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 100,
      date: DateTime.now(),
      reconciled: true,
    );

    // Pause it (same sequence as the previous test), remembering it was
    // reconciled first.
    savedAs(txById(transId), status: 'V');
    repo.syncPausedTracking(transId, paused: true, reconciled: true);
    expect(repo.wasReconciledBeforePause(transId), isTrue);
    expect(repo.accountBalance(accountId), 1000);

    // Un-pause: the sheet reads wasReconciledBeforePause to seed its own
    // "Pointée" checkbox, then saves that through updateTransaction like
    // any other edit - reproduced here directly rather than through the
    // widget.
    final wasReconciled = repo.wasReconciledBeforePause(transId);
    savedAs(txById(transId), status: wasReconciled ? 'R' : '');
    repo.syncPausedTracking(transId, paused: false, reconciled: wasReconciled);

    expect(repo.accountBalance(accountId), 900,
        reason: 'un-pausing must bring the transaction back into the balance');
    expect(txById(transId).isReconciled, isTrue,
        reason: '"Pointée" must survive a pause/un-pause round trip');
  });

  test('updateTransaction persists STATUS - regression test for the bug above: it '
      'originally had no STATUS in its SET clause at all, so any status change made '
      'through the full edit form (pause or "Pointée" alike) silently vanished', () {
    final transId = repo.insertTransaction(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 30,
      date: DateTime.now(),
    );
    expect(txById(transId).isReconciled, isFalse);

    savedAs(txById(transId), status: 'R');
    expect(txById(transId).isReconciled, isTrue);

    savedAs(txById(transId), status: 'V');
    expect(txById(transId).isVoid, isTrue);
  });

  test('deleteTransaction also clears its paused-tracking row', () {
    final transId = repo.insertTransaction(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 100,
      date: DateTime.now(),
    );
    repo.syncPausedTracking(transId, paused: true, reconciled: false);
    expect(
      db.query('SELECT 1 FROM APP_PAUSED_TRANSACTIONS WHERE TRANSID = ?', [transId]),
      isNotEmpty,
    );

    repo.deleteTransaction(transId);

    expect(
      db.query('SELECT 1 FROM APP_PAUSED_TRANSACTIONS WHERE TRANSID = ?', [transId]),
      isEmpty,
      reason: 'no dangling pause marker for a transaction that no longer exists',
    );
  });

  test('billIdForTransaction is null for a plain hand-entered transaction', () {
    final transId = repo.insertTransaction(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 20,
      date: DateTime.now(),
    );
    expect(repo.billIdForTransaction(transId), isNull);
  });

  test('billIdForTransaction resolves a transaction recorded from a recurring bill', () {
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
  });
}
