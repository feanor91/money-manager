import '../models/account.dart';
import '../models/bill_deposit.dart';
import '../models/budget.dart';
import '../models/category.dart';
import '../models/currency.dart';
import '../models/payee.dart';
import '../models/recurrence.dart';
import '../models/transaction.dart';
import 'mmex_database.dart';

/// Sentinel distinguishing "caller didn't pass this optional param" from
/// "caller explicitly passed null" - see [MmexRepository.upsertBudgetEnvelope].
const Object _unset = Object();

/// Typed CRUD access to an open MMEX database.
class MmexRepository {
  final MmexDatabase db;

  MmexRepository(this.db);

  /// Creates this app's own tables if they don't exist yet - kept
  /// separate from MMEX's own schema (prefixed APP_ so it's obviously not
  /// part of MMEX itself if the file is ever opened in real MMEX desktop).
  /// Called once whenever a database is opened (see DatabaseProvider);
  /// safe to call repeatedly, CREATE TABLE IF NOT EXISTS is a no-op once
  /// the table's already there.
  void ensureAppSchema() {
    db.execute('''
      CREATE TABLE IF NOT EXISTS APP_BUDGET_ENVELOPES (
        ENVELOPEID INTEGER PRIMARY KEY AUTOINCREMENT,
        ACCOUNTID INTEGER NOT NULL,
        CATEGID INTEGER NOT NULL,
        AMOUNT REAL NOT NULL,
        ACTIVE INTEGER NOT NULL DEFAULT 1,
        UNIQUE(ACCOUNTID, CATEGID)
      )
    ''');
    // MMEX's own NUMOCCURRENCES column counts *down* to zero as a limited
    // recurring bill fires (see catchUpBillDeposit) - it never records the
    // original total, so "3 restantes" alone can't say "out of how many".
    // This table remembers that original total the first time a bill gets
    // a limited duration, so the UI can show "3/12" instead.
    db.execute('''
      CREATE TABLE IF NOT EXISTS APP_BILL_OCCURRENCE_TOTALS (
        BILLID INTEGER PRIMARY KEY,
        TOTAL INTEGER NOT NULL
      )
    ''');
    // MMEX's CHECKINGACCOUNT_V1 has no column linking a real transaction
    // back to the recurring template it was generated from - this table
    // fills that gap so the ledger can show a "recurring" badge (and,
    // for limited-duration bills, "2/4") on transactions recorded via
    // recordBillOccurrence/catchUpBillDeposit. Only covers transactions
    // recorded from here on; existing history (or transactions a user
    // typed by hand even if they match a recurring pattern) is never
    // retroactively linked.
    db.execute('''
      CREATE TABLE IF NOT EXISTS APP_TRANSACTION_BILL_LINKS (
        TRANSID INTEGER PRIMARY KEY,
        BILLID INTEGER NOT NULL
      )
    ''');
    // Added after this table's first release - ALTER TABLE (not part of
    // the CREATE above) so databases that already have the old 2-column
    // version pick up the new ones too; harmless once they're already
    // there, since _tryAddColumn swallows the "duplicate column" error.
    _tryAddColumn('APP_TRANSACTION_BILL_LINKS', 'OCCURRENCE_INDEX', 'INTEGER');
    _tryAddColumn('APP_TRANSACTION_BILL_LINKS', 'OCCURRENCE_TOTAL', 'INTEGER');
    // Optional custom label for an envelope, distinct from its category's
    // own name - null means "use the category name" (the default when an
    // envelope is created, manually or via suggestions).
    _tryAddColumn('APP_BUDGET_ENVELOPES', 'NAME', 'TEXT');
    // A named, saveable "what if" budget - separate from the real
    // APP_BUDGET_ENVELOPES (never touched by these), so simulating doesn't
    // risk the actual budget. Several can exist per account; the user
    // creates/renames/deletes/recalls them freely (see BudgetScenario).
    db.execute('''
      CREATE TABLE IF NOT EXISTS APP_BUDGET_SCENARIOS (
        SCENARIOID INTEGER PRIMARY KEY AUTOINCREMENT,
        ACCOUNTID INTEGER NOT NULL,
        NAME TEXT NOT NULL,
        PERIOD_MONTHS INTEGER NOT NULL DEFAULT 12,
        CREATED_AT TEXT NOT NULL,
        UPDATED_AT TEXT NOT NULL
      )
    ''');
    // One simulated monthly amount per (scenario, category) - a category
    // with no row here yet simply hasn't been overridden, and the UI shows
    // the live historical average as its starting point instead.
    db.execute('''
      CREATE TABLE IF NOT EXISTS APP_BUDGET_SCENARIO_AMOUNTS (
        SCENARIOID INTEGER NOT NULL,
        CATEGID INTEGER NOT NULL,
        AMOUNT REAL NOT NULL,
        PRIMARY KEY (SCENARIOID, CATEGID)
      )
    ''');
    // Per-scenario override of whether a top-level category shows as a row -
    // no entry means "automatic" (visible iff categoriesUsedByAccount says
    // so, see _buildSimulationBody). VISIBLE=1 forces a row in even with no
    // real history yet (planning a brand new expense/income); VISIBLE=0
    // hides one that would otherwise show, without touching any saved
    // amount for it in APP_BUDGET_SCENARIO_AMOUNTS.
    db.execute('''
      CREATE TABLE IF NOT EXISTS APP_BUDGET_SCENARIO_CATEGORIES (
        SCENARIOID INTEGER NOT NULL,
        CATEGID INTEGER NOT NULL,
        VISIBLE INTEGER NOT NULL,
        PRIMARY KEY (SCENARIOID, CATEGID)
      )
    ''');
    // Null (the default) means "still a draft": every category without its
    // own saved amount keeps tracking the live suggested value (recurring
    // bill, else closed-month average - see _buildSimulationBody). Once
    // set, the scenario is "fixed" - every visible category is guaranteed a
    // row in APP_BUDGET_SCENARIO_AMOUNTS (see fixBudgetScenario) and none of
    // them auto-update anymore, only a manual edit changes them from here
    // on. The period selector keeps working either way - it's what drives
    // the "Réel" comparison window, not just the draft suggestion.
    _tryAddColumn('APP_BUDGET_SCENARIOS', 'FIXED_AT', 'TEXT');
    // 1 (the default, and the only possibility before this column existed -
    // every pre-existing row was created by a deliberate manual edit) means
    // the user themselves typed this value, via editAmount or the "add
    // category" flow - it survives a défixer. 0 means fixBudgetScenario
    // snapshotted it automatically from that category's live suggested
    // value purely to freeze it - unfixBudgetScenario deletes exactly the
    // 0-rows, so those categories resume live tracking.
    _tryAddColumn('APP_BUDGET_SCENARIO_AMOUNTS', 'MANUAL', 'INTEGER NOT NULL DEFAULT 1');
    // Budget-only categories that don't exist in CATEGORY_V1 at all - for
    // planning a spend/income that has no dedicated real category yet.
    // Referenced elsewhere (APP_BUDGET_SCENARIO_AMOUNTS.CATEGID,
    // APP_BUDGET_SCENARIO_CATEGORIES.CATEGID) as -VIRTUAL_ID, always
    // negative so it can never collide with a real (always positive)
    // CATEGID - see getVirtualBudgetCategories/createVirtualBudgetCategory.
    db.execute('''
      CREATE TABLE IF NOT EXISTS APP_BUDGET_SCENARIO_VIRTUAL_CATEGORIES (
        VIRTUAL_ID INTEGER PRIMARY KEY AUTOINCREMENT,
        SCENARIOID INTEGER NOT NULL,
        NAME TEXT NOT NULL
      )
    ''');
    // Null (the default, and the only possibility before this column
    // existed) means a top-level virtual category, same as before. A real
    // category's id means this virtual category is an artificial
    // subdivision nested under it instead - see VirtualBudgetCategory.
    _tryAddColumn('APP_BUDGET_SCENARIO_VIRTUAL_CATEGORIES', 'PARENT_CATEGID', 'INTEGER');
  }

