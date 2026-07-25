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
  final int numOccurrences;
  final String? notes;

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
  });

  factory BillDeposit.fromRow(Map<String, Object?> row) {
    final decoded = decodeRepeats((row['REPEATS'] as num?)?.toInt() ?? 3);
    return BillDeposit(
      id: row['BDID'] as int,
      accountId: row['ACCOUNTID'] as int,
      toAccountId: row['TOACCOUNTID'] as int?,
      payeeId: row['PAYEEID'] as int? ?? -1,
      transCode: transCodeFromString(row['TRANSCODE'] as String? ?? 'Withdrawal'),
      amount: (row['TRANSAMOUNT'] as num?)?.toDouble() ?? 0,
      toAmount: (row['TOTRANSAMOUNT'] as num?)?.toDouble() ?? 0,
      categoryId: row['CATEGID'] as int?,
      nextOccurrence: DateTime.tryParse(row['NEXTOCCURRENCEDATE'] as String? ?? '') ?? DateTime.now(),
      period: decoded.period,
      autoExecute: decoded.autoExecute,
      numOccurrences: (row['NUMOCCURRENCES'] as num?)?.toInt() ?? -1,
      notes: row['NOTES'] as String?,
    );
  }
}
