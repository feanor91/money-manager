import '../models/account.dart';
import '../models/bill_deposit.dart';
import '../models/budget.dart';
import '../models/category.dart';
import '../models/currency.dart';
import '../models/payee.dart';
import '../models/recurrence.dart';
import '../models/transaction.dart';
import 'mmex_database.dart';

/// Typed CRUD access to an open MMEX database.
class MmexRepository {
  final MmexDatabase db;

  MmexRepository(this.db);

  /// Adds [days] *calendar* days to [date] - never use `date.add(Duration(days:
  /// n))` for this. `Duration` addition is elapsed-time arithmetic in local
  /// time, so it drifts by an hour across a DST transition (France's
  /// autumn "fall back" has a 25-hour day) - every date bucket built that
  /// way after the transition ends up an hour off midnight, silently
  /// failing `map.containsKey()` against the exact-midnight keys the SQL
  /// results are matched against, and dropping that day's data entirely.
  /// Constructing a `DateTime` from adjusted year/month/day components
  /// instead sidesteps wall-clock arithmetic altogether.
  static DateTime _addDays(DateTime date, int days) => DateTime(date.year, date.month, date.day + days);

  // ---- Accounts ----------------------------------------------------

  List<Account> getAccounts({bool onlyOpen = false}) {
    final rows = db.query(
      'SELECT * FROM ACCOUNTLIST_V1'
      '${onlyOpen ? " WHERE STATUS = 'Open'" : ''}'
      ' ORDER BY ACCOUNTNAME COLLATE NOCASE',
    );
    return rows.map(Account.fromRow).toList();
  }

  int insertAccount({
    required String name,
    required String type,
    required double initialBalance,
    required int currencyId,
  }) {
    return db.execute(
      'INSERT INTO ACCOUNTLIST_V1 '
      '(ACCOUNTNAME, ACCOUNTTYPE, STATUS, NOTES, INITIALBAL, FAVORITEACCT, CURRENCYID, INITIALDATE) '
      "VALUES (?, ?, 'Open', '', ?, 'FALSE', ?, date('now'))",
      [name, type, initialBalance, currencyId],
    );
  }

  void updateAccount(Account account) {
    db.execute(
      'UPDATE ACCOUNTLIST_V1 SET ACCOUNTNAME = ?, ACCOUNTTYPE = ?, STATUS = ?, INITIALBAL = ? '
      'WHERE ACCOUNTID = ?',
      [account.name, account.type, account.status, account.initialBalance, account.id],
    );
  }

  void deleteAccount(int accountId) {
    db.execute('DELETE FROM ACCOUNTLIST_V1 WHERE ACCOUNTID = ?', [accountId]);
  }

  /// Current balance = initial balance + sum of signed transactions.
  /// The account's balance, summing every transaction regardless of date
  /// by default (matching MMEX's own total, which includes postdated
  /// entries the user already entered for a known future expense/income).
  /// Pass [asOf] to instead cap it at transactions dated on or before that
  /// day - what the forecast chart needs as its historical anchor, so a
  /// postdated entry further out doesn't bleed backwards into every
  /// reconstructed past point.
  double accountBalance(int accountId, {DateTime? asOf}) {
    final account = db.query(
      'SELECT INITIALBAL FROM ACCOUNTLIST_V1 WHERE ACCOUNTID = ?',
      [accountId],
    );
    final initial = (account.isEmpty ? 0 : account.first['INITIALBAL'] as num?)?.toDouble() ?? 0;

    final where = <String>[
      '(ACCOUNTID = ? OR TOACCOUNTID = ?)',
      "UPPER(TRIM(STATUS)) != 'V'",
      "(DELETEDTIME IS NULL OR DELETEDTIME = '')",
    ];
    final params = <Object?>[accountId, accountId];
    if (asOf != null) {
      where.add('TRANSDATE < ?');
      params.add(_isoDateExclusiveUpper(asOf));
    }
    final rows = db.query(
      'SELECT TRANSCODE, TRANSAMOUNT, TOTRANSAMOUNT, ACCOUNTID, TOACCOUNTID '
      'FROM CHECKINGACCOUNT_V1 WHERE ${where.join(' AND ')}',
      params,
    );

    var total = initial;
    for (final row in rows) {
      final code = row['TRANSCODE'] as String? ?? 'Withdrawal';
      final amount = (row['TRANSAMOUNT'] as num?)?.toDouble() ?? 0;
      final toAmount = (row['TOTRANSAMOUNT'] as num?)?.toDouble() ?? amount;
      final from = row['ACCOUNTID'] as int?;
      if (code == 'Deposit') {
        total += amount;
      } else if (code == 'Withdrawal') {
        total -= amount;
      } else if (code == 'Transfer') {
        if (from == accountId) {
          total -= amount;
        } else {
          total += toAmount;
        }
      }
    }
    return total;
  }

  // ---- Categories ----------------------------------------------------

  List<Category> getCategories({bool onlyActive = true}) {
    final rows = db.query(
      'SELECT * FROM CATEGORY_V1${onlyActive ? ' WHERE ACTIVE = 1' : ''} '
      'ORDER BY CATEGNAME COLLATE NOCASE',
    );
    return rows.map(Category.fromRow).toList();
  }

  int insertCategory({required String name, int? parentId}) {
    return db.execute(
      'INSERT INTO CATEGORY_V1 (CATEGNAME, ACTIVE, PARENTID) VALUES (?, 1, ?)',
      [name, parentId ?? -1],
    );
  }

  void deleteCategory(int categoryId) {
    db.execute('DELETE FROM CATEGORY_V1 WHERE CATEGID = ?', [categoryId]);
  }

  // ---- Payees ----------------------------------------------------

  List<Payee> getPayees({bool onlyActive = true}) {
    final rows = db.query(
      'SELECT * FROM PAYEE_V1${onlyActive ? ' WHERE ACTIVE = 1' : ''} '
      'ORDER BY PAYEENAME COLLATE NOCASE',
    );
    return rows.map(Payee.fromRow).toList();
  }

