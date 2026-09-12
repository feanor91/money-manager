import 'package:flutter_test/flutter_test.dart';

import 'package:money_manager/data/mmex_database.dart';
import 'package:money_manager/data/mmex_repository.dart';
import 'package:money_manager/models/transaction.dart';

import 'test_helpers.dart';

/// Backs the ledger's "Sélectionner" multi-select mode + "Modifier (N)"
/// dialog (transactions_screen.dart, 2026-09 user request): a manually
/// hand-picked set of transactions, never a same-payee-and-category
/// heuristic (see bulk_category_reassign.dart's own doc comment for why
/// that alone isn't enough - two unrelated series can share both without
/// sharing an amount).
void main() {
  late MmexDatabase db;
  late MmexRepository repo;
  late int accountId;
  late int payeeId;
  late int categoryId;
  late int otherCategoryId;

  setUp(() async {
    db = await openBlankTestDb();
    repo = MmexRepository(db);
    accountId = repo.insertAccount(
        name: 'Compte test', type: 'Checking', initialBalance: 1000, currencyId: 2);
    payeeId = repo.insertPayee(name: 'Credit agricole');
    categoryId = repo.insertCategory(name: 'Credits:Travaux');
    otherCategoryId = repo.insertCategory(name: 'Credits:Credit immobilier');
  });

  tearDown(() => db.dispose());

  int insertTx({int? categoryId, double amount = 100}) {
    return repo.insertTransaction(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: amount,
      date: DateTime(2026, 1, 1),
      categoryId: categoryId,
    );
  }

  test('only touches the ids given, never anything else matching payee/category', () {
    final selected = insertTx(categoryId: categoryId, amount: 1218.08);
    final untouched = insertTx(categoryId: categoryId, amount: 255.59);
    repo.bulkUpdateTransactions([selected], categoryId: otherCategoryId);
    final byId = {for (final t in repo.getTransactions(accountId: accountId)) t.id: t};
    expect(byId[selected]!.categoryId, otherCategoryId);
    expect(byId[untouched]!.categoryId, categoryId);
  });

  test('a field left unchecked (null) is never overwritten', () {
    final id = insertTx(categoryId: categoryId);
    repo.updateTransaction(
        repo.getTransactions(accountId: accountId).single.copyWith());
    final before = repo.getTransactions(accountId: accountId).single;
    repo.bulkUpdateTransactions([id], notes: 'Nouvelle remarque');
    final after = repo.getTransactions(accountId: accountId).single;
    expect(after.notes, 'Nouvelle remarque');
    expect(after.categoryId, before.categoryId); // jamais touché
    expect(after.payeeId, before.payeeId); // jamais touché
  });

  test('clearCategory sets the category to null without needing categoryId', () {
    final id = insertTx(categoryId: categoryId);
    repo.bulkUpdateTransactions([id], clearCategory: true);
    expect(repo.getTransactions(accountId: accountId).single.categoryId, isNull);
  });

  test('applies to several ids at once', () {
    final a = insertTx(categoryId: categoryId, amount: 1218.08);
    final b = insertTx(categoryId: categoryId, amount: 1218.08);
    final c = insertTx(categoryId: categoryId, amount: 255.59);
    repo.bulkUpdateTransactions([a, b], categoryId: otherCategoryId);
    final byId = {for (final t in repo.getTransactions(accountId: accountId)) t.id: t};
    expect(byId[a]!.categoryId, otherCategoryId);
    expect(byId[b]!.categoryId, otherCategoryId);
    expect(byId[c]!.categoryId, categoryId);
  });

  test('reconciled true/false sets STATUS accordingly', () {
    final id = insertTx();
    repo.bulkUpdateTransactions([id], reconciled: true);
    expect(repo.getTransactions(accountId: accountId).single.isReconciled, isTrue);
    repo.bulkUpdateTransactions([id], reconciled: false);
    expect(repo.getTransactions(accountId: accountId).single.isReconciled, isFalse);
  });

  test('an empty id list is a no-op', () {
    final id = insertTx(categoryId: categoryId);
    repo.bulkUpdateTransactions([], categoryId: otherCategoryId);
    expect(repo.getTransactions(accountId: accountId).single.categoryId, categoryId);
    expect(id, isNotNull);
  });

  test('changes payee across the selection', () {
    final otherPayeeId = repo.insertPayee(name: 'Nouveau tiers');
    final a = insertTx();
    final b = insertTx();
    repo.bulkUpdateTransactions([a, b], payeeId: otherPayeeId);
    final byId = {for (final t in repo.getTransactions(accountId: accountId)) t.id: t};
    expect(byId[a]!.payeeId, otherPayeeId);
    expect(byId[b]!.payeeId, otherPayeeId);
  });
}
