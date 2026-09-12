import 'package:flutter_test/flutter_test.dart';

import 'package:money_manager/data/mmex_database.dart';
import 'package:money_manager/data/mmex_repository.dart';
import 'package:money_manager/models/transaction.dart';

import 'test_helpers.dart';

void main() {
  late MmexDatabase db;
  late MmexRepository repo;
  late int accountId;
  late int otherAccountId;
  late int thirdAccountId;
  late int payeeId;
  late int otherPayeeId;
  late int oldCategoryId;
  late int newCategoryId;

  setUp(() async {
    db = await openBlankTestDb();
    repo = MmexRepository(db);
    accountId = repo.insertAccount(
        name: 'Compte test', type: 'Checking', initialBalance: 1000, currencyId: 2);
    otherAccountId = repo.insertAccount(
        name: 'Compte epargne', type: 'Savings', initialBalance: 0, currencyId: 2);
    thirdAccountId = repo.insertAccount(
        name: 'Autre compte', type: 'Checking', initialBalance: 0, currencyId: 2);
    payeeId = repo.insertPayee(name: 'Carrefour');
    otherPayeeId = repo.insertPayee(name: 'Netflix');
    oldCategoryId =
        db.execute("INSERT INTO CATEGORY_V1 (CATEGNAME, ACTIVE) VALUES ('Mal catégorisé', 1)");
    newCategoryId =
        db.execute("INSERT INTO CATEGORY_V1 (CATEGNAME, ACTIVE) VALUES ('Alimentation', 1)");
  });

  tearDown(() {
    db.dispose();
  });

  int insertTx(
      {required int payee, required int category, double amount = 10, String? notes}) {
    return repo.insertTransaction(
      accountId: accountId,
      payeeId: payee,
      transCode: TransCode.withdrawal,
      amount: amount,
      date: DateTime.now(),
      categoryId: category,
      notes: notes,
    );
  }

  int insertTransfer(
      {required int from,
      required int to,
      required int category,
      double amount = 700,
      String? notes}) {
    return repo.insertTransaction(
      accountId: from,
      toAccountId: to,
      payeeId: -1,
      transCode: TransCode.transfer,
      amount: amount,
      toAmount: amount,
      date: DateTime.now(),
      categoryId: category,
      notes: notes,
    );
  }

  test('countTransactionsMatching is 0 when nothing matches', () {
    expect(
        repo.countTransactionsMatching(payeeId: payeeId, categoryId: oldCategoryId, notes: null),
        0);
  });

  test('countTransactionsMatching counts every transaction sharing payee and category', () {
    insertTx(payee: payeeId, category: oldCategoryId);
    insertTx(payee: payeeId, category: oldCategoryId, amount: 25);
    insertTx(payee: payeeId, category: newCategoryId); // different category - not counted
    insertTx(payee: otherPayeeId, category: oldCategoryId); // different payee - not counted

    expect(
        repo.countTransactionsMatching(payeeId: payeeId, categoryId: oldCategoryId, notes: null),
        2);
  });

  // 2026-09 user report: two unrelated loan repayments (one ~255€
  // "Complément prêt travaux", one ~1218€ "Prêt immobilier") shared the
  // same payee and category without sharing an amount - the remarque is
  // the only thing left in this app's data model telling them apart.
  test('countTransactionsMatching does not mix transactions with a different remarque', () {
    insertTx(payee: payeeId, category: oldCategoryId, notes: 'Prêt immobilier', amount: 1218.08);
    insertTx(payee: payeeId, category: oldCategoryId, notes: 'Prêt immobilier', amount: 1218.08);
    insertTx(payee: payeeId, category: oldCategoryId, notes: 'Complément prêt travaux', amount: 255.59);

    expect(
      repo.countTransactionsMatching(
          payeeId: payeeId, categoryId: oldCategoryId, notes: 'Prêt immobilier'),
      2, // les deux "Prêt immobilier" - jamais celle à 255,59€
    );
  });

  test('countTransactionsMatching treats null and empty remarque as the same "no remarque"', () {
    insertTx(payee: payeeId, category: oldCategoryId, notes: null);
    insertTx(payee: payeeId, category: oldCategoryId, notes: '');

    expect(
      repo.countTransactionsMatching(payeeId: payeeId, categoryId: oldCategoryId, notes: null),
      2, // null et '' comptent comme la même "absence de remarque"
    );
  });

  test('countTransactionsMatching excludes a voided transaction', () {
    insertTx(payee: payeeId, category: oldCategoryId);
    final voidedId = insertTx(payee: payeeId, category: oldCategoryId);
    db.execute('UPDATE CHECKINGACCOUNT_V1 SET STATUS = ? WHERE TRANSID = ?', ['V', voidedId]);

    expect(
        repo.countTransactionsMatching(payeeId: payeeId, categoryId: oldCategoryId, notes: null),
        1);
  });

  test('countTransactionsMatching excludes a soft-deleted transaction', () {
    insertTx(payee: payeeId, category: oldCategoryId);
    final deletedId = insertTx(payee: payeeId, category: oldCategoryId);
    db.execute(
        'UPDATE CHECKINGACCOUNT_V1 SET DELETEDTIME = ? WHERE TRANSID = ?', ['2026-01-01', deletedId]);

    expect(
        repo.countTransactionsMatching(payeeId: payeeId, categoryId: oldCategoryId, notes: null),
        1);
  });

  test('bulkReassignTransactionCategory updates every matching transaction', () {
    final id1 = insertTx(payee: payeeId, category: oldCategoryId);
    final id2 = insertTx(payee: payeeId, category: oldCategoryId, amount: 25);

    repo.bulkReassignTransactionCategory(
      payeeId: payeeId,
      oldCategoryId: oldCategoryId,
      newCategoryId: newCategoryId,
      notes: null,
    );

    final txns = {for (final t in repo.getTransactions(accountId: accountId)) t.id: t};
    expect(txns[id1]!.categoryId, newCategoryId);
    expect(txns[id2]!.categoryId, newCategoryId);
  });

  test('bulkReassignTransactionCategory leaves other payees and categories alone', () {
    final unrelatedCategoryId =
        db.execute("INSERT INTO CATEGORY_V1 (CATEGNAME, ACTIVE) VALUES ('Autre', 1)");
    final samePayeeDifferentCategory = insertTx(payee: payeeId, category: unrelatedCategoryId);
    final differentPayeeSameCategory = insertTx(payee: otherPayeeId, category: oldCategoryId);

    repo.bulkReassignTransactionCategory(
      payeeId: payeeId,
      oldCategoryId: oldCategoryId,
      newCategoryId: newCategoryId,
      notes: null,
    );

    final txns = {for (final t in repo.getTransactions(accountId: accountId)) t.id: t};
    expect(txns[samePayeeDifferentCategory]!.categoryId, unrelatedCategoryId);
    expect(txns[differentPayeeSameCategory]!.categoryId, oldCategoryId);
  });

  test('bulkReassignTransactionCategory leaves a different remarque alone', () {
    final matching = insertTx(
        payee: payeeId, category: oldCategoryId, notes: 'Complément prêt travaux', amount: 255.59);
    final untouched =
        insertTx(payee: payeeId, category: oldCategoryId, notes: 'Prêt immobilier', amount: 1218.08);

    repo.bulkReassignTransactionCategory(
      payeeId: payeeId,
      oldCategoryId: oldCategoryId,
      newCategoryId: newCategoryId,
      notes: 'Complément prêt travaux',
    );

    final txns = {for (final t in repo.getTransactions(accountId: accountId)) t.id: t};
    expect(txns[matching]!.categoryId, newCategoryId);
    expect(txns[untouched]!.categoryId, oldCategoryId);
  });

  test('countTransfersMatching counts transfers sharing the same account pair and category', () {
    insertTransfer(from: accountId, to: otherAccountId, category: oldCategoryId);
    insertTransfer(from: accountId, to: otherAccountId, category: oldCategoryId, amount: 650);
    insertTransfer(from: accountId, to: otherAccountId, category: newCategoryId); // different category
    insertTransfer(from: accountId, to: thirdAccountId, category: oldCategoryId); // different destination

    expect(
      repo.countTransfersMatching(
          accountId: accountId, toAccountId: otherAccountId, categoryId: oldCategoryId, notes: null),
      2,
    );
  });

  test('countTransfersMatching does not count a same-payee-and-category withdrawal', () {
    insertTx(payee: payeeId, category: oldCategoryId);

    expect(
      repo.countTransfersMatching(
          accountId: accountId, toAccountId: otherAccountId, categoryId: oldCategoryId, notes: null),
      0,
    );
  });

  test('bulkReassignTransferCategory updates every matching transfer, leaves other accounts alone', () {
    final matching = insertTransfer(from: accountId, to: otherAccountId, category: oldCategoryId);
    final differentDestination = insertTransfer(from: accountId, to: thirdAccountId, category: oldCategoryId);

    repo.bulkReassignTransferCategory(
      accountId: accountId,
      toAccountId: otherAccountId,
      oldCategoryId: oldCategoryId,
      newCategoryId: newCategoryId,
      notes: null,
    );

    final txns = {for (final t in repo.getTransactions(accountId: accountId)) t.id: t};
    expect(txns[matching]!.categoryId, newCategoryId);
    expect(txns[differentDestination]!.categoryId, oldCategoryId);
  });
}