  int insertPayee({required String name, int? categoryId}) {
    return db.execute(
      'INSERT INTO PAYEE_V1 (PAYEENAME, ACTIVE, CATEGID) VALUES (?, 1, ?)',
      [name, categoryId],
    );
  }

  // ---- Transactions ----------------------------------------------------

  List<MoneyTransaction> getTransactions({
    int? accountId,
    DateTime? from,
    DateTime? to,
    int limit = 200,
  }) {
    final where = <String>["(DELETEDTIME IS NULL OR DELETEDTIME = '')"];
    final params = <Object?>[];
    if (accountId != null) {
      where.add('(ACCOUNTID = ? OR TOACCOUNTID = ?)');
      params.addAll([accountId, accountId]);
    }
    if (from != null) {
      where.add('TRANSDATE >= ?');
      params.add(_isoDate(from));
    }
    if (to != null) {
      where.add('TRANSDATE < ?');
      params.add(_isoDateExclusiveUpper(to));
    }
    final whereSql = 'WHERE ${where.join(' AND ')}';
    final rows = db.query(
      'SELECT * FROM CHECKINGACCOUNT_V1 $whereSql ORDER BY TRANSDATE DESC, TRANSID DESC LIMIT ?',
      [...params, limit],
    );
    return rows.map(MoneyTransaction.fromRow).toList();
  }

  /// Every transaction touching [accountId], each paired with the running
  /// account balance immediately after it - the same "Solde" column MMEX's
  /// own ledger view shows. Computed chronologically from the account's
  /// initial balance, then returned newest-first for display. [limit]
  /// only caps how many rows are returned, not how many are used to work
  /// out the balance (the full history is always walked).
  List<TransactionWithBalance> getTransactionsWithRunningBalance(int accountId, {int limit = 300}) {
    final accountRows = db.query('SELECT INITIALBAL FROM ACCOUNTLIST_V1 WHERE ACCOUNTID = ?', [accountId]);
    var running = (accountRows.isEmpty ? 0 : accountRows.first['INITIALBAL'] as num?)?.toDouble() ?? 0;

    final rows = db.query(
      'SELECT * FROM CHECKINGACCOUNT_V1 WHERE (ACCOUNTID = ? OR TOACCOUNTID = ?) '
      "AND (DELETEDTIME IS NULL OR DELETEDTIME = '') "
      'ORDER BY TRANSDATE ASC, TRANSID ASC',
      [accountId, accountId],
    );
    final withBalance = <TransactionWithBalance>[];
    for (final row in rows) {
      final tx = MoneyTransaction.fromRow(row);
      // Voided transactions stay visible in the ledger (so nothing looks
      // like it silently vanished) but never affect the running balance -
      // MMEX itself excludes them from every total.
      if (!tx.isVoid) running += tx.signedAmountFor(accountId);
      withBalance.add(TransactionWithBalance(tx, running));
    }
    return withBalance.reversed.take(limit).toList();
  }

