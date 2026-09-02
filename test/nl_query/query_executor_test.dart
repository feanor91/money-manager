import 'package:flutter_test/flutter_test.dart';

import 'package:money_manager/data/mmex_database.dart';
import 'package:money_manager/data/mmex_repository.dart';
import 'package:money_manager/models/recurrence.dart';
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
    // Detail transactions include both the parent's own and its subcategory's.
    expect(answer.transactions!.map((t) => t.amount).toSet(), {40, 25});
  });

  test('expenseTotal for the subcategory alone does not include the parent', () {
    final answer = runQuery(
      QueryIntent(kind: QueryKind.expenseTotal, period: july, categoryId: restaurantId),
      repo,
    );
    expect(answer.total, 25);
    expect(answer.transactions!.map((t) => t.amount), [25]);
  });

  test('expenseTotal detail list is not capped at 5 transactions', () {
    for (var i = 0; i < 10; i++) {
      repo.insertTransaction(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 1,
        date: DateTime(2026, 7, 15),
        categoryId: alimentationId,
      );
    }
    final answer = runQuery(
      QueryIntent(kind: QueryKind.expenseTotal, period: july, categoryId: alimentationId),
      repo,
    );
    // Seeded 40 (Alimentation) + 25 (Restaurant subcategory) + 10 new x1 = 12 transactions.
    expect(answer.transactions!.length, 12);
    expect(answer.total, 75);
  });

  test(
      'expenseTotal with recurringOnly counts the bill schedule itself, not the ledger - '
      'regression test for the 2026-08-07 report of a wrong-looking total', () {
    repo.insertBillDeposit(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 15,
      nextOccurrence: DateTime(2026, 7, 20),
      period: RecurrencePeriod.monthly,
      autoExecute: RecurrenceAutoExecute.manual,
      categoryId: alimentationId,
    );

    // No repo.recordBillOccurrence call - recurringOnly must answer purely
    // from the schedule, ignoring the two ad-hoc ledger withdrawals (40 +
    // 25) already seeded in setUp, whether or not the bill has actually
    // fired in the ledger yet.
    final answer = runQuery(
      QueryIntent(kind: QueryKind.expenseTotal, period: july, recurringOnly: true),
      repo,
    );
    expect(answer.total, 15);
    expect(answer.categoryBreakdown, {alimentationId: 15});
  });

  test('expenseTotal with recurringOnly and a categoryId has no ledger detail to show', () {
    repo.insertBillDeposit(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 15,
      nextOccurrence: DateTime(2026, 7, 20),
      period: RecurrencePeriod.monthly,
      autoExecute: RecurrenceAutoExecute.manual,
      categoryId: alimentationId,
    );

    final answer = runQuery(
      QueryIntent(
        kind: QueryKind.expenseTotal,
        period: july,
        categoryId: alimentationId,
        recurringOnly: true,
      ),
      repo,
    );
    expect(answer.total, 15);
    expect(answer.transactions, isEmpty); // a schedule occurrence isn't a MoneyTransaction to show
  });

  test('expenseByMonth breaks down a category across months, zero-filling months with no spend', () {
    // setUp only seeded July; August (same account, same category) gets one
    // more so the breakdown has a real second, different month to check.
    repo.insertTransaction(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 12,
      date: DateTime(2026, 8, 3),
      categoryId: alimentationId,
    );
    final answer = runQuery(
      QueryIntent(
        kind: QueryKind.expenseByMonth,
        period: DateRange(start: DateTime(2026, 6, 1), end: DateTime(2026, 9, 1), label: 'test'),
        categoryId: alimentationId,
      ),
      repo,
    );
    expect(answer.monthlyBreakdown, {
      DateTime(2026, 6): 0,
      DateTime(2026, 7): 65, // Alimentation (40) + its subcategory Restaurant (25)
      DateTime(2026, 8): 12,
    });
  });

  test('expenseByMonth with no category sums every category per month', () {
    final answer = runQuery(
      QueryIntent(kind: QueryKind.expenseByMonth, period: july),
      repo,
    );
    expect(answer.monthlyBreakdown, {DateTime(2026, 7): 65});
  });

  test('adHoc runs end-to-end through runQuery against the ordinary repo', () {
    final answer = runQuery(
      QueryIntent(
        kind: QueryKind.adHoc,
        period: july,
        adHocMetric: AdHocMetric.sum,
        adHocTransactionType: AdHocTransactionType.withdrawal,
        adHocGroupBy: AdHocGroupBy.category,
      ),
      repo,
    );
    final byLabel = {for (final e in answer.adHocResult!) e.key: e.value};
    expect(byLabel['Alimentation Test'], 40);
    expect(byLabel['Alimentation Test:Restaurant Test'], 25);
    // Every other field stays null - this kind only ever populates adHocResult.
    expect(answer.total, isNull);
    expect(answer.categoryBreakdown, isNull);
    expect(answer.monthlyBreakdown, isNull);
  });

  test('adHoc throws if adHocMetric/adHocTransactionType/adHocGroupBy is missing', () {
    expect(
      () => runQuery(QueryIntent(kind: QueryKind.adHoc, period: july), repo),
      throwsArgumentError,
    );
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

  test('balanceByMonth returns one snapshot per month, keyed by each '
      "month's 1st (2026-09-02: solde + \"mois par mois\" used to silently "
      'collapse to a single point)', () {
    final answer = runQuery(
      QueryIntent(
        kind: QueryKind.balanceByMonth,
        period: period(DateTime(2026, 7, 1), DateTime(2026, 9, 1)),
        accountId: accountId,
        balanceDay: 15,
      ),
      repo,
    );
    final monthly = answer.monthlyBreakdown!;
    expect(monthly.keys.toSet(), {DateTime(2026, 7, 1), DateTime(2026, 8, 1)});
    // 1000 initial + 1500 deposit - 40 - 25, all on or before the 15th.
    expect(monthly[DateTime(2026, 7, 1)], 2435);
    // No transactions in August - the running balance carries forward.
    expect(monthly[DateTime(2026, 8, 1)], 2435);
  });

  test('balanceByMonth with no explicit day uses the last day of each month', () {
    final answer = runQuery(
      QueryIntent(
        kind: QueryKind.balanceByMonth,
        period: period(DateTime(2026, 7, 1), DateTime(2026, 8, 1)),
        accountId: accountId,
      ),
      repo,
    );
    expect(answer.monthlyBreakdown![DateTime(2026, 7, 1)], 2435);
  });

  test('balanceByMonth without a resolved accountId throws rather than guessing', () {
    expect(
      () => runQuery(QueryIntent(kind: QueryKind.balanceByMonth, period: july), repo),
      throwsArgumentError,
    );
  });

  test('topExpenses ranks categories by their total, biggest first', () {
    final answer =
        runQuery(QueryIntent(kind: QueryKind.topExpenses, period: july, topN: 5), repo);
    expect(answer.categoryBreakdown, {alimentationId: 40, restaurantId: 25});
  });

  test('topExpenses ranks by category total, not by a single transaction amount', () {
    // A category with several smaller withdrawals (65 total here, on top of
    // the 40 already seeded above) must outrank a single bigger one-off
    // withdrawal in another category (80) - ranking individual transactions
    // instead of category totals was the bug this guards against.
    final facturesId = repo.insertCategory(name: 'Factures Test');
    repo.insertTransaction(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 80,
      date: DateTime(2026, 7, 15),
      categoryId: facturesId,
    );
    repo.insertTransaction(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 65,
      date: DateTime(2026, 7, 20),
      categoryId: alimentationId,
    );
    final answer =
        runQuery(QueryIntent(kind: QueryKind.topExpenses, period: july, topN: 1), repo);
    // Alimentation: 40 (seeded) + 65 = 105, bigger than Factures' single 80.
    expect(answer.categoryBreakdown, {alimentationId: 105});
  });

  test('payeeSpend sums withdrawals at that payee only', () {
    final answer = runQuery(
      QueryIntent(kind: QueryKind.payeeSpend, period: july, payeeId: payeeId),
      repo,
    );
    expect(answer.total, 65);
    expect(answer.transactions!.map((t) => t.amount).toSet(), {40, 25});
  });

  test('payeeSpend without a resolved payeeId throws rather than guessing', () {
    expect(
      () => runQuery(QueryIntent(kind: QueryKind.payeeSpend, period: july), repo),
      throwsArgumentError,
    );
  });

  test('payeeSpend detail list is not capped at 5 transactions', () {
    for (var i = 0; i < 10; i++) {
      repo.insertTransaction(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 1,
        date: DateTime(2026, 7, 15),
      );
    }
    final answer = runQuery(
      QueryIntent(kind: QueryKind.payeeSpend, period: july, payeeId: payeeId),
      repo,
    );
    // Seeded 40 + 25 + 10 new x1 = 12 transactions.
    expect(answer.transactions!.length, 12);
    expect(answer.total, 75);
  });

  test('a period with no matching transactions returns zero, not an error', () {
    final empty = period(DateTime(2020, 1, 1), DateTime(2020, 2, 1));
    final answer = runQuery(QueryIntent(kind: QueryKind.expenseTotal, period: empty), repo);
    expect(answer.total, 0);
    expect(answer.categoryBreakdown, isEmpty);
  });

  group('QueryKind.outlook', () {
    // Fixed "today" so these stay deterministic - runQuery's `now` override
    // exists precisely for this (unlike MmexRepository.forecastAccountBalance,
    // which always reads the real clock).
    final now = DateTime(2026, 8, 3, 10, 30);
    final august = DateRange(
        start: DateTime(2026, 8, 1), end: DateTime(2026, 9, 1), label: 'Août 2026');

    test('requires a resolved accountId', () {
      expect(
        () => runQuery(QueryIntent(kind: QueryKind.outlook, period: august), repo, now: now),
        throwsArgumentError,
      );
    });

    test('stays positive: no crossing date even though a recurring bill is due', () {
      final freshId = repo.insertAccount(
          name: 'Fresh 1', type: 'Checking', initialBalance: 1000, currencyId: 2);
      repo.insertBillDeposit(
        accountId: freshId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 50,
        nextOccurrence: DateTime(2026, 8, 10),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
        categoryId: alimentationId,
      );
      final answer = runQuery(
        QueryIntent(kind: QueryKind.outlook, period: august, accountId: freshId),
        repo,
        now: now,
      );
      expect(answer.total, 1000);
      expect(answer.forecastTotal, 950);
      expect(answer.forecastCrossesNegativeOn, isNull);
    });

    test('goes negative: crossing date and category breakdown both point at the real cause', () {
      final freshId = repo.insertAccount(
          name: 'Fresh 2', type: 'Checking', initialBalance: 100, currencyId: 2);
      repo.insertBillDeposit(
        accountId: freshId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 300,
        nextOccurrence: DateTime(2026, 8, 15),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
        categoryId: alimentationId,
      );
      final answer = runQuery(
        QueryIntent(kind: QueryKind.outlook, period: august, accountId: freshId),
        repo,
        now: now,
      );
      expect(answer.total, 100);
      expect(answer.forecastTotal, -200);
      expect(answer.forecastCrossesNegativeOn, DateTime(2026, 8, 15));
      expect(answer.categoryBreakdown, {alimentationId: -300});
    });

    test('already negative today: projects forward flat when nothing recurring is due', () {
      final freshId = repo.insertAccount(
          name: 'Fresh 3', type: 'Checking', initialBalance: -50, currencyId: 2);
      final answer = runQuery(
        QueryIntent(kind: QueryKind.outlook, period: august, accountId: freshId),
        repo,
        now: now,
      );
      expect(answer.total, -50);
      expect(answer.forecastTotal, -50);
      // No *new* crossing to report - it was already negative before today.
      expect(answer.forecastCrossesNegativeOn, isNull);
    });

    test('an already-recorded future transaction lands in the forecast (not '
        "today's total) and is not attributed to any category - it is not a "
        'recurring bill', () {
      final freshId = repo.insertAccount(
          name: 'Fresh 4', type: 'Checking', initialBalance: 100, currencyId: 2);
      repo.insertTransaction(
        accountId: freshId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 150,
        date: DateTime(2026, 8, 20),
        categoryId: restaurantId,
      );
      final answer = runQuery(
        QueryIntent(kind: QueryKind.outlook, period: august, accountId: freshId),
        repo,
        now: now,
      );
      // `total` is the real balance as of today (asOf: today) - it must
      // *not* count the postdated transaction yet, since it hasn't
      // happened as of "now" (2026-08-03) - but `forecastTotal` (period end
      // is after the transaction's own date) must, via futureDailyNet. The
      // breakdown can only ever explain *recurring* bills, so it stays
      // empty here regardless.
      expect(answer.total, 100);
      expect(answer.forecastTotal, -50);
      expect(answer.categoryBreakdown, isEmpty);
    });

    test('a period that has already ended returns the plain balance, no projection', () {
      final freshId = repo.insertAccount(
          name: 'Fresh 5', type: 'Checking', initialBalance: 100, currencyId: 2);
      final july = DateRange(
          start: DateTime(2026, 7, 1), end: DateTime(2026, 8, 1), label: 'Juillet 2026');
      final answer = runQuery(
        QueryIntent(kind: QueryKind.outlook, period: july, accountId: freshId),
        repo,
        now: now,
      );
      expect(answer.total, 100);
      expect(answer.forecastTotal, 100);
    });
  });
}
