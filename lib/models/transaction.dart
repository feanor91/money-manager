enum TransCode { withdrawal, deposit, transfer }

TransCode transCodeFromString(String code) {
  switch (code) {
    case 'Deposit':
      return TransCode.deposit;
    case 'Transfer':
      return TransCode.transfer;
    default:
      return TransCode.withdrawal;
  }
}

String transCodeToString(TransCode code) {
  switch (code) {
    case TransCode.deposit:
      return 'Deposit';
    case TransCode.transfer:
      return 'Transfer';
    case TransCode.withdrawal:
      return 'Withdrawal';
  }
}

class MoneyTransaction {
  final int id;
  final int accountId;
  final int? toAccountId;
  final int payeeId;
  final TransCode transCode;
  final double amount;
  final double toAmount;
  final String status;
  final int? categoryId;
  final DateTime date;
  final String? notes;

  const MoneyTransaction({
    required this.id,
    required this.accountId,
    required this.payeeId,
    required this.transCode,
    required this.amount,
    required this.toAmount,
    required this.status,
    required this.date,
    this.toAccountId,
    this.categoryId,
    this.notes,
  });

  /// "Pointee" in MMEX parlance: reconciled against a bank statement.
  /// Trimmed/uppercased defensively - some databases (older exports, edits
  /// from other tools) can have stray whitespace or lowercase status codes
  /// that a strict `== 'R'` would miss even though MMEX itself treats them
  /// as reconciled.
  bool get isReconciled => status.trim().toUpperCase() == 'R';

  /// Voided in MMEX: cancelled and excluded from balance calculations.
  bool get isVoid => status.trim().toUpperCase() == 'V';

  /// Signed amount from the point of view of [accountId] (the transaction's
  /// primary/source account): negative for outgoing money (withdrawal /
  /// transfer out), positive for incoming.
  ///
  /// For a transfer this is only correct when looking at it from the
  /// *source* account. Use [signedAmountFor] when the viewing context is a
  /// specific account, so a transfer shows as a credit on the destination
  /// account instead of a debit on both.
  double get signedAmount => signedAmountFor(null);

  /// Signed amount from the point of view of [viewpointAccountId]. Pass the
  /// account currently being viewed (e.g. the dashboard/transactions
  /// account filter) so a transfer's destination account sees a positive
  /// credit rather than the same debit as the source account. When null
  /// (no specific account in view, e.g. "all accounts"), transfers default
  /// to the source account's perspective.
  double signedAmountFor(int? viewpointAccountId) {
    switch (transCode) {
      case TransCode.deposit:
        return amount;
      case TransCode.withdrawal:
        return -amount;
      case TransCode.transfer:
        if (viewpointAccountId != null && viewpointAccountId == toAccountId) {
          return toAmount;
        }
        return -amount;
    }
  }

  MoneyTransaction copyWith({DateTime? date}) {
    return MoneyTransaction(
      id: id,
      accountId: accountId,
      toAccountId: toAccountId,
      payeeId: payeeId,
      transCode: transCode,
      amount: amount,
      toAmount: toAmount,
      status: status,
      categoryId: categoryId,
      date: date ?? this.date,
      notes: notes,
    );
  }

  factory MoneyTransaction.fromRow(Map<String, Object?> row) {
    return MoneyTransaction(
      id: row['TRANSID'] as int,
      accountId: row['ACCOUNTID'] as int,
      toAccountId: row['TOACCOUNTID'] as int?,
      payeeId: row['PAYEEID'] as int? ?? -1,
      transCode: transCodeFromString(row['TRANSCODE'] as String? ?? 'Withdrawal'),
      amount: (row['TRANSAMOUNT'] as num?)?.toDouble() ?? 0,
      toAmount: (row['TOTRANSAMOUNT'] as num?)?.toDouble() ?? 0,
      status: row['STATUS'] as String? ?? '',
      categoryId: row['CATEGID'] as int?,
      date: DateTime.tryParse((row['TRANSDATE'] as String? ?? '')) ?? DateTime.now(),
      notes: row['NOTES'] as String?,
    );
  }
}

/// A transaction paired with the running account balance immediately after
/// it - see [MmexRepository.getTransactionsWithRunningBalance].
class TransactionWithBalance {
  final MoneyTransaction transaction;
  final double balanceAfter;

  const TransactionWithBalance(this.transaction, this.balanceAfter);
}