  void _tryAddColumn(String table, String column, String type) {
    try {
      db.execute('ALTER TABLE $table ADD COLUMN $column $type');
    } catch (_) {
      // Column already exists - fine, that's the common case after the
      // first run.
    }
  }

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
  /// entries the user already entered for a known future expense/income) -
  /// this is deliberately also what the forecast chart/cards start their
  /// projection from (2026-08-03: previously capped at today for that use,
  /// but that silently hid an already-recorded future transaction from the
  /// projection instead of counting it, see forecastAccountBalance and
  /// ForecastChart._buildPoints). Pass [asOf] for a point-in-time answer
  /// instead - "what was/will my balance be as of that day" (e.g. the
  /// natural-language query feature's "solde" questions) - capping at
  /// transactions dated on or before it.
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

  void renameCategory(int categoryId, String newName) {
    db.execute(
      'UPDATE CATEGORY_V1 SET CATEGNAME = ? WHERE CATEGID = ?',
      [newName, categoryId],
    );
  }

  /// Reparents a subcategory under a different top-level category (or, if
  /// [newParentId] is null, promotes it to top-level itself). Every
  /// transaction/bill/budget/payee already pointing at this category keeps
  /// pointing at the same CATEGID, so they move along with it automatically
  /// - only which parent it's nested under changes.
  void moveCategory(int categoryId, int? newParentId) {
    db.execute(
      'UPDATE CATEGORY_V1 SET PARENTID = ? WHERE CATEGID = ?',
      [newParentId ?? -1, categoryId],
    );
  }

  /// Toggles a category between active and archived (MMEX's ACTIVE flag):
  /// an archived category is hidden from pickers and this screen's default
  /// view, but its existing transactions/history are untouched - the safe
  /// alternative to deleting when [categoryInUse] blocks a hard delete.
  void setCategoryActive(int categoryId, bool active) {
    db.execute(
      'UPDATE CATEGORY_V1 SET ACTIVE = ? WHERE CATEGID = ?',
      [active ? 1 : 0, categoryId],
    );
  }

  /// Everything that would block a hard [deleteCategory] call: any
  /// subcategory still under it, or any row elsewhere that still points at
  /// it. Checked up front so the UI can explain *why* delete is disabled
  /// instead of just failing (a foreign key isn't actually enforced by the
  /// .mmb schema, so deleteCategory itself wouldn't fail - it would just
  /// silently orphan those rows, which is the thing this method exists to
  /// prevent the UI from ever doing).
  CategoryUsage categoryUsage(int categoryId) {
    final children = db.query(
      'SELECT COUNT(*) AS n FROM CATEGORY_V1 WHERE PARENTID = ?',
      [categoryId],
    );
    final transactions = db.query(
      'SELECT COUNT(*) AS n FROM CHECKINGACCOUNT_V1 WHERE CATEGID = ?',
      [categoryId],
    );
    final bills = db.query(
      'SELECT COUNT(*) AS n FROM BILLSDEPOSITS_V1 WHERE CATEGID = ?',
      [categoryId],
    );
    final budgets = db.query(
      'SELECT COUNT(*) AS n FROM BUDGETTABLE_V1 WHERE CATEGID = ?',
      [categoryId],
    );
    final payees = db.query(
      'SELECT COUNT(*) AS n FROM PAYEE_V1 WHERE CATEGID = ?',
      [categoryId],
    );
    int count(List<Map<String, Object?>> rows) => (rows.first['n'] as int?) ?? 0;
    return CategoryUsage(
      childCategoryCount: count(children),
      transactionCount: count(transactions),
      recurringCount: count(bills),
      budgetEntryCount: count(budgets),
      payeeDefaultCount: count(payees),
    );
  }

  void deleteCategory(int categoryId) {
    db.execute('DELETE FROM CATEGORY_V1 WHERE CATEGID = ?', [categoryId]);
  }