  int insertTransaction({
    required int accountId,
    required int payeeId,
    required TransCode transCode,
    required double amount,
    required DateTime date,
    int? categoryId,
    int? toAccountId,
    double? toAmount,
    String? notes,
    bool reconciled = false,
  }) {
    return db.execute(
      'INSERT INTO CHECKINGACCOUNT_V1 '
      '(ACCOUNTID, TOACCOUNTID, PAYEEID, TRANSCODE, TRANSAMOUNT, TOTRANSAMOUNT, STATUS, CATEGID, TRANSDATE, NOTES) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        accountId,
        toAccountId,
        payeeId,
        transCodeToString(transCode),
        amount,
        toAmount ?? amount,
        reconciled ? 'R' : '',
        categoryId,
        _isoDate(date),
        notes ?? '',
      ],
    );
  }

  void updateTransaction(MoneyTransaction tx) {
    db.execute(
      'UPDATE CHECKINGACCOUNT_V1 SET ACCOUNTID = ?, TOACCOUNTID = ?, PAYEEID = ?, TRANSCODE = ?, '
      'TRANSAMOUNT = ?, TOTRANSAMOUNT = ?, CATEGID = ?, TRANSDATE = ?, NOTES = ? WHERE TRANSID = ?',
      [
        tx.accountId,
        tx.toAccountId,
        tx.payeeId,
        transCodeToString(tx.transCode),
        tx.amount,
        tx.toAmount,
        tx.categoryId,
        _isoDate(tx.date),
        tx.notes ?? '',
        tx.id,
      ],
    );
  }

  void deleteTransaction(int transId) {
    db.execute('DELETE FROM CHECKINGACCOUNT_V1 WHERE TRANSID = ?', [transId]);
  }

  /// Toggles a transaction's reconciled ("pointe") state.
  void setReconciled(int transId, bool reconciled) {
    db.execute(
      'UPDATE CHECKINGACCOUNT_V1 SET STATUS = ? WHERE TRANSID = ?',
      [reconciled ? 'R' : '', transId],
    );
  }

  /// Net signed monthly totals (income - expenses) for the last [months]
  /// months up to and including the month of [anchor]. When [accountId] is
  /// given, only that account's transactions are counted (transfers are
  /// included, signed from that account's point of view).
  Map<DateTime, double> monthlyNetTotals({
    required DateTime anchor,
    required int months,
    int? accountId,
  }) {
    final start = DateTime(anchor.year, anchor.month - months + 1, 1);
    final where = <String>[
      'TRANSDATE >= ?',
      'TRANSDATE < ?',
      "UPPER(TRIM(STATUS)) != 'V'",
      "(DELETEDTIME IS NULL OR DELETEDTIME = '')",
    ];
    final params = <Object?>[_isoDate(start), _isoDate(DateTime(anchor.year, anchor.month + 1, 1))];
    if (accountId != null) {
      where.add('(ACCOUNTID = ? OR TOACCOUNTID = ?)');
      params.addAll([accountId, accountId]);
    } else {
      where.add('TRANSCODE != ?');
      params.add('Transfer');
    }
    final rows = db.query(
      'SELECT TRANSDATE, TRANSCODE, TRANSAMOUNT, TOTRANSAMOUNT, ACCOUNTID FROM CHECKINGACCOUNT_V1 '
      'WHERE ${where.join(' AND ')}',
      params,
    );
    final result = <DateTime, double>{
      for (var i = 0; i < months; i++)
        DateTime(start.year, start.month + i, 1): 0.0,
    };
    for (final row in rows) {
      final date = DateTime.tryParse(row['TRANSDATE'] as String? ?? '');
      if (date == null) continue;
      final bucket = DateTime(date.year, date.month, 1);
      if (!result.containsKey(bucket)) continue;
      final amount = (row['TRANSAMOUNT'] as num?)?.toDouble() ?? 0;
      final toAmount = (row['TOTRANSAMOUNT'] as num?)?.toDouble() ?? amount;
      final code = row['TRANSCODE'] as String?;
      double signed;
      if (code == 'Deposit') {
        signed = amount;
      } else if (code == 'Withdrawal') {
        signed = -amount;
      } else {
        // Transfer: only reachable when filtering to a single account.
        final from = row['ACCOUNTID'] as int?;
        signed = from == accountId ? -amount : toAmount;
      }
      result[bucket] = (result[bucket] ?? 0) + signed;
    }
    return result;
  }

  /// Net signed totals bucketed into Sunday-starting weeks, for [weeks]
  /// buckets up to and including the week containing [anchor]. Mirrors
  /// [monthlyNetTotals] but at week resolution.
  Map<DateTime, double> weeklyNetTotals({
    required DateTime anchor,
    required int weeks,
    int? accountId,
  }) {
    final anchorWeekStart = _weekStart(anchor);
    final start = _addDays(anchorWeekStart, -7 * (weeks - 1));
    final end = _addDays(anchorWeekStart, 6);
    final where = <String>[
      'TRANSDATE >= ?',
      'TRANSDATE < ?',
      "UPPER(TRIM(STATUS)) != 'V'",
      "(DELETEDTIME IS NULL OR DELETEDTIME = '')",
    ];
    final params = <Object?>[_isoDate(start), _isoDateExclusiveUpper(end)];
    if (accountId != null) {
      where.add('(ACCOUNTID = ? OR TOACCOUNTID = ?)');
      params.addAll([accountId, accountId]);
    } else {
      where.add('TRANSCODE != ?');
      params.add('Transfer');
    }
    final rows = db.query(
      'SELECT TRANSDATE, TRANSCODE, TRANSAMOUNT, TOTRANSAMOUNT, ACCOUNTID FROM CHECKINGACCOUNT_V1 '
      'WHERE ${where.join(' AND ')}',
      params,
    );
    final result = <DateTime, double>{
      for (var i = 0; i < weeks; i++) _addDays(start, 7 * i): 0.0,
    };
    for (final row in rows) {
      final date = DateTime.tryParse(row['TRANSDATE'] as String? ?? '');
      if (date == null) continue;
      final bucket = _weekStart(date);
      if (!result.containsKey(bucket)) continue;
      final amount = (row['TRANSAMOUNT'] as num?)?.toDouble() ?? 0;
      final toAmount = (row['TOTRANSAMOUNT'] as num?)?.toDouble() ?? amount;
      final code = row['TRANSCODE'] as String?;
      double signed;
      if (code == 'Deposit') {
        signed = amount;
      } else if (code == 'Withdrawal') {
        signed = -amount;
      } else {
        final from = row['ACCOUNTID'] as int?;
        signed = from == accountId ? -amount : toAmount;
      }
      result[bucket] = (result[bucket] ?? 0) + signed;
    }
    return result;
  }

  /// Mechanical projection of recurring transactions bucketed by
  /// Sunday-starting week (see [recurringMonthlyNet] for the rationale).
  Map<DateTime, double> recurringWeeklyNet({
    required DateTime anchor,
    required int weeks,
    int? accountId,
  }) {
    final anchorWeekStart = _weekStart(anchor);
    final start = _addDays(anchorWeekStart, -7 * (weeks - 1));
    final end = _addDays(anchorWeekStart, 6);
    final result = <DateTime, double>{
      for (var i = 0; i < weeks; i++) _addDays(start, 7 * i): 0.0,
    };

    for (final bill in getBillDeposits()) {
      if (bill.paused) continue;
      final involvesAccount = accountId == null ||
          bill.accountId == accountId ||
          bill.toAccountId == accountId;
      if (!involvesAccount) continue;
      if (accountId == null && bill.transCode == TransCode.transfer) continue;

      final signedAmount = _billSignedAmount(bill, accountId);
      for (final occurrence in _occurrencesInRange(bill, start, end)) {
        final bucket = _weekStart(occurrence);
        final current = result[bucket];
        if (current == null) continue;
        result[bucket] = current + signedAmount;
      }
    }
    return result;
  }

  /// Net signed totals bucketed by calendar day, for [days] buckets up to
  /// and including [anchor]. Mirrors [weeklyNetTotals] at day resolution.
  Map<DateTime, double> dailyNetTotals({
    required DateTime anchor,
    required int days,
    int? accountId,
  }) {
    final anchorDay = DateTime(anchor.year, anchor.month, anchor.day);
    final start = _addDays(anchorDay, -(days - 1));
    final where = <String>[
      'TRANSDATE >= ?',
      'TRANSDATE < ?',
      "UPPER(TRIM(STATUS)) != 'V'",
      "(DELETEDTIME IS NULL OR DELETEDTIME = '')",
    ];
    final params = <Object?>[_isoDate(start), _isoDateExclusiveUpper(anchorDay)];
    if (accountId != null) {
      where.add('(ACCOUNTID = ? OR TOACCOUNTID = ?)');
      params.addAll([accountId, accountId]);
    } else {
      where.add('TRANSCODE != ?');
      params.add('Transfer');
    }
    final rows = db.query(
      'SELECT TRANSDATE, TRANSCODE, TRANSAMOUNT, TOTRANSAMOUNT, ACCOUNTID FROM CHECKINGACCOUNT_V1 '
      'WHERE ${where.join(' AND ')}',
      params,
    );
    final result = <DateTime, double>{
      for (var i = 0; i < days; i++) _addDays(start, i): 0.0,
    };
    for (final row in rows) {
      final date = DateTime.tryParse(row['TRANSDATE'] as String? ?? '');
      if (date == null) continue;
      final bucket = DateTime(date.year, date.month, date.day);
      if (!result.containsKey(bucket)) continue;
      final amount = (row['TRANSAMOUNT'] as num?)?.toDouble() ?? 0;
      final toAmount = (row['TOTRANSAMOUNT'] as num?)?.toDouble() ?? amount;
      final code = row['TRANSCODE'] as String?;
      double signed;
      if (code == 'Deposit') {
        signed = amount;
      } else if (code == 'Withdrawal') {
        signed = -amount;
      } else {
        final from = row['ACCOUNTID'] as int?;
        signed = from == accountId ? -amount : toAmount;
      }
      result[bucket] = (result[bucket] ?? 0) + signed;
    }
    return result;
  }

  /// Mechanical projection of recurring transactions bucketed by calendar
  /// day (see [recurringMonthlyNet] for the rationale).
  Map<DateTime, double> recurringDailyNet({
    required DateTime anchor,
    required int days,
    int? accountId,
  }) {
    final anchorDay = DateTime(anchor.year, anchor.month, anchor.day);
    final start = _addDays(anchorDay, -(days - 1));
    final result = <DateTime, double>{
      for (var i = 0; i < days; i++) _addDays(start, i): 0.0,
    };

    for (final bill in getBillDeposits()) {
      if (bill.paused) continue;
      final involvesAccount = accountId == null ||
          bill.accountId == accountId ||
          bill.toAccountId == accountId;
      if (!involvesAccount) continue;
      if (accountId == null && bill.transCode == TransCode.transfer) continue;

      final signedAmount = _billSignedAmount(bill, accountId);
      for (final occurrence in _occurrencesInRange(bill, start, anchorDay)) {
        final bucket = DateTime(occurrence.year, occurrence.month, occurrence.day);
        final current = result[bucket];
        if (current == null) continue;
        result[bucket] = current + signedAmount;
      }
    }
    return result;
  }

  /// Projects [accountId]'s balance forward from today to [targetDate]
  /// using only known recurring transactions (see [recurringDailyNet]) -
  /// the same mechanical projection the forecast chart uses, collapsed to a
  /// single final figure. Returns the plain current balance if [targetDate]
  /// isn't in the future.
  double forecastAccountBalance(int accountId, DateTime targetDate) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(targetDate.year, targetDate.month, targetDate.day);
    final balance = accountBalance(accountId, asOf: now);
    if (!target.isAfter(today)) return balance;

    final recurring = recurringDailyNet(
      anchor: target,
      days: _daysBetween(today, target) + 1,
      accountId: accountId,
    );
    var total = balance;
    var cursor = _addDays(today, 1);
    while (!cursor.isAfter(target)) {
      total += recurring[cursor] ?? 0.0;
      cursor = _addDays(cursor, 1);
    }
    return total;
  }

  /// Whole calendar days from [a] to [b] (both taken as local dates,
  /// ignoring time-of-day). Computed via UTC dates - which have no DST -
  /// so a `.difference().inDays` spanning a spring-forward/fall-back
  /// transition can't come out one day short or long the way local-time
  /// difference can.
  static int _daysBetween(DateTime a, DateTime b) {
    final utcA = DateTime.utc(a.year, a.month, a.day);
    final utcB = DateTime.utc(b.year, b.month, b.day);
    return utcB.difference(utcA).inDays;
  }

  /// Every individual recurring-transaction occurrence between [start] and
  /// [end] (inclusive), with enough detail (label, date, signed amount) to
  /// annotate a forecast chart - unlike [recurringDailyNet], which only
  /// returns the day's aggregated total and loses which bill(s) made it up.
  List<RecurringOccurrence> recurringOccurrencesInRange({
    required DateTime start,
    required DateTime end,
    int? accountId,
  }) {
    final payees = {for (final p in getPayees(onlyActive: false)) p.id: p};
    final accounts = {for (final a in getAccounts()) a.id: a};
    final result = <RecurringOccurrence>[];

    for (final bill in getBillDeposits()) {
      if (bill.paused) continue;
      final involvesAccount = accountId == null ||
          bill.accountId == accountId ||
          bill.toAccountId == accountId;
      if (!involvesAccount) continue;
      if (accountId == null && bill.transCode == TransCode.transfer) continue;

      final signedAmount = _billSignedAmount(bill, accountId);
      final label = bill.transCode == TransCode.transfer
          ? '${accounts[bill.accountId]?.name ?? '?'} -> ${accounts[bill.toAccountId]?.name ?? '?'}'
          : (payees[bill.payeeId]?.name ?? 'Paye inconnu');

      for (final occurrence in _occurrencesInRange(bill, start, end)) {
        result.add(RecurringOccurrence(date: occurrence, label: label, signedAmount: signedAmount));
      }
    }
    result.sort((a, b) => a.date.compareTo(b.date));
    return result;
  }

  double _billSignedAmount(BillDeposit bill, int? accountId) {
    if (bill.transCode == TransCode.deposit) return bill.amount;
    if (bill.transCode == TransCode.withdrawal) return -bill.amount;
    return bill.accountId == accountId ? -bill.amount : bill.toAmount;
  }

  DateTime _weekStart(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    // Dart's DateTime.weekday: Monday=1 ... Sunday=7. Weeks start on Sunday.
    final daysSinceSunday = d.weekday % 7;
    return _addDays(d, -daysSinceSunday);
  }

  /// Spending by category for the given month (expenses only, positive
  /// values), optionally restricted to a single account.
  Map<int, double> categorySpendForMonth(DateTime month, {int? accountId}) {
    final start = DateTime(month.year, month.month, 1);
    final end = DateTime(month.year, month.month + 1, 1);
    final where = <String>[
      "TRANSDATE >= ?",
      "TRANSDATE < ?",
      "TRANSCODE = 'Withdrawal'",
      "UPPER(TRIM(STATUS)) != 'V'",
      "(DELETEDTIME IS NULL OR DELETEDTIME = '')",
    ];
    final params = <Object?>[_isoDate(start), _isoDate(end)];
    if (accountId != null) {
      where.add('ACCOUNTID = ?');
      params.add(accountId);
    }
    final rows = db.query(
      'SELECT CATEGID, TRANSAMOUNT FROM CHECKINGACCOUNT_V1 WHERE ${where.join(' AND ')}',
      params,
    );
    final totals = <int, double>{};
    for (final row in rows) {
      final categId = row['CATEGID'] as int?;
      if (categId == null) continue;
      final amount = (row['TRANSAMOUNT'] as num?)?.toDouble() ?? 0;
      totals[categId] = (totals[categId] ?? 0) + amount;
    }
    return totals;
  }

  // ---- Recurring transactions (bills/deposits) ----------------------

  List<BillDeposit> getBillDeposits() {
    final rows = db.query('SELECT * FROM BILLSDEPOSITS_V1 ORDER BY NEXTOCCURRENCEDATE ASC');
    final pausedIds = getPausedBillIds();
    return rows
        .map((row) => BillDeposit.fromRow(row, paused: pausedIds.contains(row['BDID'] as int)))
        .toList();
  }

  static const _pausedBillsInfoName = 'MMEXFLUTTER_PAUSED_BILLS';

  /// Ids of recurring templates the user paused - stored as a
  /// comma-separated list in INFOTABLE_V1 (MMEX's own generic settings
  /// table, already used for e.g. BASECURRENCYID), under an app-specific
  /// key so it never collides with anything MMEX itself reads/writes.
  /// Deliberately NOT a schema change to BILLSDEPOSITS_V1: this way the
  /// .mmb file stays a plain, portable MMEX database - opening it in the
  /// real MMEX desktop app just ignores this extra row.
  Set<int> getPausedBillIds() {
    final rows = db.query("SELECT INFOVALUE FROM INFOTABLE_V1 WHERE INFONAME = '$_pausedBillsInfoName'");
    if (rows.isEmpty) return {};
    final value = rows.first['INFOVALUE'] as String? ?? '';
    return value.split(',').map(int.tryParse).whereType<int>().toSet();
  }

  void setBillPaused(int billId, bool paused) {
    final ids = getPausedBillIds();
    if (paused) {
      ids.add(billId);
    } else {
      ids.remove(billId);
    }
    final value = ids.join(',');
    final existing = db.query("SELECT INFOID FROM INFOTABLE_V1 WHERE INFONAME = '$_pausedBillsInfoName'");
    if (existing.isEmpty) {
      db.execute(
        'INSERT INTO INFOTABLE_V1 (INFONAME, INFOVALUE) VALUES (?, ?)',
        [_pausedBillsInfoName, value],
      );
    } else {
      db.execute(
        'UPDATE INFOTABLE_V1 SET INFOVALUE = ? WHERE INFONAME = ?',
        [value, _pausedBillsInfoName],
      );
    }
  }

  int insertBillDeposit({
    required int accountId,
    required int payeeId,
    required TransCode transCode,
    required double amount,
    required DateTime nextOccurrence,
    required RecurrencePeriod period,
    required RecurrenceAutoExecute autoExecute,
    int? categoryId,
    int? toAccountId,
    double? toAmount,
    String? notes,
    int numOccurrences = -1,
  }) {
    return db.execute(
      'INSERT INTO BILLSDEPOSITS_V1 '
      '(ACCOUNTID, TOACCOUNTID, PAYEEID, TRANSCODE, TRANSAMOUNT, TOTRANSAMOUNT, STATUS, CATEGID, '
      'TRANSDATE, NEXTOCCURRENCEDATE, REPEATS, NUMOCCURRENCES, NOTES) '
      "VALUES (?, ?, ?, ?, ?, ?, '', ?, ?, ?, ?, ?, ?)",
      [
        accountId,
        toAccountId,
        payeeId,
        transCodeToString(transCode),
        amount,
        toAmount ?? amount,
        categoryId,
        _isoDate(nextOccurrence),
        _isoDate(nextOccurrence),
        encodeRepeats(period, autoExecute),
        numOccurrences,
        notes ?? '',
      ],
    );
  }

  void updateBillDeposit(BillDeposit bill) {
    db.execute(
      'UPDATE BILLSDEPOSITS_V1 SET ACCOUNTID = ?, TOACCOUNTID = ?, PAYEEID = ?, TRANSCODE = ?, '
      'TRANSAMOUNT = ?, TOTRANSAMOUNT = ?, CATEGID = ?, NEXTOCCURRENCEDATE = ?, REPEATS = ?, '
      'NUMOCCURRENCES = ?, NOTES = ? WHERE BDID = ?',
      [
        bill.accountId,
        bill.toAccountId,
        bill.payeeId,
        transCodeToString(bill.transCode),
        bill.amount,
        bill.toAmount,
        bill.categoryId,
        _isoDate(bill.nextOccurrence),
        encodeRepeats(bill.period, bill.autoExecute),
        bill.numOccurrences,
        bill.notes ?? '',
        bill.id,
      ],
    );
  }

  void deleteBillDeposit(int bdId) {
    db.execute('DELETE FROM BILLSDEPOSITS_V1 WHERE BDID = ?', [bdId]);
  }

  /// Recurring templates whose next occurrence is due on or before [asOf] -
  /// excludes paused templates (see [BillDeposit.paused]), which are never
  /// auto-added nor projected.
  List<BillDeposit> getDueBillDeposits(DateTime asOf) {
    return getBillDeposits()
        .where((b) => !b.paused && !b.nextOccurrence.isAfter(asOf))
        .toList();
  }

  /// Records a single occurrence of [bill] as a real transaction dated
  /// [date], then advances the template's next-occurrence date to the first
  /// cycle date after [date] (deleting the template if it has just run out
  /// of remaining occurrences).
  int recordBillOccurrence(BillDeposit bill, {required DateTime date, bool reconciled = false}) {
    final transId = insertTransaction(
      accountId: bill.accountId,
      payeeId: bill.payeeId,
      transCode: bill.transCode,
      amount: bill.amount,
      date: date,
      categoryId: bill.categoryId,
      toAccountId: bill.toAccountId,
      toAmount: bill.toAmount,
      notes: bill.notes,
      reconciled: reconciled,
    );
    // The recorded date may be earlier than the template's own scheduled
    // occurrence (recording a bill a little early/late) - always advance
    // from at least the template's own anchor so the schedule can't get
    // stuck repeating the same "next occurrence" forever.
    final advanceFrom = date.isAfter(bill.nextOccurrence) ? date : bill.nextOccurrence;
    _applyScheduleAdvance(bill, _advanceSchedule(bill, advanceFrom));
    return transId;
  }

  /// Catches up every missed occurrence of [bill] between its current next
  /// occurrence and [asOf] (inclusive), recording each as a real
  /// transaction, then advances the template past [asOf]. Returns the
  /// inserted transaction ids.
  ///
  /// Never generates more occurrences than the template actually has left:
  /// a limited ("durée limitée") bill stops exactly at its remaining count
  /// even when [asOf] is far enough in the future to otherwise cover more
  /// cycle dates - see [_advanceSchedule].
  List<int> catchUpBillDeposit(BillDeposit bill, DateTime asOf, {bool reconciled = false}) {
    final advance = _advanceSchedule(bill, asOf);
    final ids = <int>[];
    for (final occurrence in advance.occurrences) {
      ids.add(insertTransaction(
        accountId: bill.accountId,
        payeeId: bill.payeeId,
        transCode: bill.transCode,
        amount: bill.amount,
        date: occurrence,
        categoryId: bill.categoryId,
        toAccountId: bill.toAccountId,
        toAmount: bill.toAmount,
        notes: bill.notes,
        reconciled: reconciled,
      ));
    }
    if (advance.occurrences.isNotEmpty) {
      _applyScheduleAdvance(bill, advance);
    }
    return ids;
  }

  void _applyScheduleAdvance(BillDeposit bill, _ScheduleAdvance advance) {
    if (advance.nextOccurrence == null) {
      deleteBillDeposit(bill.id);
      return;
    }
    db.execute(
      'UPDATE BILLSDEPOSITS_V1 SET NEXTOCCURRENCEDATE = ?, REPEATS = ?, NUMOCCURRENCES = ? WHERE BDID = ?',
      [
        _isoDate(advance.nextOccurrence!),
        encodeRepeats(advance.period, bill.autoExecute),
        advance.numOccurrences,
        bill.id,
      ],
    );
  }

  /// Walks [bill]'s schedule forward from its current next-occurrence date,
  /// emitting every occurrence up to and including [through], and returns
  /// where the template ends up afterwards. Mirrors MMEX's own
  /// `SchedModel::reschedule_id`/`Repeat::next_repeat` (one occurrence at a
  /// time) instead of separately computing "how many occurrences" and
  /// "what's the next date" - the two must stay in lockstep, or a limited
  /// ("durée limitée") template can fire more real transactions than its
  /// remaining count allows and then, because a negative leftover count
  /// reads as "unlimited" (see [BillDeposit.numOccurrences]), keep firing
  /// forever afterwards instead of stopping.
  ///
  /// [RecurrencePeriod.inXDays]/[inXMonths] follow MMEX's own semantics for
  /// these: NUMOCCURRENCES holds the day/month interval X, not a count, and
  /// the *first* firing always converts the schedule into a plain one-off
  /// due X (days/months) later - i.e. exactly two firings, X apart, ever -
  /// matching `Repeat`'s constructor (`m_num = 2` for `is_in_x`) and
  /// `next_repeat` (converts to `e_once` once `m_num == 1`).
  /// [RecurrencePeriod.everyXDays]/[everyXMonths] instead repeat forever
  /// with that interval, exactly like `is_every_x` hardcoding `m_num = -1`
  /// (see moneymanagerex/src/data/_Repeat.cpp).
  _ScheduleAdvance _advanceSchedule(BillDeposit bill, DateTime through) {
    final occurrences = <DateTime>[];
    var period = bill.period;
    var count = bill.numOccurrences;
    var cursor = bill.nextOccurrence;
    var guard = 0;
    var exhausted = false;

    while (!cursor.isAfter(through) && guard < 1000) {
      guard++;
      occurrences.add(cursor);

      if (period == RecurrencePeriod.inXDays || period == RecurrencePeriod.inXMonths) {
        final x = count > 0 ? count : 1;
        cursor = period == RecurrencePeriod.inXDays ? _addDays(cursor, x) : _addMonths(cursor, x);
        period = RecurrencePeriod.none;
        count = 1;
        continue;
      }
      if (period == RecurrencePeriod.everyXDays || period == RecurrencePeriod.everyXMonths) {
        final x = count > 0 ? count : 1;
        cursor = period == RecurrencePeriod.everyXDays ? _addDays(cursor, x) : _addMonths(cursor, x);
        continue; // always infinite - count keeps holding the interval X.
      }

      if (count > 0) {
        count -= 1;
        if (count == 0) {
          exhausted = true;
          break;
        }
      }
      final monthStep = _monthStepForPeriod(period);
      final dayStep = _dayStepForPeriod(period);
      if (monthStep != null) {
        cursor = _stepMonths(cursor, monthStep, period);
      } else if (dayStep != null) {
        cursor = _addDays(cursor, dayStep);
      } else {
        exhausted = true; // RecurrencePeriod.none: a one-off, never repeats.
        break;
      }
    }

    return _ScheduleAdvance(
      occurrences: occurrences,
      nextOccurrence: exhausted ? null : cursor,
      period: period,
      numOccurrences: count,
    );
  }

  /// Mechanically projects every recurring transaction template forward
  /// (and backward) along its own cycle, independent of whether it has
  /// actually executed yet, and buckets the signed amounts by month. Used to
  /// give the forecast chart a concrete, known component of future cash
  /// flow instead of a flat average - and, over the same historical window,
  /// to work out how much of the past average was "recurring" vs
  /// discretionary spending.
  Map<DateTime, double> recurringMonthlyNet({
    required DateTime anchor,
    required int months,
    int? accountId,
  }) {
    final start = DateTime(anchor.year, anchor.month - months + 1, 1);
    final end = DateTime(anchor.year, anchor.month + 1, 0);
    final result = <DateTime, double>{
      for (var i = 0; i < months; i++)
        DateTime(start.year, start.month + i, 1): 0.0,
    };

    for (final bill in getBillDeposits()) {
      if (bill.paused) continue;
      final involvesAccount = accountId == null ||
          bill.accountId == accountId ||
          bill.toAccountId == accountId;
      if (!involvesAccount) continue;
      if (accountId == null && bill.transCode == TransCode.transfer) continue;

      final signedAmount = _billSignedAmount(bill, accountId);
      for (final occurrence in _occurrencesInRange(bill, start, end)) {
        final bucket = DateTime(occurrence.year, occurrence.month, 1);
        final current = result[bucket];
        if (current == null) continue;
        result[bucket] = current + signedAmount;
      }
    }
    return result;
  }

  /// Never emits an occurrence before [BillDeposit.nextOccurrence]: MMEX
  /// advances that date past every occurrence it already executed, so
  /// anything earlier is already a real transaction in the ledger. Without
  /// this floor, walking backward to cover [rangeStart] would regenerate
  /// the most recently completed occurrence as if it were still pending -
  /// double-counting it once as real history and once as a projection.
  List<DateTime> _occurrencesInRange(BillDeposit bill, DateTime rangeStart, DateTime rangeEnd) {
    final occurrences = <DateTime>[];
    final effectiveStart =
        rangeStart.isBefore(bill.nextOccurrence) ? bill.nextOccurrence : rangeStart;
    if (effectiveStart.isAfter(rangeEnd)) return occurrences;

    // "Dans X jours/mois": always exactly 2 firings, X apart, then done -
    // not a genuine indefinite cycle to project forward/backward like the
    // other periods (see _advanceSchedule).
    if (periodIsFixedTwoShot(bill.period)) {
      final x = bill.numOccurrences > 0 ? bill.numOccurrences : 1;
      final second = bill.period == RecurrencePeriod.inXDays
          ? _addDays(bill.nextOccurrence, x)
          : _addMonths(bill.nextOccurrence, x);
      for (final occurrence in [bill.nextOccurrence, second]) {
        if (!occurrence.isBefore(effectiveStart) && !occurrence.isAfter(rangeEnd)) {
          occurrences.add(occurrence);
        }
      }
      return occurrences;
    }

    final monthStep = _monthStepForBill(bill);
    if (monthStep != null) {
      var cursor = bill.nextOccurrence;
      var guard = 0;
      while (!cursor.isBefore(effectiveStart) && guard < 1000) {
        cursor = _stepMonths(cursor, -monthStep, bill.period);
        guard++;
      }
      cursor = _stepMonths(cursor, monthStep, bill.period);
      guard = 0;
      while (!cursor.isAfter(rangeEnd) && guard < 1000) {
        occurrences.add(cursor);
        cursor = _stepMonths(cursor, monthStep, bill.period);
        guard++;
      }
      return occurrences;
    }

    final dayStep = _dayStepForBill(bill);
    if (dayStep == null) return occurrences; // RecurrencePeriod.none: one-off, not recurring.
    var cursor = bill.nextOccurrence;
    var guard = 0;
    while (!cursor.isBefore(effectiveStart) && guard < 5000) {
      cursor = _addDays(cursor, -dayStep);
      guard++;
    }
    cursor = _addDays(cursor, dayStep);
    guard = 0;
    while (!cursor.isAfter(rangeEnd) && guard < 5000) {
      occurrences.add(cursor);
      cursor = _addDays(cursor, dayStep);
      guard++;
    }
    return occurrences;
  }

  /// Month step for periods whose interval is fixed by the period itself.
  /// [RecurrencePeriod.inXDays]/[inXMonths]/[everyXDays]/[everyXMonths] are
  /// deliberately absent here - the "in X" ones are always exactly 2 shots
  /// (handled directly in [_occurrencesInRange]/[_advanceSchedule]), and
  /// "every X" needs the bill's own NUMOCCURRENCES for its interval, so it
  /// goes through [_monthStepForBill]/[_dayStepForBill] instead.
  int? _monthStepForPeriod(RecurrencePeriod period) {
    switch (period) {
      case RecurrencePeriod.monthly:
      case RecurrencePeriod.monthlyLastDay:
      case RecurrencePeriod.monthlyLastBusinessDay:
        return 1;
      case RecurrencePeriod.biMonthly:
        return 2;
      case RecurrencePeriod.quarterly:
        return 3;
      case RecurrencePeriod.halfYearly:
        return 6;
      case RecurrencePeriod.yearly:
        return 12;
      case RecurrencePeriod.fourMonths:
        return 4;
      default:
        return null;
    }
  }

  int? _dayStepForPeriod(RecurrencePeriod period) {
    switch (period) {
      case RecurrencePeriod.weekly:
        return 7;
      case RecurrencePeriod.biWeekly:
        return 14;
      case RecurrencePeriod.fourWeeks:
        return 28;
      case RecurrencePeriod.daily:
        return 1;
      default:
        return null;
    }
  }

  int? _monthStepForBill(BillDeposit bill) {
    if (bill.period == RecurrencePeriod.everyXMonths) {
      return bill.numOccurrences > 0 ? bill.numOccurrences : 1;
    }
    return _monthStepForPeriod(bill.period);
  }

  int? _dayStepForBill(BillDeposit bill) {
    if (bill.period == RecurrencePeriod.everyXDays) {
      return bill.numOccurrences > 0 ? bill.numOccurrences : 1;
    }
    return _dayStepForPeriod(bill.period);
  }

  DateTime _addMonths(DateTime date, int months) {
    final total = date.year * 12 + (date.month - 1) + months;
    final year = total ~/ 12;
    final month = total % 12 + 1;
    final lastDayOfMonth = DateTime(year, month + 1, 0).day;
    return DateTime(year, month, date.day > lastDayOfMonth ? lastDayOfMonth : date.day);
  }

  /// Steps [date] forward (or back, for negative [months]) by [months]
  /// calendar months, snapping the result onto the true last calendar day
  /// (and, for [RecurrencePeriod.monthlyLastBusinessDay], the last weekday)
  /// of the destination month when [period] calls for it - mirroring
  /// MMEX's own `Repeat::next_date` (`moneymanagerex/src/data/_Repeat.cpp`),
  /// which does this explicitly via `SetToLastMonthDay`/`SetToPrevWeekDay`
  /// rather than relying on [_addMonths]'s generic same-day-of-month clamp.
  /// Without this, a bill starting on, say, the 15th would drift to "15th
  /// of each month" instead of landing on each month's actual last
  /// (business) day.
  DateTime _stepMonths(DateTime date, int months, RecurrencePeriod period) {
    var next = _addMonths(date, months);
    if (period == RecurrencePeriod.monthlyLastDay ||
        period == RecurrencePeriod.monthlyLastBusinessDay) {
      next = _lastDayOfMonth(next);
      if (period == RecurrencePeriod.monthlyLastBusinessDay) {
        next = _lastBusinessDay(next);
      }
    }
    return next;
  }

  DateTime _lastDayOfMonth(DateTime date) => DateTime(date.year, date.month + 1, 0);

  DateTime _lastBusinessDay(DateTime date) {
    var d = date;
    while (d.weekday == DateTime.saturday || d.weekday == DateTime.sunday) {
      d = _addDays(d, -1);
    }
    return d;
  }

  // ---- Budgets ----------------------------------------------------

  List<BudgetYear> getBudgetYears() {
    final rows = db.query('SELECT * FROM BUDGETYEAR_V1 ORDER BY BUDGETYEARNAME DESC');
    return rows.map(BudgetYear.fromRow).toList();
  }

  List<BudgetEntry> getBudgetEntries(int budgetYearId) {
    final rows = db.query(
      'SELECT * FROM BUDGETTABLE_V1 WHERE BUDGETYEARID = ? AND ACTIVE = 1',
      [budgetYearId],
    );
    return rows.map(BudgetEntry.fromRow).toList();
  }

  void upsertBudgetEntry({
    int? id,
    required int budgetYearId,
    required int categoryId,
    required BudgetPeriod period,
    required double amount,
  }) {
    if (id != null) {
      db.execute(
        'UPDATE BUDGETTABLE_V1 SET PERIOD = ?, AMOUNT = ? WHERE BUDGETENTRYID = ?',
        [_periodToString(period), amount, id],
      );
    } else {
      db.execute(
        'INSERT INTO BUDGETTABLE_V1 (BUDGETYEARID, CATEGID, PERIOD, AMOUNT, ACTIVE) '
        'VALUES (?, ?, ?, ?, 1)',
        [budgetYearId, categoryId, _periodToString(period), amount],
      );
    }
  }

  // ---- Currencies ----------------------------------------------------

  CurrencyFormat? getCurrency(int currencyId) {
    final rows = db.query('SELECT * FROM CURRENCYFORMATS_V1 WHERE CURRENCYID = ?', [currencyId]);
    if (rows.isEmpty) return null;
    return CurrencyFormat.fromRow(rows.first);
  }

  CurrencyFormat? getBaseCurrency() {
    final infoRows = db.query("SELECT INFOVALUE FROM INFOTABLE_V1 WHERE INFONAME = 'BASECURRENCYID'");
    if (infoRows.isEmpty) return getDefaultCurrency();
    final id = int.tryParse(infoRows.first['INFOVALUE'] as String? ?? '');
    if (id == null) return getDefaultCurrency();
    return getCurrency(id) ?? getDefaultCurrency();
  }

  CurrencyFormat? getDefaultCurrency() {
    final rows = db.query('SELECT * FROM CURRENCYFORMATS_V1 LIMIT 1');
    if (rows.isEmpty) return null;
    return CurrencyFormat.fromRow(rows.first);
  }

  String _isoDate(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  /// The day *after* [date], for use as an exclusive upper bound. TRANSDATE
  /// is stored with a time suffix (e.g. "2026-07-25T00:00:00"), which sorts
  /// as greater than the bare date string "2026-07-25" in a text comparison
  /// - so `TRANSDATE <= '2026-07-25'` silently drops every transaction
  /// dated on the 25th itself. `TRANSDATE < isoDateExclusiveUpper(day)`
  /// avoids that entirely.
  String _isoDateExclusiveUpper(DateTime date) => _isoDate(_addDays(date, 1));

  String _periodToString(BudgetPeriod period) {
    switch (period) {
      case BudgetPeriod.weekly:
        return 'Weekly';
      case BudgetPeriod.biWeekly:
        return 'Bi-Weekly';
      case BudgetPeriod.monthly:
        return 'Monthly';
      case BudgetPeriod.quarterly:
        return 'Quarterly';
      case BudgetPeriod.halfYearly:
        return 'Half-Yearly';
      case BudgetPeriod.yearly:
        return 'Yearly';
      case BudgetPeriod.none:
        return 'None';
    }
  }
}

/// A single dated, labelled, signed occurrence of a recurring transaction -
/// see [MmexRepository.recurringOccurrencesInRange].
class RecurringOccurrence {
  final DateTime date;
  final String label;
  final double signedAmount;

  RecurringOccurrence({required this.date, required this.label, required this.signedAmount});
}

/// Result of walking a [BillDeposit]'s schedule forward - see
/// [MmexRepository._advanceSchedule].
class _ScheduleAdvance {
  final List<DateTime> occurrences;
  final DateTime? nextOccurrence; // null => template exhausted, delete it.
  final RecurrencePeriod period;
  final int numOccurrences;

  _ScheduleAdvance({
    required this.occurrences,
    required this.nextOccurrence,
    required this.period,
    required this.numOccurrences,
  });
}
