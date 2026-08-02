import 'package:flutter_test/flutter_test.dart';

import 'package:money_manager/data/mmex_database.dart';
import 'package:money_manager/data/mmex_repository.dart';
import 'package:money_manager/models/transaction.dart';
import 'package:money_manager/services/nl_query/query_executor.dart';
import 'package:money_manager/services/nl_query/query_intent.dart';

import '../test_helpers.dart';

void main() {
  late MmexDatabase db;
  late MmexRepository repo;
  late int accountId;
  late int alimentationId;
  late int restaurantId;
  late int payeeId;

  DateRange period(DateTime start, DateTime end) =>
      DateRange(start: start, end: end, label: 'test');

  setUp(() async {
    db = await openBlankTestDb();
    repo = MmexRepository(db);
    accountId = repo.insertAccount(
        name: 'Compte test', type: 'Checking', initialBalance: 1000, currencyId: 2);
    // The blank schema seeds these two by default (see
    // assets/mmex_blank_schema.sql) - reuse them rather than inserting
    // duplicates with the same names, which the schema's unique
    // (CATEGNAME, PARENTID) constraint rejects.
    alimentationId = repo.insertCategory(name: 'Alimentation Test');
    restaurantId = repo.insertCategory(name: 'Restaurant Test', parentId: alimentationId);
    payeeId = repo.insertPayee(name: 'Carrefour');

    repo.insertTransaction(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 40,
      date: DateTime(2026, 7, 5),
      categoryId: alimentationId,
    );
    repo.insertTransaction(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 25,
      date: DateTime(2026, 7, 10),
      categoryId: restaurantId,
    );
    repo.insertTransaction(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.deposit,
      amount: 1500,
      date: DateTime(2026, 7, 1),
    );
  });

  tearDown(() {
    db.dispose();
  });

  final july = DateRange(
      start: DateTime(2026, 7, 1), end: DateTime(2026, 8, 1), label: 'Juillet 2026');

  test('expenseTotal with no category sums every withdrawal and breaks down by category', () {
    final answer = runQuery(QueryIntent(kind: QueryKind.expenseTotal, period: july), repo);
    expect(answer.total, 65);
    expect(answer.categoryBreakdown, {alimentationId: 40, restaurantId: 25});
  });

  test('expenseTotal for the parent category rolls up its subcategory', () {
    final answer = runQuery(
      QueryIntent(kind: QueryKind.expenseTotal, period: july, categoryId: alimentationId),
      repo,
    );
    // 40 (Alimentation itself) + 25 (Restaurant, its subcategory)
    expect(answer.total, 65);
  });

  test('expenseTotal for the subcategory alone does not include the parent', () {
    final answer = runQuery(
      QueryIntent(kind: QueryKind.expenseTotal, period: july, categoryId: restaurantId),
      repo,
    );
    expect(answer.total, 25);
  });

  test('incomeTotal sums deposits', () {
    final answer = runQuery(QueryIntent(kind: QueryKind.incomeTotal, period: july), repo);
    expect(answer.income, 1500);
  });

  test('incomeVsExpense returns both totals', () {
    final answer = runQuery(QueryIntent(kind: QueryKind.incomeVsExpense, period: july), repo);
    expect(answer.income, 1500);
    expect(answer.expense, 65);
  });

  test('balance uses accountBalance as of the given date', () {
    final answer = runQuery(
      QueryIntent(
          kind: QueryKind.balance,
          period: july,
          accountId: accountId,
          asOf: DateTime(2026, 7, 31)),
      repo,
    );
    // 1000 initial + 1500 deposit - 40 - 25
    expect(answer.total, 2435);
  });

  test('balance without a resolved accountId throws rather than guessing', () {
    expect(
      () => runQuery(QueryIntent(kind: QueryKind.balance, period: july), repo),
      throwsArgumentError,
    );
  });

  test('topExpenses returns withdrawals biggest first', () {
    final answer =
        runQuery(QueryIntent(kind: QueryKind.topExpenses, period: july, topN: 5), repo);
    expect(answer.transactions!.map((t) => t.amount), [40, 25]);
  });

  test('payeeSpend sums withdrawals at that payee only', () {
    final answer = runQuery(
      QueryIntent(kind: QueryKind.payeeSpend, period: july, payeeId: payeeId),
      repo,
    );
    expect(answer.total, 65);
  });

  test('payeeSpend without a resolved payeeId throws rather than guessing', () {
    expect(
      () => runQuery(QueryIntent(kind: QueryKind.payeeSpend, period: july), repo),
      throwsArgumentError,
    );
  });

  test('a period with no matching transactions returns zero, not an error', () {
    final empty = period(DateTime(2020, 1, 1), DateTime(2020, 2, 1));
    final answer = runQuery(QueryIntent(kind: QueryKind.expenseTotal, period: empty), repo);
    expect(answer.total, 0);
    expect(answer.categoryBreakdown, isEmpty);
  });
}