  /// Merges [fromId] into [toId]: every transaction, recurring bill, payee
  /// default category, and budget entry pointing at [fromId] is repointed
  /// to [toId], then [fromId] is deleted. Only meant for leaf categories
  /// (see [CategoryUsage.childCategoryCount]) - the caller should keep a
  /// category with subcategories out of the merge target picker, since
  /// there's no single sensible answer for what should happen to its
  /// children otherwise.
  void mergeCategories({required int fromId, required int toId}) {
    if (fromId == toId) return;
    db.transaction(() {
      db.execute(
        'UPDATE CHECKINGACCOUNT_V1 SET CATEGID = ? WHERE CATEGID = ?',
        [toId, fromId],
      );
      db.execute(
        'UPDATE BILLSDEPOSITS_V1 SET CATEGID = ? WHERE CATEGID = ?',
        [toId, fromId],
      );
      db.execute(
        'UPDATE PAYEE_V1 SET CATEGID = ? WHERE CATEGID = ?',
        [toId, fromId],
      );
      // One budget entry per (year, category) - if the target already has
      // one for a year the source also has, keep the target's and drop the
      // source's instead of ending up with two rows for the same category.
      final conflicting = db.query(
        'SELECT s.BUDGETENTRYID AS id FROM BUDGETTABLE_V1 s '
        'WHERE s.CATEGID = ? AND EXISTS ('
        '  SELECT 1 FROM BUDGETTABLE_V1 t '
        '  WHERE t.CATEGID = ? AND t.BUDGETYEARID = s.BUDGETYEARID'
        ')',
        [fromId, toId],
      );
      for (final row in conflicting) {
        db.execute('DELETE FROM BUDGETTABLE_V1 WHERE BUDGETENTRYID = ?', [row['id']]);
      }
      db.execute(
        'UPDATE BUDGETTABLE_V1 SET CATEGID = ? WHERE CATEGID = ?',
        [toId, fromId],
      );
      db.execute('DELETE FROM CATEGORY_V1 WHERE CATEGID = ?', [fromId]);
    });
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

  /// Earliest/latest transaction year touching [accountId] - a single cheap
  /// SQL `MIN`/`MAX`, not a full history walk. Used to bound the ledger's
  /// year picker to years that actually have something in them, rather than
  /// a hardcoded range that's either too short (an older account) or full
  /// of empty years (a newer one). Null if the account has no transactions
  /// at all yet.
  ({int min, int max})? transactionYearRange(int accountId) {
    final row = db.query(
      'SELECT MIN(TRANSDATE) AS minDate, MAX(TRANSDATE) AS maxDate FROM CHECKINGACCOUNT_V1 '
      "WHERE (ACCOUNTID = ? OR TOACCOUNTID = ?) AND (DELETEDTIME IS NULL OR DELETEDTIME = '')",
      [accountId, accountId],
    ).first;
    final minYear = DateTime.tryParse(row['minDate'] as String? ?? '')?.year;
    final maxYear = DateTime.tryParse(row['maxDate'] as String? ?? '')?.year;
    if (minYear == null || maxYear == null) return null;
    return (min: minYear, max: maxYear);
  }

  /// Every transaction touching [accountId] within [from, to) (either or
  /// both may be omitted for "since the beginning"/"through the latest"),
  /// each paired with the running account balance immediately after it -
  /// the same "Solde" column MMEX's own ledger view shows. [to] is an
  /// *exclusive* upper bound (the first day NOT included) - for "the whole
  /// month of March" pass `from: DateTime(y, 3)`, `to: DateTime(y, 4)`.
  ///
  /// The balance just before [from] is computed with a single SQL `SUM`
  /// instead of walking every prior transaction into a Dart object one by
  /// one - confirmed 2026-07-31 that the latter (this method's previous
  /// design: always walk *every* transaction ever recorded for the account,
  /// regardless of how many were actually going to be shown) could freeze
  /// the tab once an account had years of history. Callers (see
  /// transactions_screen.dart) are expected to pass a bounded window - e.g.
  /// one month - rather than relying on this method to stay cheap with no
  /// bounds at all; passing neither [from] nor [to] still works but is
  /// exactly as expensive as before.
  List<TransactionWithBalance> getTransactionsWithRunningBalance(
    int accountId, {
    DateTime? from,
    DateTime? to,
  }) {
    final accountRows = db.query('SELECT INITIALBAL FROM ACCOUNTLIST_V1 WHERE ACCOUNTID = ?', [accountId]);
    var running = (accountRows.isEmpty ? 0 : accountRows.first['INITIALBAL'] as num?)?.toDouble() ?? 0;

    if (from != null) {
      // Mirrors MoneyTransaction.signedAmountFor's sign rules exactly (see
      // its doc comment) - kept in sync with that if those rules ever
      // change. Voided transactions never affect the balance, same as MMEX.
      final priorSumRow = db.query(
        '''
        SELECT SUM(
          CASE
            WHEN UPPER(TRIM(STATUS)) = 'V' THEN 0
            WHEN TRANSCODE = 'Transfer' AND TOACCOUNTID = ? THEN TOTRANSAMOUNT
            WHEN TRANSCODE = 'Transfer' THEN -TRANSAMOUNT
            WHEN TRANSCODE = 'Deposit' THEN TRANSAMOUNT
            ELSE -TRANSAMOUNT
          END
        ) AS priorSum
        FROM CHECKINGACCOUNT_V1
        WHERE (ACCOUNTID = ? OR TOACCOUNTID = ?) AND (DELETEDTIME IS NULL OR DELETEDTIME = '')
          AND TRANSDATE < ?
        ''',
        [accountId, accountId, accountId, _isoDate(from)],
      );
      running += (priorSumRow.first['priorSum'] as num?)?.toDouble() ?? 0;
    }

    final where = <String>[
      '(ACCOUNTID = ? OR TOACCOUNTID = ?)',
      "(DELETEDTIME IS NULL OR DELETEDTIME = '')",
    ];
    final params = <Object?>[accountId, accountId];
    if (from != null) {
      where.add('TRANSDATE >= ?');
      params.add(_isoDate(from));
    }
    if (to != null) {
      where.add('TRANSDATE < ?');
      params.add(_isoDate(to));
    }

    final rows = db.query(
      'SELECT * FROM CHECKINGACCOUNT_V1 WHERE ${where.join(' AND ')} '
      'ORDER BY TRANSDATE ASC, TRANSID ASC',
      params,
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
    return withBalance.reversed.toList();
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
    db.execute('DELETE FROM APP_TRANSACTION_BILL_LINKS WHERE TRANSID = ?', [transId]);
  }

  /// How many real ledger transactions share [payeeId] and [categoryId] -
  /// "identical" for the purposes of a bulk category reassignment (see
  /// [bulkReassignTransactionCategory]): same payee and same current
  /// category, regardless of account or amount - a payee's category is
  /// normally stable across both (groceries vary in amount every time but
  /// stay the same category; the same payee can pay from more than one of
  /// the user's own accounts).
  int countTransactionsMatching({required int payeeId, required int categoryId}) {
    final rows = db.query(
      'SELECT COUNT(*) AS c FROM CHECKINGACCOUNT_V1 WHERE PAYEEID = ? AND CATEGID = ? '
      "AND UPPER(TRIM(STATUS)) != 'V' AND (DELETEDTIME IS NULL OR DELETEDTIME = '')",
      [payeeId, categoryId],
    );
    return rows.first['c'] as int;
  }

  /// Reassigns every real ledger transaction matching [payeeId] and
  /// [oldCategoryId] to [newCategoryId] at once - see
  /// [countTransactionsMatching] for what "matching" means. Offered after
  /// changing a single transaction's category (or a recurring bill's -
  /// bills live in a separate table, but this always sweeps the ledger)
  /// to fix every other occurrence of the same mistake in one go.
  void bulkReassignTransactionCategory({
    required int payeeId,
    required int oldCategoryId,
    required int newCategoryId,
  }) {
    db.execute(
      'UPDATE CHECKINGACCOUNT_V1 SET CATEGID = ? WHERE PAYEEID = ? AND CATEGID = ? '
      "AND UPPER(TRIM(STATUS)) != 'V' AND (DELETEDTIME IS NULL OR DELETEDTIME = '')",
      [newCategoryId, payeeId, oldCategoryId],
    );
  }

  /// Transfer counterpart to [countTransactionsMatching] - a transfer has
  /// no meaningful payee in this app (PAYEEID is always forced to -1, see
  /// TransactionEditorSheet/RecurringEditorSheet's own _save), so the
  /// (source, destination) account pair plays the role a payee normally
  /// would for identifying "the same recurring transfer" across months.
  int countTransfersMatching({
    required int accountId,
    required int toAccountId,
    required int categoryId,
  }) {
    final rows = db.query(
      'SELECT COUNT(*) AS c FROM CHECKINGACCOUNT_V1 WHERE ACCOUNTID = ? AND TOACCOUNTID = ? '
      "AND CATEGID = ? AND TRANSCODE = 'Transfer' AND UPPER(TRIM(STATUS)) != 'V' "
      "AND (DELETEDTIME IS NULL OR DELETEDTIME = '')",
      [accountId, toAccountId, categoryId],
    );
    return rows.first['c'] as int;
  }

  /// Reassigns every real ledger transfer matching [accountId],
  /// [toAccountId] and [oldCategoryId] to [newCategoryId] at once - see
  /// [countTransfersMatching].
  void bulkReassignTransferCategory({
    required int accountId,
    required int toAccountId,
    required int oldCategoryId,
    required int newCategoryId,
  }) {
    db.execute(
      'UPDATE CHECKINGACCOUNT_V1 SET CATEGID = ? WHERE ACCOUNTID = ? AND TOACCOUNTID = ? '
      "AND CATEGID = ? AND TRANSCODE = 'Transfer' AND UPPER(TRIM(STATUS)) != 'V' "
      "AND (DELETEDTIME IS NULL OR DELETEDTIME = '')",
      [newCategoryId, accountId, toAccountId, oldCategoryId],
    );
  }

  /// Links [transId] back to bill [billId] it was just recorded from, along
  /// with its place in a limited-duration bill's fixed sequence (e.g. the
  /// 1st of 4) when known - see [recordBillOccurrence]/[catchUpBillDeposit]
  /// for how [occurrenceIndex]/[occurrenceTotal] are worked out, since the
  /// bill's own remaining count keeps moving as further occurrences fire
  /// and (for a multi-occurrence catch-up) can't just be read once.
  void _linkTransactionToBill(
    int transId,
    int billId, {
    required int? occurrenceIndex,
    required int? occurrenceTotal,
  }) {
    db.execute(
      'INSERT OR REPLACE INTO APP_TRANSACTION_BILL_LINKS '
      '(TRANSID, BILLID, OCCURRENCE_INDEX, OCCURRENCE_TOTAL) VALUES (?, ?, ?, ?)',
      [transId, billId, occurrenceIndex, occurrenceTotal],
    );
  }

  /// Ids of transactions recorded from a recurring template (see
  /// [recordBillOccurrence]/[catchUpBillDeposit]) - used to badge them in
  /// the ledger. See [APP_TRANSACTION_BILL_LINKS] in [ensureAppSchema] for
  /// why this can't just be read off the transaction itself.
  Set<int> recurringTransactionIds() {
    final rows = db.query('SELECT TRANSID FROM APP_TRANSACTION_BILL_LINKS');
    return {for (final row in rows) row['TRANSID'] as int};
  }

  /// This transaction's place in its recurring template's fixed sequence
  /// (e.g. "the 2nd of 4") - only present for limited-duration bills whose
  /// original total was known at the time this transaction was recorded
  /// (see [_linkTransactionToBill]). Null for everything else: unlimited
  /// recurring bills, "every X .../dans X ..." interval periods, or
  /// transactions recorded before this feature existed.
  Map<int, ({int index, int total})> recurringTransactionOccurrences() {
    final rows = db.query(
      'SELECT TRANSID, OCCURRENCE_INDEX, OCCURRENCE_TOTAL FROM APP_TRANSACTION_BILL_LINKS '
      'WHERE OCCURRENCE_INDEX IS NOT NULL AND OCCURRENCE_TOTAL IS NOT NULL',
    );
    return {
      for (final row in rows)
        row['TRANSID'] as int: (
          index: row['OCCURRENCE_INDEX'] as int,
          total: row['OCCURRENCE_TOTAL'] as int,
        ),
    };
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

  /// Net signed total *per category* from known recurring bills whose
  /// occurrence(s) fall within [start, end] (both inclusive, matching
  /// [_occurrencesInRange]'s own convention) - like [recurringDailyNet] but
  /// bucketed by category instead of by day, so a "why" answer (see
  /// QueryKind.outlook) can name *which* recurring bills drive a projected
  /// change instead of just a day-by-day total. A bill with no category set
  /// is dropped - nothing to attribute it to.
  Map<int, double> recurringCategoryNet({
    required DateTime start,
    required DateTime end,
    int? accountId,
  }) {
    final result = <int, double>{};
    for (final bill in getBillDeposits()) {
      if (bill.paused) continue;
      final involvesAccount = accountId == null ||
          bill.accountId == accountId ||
          bill.toAccountId == accountId;
      if (!involvesAccount) continue;
      if (accountId == null && bill.transCode == TransCode.transfer) continue;
      final categoryId = bill.categoryId;
      if (categoryId == null) continue;

      final occurrenceCount = _occurrencesInRange(bill, start, end).length;
      if (occurrenceCount == 0) continue;
      final signedAmount = _billSignedAmount(bill, accountId);
      result[categoryId] = (result[categoryId] ?? 0) + signedAmount * occurrenceCount;
    }
    return result;
  }

  /// Projects [accountId]'s balance forward from today to [targetDate]
  /// using only known recurring transactions (see [recurringDailyNet]) -
  /// the same mechanical projection the forecast chart uses, collapsed to a
  /// single final figure. Returns the plain current balance if [targetDate]
  /// isn't in the future.
  ///
  /// Starts from the same all-transactions total [accountBalance] returns
  /// with no [accountBalance.asOf] - deliberately including anything already
  /// entered with a future date - not a same-day cap: recording a recurring
  /// bill's occurrence always advances its own next-occurrence date past
  /// it (see [recordBillOccurrence]/[catchUpBillDeposit]), so an
  /// already-recorded postdated entry can never also get re-projected here.
  double forecastAccountBalance(int accountId, DateTime targetDate) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(targetDate.year, targetDate.month, targetDate.day);
    final balance = accountBalance(accountId);
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
          : (payees[bill.payeeId]?.name ?? 'Payé inconnu');

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
    return categorySpendForPeriod(start, end, accountId: accountId);
  }

  /// Same as [categorySpendForMonth] but over an arbitrary [start, end)
  /// window instead of a fixed calendar month - e.g. a budget window that
  /// starts mid-month, see BudgetScreen and models/budget_period.dart.
  Map<int, double> categorySpendForPeriod(DateTime start, DateTime end, {int? accountId}) {
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

  /// Same idea as [categorySpendForPeriod] but for a single payee instead
  /// of every category - "combien j'ai dépensé chez X" (natural-language
  /// query feature). Withdrawals only, same exclusions (voided, deleted).
  double payeeSpendForPeriod(int payeeId, DateTime start, DateTime end, {int? accountId}) {
    final where = <String>[
      "TRANSDATE >= ?",
      "TRANSDATE < ?",
      "TRANSCODE = 'Withdrawal'",
      "PAYEEID = ?",
      "UPPER(TRIM(STATUS)) != 'V'",
      "(DELETEDTIME IS NULL OR DELETEDTIME = '')",
    ];
    final params = <Object?>[_isoDate(start), _isoDate(end), payeeId];
    if (accountId != null) {
      where.add('ACCOUNTID = ?');
      params.add(accountId);
    }
    final rows = db.query(
      'SELECT TRANSAMOUNT FROM CHECKINGACCOUNT_V1 WHERE ${where.join(' AND ')}',
      params,
    );
    var total = 0.0;
    for (final row in rows) {
      total += (row['TRANSAMOUNT'] as num?)?.toDouble() ?? 0;
    }
    return total;
  }

  /// Individual withdrawals within [start, end) tagged with any of
  /// [categoryIds] - detail behind a single-category natural-language
  /// answer ("combien j'ai dépensé en Alimentation"), biggest first. Pass
  /// the category itself plus its direct children (see [rolledUpSpend])
  /// so a parent-category question's detail also picks up transactions
  /// recorded against a subcategory. Same exclusions as
  /// [categorySpendForPeriod].
  List<MoneyTransaction> transactionsForCategories(
    List<int> categoryIds,
    DateTime start,
    DateTime end, {
    int? accountId,
    int limit = 5,
  }) {
    if (categoryIds.isEmpty) return const [];
    final where = <String>[
      "TRANSDATE >= ?",
      "TRANSDATE < ?",
      "TRANSCODE = 'Withdrawal'",
      "CATEGID IN (${categoryIds.map((_) => '?').join(',')})",
      "UPPER(TRIM(STATUS)) != 'V'",
      "(DELETEDTIME IS NULL OR DELETEDTIME = '')",
    ];
    final params = <Object?>[_isoDate(start), _isoDate(end), ...categoryIds];
    if (accountId != null) {
      where.add('ACCOUNTID = ?');
      params.add(accountId);
    }
    final rows = db.query(
      'SELECT * FROM CHECKINGACCOUNT_V1 WHERE ${where.join(' AND ')} '
      'ORDER BY TRANSAMOUNT DESC LIMIT ?',
      [...params, limit],
    );
    return rows.map(MoneyTransaction.fromRow).toList();
  }

  /// Individual withdrawals at [payeeId] within [start, end) - detail
  /// behind "combien j'ai dépensé chez X" (natural-language query
  /// feature), biggest first. Same exclusions as [payeeSpendForPeriod].
  List<MoneyTransaction> transactionsForPayee(
    int payeeId,
    DateTime start,
    DateTime end, {
    int? accountId,
    int limit = 5,
  }) {
    final where = <String>[
      "TRANSDATE >= ?",
      "TRANSDATE < ?",
      "TRANSCODE = 'Withdrawal'",
      "PAYEEID = ?",
      "UPPER(TRIM(STATUS)) != 'V'",
      "(DELETEDTIME IS NULL OR DELETEDTIME = '')",
    ];
    final params = <Object?>[_isoDate(start), _isoDate(end), payeeId];
    if (accountId != null) {
      where.add('ACCOUNTID = ?');
      params.add(accountId);
    }
    final rows = db.query(
      'SELECT * FROM CHECKINGACCOUNT_V1 WHERE ${where.join(' AND ')} '
      'ORDER BY TRANSAMOUNT DESC LIMIT ?',
      [...params, limit],
    );
    return rows.map(MoneyTransaction.fromRow).toList();
  }

  /// Most recent withdrawal date per category within [start, end) for
  /// [accountId] - used to flag a history-based budget suggestion whose
  /// evidence is stale (see BudgetScreen's suggestions dialog): a category
  /// that hasn't seen a real transaction in months is a weaker basis for
  /// "budget this much every month" than one spent in recently.
  Map<int, DateTime> lastSpendDatePerCategory(DateTime start, DateTime end, {int? accountId}) {
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
      'SELECT CATEGID, MAX(TRANSDATE) AS lastDate FROM CHECKINGACCOUNT_V1 '
      'WHERE ${where.join(' AND ')} GROUP BY CATEGID',
      params,
    );
    final result = <int, DateTime>{};
    for (final row in rows) {
      final categId = row['CATEGID'] as int?;
      final dateStr = row['lastDate'] as String?;
      if (categId == null || dateStr == null) continue;
      final date = DateTime.tryParse(dateStr);
      if (date != null) result[categId] = date;
    }
    return result;
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
    db.execute('DELETE FROM APP_BILL_OCCURRENCE_TOTALS WHERE BILLID = ?', [bdId]);
  }

  /// Remembers [total] as the original occurrence count for [billId] the
  /// first time it gets a limited duration - a no-op if one's already
  /// recorded, so later edits to the remaining count (which is all
  /// [BillDeposit.numOccurrences] tracks) don't overwrite the original
  /// total. See [ensureAppSchema].
  void ensureBillOccurrenceTotal(int billId, int total) {
    db.execute(
      'INSERT OR IGNORE INTO APP_BILL_OCCURRENCE_TOTALS (BILLID, TOTAL) VALUES (?, ?)',
      [billId, total],
    );
  }

  /// Original occurrence totals recorded via [ensureBillOccurrenceTotal],
  /// keyed by bill id - only present for bills that have had a limited
  /// duration since this feature was added.
  Map<int, int> billOccurrenceTotals() {
    final rows = db.query('SELECT BILLID, TOTAL FROM APP_BILL_OCCURRENCE_TOTALS');
    return {
      for (final row in rows) row['BILLID'] as int: row['TOTAL'] as int,
    };
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
    final total = billOccurrenceTotals()[bill.id];
    final hasFixedCount = !periodUsesXParam(bill.period) && bill.numOccurrences >= 0;
    _linkTransactionToBill(
      transId,
      bill.id,
      occurrenceIndex: (hasFixedCount && total != null) ? total - bill.numOccurrences + 1 : null,
      occurrenceTotal: hasFixedCount ? total : null,
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
    final total = billOccurrenceTotals()[bill.id];
    final hasFixedCount = !periodUsesXParam(bill.period) && bill.numOccurrences >= 0;
    // Catching up several missed occurrences in one call still assigns
    // each a distinct, increasing index (1st, 2nd, ...) - bill.numOccurrences
    // itself only updates once at the end (see _applyScheduleAdvance
    // below), so it can't be re-read per iteration the way
    // recordBillOccurrence does for a single occurrence.
    var remaining = bill.numOccurrences;
    for (final occurrence in advance.occurrences) {
      final transId = insertTransaction(
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
      );
      _linkTransactionToBill(
        transId,
        bill.id,
        occurrenceIndex: (hasFixedCount && total != null) ? total - remaining + 1 : null,
        occurrenceTotal: hasFixedCount ? total : null,
      );
      if (hasFixedCount) remaining--;
      ids.add(transId);
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

  // ---- Budget envelopes (this app's own table, not MMEX's schema) ----
  //
  // MMEX's own budgeting model (BudgetYear/BudgetEntry above) is
  // year/period-based and has no per-account column - this app's own
  // simplified budget (BudgetScreen: one envelope per account+category,
  // always a constant monthly amount) doesn't fit that shape, so it's
  // backed by its own dedicated table instead (see [ensureAppSchema]).

  List<BudgetEnvelope> getBudgetEnvelopes(int accountId) {
    final rows = db.query(
      'SELECT * FROM APP_BUDGET_ENVELOPES WHERE ACCOUNTID = ? AND ACTIVE = 1',
      [accountId],
    );
    return rows.map(BudgetEnvelope.fromRow).toList();
  }

  void upsertBudgetEnvelope({
    int? id,
    required int accountId,
    required int categoryId,
    required double amount,
    Object? name = _unset,
  }) {
    if (id != null) {
      if (identical(name, _unset)) {
        db.execute('UPDATE APP_BUDGET_ENVELOPES SET AMOUNT = ? WHERE ENVELOPEID = ?', [amount, id]);
      } else {
        db.execute(
          'UPDATE APP_BUDGET_ENVELOPES SET AMOUNT = ?, NAME = ? WHERE ENVELOPEID = ?',
          [amount, name, id],
        );
      }
    } else {
      // ON CONFLICT covers the (rare, but possible via the suggestions
      // dialog racing a manual add) case of already having an envelope
      // for this exact account+category - update it in place instead of
      // erroring on the UNIQUE constraint.
      db.execute(
        'INSERT INTO APP_BUDGET_ENVELOPES (ACCOUNTID, CATEGID, AMOUNT, ACTIVE) VALUES (?, ?, ?, 1) '
        'ON CONFLICT(ACCOUNTID, CATEGID) DO UPDATE SET AMOUNT = excluded.AMOUNT, ACTIVE = 1',
        [accountId, categoryId, amount],
      );
    }
  }

  void deleteBudgetEnvelope(int id) {
    db.execute('DELETE FROM APP_BUDGET_ENVELOPES WHERE ENVELOPEID = ?', [id]);
  }

  /// Wipes every envelope for [accountId] only - other accounts' budgets
  /// are untouched, since envelopes are scoped per account (see
  /// getBudgetEnvelopes).
  void resetBudgetEnvelopes(int accountId) {
    db.execute('DELETE FROM APP_BUDGET_ENVELOPES WHERE ACCOUNTID = ?', [accountId]);
  }

  // ---- Budget scenarios (named "what if" simulations, this app's own
  // tables - never touches APP_BUDGET_ENVELOPES or MMEX's own schema) ----

  List<BudgetScenario> getBudgetScenarios(int accountId) {
    final rows = db.query(
      'SELECT * FROM APP_BUDGET_SCENARIOS WHERE ACCOUNTID = ? ORDER BY UPDATED_AT DESC',
      [accountId],
    );
    return rows.map(BudgetScenario.fromRow).toList();
  }

  int createBudgetScenario({
    required int accountId,
    required String name,
    int periodMonths = 12,
  }) {
    final now = DateTime.now().toIso8601String();
    return db.execute(
      'INSERT INTO APP_BUDGET_SCENARIOS (ACCOUNTID, NAME, PERIOD_MONTHS, CREATED_AT, UPDATED_AT) '
      'VALUES (?, ?, ?, ?, ?)',
      [accountId, name, periodMonths, now, now],
    );
  }

  void renameBudgetScenario(int scenarioId, String name) {
    db.execute(
      'UPDATE APP_BUDGET_SCENARIOS SET NAME = ?, UPDATED_AT = ? WHERE SCENARIOID = ?',
      [name, DateTime.now().toIso8601String(), scenarioId],
    );
  }

  void setBudgetScenarioPeriodMonths(int scenarioId, int months) {
    db.execute(
      'UPDATE APP_BUDGET_SCENARIOS SET PERIOD_MONTHS = ?, UPDATED_AT = ? WHERE SCENARIOID = ?',
      [months, DateTime.now().toIso8601String(), scenarioId],
    );
  }

  /// Deletes [scenarioId] and every simulated amount saved under it - other
  /// scenarios (and the real APP_BUDGET_ENVELOPES budget) are untouched.
  void deleteBudgetScenario(int scenarioId) {
    db.execute('DELETE FROM APP_BUDGET_SCENARIO_AMOUNTS WHERE SCENARIOID = ?', [scenarioId]);
    db.execute('DELETE FROM APP_BUDGET_SCENARIO_CATEGORIES WHERE SCENARIOID = ?', [scenarioId]);
    db.execute('DELETE FROM APP_BUDGET_SCENARIO_VIRTUAL_CATEGORIES WHERE SCENARIOID = ?', [scenarioId]);
    db.execute('DELETE FROM APP_BUDGET_SCENARIOS WHERE SCENARIOID = ?', [scenarioId]);
  }

  /// categoryId -> simulated monthly amount saved under [scenarioId] - a
  /// category missing from this map simply has no override yet; the UI
  /// falls back to the live historical average as its starting point
  /// (see [categoryNetTotalsForPeriod]) rather than showing zero.
  Map<int, double> getBudgetScenarioAmounts(int scenarioId) {
    final rows = db.query(
      'SELECT CATEGID, AMOUNT FROM APP_BUDGET_SCENARIO_AMOUNTS WHERE SCENARIOID = ?',
      [scenarioId],
    );
    return {for (final row in rows) row['CATEGID'] as int: (row['AMOUNT'] as num).toDouble()};
  }

  /// Always saved as MANUAL=1 - this is only ever called from a deliberate
  /// user edit (editAmount, or entering an amount for a newly-added
  /// category), so it must survive a défixer even if the scenario is fixed
  /// right now (see [fixBudgetScenario]/[unfixBudgetScenario]).
  void upsertBudgetScenarioAmount({
    required int scenarioId,
    required int categoryId,
    required double amount,
  }) {
    db.execute(
      'INSERT INTO APP_BUDGET_SCENARIO_AMOUNTS (SCENARIOID, CATEGID, AMOUNT, MANUAL) '
      'VALUES (?, ?, ?, 1) '
      'ON CONFLICT(SCENARIOID, CATEGID) DO UPDATE SET AMOUNT = excluded.AMOUNT, MANUAL = 1',
      [scenarioId, categoryId, amount],
    );
    db.execute(
      'UPDATE APP_BUDGET_SCENARIOS SET UPDATED_AT = ? WHERE SCENARIOID = ?',
      [DateTime.now().toIso8601String(), scenarioId],
    );
  }

  /// Locks in [currentValues] (categoryId -> whatever _buildSimulationBody
  /// is showing as its simulated amount right now, live-suggested or
  /// already-manual alike) as of this moment: any category in there with no
  /// saved row yet gets one, tagged MANUAL=0 since it's an automatic
  /// snapshot, not something the user typed - a category that already has a
  /// row (MANUAL=0 or 1) is left exactly as-is. Then stamps FIXED_AT so
  /// _buildSimulationBody stops falling back to the live suggestion for
  /// every category from here on (see [BudgetScenario.isFixed]).
  void fixBudgetScenario(int scenarioId, Map<int, double> currentValues) {
    final existing = getBudgetScenarioAmounts(scenarioId).keys.toSet();
    for (final entry in currentValues.entries) {
      if (existing.contains(entry.key)) continue;
      db.execute(
        'INSERT INTO APP_BUDGET_SCENARIO_AMOUNTS (SCENARIOID, CATEGID, AMOUNT, MANUAL) '
        'VALUES (?, ?, ?, 0)',
        [scenarioId, entry.key, entry.value],
      );
    }
    db.execute(
      'UPDATE APP_BUDGET_SCENARIOS SET FIXED_AT = ?, UPDATED_AT = ? WHERE SCENARIOID = ?',
      [DateTime.now().toIso8601String(), DateTime.now().toIso8601String(), scenarioId],
    );
  }

  /// Reverts to draft: deletes every auto-snapshotted (MANUAL=0) amount so
  /// those categories resume live tracking, and clears FIXED_AT. Amounts
  /// the user actually typed (MANUAL=1) are untouched.
  void unfixBudgetScenario(int scenarioId) {
    db.execute(
      'DELETE FROM APP_BUDGET_SCENARIO_AMOUNTS WHERE SCENARIOID = ? AND MANUAL = 0',
      [scenarioId],
    );
    db.execute(
      'UPDATE APP_BUDGET_SCENARIOS SET FIXED_AT = NULL, UPDATED_AT = ? WHERE SCENARIOID = ?',
      [DateTime.now().toIso8601String(), scenarioId],
    );
  }

  /// Removes a single category's override, reverting it to tracking the
  /// live historical average again (see [getBudgetScenarioAmounts]).
  void deleteBudgetScenarioAmount(int scenarioId, int categoryId) {
    db.execute(
      'DELETE FROM APP_BUDGET_SCENARIO_AMOUNTS WHERE SCENARIOID = ? AND CATEGID = ?',
      [scenarioId, categoryId],
    );
  }

  /// categoryId -> explicit visibility override for [scenarioId] - a
  /// category missing from this map just follows the automatic default in
  /// _buildSimulationBody (see APP_BUDGET_SCENARIO_CATEGORIES).
  Map<int, bool> getBudgetScenarioCategoryOverrides(int scenarioId) {
    final rows = db.query(
      'SELECT CATEGID, VISIBLE FROM APP_BUDGET_SCENARIO_CATEGORIES WHERE SCENARIOID = ?',
      [scenarioId],
    );
    return {for (final row in rows) row['CATEGID'] as int: (row['VISIBLE'] as int) == 1};
  }

  void setBudgetScenarioCategoryVisible(int scenarioId, int categoryId, bool visible) {
    db.execute(
      'INSERT INTO APP_BUDGET_SCENARIO_CATEGORIES (SCENARIOID, CATEGID, VISIBLE) VALUES (?, ?, ?) '
      'ON CONFLICT(SCENARIOID, CATEGID) DO UPDATE SET VISIBLE = excluded.VISIBLE',
      [scenarioId, categoryId, visible ? 1 : 0],
    );
  }

  /// -VIRTUAL_ID -> name for every budget-only category ever created under
  /// [scenarioId] (regardless of its current show/hide state - same
  /// "definition persists, visibility is separate" rule as a real category,
  /// see [getBudgetScenarioCategoryOverrides]). The negative id is what the
  /// rest of the scenario machinery (amounts, visibility, _ScenarioRow)
  /// actually keys on - see APP_BUDGET_SCENARIO_VIRTUAL_CATEGORIES' own
  /// schema comment for why it's negated.
  List<VirtualBudgetCategory> getVirtualBudgetCategories(int scenarioId) {
    final rows = db.query(
      'SELECT VIRTUAL_ID, NAME, PARENT_CATEGID FROM APP_BUDGET_SCENARIO_VIRTUAL_CATEGORIES '
      'WHERE SCENARIOID = ?',
      [scenarioId],
    );
    return [
      for (final row in rows)
        VirtualBudgetCategory(
          id: -(row['VIRTUAL_ID'] as int),
          name: row['NAME'] as String,
          parentCategId: row['PARENT_CATEGID'] as int?,
        ),
    ];
  }

  /// Returns the new category's negative id, ready to use anywhere a real
  /// CATEGID would go in the scenario tables. [parentCategId] nests it
  /// under a real category as an artificial subdivision instead of making
  /// it a top-level category of its own - see VirtualBudgetCategory.
  int createVirtualBudgetCategory(int scenarioId, String name, {int? parentCategId}) {
    final id = db.execute(
      'INSERT INTO APP_BUDGET_SCENARIO_VIRTUAL_CATEGORIES (SCENARIOID, NAME, PARENT_CATEGID) '
      'VALUES (?, ?, ?)',
      [scenarioId, name, parentCategId],
    );
    return -id;
  }

  /// Signed net total per leaf category for [accountId] within [start,
  /// end) - like [categorySpendForPeriod], but covers income and
  /// categorized-transfer categories too (not just Withdrawal), signed
  /// from this account's own point of view (an income category reads
  /// positive, an expense one negative). The simulation view needs both
  /// side by side, unlike the envelope-based Budget view, which is
  /// deliberately expense-only.
  Map<int, double> categoryNetTotalsForPeriod(
    DateTime start,
    DateTime end, {
    required int accountId,
  }) {
    final rows = db.query(
      'SELECT * FROM CHECKINGACCOUNT_V1 '
      'WHERE (ACCOUNTID = ? OR TOACCOUNTID = ?) AND CATEGID IS NOT NULL '
      "AND (DELETEDTIME IS NULL OR DELETEDTIME = '') AND UPPER(TRIM(STATUS)) != 'V' "
      'AND TRANSDATE >= ? AND TRANSDATE < ?',
      [accountId, accountId, _isoDate(start), _isoDate(end)],
    );
    final totals = <int, double>{};
    for (final row in rows) {
      final tx = MoneyTransaction.fromRow(row);
      totals[tx.categoryId!] = (totals[tx.categoryId!] ?? 0) + tx.signedAmountFor(accountId);
    }
    return totals;
  }

  /// categoryId -> monthly-equivalent total of every active (non-paused),
  /// still-recurring withdrawal bill in that category - the basis for an
  /// "auto" envelope (see BudgetScreen): a category that already has a
  /// recurring bill doesn't need its budget target typed in separately,
  /// the schedule already says how much it costs every month.
  Map<int, double> categoryMonthlyRecurringTotals({int? accountId}) {
    final totals = <int, double>{};
    for (final bill in getBillDeposits()) {
      if (bill.paused) continue;
      if (bill.transCode != TransCode.withdrawal) continue;
      if (accountId != null && bill.accountId != accountId) continue;
      final categoryId = bill.categoryId;
      if (categoryId == null) continue;
      final factor = recurrencePeriodToMonthlyFactor(bill.period, bill.numOccurrences);
      if (factor <= 0) continue;
      totals[categoryId] = (totals[categoryId] ?? 0) + bill.amount * factor;
    }
    return totals;
  }

  /// Real income (deposits) recorded for [accountId] within [start, end) -
  /// the counterpart to categorySpendForPeriod, for the always-shown
  /// "Revenus" gauge on the budget screen (see BudgetScreen).
  /// True if [name] is (a fold-cased match for) "Epargne" - used to keep
  /// savings transfers out of the income totals below: moving money into a
  /// savings account isn't new income, so a transfer categorised that way
  /// (directly, or under a parent category named that) doesn't count as
  /// income for the account receiving it either. Not imported from
  /// utils/list_utils.dart's foldDiacritics on purpose - the data layer
  /// stays free of UI-layer imports, this one check doesn't need it.
  bool _isSavingsCategoryName(String name) {
    final normalized = name
        .trim()
        .toLowerCase()
        .replaceAll('é', 'e')
        .replaceAll('è', 'e')
        .replaceAll('ê', 'e');
    return normalized == 'epargne';
  }

  bool _isSavingsCategory(int? categoryId, Map<int, Category> categoriesById) {
    if (categoryId == null) return false;
    final category = categoriesById[categoryId];
    if (category == null) return false;
    if (_isSavingsCategoryName(category.name)) return true;
    final parent = category.parentId == null ? null : categoriesById[category.parentId];
    return parent != null && _isSavingsCategoryName(parent.name);
  }

  /// Every category id that's ever actually appeared on a transaction for
  /// [accountId] - used to keep a category picker scoped to what's
  /// genuinely relevant to the account being budgeted for (see
  /// BudgetScreen's "Budgeter une sous-categorie" flow), instead of every
  /// category defined anywhere in the file regardless of which account
  /// it's ever been used on. Matches on TOACCOUNTID too, not just
  /// ACCOUNTID - a categorized transfer *received* by this account (e.g.
  /// a recurring "Virement:Revenus" from another of the user's own
  /// accounts) is just as relevant here as one sent from it.
  Set<int> categoriesUsedByAccount(int accountId) {
    final rows = db.query(
      'SELECT DISTINCT CATEGID FROM CHECKINGACCOUNT_V1 '
      'WHERE (ACCOUNTID = ? OR TOACCOUNTID = ?) AND CATEGID IS NOT NULL',
      [accountId, accountId],
    );
    return {
      for (final row in rows)
        if (row['CATEGID'] != null) row['CATEGID'] as int,
    };
  }

  /// Real income for [accountId] within [start, end): actual deposits,
  /// plus incoming transfers from another account (money arriving here,
  /// whatever it's categorised as) - except a transfer categorised as
  /// "Epargne" (see [_isSavingsCategory]), since routing money into
  /// savings isn't new income.
  double incomeForPeriod(DateTime start, DateTime end, {int? accountId}) {
    final where = <String>[
      "TRANSDATE >= ?",
      "TRANSDATE < ?",
      "(TRANSCODE = 'Deposit' OR TRANSCODE = 'Transfer')",
      "UPPER(TRIM(STATUS)) != 'V'",
      "(DELETEDTIME IS NULL OR DELETEDTIME = '')",
    ];
    final params = <Object?>[_isoDate(start), _isoDate(end)];
    if (accountId != null) {
      where.add('(ACCOUNTID = ? OR TOACCOUNTID = ?)');
      params.addAll([accountId, accountId]);
    }
    final rows = db.query(
      'SELECT TRANSCODE, ACCOUNTID, TOACCOUNTID, TRANSAMOUNT, TOTRANSAMOUNT, CATEGID '
      'FROM CHECKINGACCOUNT_V1 WHERE ${where.join(' AND ')}',
      params,
    );
    final categoriesById = {for (final c in getCategories(onlyActive: false)) c.id: c};

    var total = 0.0;
    for (final row in rows) {
      if (_isSavingsCategory(row['CATEGID'] as int?, categoriesById)) continue;
      if (row['TRANSCODE'] == 'Deposit') {
        if (accountId != null && row['ACCOUNTID'] != accountId) continue;
        total += (row['TRANSAMOUNT'] as num?)?.toDouble() ?? 0;
      } else if (row['TRANSCODE'] == 'Transfer') {
        if (accountId != null && row['TOACCOUNTID'] != accountId) continue;
        total += (row['TOTRANSAMOUNT'] as num?)?.toDouble() ?? 0;
      }
    }
    return total;
  }

  /// Monthly-equivalent total of every active, still-recurring deposit
  /// (or incoming, non-savings transfer) bill for [accountId] - expected
  /// income, same idea as [categoryMonthlyRecurringTotals] but for income
  /// instead of spending (and not broken down by category - income isn't
  /// budgeted per category here, just as a single expected total).
  double monthlyRecurringIncome({int? accountId}) {
    final categoriesById = {for (final c in getCategories(onlyActive: false)) c.id: c};
    var total = 0.0;
    for (final bill in getBillDeposits()) {
      if (bill.paused) continue;
      if (_isSavingsCategory(bill.categoryId, categoriesById)) continue;
      final isIncoming = bill.transCode == TransCode.deposit ||
          (bill.transCode == TransCode.transfer &&
              (accountId == null || bill.toAccountId == accountId));
      if (!isIncoming) continue;
      if (bill.transCode == TransCode.deposit && accountId != null && bill.accountId != accountId) {
        continue;
      }
      final factor = recurrencePeriodToMonthlyFactor(bill.period, bill.numOccurrences);
      if (factor <= 0) continue;
      total += (bill.transCode == TransCode.transfer ? bill.toAmount : bill.amount) * factor;
    }
    return total;
  }

  /// Per-category counterpart to [monthlyRecurringIncome] - identical
  /// deposit-or-incoming-transfer-excluding-Épargne rule, just broken down
  /// by category instead of summed into one total. The budget simulator
  /// shows income per category (unlike the single combined income gauge
  /// [monthlyRecurringIncome] was originally built for), so a recurring
  /// paycheque/etc. can take priority over a category's historical average
  /// there the same way a recurring bill already does for expenses (see
  /// [categoryMonthlyRecurringTotals]).
  Map<int, double> categoryMonthlyRecurringIncomeTotals({int? accountId}) {
    final categoriesById = {for (final c in getCategories(onlyActive: false)) c.id: c};
    final totals = <int, double>{};
    for (final bill in getBillDeposits()) {
      if (bill.paused) continue;
      if (_isSavingsCategory(bill.categoryId, categoriesById)) continue;
      final categoryId = bill.categoryId;
      if (categoryId == null) continue;
      final isIncoming = bill.transCode == TransCode.deposit ||
          (bill.transCode == TransCode.transfer &&
              (accountId == null || bill.toAccountId == accountId));
      if (!isIncoming) continue;
      if (bill.transCode == TransCode.deposit && accountId != null && bill.accountId != accountId) {
        continue;
      }
      final factor = recurrencePeriodToMonthlyFactor(bill.period, bill.numOccurrences);
      if (factor <= 0) continue;
      totals[categoryId] = (totals[categoryId] ?? 0) +
          (bill.transCode == TransCode.transfer ? bill.toAmount : bill.amount) * factor;
    }
    return totals;
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
