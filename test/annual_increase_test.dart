import 'package:flutter_test/flutter_test.dart';

import 'package:money_manager/data/mmex_database.dart';
import 'package:money_manager/data/mmex_repository.dart';
import 'package:money_manager/models/recurrence.dart';
import 'package:money_manager/models/transaction.dart';

import 'test_helpers.dart';

/// "Augmentation annuelle" (2026-09 user request) - a per-recurring-bill
/// percentage that compounds the projected amount once a year, on the
/// anniversary of a stored anchor date, plus the historical suggestion
/// computed from this account+payee's real transaction history.
void main() {
  late MmexDatabase db;
  late MmexRepository repo;
  late int accountId;
  late int payeeId;

  setUp(() async {
    db = await openBlankTestDb();
    repo = MmexRepository(db);
    accountId = repo.insertAccount(
        name: 'Compte test', type: 'Checking', initialBalance: 0, currencyId: 2);
    payeeId = repo.insertPayee(name: 'Bailleur');
  });

  tearDown(() => db.dispose());

  group('getBillAnnualIncrease / setBillAnnualIncrease / clearBillAnnualIncrease', () {
    late int billId;

    setUp(() {
      billId = repo.insertBillDeposit(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 800,
        nextOccurrence: DateTime(2026, 3, 5),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
      );
    });

    test('a fresh bill has no annual increase configured', () {
      expect(repo.getBillAnnualIncrease(billId), isNull);
      expect(repo.getBillDeposits().single.annualIncreasePercent, 0);
      expect(repo.getBillDeposits().single.annualIncreaseAnchor, isNull);
    });

    test('setting is readable back via both the direct getter and getBillDeposits', () {
      repo.setBillAnnualIncrease(billId, percent: 3.5, anchor: DateTime(2026, 3, 5));

      final direct = repo.getBillAnnualIncrease(billId);
      expect(direct!.percent, 3.5);
      expect(direct.anchor, DateTime(2026, 3, 5));

      final bill = repo.getBillDeposits().single;
      expect(bill.annualIncreasePercent, 3.5);
      expect(bill.annualIncreaseAnchor, DateTime(2026, 3, 5));
    });

    test('a second call replaces rather than duplicates', () {
      repo.setBillAnnualIncrease(billId, percent: 2, anchor: DateTime(2026, 1, 1));
      repo.setBillAnnualIncrease(billId, percent: 4, anchor: DateTime(2026, 6, 1));

      final direct = repo.getBillAnnualIncrease(billId);
      expect(direct!.percent, 4);
      expect(direct.anchor, DateTime(2026, 6, 1));
    });

    test('clearing removes it entirely', () {
      repo.setBillAnnualIncrease(billId, percent: 3, anchor: DateTime(2026, 3, 5));
      repo.clearBillAnnualIncrease(billId);
      expect(repo.getBillAnnualIncrease(billId), isNull);
    });
  });

  group('suggestedAnnualIncrease', () {
    late int billId;

    setUp(() {
      billId = repo.insertBillDeposit(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 900,
        nextOccurrence: DateTime(2026, 3, 5),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
      );
    });

    test('null with fewer than 2 matching real transactions', () {
      repo.insertTransaction(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 800,
        date: DateTime(2020, 3, 5),
      );
      expect(repo.suggestedAnnualIncrease(billId), isNull);
    });

    test('null when the history spans less than 3 years', () {
      repo.insertTransaction(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 800,
        date: DateTime(2024, 3, 5),
      );
      repo.insertTransaction(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 850,
        date: DateTime(2026, 3, 5),
      );
      expect(repo.suggestedAnnualIncrease(billId), isNull);
    });

    test('computes the compound annual growth rate over 4 years of real history', () {
      // 800 -> 800 * 1.03^4 ≈ 900.36 over exactly 4 years - a clean ~3%/an.
      repo.insertTransaction(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 800,
        date: DateTime(2022, 3, 5),
      );
      repo.insertTransaction(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 900.36,
        date: DateTime(2026, 3, 5),
      );

      final suggestion = repo.suggestedAnnualIncrease(billId);
      expect(suggestion, isNotNull);
      expect(suggestion!.percent, closeTo(3.0, 0.05));
      expect(suggestion.anchor, DateTime(2026, 3, 5));
      expect(suggestion.yearsSpan, closeTo(4.0, 0.05));
    });

    test('never matches a transaction on a different account or payee', () {
      final otherAccountId = repo.insertAccount(
          name: 'Autre compte', type: 'Checking', initialBalance: 0, currencyId: 2);
      final otherPayeeId = repo.insertPayee(name: 'Autre tiers');
      repo.insertTransaction(
        accountId: otherAccountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 800,
        date: DateTime(2020, 3, 5),
      );
      repo.insertTransaction(
        accountId: accountId,
        payeeId: otherPayeeId,
        transCode: TransCode.withdrawal,
        amount: 900,
        date: DateTime(2026, 3, 5),
      );
      expect(repo.suggestedAnnualIncrease(billId), isNull);
    });

    test(
        'never mixes in a transaction sharing the same payee+account but a '
        'different category - regression test for the 2026-09 user report '
        'of a nonsensical suggested rate on a fixed-rate mortgage: the '
        'payee was the bank itself, shared with several unrelated real '
        'bills (insurance premiums, ...) under the same payee', () {
      final mortgageCategoryId =
          repo.insertCategory(name: 'Crédit immobilier');
      final insuranceCategoryId = repo.insertCategory(name: 'Assurance');
      final mortgageBillId = repo.insertBillDeposit(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 1200,
        categoryId: mortgageCategoryId,
        nextOccurrence: DateTime(2026, 3, 5),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
      );
      // Same payee+account as the mortgage, but a totally different,
      // much smaller product (an insurance premium) under a different
      // category - must never be mistaken for the mortgage's own history.
      repo.insertTransaction(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 30,
        categoryId: insuranceCategoryId,
        date: DateTime(2020, 1, 1),
      );
      repo.insertTransaction(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 1200,
        categoryId: mortgageCategoryId,
        date: DateTime(2020, 3, 5),
      );
      repo.insertTransaction(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 1200,
        categoryId: mortgageCategoryId,
        date: DateTime(2026, 3, 5),
      );

      final suggestion = repo.suggestedAnnualIncrease(mortgageBillId);
      // A genuinely fixed-rate mortgage: 0% - never the wildly negative
      // rate mixing in the 30€ insurance premium would have produced.
      expect(suggestion, isNotNull);
      expect(suggestion!.percent, closeTo(0, 0.01));
    });

    test(
        'never mixes in a transaction sharing payee+account+category but a '
        "different NOTES - regression test for the 2026-09 live follow-up: "
        'two real loans to the same bank (a mortgage and a works loan) '
        'share payee, account, category AND transcode, distinguished only '
        'by NOTES, so the category filter alone was not enough - the '
        'mortgage must never be diluted by the works loan\'s own amounts', () {
      final loansCategoryId = repo.insertCategory(name: 'Crédits');
      final mortgageBillId = repo.insertBillDeposit(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 1218.08,
        categoryId: loansCategoryId,
        notes: 'Prêt appart',
        nextOccurrence: DateTime(2026, 3, 5),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
      );
      // The mortgage itself: flat over the years (fixed-rate).
      repo.insertTransaction(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 1218.08,
        categoryId: loansCategoryId,
        notes: 'Prêt appart',
        date: DateTime(2020, 3, 5),
      );
      repo.insertTransaction(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 1218.08,
        categoryId: loansCategoryId,
        notes: 'Prêt appart',
        date: DateTime(2026, 3, 5),
      );
      // Same payee+account+category+transcode, but a different loan
      // (distinguished only by NOTES) with a much smaller amount - must
      // never leak into the mortgage's own suggestion.
      repo.insertTransaction(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 255.59,
        categoryId: loansCategoryId,
        notes: 'Prêt travaux',
        date: DateTime(2020, 3, 5),
      );
      repo.insertTransaction(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 255.59,
        categoryId: loansCategoryId,
        notes: 'Prêt travaux',
        date: DateTime(2026, 3, 5),
      );

      final suggestion = repo.suggestedAnnualIncrease(mortgageBillId);
      expect(suggestion, isNotNull);
      expect(suggestion!.percent, closeTo(0, 0.01));
    });

    test('rejects an implausible suggestion (beyond ±30%/an) rather than '
        'proposing it - almost certainly contaminated data, not a real '
        'metered/indexed rate, even after the category filter above', () {
      final categoryId = repo.insertCategory(name: 'Loyer');
      final rentBillId = repo.insertBillDeposit(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 700,
        categoryId: categoryId,
        nextOccurrence: DateTime(2026, 3, 5),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
      );
      repo.insertTransaction(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 100,
        categoryId: categoryId,
        date: DateTime(2020, 3, 5),
      );
      repo.insertTransaction(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 700,
        categoryId: categoryId,
        date: DateTime(2026, 3, 5),
      );
      expect(repo.suggestedAnnualIncrease(rentBillId), isNull);
    });

    test('null for a transfer - no single payee identity to search real history by', () {
      final toAccountId = repo.insertAccount(
          name: 'Compte destination', type: 'Checking', initialBalance: 0, currencyId: 2);
      final transferId = repo.insertBillDeposit(
        accountId: accountId,
        payeeId: -1,
        toAccountId: toAccountId,
        transCode: TransCode.transfer,
        amount: 100,
        nextOccurrence: DateTime(2026, 3, 5),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
      );
      expect(repo.suggestedAnnualIncrease(transferId), isNull);
    });
  });

  group('projection engines apply the compounded increase', () {
    late int billId;

    setUp(() {
      billId = repo.insertBillDeposit(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 1000,
        nextOccurrence: DateTime(2026, 1, 5),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
      );
    });

    test('recurringMonthlyNet keeps the flat amount before an increase is configured', () {
      final net = repo.recurringMonthlyNet(
          anchor: DateTime(2026, 4, 1), months: 4, accountId: accountId);
      expect(net.values.every((v) => v == -1000.0), isTrue);
    });

    test('a 10% increase, anchored on the bill\'s own next occurrence date, '
        'applies starting exactly at the first anniversary', () {
      repo.setBillAnnualIncrease(billId, percent: 10, anchor: DateTime(2026, 1, 5));

      // Before the first anniversary (Jan 2027): still the flat amount.
      final before = repo.recurringMonthlyNet(
          anchor: DateTime(2026, 12, 1), months: 12, accountId: accountId);
      expect(before[DateTime(2026, 12, 1)], -1000.0);

      // On/after the first anniversary: +10%, compounding.
      final after = repo.recurringMonthlyNet(
          anchor: DateTime(2027, 1, 1), months: 13, accountId: accountId);
      expect(after[DateTime(2027, 1, 1)], closeTo(-1100.0, 0.001));

      // A second anniversary (Jan 2028): +10% again, compounded (not
      // additive) - 1000 * 1.1^2 = 1210, not 1000 * 1.2 = 1200.
      final secondYear = repo.recurringMonthlyNet(
          anchor: DateTime(2028, 1, 1), months: 25, accountId: accountId);
      expect(secondYear[DateTime(2028, 1, 1)], closeTo(-1210.0, 0.001));
    });

    test('recurringDailyNet and recurringPeriodNet apply the exact same '
        'compounded amount as recurringMonthlyNet for the same occurrence', () {
      repo.setBillAnnualIncrease(billId, percent: 10, anchor: DateTime(2026, 1, 5));

      final daily = repo.recurringDailyNet(
          anchor: DateTime(2027, 1, 5), days: 1, accountId: accountId);
      expect(daily[DateTime(2027, 1, 5)], closeTo(-1100.0, 0.001));

      final period = repo.recurringPeriodNet(
          anchor: DateTime(2027, 1, 5),
          periods: 1,
          startDay: 1,
          accountId: accountId);
      expect(period.values.single, closeTo(-1100.0, 0.001));
    });

    test('clearing the increase goes back to the flat amount', () {
      repo.setBillAnnualIncrease(billId, percent: 10, anchor: DateTime(2026, 1, 5));
      repo.clearBillAnnualIncrease(billId);

      final net = repo.recurringMonthlyNet(
          anchor: DateTime(2027, 1, 1), months: 13, accountId: accountId);
      expect(net[DateTime(2027, 1, 1)], -1000.0);
    });
  });
}
