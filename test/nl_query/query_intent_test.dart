import 'package:flutter_test/flutter_test.dart';
import 'package:money_manager/services/nl_query/query_intent.dart';

void main() {
  final july = DateRange(
      start: DateTime(2026, 7, 1), end: DateTime(2026, 8, 1), label: 'Juillet 2026');

  test('copyWith preserves every field it is not explicitly given', () {
    final original = QueryIntent(
      kind: QueryKind.adHoc,
      period: july,
      categoryId: 1,
      payeeId: 2,
      topN: 7,
      recurringOnly: true,
      adHocMetric: AdHocMetric.count,
      adHocTransactionType: AdHocTransactionType.deposit,
      adHocGroupBy: AdHocGroupBy.month,
      adHocLimit: 3,
    );

    // Reproduces the exact bug this method fixes: nl_query_dialog.dart
    // rebuilds the intent with only accountId changed (the account-default
    // fill-in) - a manual QueryIntent(...) reconstruction there had already
    // silently dropped recurringOnly this same way before copyWith existed.
    final withAccount = original.copyWith(accountId: 10);

    expect(withAccount.accountId, 10);
    expect(withAccount.kind, QueryKind.adHoc);
    expect(withAccount.period, july);
    expect(withAccount.categoryId, 1);
    expect(withAccount.payeeId, 2);
    expect(withAccount.topN, 7);
    expect(withAccount.recurringOnly, isTrue);
    expect(withAccount.adHocMetric, AdHocMetric.count);
    expect(withAccount.adHocTransactionType, AdHocTransactionType.deposit);
    expect(withAccount.adHocGroupBy, AdHocGroupBy.month);
    expect(withAccount.adHocLimit, 3);
  });

  test('copyWith can override the period (the outlook-default rebuild case)', () {
    final original = QueryIntent(kind: QueryKind.outlook, period: july, accountId: 5);
    final august = DateRange(start: DateTime(2026, 8, 1), end: DateTime(2026, 9, 1), label: 'Août 2026');
    final rebuilt = original.copyWith(period: august);
    expect(rebuilt.period, august);
    expect(rebuilt.accountId, 5);
    expect(rebuilt.kind, QueryKind.outlook);
  });
}
