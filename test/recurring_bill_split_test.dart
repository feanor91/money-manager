import 'package:flutter_test/flutter_test.dart';

import 'package:money_manager/data/mmex_database.dart';
import 'package:money_manager/data/mmex_repository.dart';
import 'package:money_manager/models/recurrence.dart';
import 'package:money_manager/models/transaction.dart';

import 'test_helpers.dart';

/// "Répartir en X fois" (2026-09-02 user request: "je découpe Axeria en 2
/// ou 3 paiements plutôt qu'un seul... à présent je le fais manuellement,
/// si je pouvais l'automatiser ce serait cool") - recordBillOccurrence's
/// splitInto param, and the recurrenceMonthSpan cap it's built around.
void main() {
  group('recurrenceMonthSpan (caps "Répartir en X fois")', () {
    test('monthly-ish periods span exactly 1 month (the dialog itself only '
        'offers the split control when the span is at least 3 - see the '
        'next group)', () {
      expect(recurrenceMonthSpan(RecurrencePeriod.monthly), 1);
      expect(recurrenceMonthSpan(RecurrencePeriod.monthlyLastDay), 1);
      expect(recurrenceMonthSpan(RecurrencePeriod.monthlyLastBusinessDay), 1);
    });

    test('multi-month periods return their real month span', () {
      expect(recurrenceMonthSpan(RecurrencePeriod.biMonthly), 2);
      expect(recurrenceMonthSpan(RecurrencePeriod.quarterly), 3);
      expect(recurrenceMonthSpan(RecurrencePeriod.fourMonths), 4);
      expect(recurrenceMonthSpan(RecurrencePeriod.halfYearly), 6);
      expect(recurrenceMonthSpan(RecurrencePeriod.yearly), 12);
    });

    test('periods with no fixed monthly interval return null - weekly/daily/'
        'X-param periods can\'t offer a sensible split cap', () {
      for (final period in [
        RecurrencePeriod.weekly,
        RecurrencePeriod.biWeekly,
        RecurrencePeriod.fourWeeks,
        RecurrencePeriod.daily,
        RecurrencePeriod.inXDays,
        RecurrencePeriod.inXMonths,
        RecurrencePeriod.everyXDays,
        RecurrencePeriod.everyXMonths,
        RecurrencePeriod.none,
      ]) {
        expect(recurrenceMonthSpan(period), isNull, reason: '$period');
      }
    });
  });

  group('MmexRepository.recordBillOccurrence splitInto', () {
    late MmexDatabase db;
    late MmexRepository repo;
    late int accountId;
    late int payeeId;

    setUp(() async {
      db = await openBlankTestDb();
      repo = MmexRepository(db);
      accountId = repo.insertAccount(
          name: 'Compte test', type: 'Checking', initialBalance: 1000, currencyId: 2);
      payeeId = repo.insertPayee(name: 'Axeria');
    });

    tearDown(() => db.dispose());

    List<MoneyTransaction> transactionsFor(int billId) {
      return repo
          .getTransactionsWithRunningBalance(accountId)
          .map((t) => t.transaction)
          .where((t) => repo.billIdForTransaction(t.id) == billId)
          .toList()
        ..sort((a, b) => a.date.compareTo(b.date));
    }

    test('splitInto: 1 (default) behaves exactly like before - a single '
        'transaction, unmodified notes', () {
      final billId = repo.insertBillDeposit(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 300,
        nextOccurrence: DateTime(2026, 1, 1),
        period: RecurrencePeriod.quarterly,
        autoExecute: RecurrenceAutoExecute.manual,
        notes: 'Assurance',
      );
      final bill = repo.getBillDeposits().single;

      repo.recordBillOccurrence(bill, date: DateTime(2026, 1, 1));

      final txs = transactionsFor(billId);
      expect(txs, hasLength(1));
      expect(txs.single.amount, 300.0);
      expect(txs.single.date, DateTime(2026, 1, 1));
      expect(txs.single.notes, 'Assurance');
    });

    test('splitInto: 3 records 3 transactions, monthly from the chosen '
        'date, summing back to the exact real amount (cents-safe)', () {
      final billId = repo.insertBillDeposit(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 100,
        nextOccurrence: DateTime(2026, 1, 1),
        period: RecurrencePeriod.quarterly,
        autoExecute: RecurrenceAutoExecute.manual,
        notes: 'Assurance',
      );
      final bill = repo.getBillDeposits().single;

      repo.recordBillOccurrence(bill, date: DateTime(2026, 1, 1), splitInto: 3);

      final txs = transactionsFor(billId);
      expect(txs, hasLength(3));
      expect(txs.map((t) => t.date), [
        DateTime(2026, 1, 1),
        DateTime(2026, 2, 1),
        DateTime(2026, 3, 1),
      ]);
      // 100.00 split 3 ways: no cent lost or invented.
      expect(txs.fold(0.0, (sum, t) => sum + t.amount), closeTo(100.0, 0.001));
      expect(txs.map((t) => t.amount).toSet(), {33.34, 33.33});
      expect(txs.map((t) => t.notes), ['Assurance (1/3)', 'Assurance (2/3)', 'Assurance (3/3)']);
    });

    test('a bill with no notes gets a bare "(i/N)" label, not a stray '
        'leading space', () {
      repo.insertBillDeposit(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 90,
        nextOccurrence: DateTime(2026, 1, 1),
        period: RecurrencePeriod.quarterly,
        autoExecute: RecurrenceAutoExecute.manual,
      );
      final bill = repo.getBillDeposits().single;

      repo.recordBillOccurrence(bill, date: DateTime(2026, 1, 1), splitInto: 2);

      final txs = transactionsFor(bill.id)..sort((a, b) => a.date.compareTo(b.date));
      expect(txs.map((t) => t.notes), ['(1/2)', '(2/2)']);
    });

    test('splitting never consumes extra remaining-occurrence slots - every '
        'installment shares the same occurrence index/total as a single '
        'unsplit occurrence would have gotten', () {
      final billId = repo.insertBillDeposit(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 300,
        nextOccurrence: DateTime(2026, 1, 1),
        period: RecurrencePeriod.quarterly,
        autoExecute: RecurrenceAutoExecute.manual,
        numOccurrences: 4, // "durée limitée" bill, 4 quarters left
      );
      repo.ensureBillOccurrenceTotal(billId, 4);
      final bill = repo.getBillDeposits().single;

      repo.recordBillOccurrence(bill, date: DateTime(2026, 1, 1), splitInto: 3);

      final occurrences = repo.recurringTransactionOccurrences();
      final txs = transactionsFor(billId);
      expect(txs, hasLength(3));
      for (final t in txs) {
        expect(occurrences[t.id]?.index, 1, reason: 'installment dated ${t.date}');
        expect(occurrences[t.id]?.total, 4);
      }
      // The template itself only advanced by ONE real cycle, same as an
      // unsplit recording of this exact occurrence would have done -
      // 3 remaining now, not 3 minus the installment count.
      final updated = repo.getBillDeposits().single;
      expect(updated.numOccurrences, 3);
      expect(updated.nextOccurrence, DateTime(2026, 4, 1));
    });

    test('the template\'s own schedule advances identically whether or not '
        'the occurrence was split', () {
      final billIdSplit = repo.insertBillDeposit(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 300,
        nextOccurrence: DateTime(2026, 1, 1),
        period: RecurrencePeriod.quarterly,
        autoExecute: RecurrenceAutoExecute.manual,
      );
      final billIdWhole = repo.insertBillDeposit(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 300,
        nextOccurrence: DateTime(2026, 1, 1),
        period: RecurrencePeriod.quarterly,
        autoExecute: RecurrenceAutoExecute.manual,
      );
      final billSplit = repo.getBillDeposits().firstWhere((b) => b.id == billIdSplit);
      final billWhole = repo.getBillDeposits().firstWhere((b) => b.id == billIdWhole);

      repo.recordBillOccurrence(billSplit, date: DateTime(2026, 1, 1), splitInto: 3);
      repo.recordBillOccurrence(billWhole, date: DateTime(2026, 1, 1));

      final updatedSplit = repo.getBillDeposits().firstWhere((b) => b.id == billIdSplit);
      final updatedWhole = repo.getBillDeposits().firstWhere((b) => b.id == billIdWhole);
      expect(updatedSplit.nextOccurrence, updatedWhole.nextOccurrence);
    });

    test('splitInto: 0 or negative is treated the same as 1 (defensive, '
        'never divides by zero)', () {
      final billId = repo.insertBillDeposit(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 300,
        nextOccurrence: DateTime(2026, 1, 1),
        period: RecurrencePeriod.quarterly,
        autoExecute: RecurrenceAutoExecute.manual,
      );
      final bill = repo.getBillDeposits().single;

      repo.recordBillOccurrence(bill, date: DateTime(2026, 1, 1), splitInto: 0);

      expect(transactionsFor(billId), hasLength(1));
    });
  });
}
