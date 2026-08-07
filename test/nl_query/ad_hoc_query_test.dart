import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:money_manager/data/mmex_database.dart';
import 'package:money_manager/data/mmex_repository.dart';
import 'package:money_manager/models/recurrence.dart';
import 'package:money_manager/models/transaction.dart';
import 'package:money_manager/services/nl_query/ad_hoc_query.dart';
import 'package:money_manager/services/nl_query/query_intent.dart';

import '../test_helpers.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('fr_FR');
  });

  late MmexDatabase db;
  late MmexRepository repo;
  late int accountId;
  late int otherAccountId;
  late int alimentationId;
  late int restaurantId;
  late int carrefourId;
  late int fnacId;

  final july = DateRange(
      start: DateTime(2026, 7, 1), end: DateTime(2026, 8, 1), label: 'Juillet 2026');

  List<MapEntry<String, double>> run(QueryIntent intent) {
    final categories = repo.getCategories(onlyActive: false);
    final rows = intent.recurringOnly
        ? aggregateRecurringScheduleRows(
            repo.recurringScheduleRows(start: intent.period.start, end: intent.period.end),
            intent,
            categories: categories,
          )
        : repo.db.query(
            buildAdHocSql(intent, categories: categories).sql,
            buildAdHocSql(intent, categories: categories).params,
          );
    return mapAdHocRows(rows, intent,
        categories: categories, accounts: repo.getAccounts(), payees: repo.getPayees(onlyActive: false));
  }

  setUp(() async {
    db = await openBlankTestDb();
    repo = MmexRepository(db);
    accountId = repo.insertAccount(
        name: 'Compte test', type: 'Checking', initialBalance: 1000, currencyId: 2);
    otherAccountId = repo.insertAccount(
        name: 'Autre compte', type: 'Savings', initialBalance: 0, currencyId: 2);
    alimentationId = repo.insertCategory(name: 'Alimentation Test');
    restaurantId = repo.insertCategory(name: 'Restaurant Test', parentId: alimentationId);
    carrefourId = repo.insertPayee(name: 'Carrefour');
    fnacId = repo.insertPayee(name: 'Fnac');

    repo.insertTransaction(
      accountId: accountId,
      payeeId: carrefourId,
      transCode: TransCode.withdrawal,
      amount: 40,
      date: DateTime(2026, 7, 5),
      categoryId: alimentationId,
    );
    repo.insertTransaction(
      accountId: accountId,
      payeeId: carrefourId,
      transCode: TransCode.withdrawal,
      amount: 25,
      date: DateTime(2026, 7, 10),
      categoryId: restaurantId,
    );
    repo.insertTransaction(
      accountId: otherAccountId,
      payeeId: fnacId,
      transCode: TransCode.withdrawal,
      amount: 15,
      date: DateTime(2026, 7, 12),
      categoryId: alimentationId,
    );
    repo.insertTransaction(
      accountId: accountId,
      payeeId: carrefourId,
      transCode: TransCode.deposit,
      amount: 1500,
      date: DateTime(2026, 7, 1),
    );
  });

  tearDown(() => db.dispose());

  QueryIntent adHoc({
    AdHocMetric metric = AdHocMetric.sum,
    AdHocTransactionType transactionType = AdHocTransactionType.withdrawal,
    AdHocGroupBy groupBy = AdHocGroupBy.none,
    DateRange? period,
    int? categoryId,
    int? accountId,
    int? payeeId,
    bool recurringOnly = false,
    int? adHocLimit,
  }) =>
      QueryIntent(
        kind: QueryKind.adHoc,
        period: period ?? july,
        categoryId: categoryId,
        accountId: accountId,
        payeeId: payeeId,
        recurringOnly: recurringOnly,
        adHocMetric: metric,
        adHocTransactionType: transactionType,
        adHocGroupBy: groupBy,
        adHocLimit: adHocLimit,
      );

  test('sum/count/average with groupBy none, across every withdrawal in the period', () {
    // 40 (Alimentation, compte test) + 25 (Restaurant, compte test) + 15
    // (Alimentation, autre compte) = 80, 3 withdrawals, average 26.666...
    expect(run(adHoc(metric: AdHocMetric.sum)).single.value, 80);
    expect(run(adHoc(metric: AdHocMetric.count)).single.value, 3);
    expect(run(adHoc(metric: AdHocMetric.average)).single.value, closeTo(26.67, 0.01));
  });

  test(
      'groupBy: category is never rolled up parent/child, while a categoryId *filter* still rolls up',
      () {
    final grouped = run(adHoc(groupBy: AdHocGroupBy.category));
    // Alimentation (40+15=55) and Restaurant (25) stay two separate rows -
    // no parent/child merging for the *grouping* dimension.
    final byLabel = {for (final e in grouped) e.key: e.value};
    expect(byLabel['Alimentation Test'], 55);
    expect(byLabel['Alimentation Test:Restaurant Test'], 25);

    // But filtering *to* the parent category still rolls its child in -
    // filtering and grouping are orthogonal mechanisms. No account filter
    // here, so both accounts' Alimentation-family spend counts: 40 + 25
    // (compte test, Alimentation + its child Restaurant) + 15 (autre
    // compte, Alimentation) = 80.
    final filteredTotal = run(adHoc(categoryId: alimentationId, groupBy: AdHocGroupBy.none));
    expect(filteredTotal.single.value, 80);
  });

  test('groupBy: month zero-fills missing months and stays chronological even with a limit set', () {
    final threeMonths = DateRange(
        start: DateTime(2026, 6, 1), end: DateTime(2026, 9, 1), label: 'test');
    // Scoped to accountId specifically so the expected July total (40 + 25)
    // isn't also picking up otherAccountId's 15 - keeps this test's numbers
    // about the month-bucketing/zero-fill behavior, not cross-account sums
    // (already covered by the groupBy:account test below).
    final result = run(
        adHoc(period: threeMonths, accountId: accountId, groupBy: AdHocGroupBy.month, adHocLimit: 1));
    expect(result, hasLength(3)); // June, July, August - adHocLimit ignored for month
    expect(result[0].value, 0); // June: no data
    expect(result[1].value, 65); // July: 40 (Alimentation) + 25 (Restaurant), this account only
    expect(result[2].value, 0); // August: no data
  });

  test(
      'recurringOnly counts the bill schedule itself - never the ledger, even ignoring the '
      'unrelated real withdrawals already in the ledger from setUp', () {
    repo.insertBillDeposit(
      accountId: accountId,
      payeeId: carrefourId,
      transCode: TransCode.withdrawal,
      amount: 12,
      nextOccurrence: DateTime(2026, 7, 20),
      period: RecurrencePeriod.monthly,
      autoExecute: RecurrenceAutoExecute.manual,
      categoryId: alimentationId,
    );

    // No repo.recordBillOccurrence call here on purpose - 2026-08-07
    // decision: recurringOnly must answer purely from the schedule, so the
    // bill's own scheduled amount counts here whether or not anything's
    // actually been recorded in the ledger for it yet.
    final result = run(adHoc(recurringOnly: true));
    expect(result.single.value, 12); // only the bill's own scheduled amount
  });

  test('transactionType: any includes transfers, unlike the 3 specific values', () {
    repo.insertTransaction(
      accountId: accountId,
      payeeId: carrefourId,
      transCode: TransCode.transfer,
      amount: 100,
      toAccountId: otherAccountId,
      date: DateTime(2026, 7, 15),
    );
    final anyCount = run(adHoc(metric: AdHocMetric.count, transactionType: AdHocTransactionType.any));
    final transferCount =
        run(adHoc(metric: AdHocMetric.count, transactionType: AdHocTransactionType.transfer));
    expect(transferCount.single.value, 1);
    // 3 withdrawals + 1 deposit + 1 transfer = 5
    expect(anyCount.single.value, 5);
  });

  test('adHocLimit caps category/payee/account groupings, highest value first', () {
    final capped = run(adHoc(groupBy: AdHocGroupBy.category, adHocLimit: 1));
    expect(capped, hasLength(1));
    expect(capped.single.key, 'Alimentation Test'); // 55 > 25
  });

  test('no cap at all when adHocLimit is null, even for a grouped question', () {
    final uncapped = run(adHoc(groupBy: AdHocGroupBy.category));
    expect(uncapped, hasLength(2)); // both Alimentation and Restaurant shown
  });

  test('groupBy: payee and groupBy: account resolve to display names', () {
    // No account filter, so both Carrefour (compte test) and Fnac (autre
    // compte)'s withdrawals show up.
    final byPayee = run(adHoc(groupBy: AdHocGroupBy.payee));
    final byPayeeMap = {for (final e in byPayee) e.key: e.value};
    expect(byPayeeMap['Carrefour'], 65); // 40 + 25, compte test
    expect(byPayeeMap['Fnac'], 15); // autre compte

    final byAccount = run(adHoc(groupBy: AdHocGroupBy.account));
    final byAccountMap = {for (final e in byAccount) e.key: e.value};
    expect(byAccountMap['Compte test'], 65);
    expect(byAccountMap['Autre compte'], 15);
  });

  test('buildAdHocSql throws if metric/transactionType/groupBy is missing', () {
    final incomplete = QueryIntent(kind: QueryKind.adHoc, period: july);
    expect(() => buildAdHocSql(incomplete, categories: repo.getCategories(onlyActive: false)),
        throwsArgumentError);
  });
}
