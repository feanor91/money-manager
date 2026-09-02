import 'recurrence.dart';
import 'transaction.dart';

/// A recurring/scheduled transaction template (MMEX table BILLSDEPOSITS_V1).
class BillDeposit {
  final int id;
  final int accountId;
  final int? toAccountId;
  final int payeeId;
  final TransCode transCode;
  final double amount;
  final double toAmount;
  final int? categoryId;
  final DateTime nextOccurrence;
  final RecurrencePeriod period;
  final RecurrenceAutoExecute autoExecute;

  /// -1 = repeats forever; otherwise the remaining occurrence count - EXCEPT
  /// when [periodUsesXParam] is true for [period], in which case this is the
  /// day/month interval X ("dans/tous les X ..."), not a count at all.
  final int numOccurrences;
  final String? notes;

  /// True if the user paused this template: excluded from auto-add/catch-up
  /// and from the forecast, without deleting it or touching
  /// BILLSDEPOSITS_V1 - stored separately, see
  /// [MmexRepository.getPausedBillIds]/[MmexRepository.setBillPaused].
  final bool paused;

  /// Meaningless for a real MMEX bill (always 0 - [fromRow] never sets it) -
  /// only [SimVirtualBill.toBillDeposit] ever produces a non-zero value,
  /// for the simulator's "dépenses imprévues" adjustment (2026-09-02 user
  /// request). When > 0, [MmexRepository._monthlyNetForBills] applies a
  /// small, deterministically-seeded random variation per occurrence
  /// instead of the exact same amount every single month - see
  /// `_seededMonthlyJitter`. A percentage (e.g. 10 = ±10%), never negative.
  final double variancePercent;

  const BillDeposit({
    required this.id,
    required this.accountId,
    required this.payeeId,
    required this.transCode,
    required this.amount,
    required this.toAmount,
    required this.nextOccurrence,
    required this.period,
    required this.autoExecute,
    required this.numOccurrences,
    this.toAccountId,
    this.categoryId,
    this.notes,
    this.paused = false,
    this.variancePercent = 0,
  });

  /// Mirrors [MoneyTransaction.copyWith]: a non-transfer bill always has
  /// toAmount == amount too, so [amount] alone is enough - no separate
  /// toAmount param to keep them in sync by construction.
  BillDeposit copyWith({double? amount}) {
    return BillDeposit(
      id: id,
      accountId: accountId,
      toAccountId: toAccountId,
      payeeId: payeeId,
      transCode: transCode,
      amount: amount ?? this.amount,
      toAmount: amount ?? toAmount,
      categoryId: categoryId,
      nextOccurrence: nextOccurrence,
      period: period,
      autoExecute: autoExecute,
      numOccurrences: numOccurrences,
      notes: notes,
      paused: paused,
    );
  }

  factory BillDeposit.fromRow(Map<String, Object?> row, {bool paused = false}) {
    final decoded = decodeRepeats((row['REPEATS'] as num?)?.toInt() ?? 3);
    return BillDeposit(
      id: row['BDID'] as int,
      accountId: row['ACCOUNTID'] as int,
      toAccountId: row['TOACCOUNTID'] as int?,
      payeeId: row['PAYEEID'] as int? ?? -1,
      transCode:
          transCodeFromString(row['TRANSCODE'] as String? ?? 'Withdrawal'),
      amount: (row['TRANSAMOUNT'] as num?)?.toDouble() ?? 0,
      toAmount: (row['TOTRANSAMOUNT'] as num?)?.toDouble() ?? 0,
      categoryId: row['CATEGID'] as int?,
      nextOccurrence:
          DateTime.tryParse(row['NEXTOCCURRENCEDATE'] as String? ?? '') ??
              DateTime.now(),
      period: decoded.period,
      autoExecute: decoded.autoExecute,
      numOccurrences: (row['NUMOCCURRENCES'] as num?)?.toInt() ?? -1,
      notes: row['NOTES'] as String?,
      paused: paused,
    );
  }
}
