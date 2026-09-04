import 'dart:math';

import '../models/account.dart';
import '../models/bill_deposit.dart';
import '../models/budget.dart';
import '../models/budget_period.dart'
    show BudgetWindow, budgetWindowContaining, previousBudgetWindow, nextForecastDay;
import '../models/category.dart';
import '../models/currency.dart';
import '../models/payee.dart';
import '../models/recurrence.dart';
import '../models/sim_scenario.dart';
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
    // "Pause" a real ledger transaction (2026-08-06, requested alongside
    // recurring bills' own pause) - excludes it from every balance/report
    // query via MMEX's own Void status ('V', see accountBalance and every
    // other query in this file filtering `STATUS != 'V'`), rather than a
    // new app-owned exclusion filter that would need threading through
    // every one of those queries and wouldn't mean anything to the real
    // MMEX desktop app opening the same file. Void is a single field MMEX
    // also uses for "Pointée" (Reconciled, 'R') - this table remembers
    // whether a transaction was reconciled right before being paused, so
    // un-pausing can restore that instead of losing it the moment STATUS
    // gets overwritten with 'V'. See TransactionEditorSheet._save.
    db.execute('''
      CREATE TABLE IF NOT EXISTS APP_PAUSED_TRANSACTIONS (
        TRANSID INTEGER PRIMARY KEY,
        WAS_RECONCILED INTEGER NOT NULL
      )
    ''');
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
    _tryAddColumn(
        'APP_BUDGET_SCENARIO_AMOUNTS', 'MANUAL', 'INTEGER NOT NULL DEFAULT 1');
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
    _tryAddColumn(
        'APP_BUDGET_SCENARIO_VIRTUAL_CATEGORIES', 'PARENT_CATEGID', 'INTEGER');

    // Long-term "what if" scenarios (PLAN_SIMULATION_LONG_TERME.md, phase
    // 1, 2026-09-02) - same split as the budget scenarios above: a
    // scenario row is just a name, everything it actually changes lives in
    // the three tables below it. Never touches BILLSDEPOSITS_V1/
    // CHECKINGACCOUNT_V1 - see MmexRepository.simulatedMonthlyNet.
    db.execute('''
      CREATE TABLE IF NOT EXISTS APP_SIM_SCENARIOS (
        SCENARIOID INTEGER PRIMARY KEY AUTOINCREMENT,
        NAME TEXT NOT NULL,
        CREATED_AT TEXT NOT NULL,
        UPDATED_AT TEXT NOT NULL
      )
    ''');
    // A scenario's change to one real recurring bill - see SimBillOverride's
    // own doc comment for why this is two independent, composable columns
    // rather than one "changes to X starting on date Y" field.
    db.execute('''
      CREATE TABLE IF NOT EXISTS APP_SIM_BILL_OVERRIDES (
        SCENARIOID INTEGER NOT NULL,
        BILLID INTEGER NOT NULL,
        DISABLED_FROM TEXT,
        AMOUNT_OVERRIDE REAL,
        PRIMARY KEY (SCENARIOID, BILLID)
      )
    ''');
    // A recurring operation that exists only inside this scenario, never in
    // BILLSDEPOSITS_V1 - see SimVirtualBill.
    db.execute('''
      CREATE TABLE IF NOT EXISTS APP_SIM_VIRTUAL_BILLS (
        VIRTUALBILLID INTEGER PRIMARY KEY AUTOINCREMENT,
        SCENARIOID INTEGER NOT NULL,
        ACCOUNTID INTEGER NOT NULL,
        LABEL TEXT NOT NULL,
        TRANSCODE TEXT NOT NULL,
        AMOUNT REAL NOT NULL,
        START_DATE TEXT NOT NULL,
        PERIOD TEXT NOT NULL,
        NUM_OCCURRENCES INTEGER NOT NULL DEFAULT -1
      )
    ''');
    // A single hypothetical transaction (not recurring) - see SimOneOffEvent.
    db.execute('''
      CREATE TABLE IF NOT EXISTS APP_SIM_ONE_OFF_EVENTS (
        EVENTID INTEGER PRIMARY KEY AUTOINCREMENT,
        SCENARIOID INTEGER NOT NULL,
        ACCOUNTID INTEGER NOT NULL,
        LABEL TEXT NOT NULL,
        TRANSCODE TEXT NOT NULL,
        AMOUNT REAL NOT NULL,
        DATE TEXT NOT NULL
      )
    ''');
    // A virtual bill's optional month-to-month random variation (2026-09-02
    // user request: the pure-recurring-bills projection was always too
    // smooth/optimistic, real life has non-recurring spending too) - see
    // BillDeposit.variancePercent/MmexRepository.historicalDiscretionaryMonthlyAverage.
    // 0 (the default) means every occurrence keeps the exact same amount,
    // same as before this column existed.
    _tryAddColumn(
        'APP_SIM_VIRTUAL_BILLS', 'VARIANCE_PERCENT', 'REAL NOT NULL DEFAULT 0');
    // "Solde final supposé" (2026-09-02 user request) - an assumed/known
    // balance the user trusts more than the raw projection at the app's
    // existing "Jour de prévision du solde" date (DatabaseProvider.forecastDay
    // / models/budget_period.dart's nextForecastDay - the same date the
    // dashboard's own near-term forecast already anchors to). Null (the
    // default) means no adjustment - see
    // MmexRepository.forecastAccountBalanceForScenario/_SimulationChart for
    // how and when this actually gets applied (only when the scenario's own
    // calculated balance at that date is already positive - never allowed
    // to paper over a genuinely negative projection).
    _tryAddColumn('APP_SIM_SCENARIOS', 'ASSUMED_FINAL_BALANCE', 'REAL');
    // Per-account replacement for the column above (2026-09 user request:
    // the simulation screen now shows one curve per selected account, so a
    // single scenario-wide "solde final supposé" applying the exact same
    // target to every account no longer makes sense - each account needs
    // its own). The old column is left in place, never written to again,
    // purely as a one-time fallback default for an account that has no row
    // here yet - see MmexRepository.getSimAssumedFinalBalance.
    // AMOUNT is nullable on purpose: a row with AMOUNT = NULL still means
    // something (see getSimAssumedFinalBalance's own doc comment) -
    // "this account was explicitly cleared, stop falling back to the
    // legacy scenario-wide column for it" - so the row itself has to
    // exist even when there's no number to store.
    db.execute('''
      CREATE TABLE IF NOT EXISTS APP_SIM_ASSUMED_FINAL_BALANCES (
        SCENARIOID INTEGER NOT NULL,
        ACCOUNTID INTEGER NOT NULL,
        AMOUNT REAL,
        PRIMARY KEY (SCENARIOID, ACCOUNTID)
      )
    ''');
    // "Augmentation annuelle" per *real* recurring bill (2026-09 user
    // request) - a percentage this bill's projected amount compounds by
    // once per year, on the anniversary of ANCHOR_DATE (month/day only).
    // Deliberately keyed by BILLID alone, not by scenario - a property of
    // the bill itself (like its amount or its next due date), applied
    // identically in every simulation scenario, never a per-scenario
    // override (2026-09 user decision - keeps this consistent with "this
    // is what the bill actually does", the same way pausing a bill or
    // editing BILLSDEPOSITS_V1 directly would be). See
    // MmexRepository.getBillAnnualIncrease/setBillAnnualIncrease/
    // suggestedAnnualIncrease. A virtual bill's own equivalent lives
    // directly on APP_SIM_VIRTUAL_BILLS below instead, since it has no
    // BILLSDEPOSITS_V1 row to key off of.
    db.execute('''
      CREATE TABLE IF NOT EXISTS APP_BILL_ANNUAL_INCREASE (
        BILLID INTEGER PRIMARY KEY,
        PERCENT REAL NOT NULL,
        ANCHOR_DATE TEXT NOT NULL
      )
    ''');
    _tryAddColumn('APP_SIM_VIRTUAL_BILLS', 'ANNUAL_INCREASE_PERCENT',
        'REAL NOT NULL DEFAULT 0');
    _tryAddColumn(
        'APP_SIM_VIRTUAL_BILLS', 'ANNUAL_INCREASE_ANCHOR', 'TEXT');
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
  static DateTime _addDays(DateTime date, int days) =>
      DateTime(date.year, date.month, date.day + days);

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
      [
        account.name,
        account.type,
        account.status,
        account.initialBalance,
        account.id
      ],
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
    final initial = (account.isEmpty ? 0 : account.first['INITIALBAL'] as num?)
            ?.toDouble() ??
        0;

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
    int count(List<Map<String, Object?>> rows) =>
        (rows.first['n'] as int?) ?? 0;
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
        db.execute(
            'DELETE FROM BUDGETTABLE_V1 WHERE BUDGETENTRYID = ?', [row['id']]);
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

  /// Finds an existing payee matching [name] case-insensitively (trimmed),
  /// or creates a new one if none exists - lets the ledger/recurring
  /// editors' "Tiers" field resolve newly-typed text at save time even
  /// when the user never explicitly tapped the field's own "create"
  /// button (see TransactionEditorSheet._save/RecurringEditorSheet._save),
  /// instead of that text being silently discarded.
  int resolveOrCreatePayee({required String name, int? categoryId}) {
    final trimmed = name.trim();
    final existing = db.query(
      'SELECT PAYEEID FROM PAYEE_V1 WHERE PAYEENAME = ? COLLATE NOCASE LIMIT 1',
      [trimmed],
    );
    if (existing.isNotEmpty) return existing.first['PAYEEID'] as int;
    return insertPayee(name: trimmed, categoryId: categoryId);
  }

  /// How many real records reference [payeeId] - real ledger transactions
  /// plus recurring bill templates, the same two sources
  /// [categoryUsage]/[CategoryUsage] already counts for a category. Used by
  /// the "Gestion des tiers" settings screen to decide whether a payee can
  /// be deleted outright (0) or must be kept.
  int payeeUsageCount(int payeeId) {
    int count(String sql) => (db.query(sql, [payeeId]).first['n'] as int?) ?? 0;
    return count(
            'SELECT COUNT(*) AS n FROM CHECKINGACCOUNT_V1 WHERE PAYEEID = ?') +
        count('SELECT COUNT(*) AS n FROM BILLSDEPOSITS_V1 WHERE PAYEEID = ?');
  }

  void renamePayee(int payeeId, String newName) {
    db.execute('UPDATE PAYEE_V1 SET PAYEENAME = ? WHERE PAYEEID = ?',
        [newName, payeeId]);
  }

  /// Only meant to be called once [payeeUsageCount] is actually 0 - the
  /// caller (payees_screen.dart) is responsible for that check; this
  /// itself doesn't re-verify it, same division of responsibility as
  /// [deleteCategory] (CategoriesScreen enforces [CategoryUsage.canDelete]
  /// before ever calling it).
  void deletePayee(int payeeId) {
    db.execute('DELETE FROM PAYEE_V1 WHERE PAYEEID = ?', [payeeId]);
  }

  /// Re-points every real ledger transaction and recurring bill from
  /// [fromId] to [toId] (the only two tables [payeeUsageCount] itself
  /// counts), then deletes the now-unreferenced source payee - same shape
  /// as [mergeCategories]. Lets several near-duplicate merchant labels an
  /// export/import produced (e.g. several "CB AMINE VIANDE FACT xxxxx"
  /// rows from different statement lines for the same butcher) collapse
  /// into one real "Boucherie" payee without losing any history.
  void mergePayees({required int fromId, required int toId}) {
    if (fromId == toId) return;
    db.transaction(() {
      db.execute(
        'UPDATE CHECKINGACCOUNT_V1 SET PAYEEID = ? WHERE PAYEEID = ?',
        [toId, fromId],
      );
      db.execute(
        'UPDATE BILLSDEPOSITS_V1 SET PAYEEID = ? WHERE PAYEEID = ?',
        [toId, fromId],
      );
      db.execute('DELETE FROM PAYEE_V1 WHERE PAYEEID = ?', [fromId]);
    });
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

  /// Same as [transactionYearRange] but across every account at once -
  /// used by cross-account analysis screens (e.g. the spending explorer)
  /// that aren't scoped to a single account.
  ({int min, int max})? transactionYearRangeAll() {
    final row = db
        .query(
          'SELECT MIN(TRANSDATE) AS minDate, MAX(TRANSDATE) AS maxDate FROM CHECKINGACCOUNT_V1 '
          "WHERE (DELETEDTIME IS NULL OR DELETEDTIME = '')",
        )
        .first;
    final minYear = DateTime.tryParse(row['minDate'] as String? ?? '')?.year;
    final maxYear = DateTime.tryParse(row['maxDate'] as String? ?? '')?.year;
    if (minYear == null || maxYear == null) return null;
    return (min: minYear, max: maxYear);
  }

  /// Flexible cross-account transaction query for analysis screens: any
  /// combination of years/categories/payees/accounts, all optional (an
  /// empty or null list means "no filter on that dimension"). Transfers are
  /// always excluded - they move money between the user's own accounts and don't
  /// carry the category/payee semantics this kind of filter is built
  /// around - as are voided transactions (`STATUS = 'V'`), same as MMEX's
  /// own balance calculations.
  List<MoneyTransaction> getTransactionsFiltered({
    List<int>? years,
    List<int>? categoryIds,
    List<int>? payeeIds,
    List<int>? accountIds,
    int limit = 20000,
  }) {
    final where = <String>[
      "(DELETEDTIME IS NULL OR DELETEDTIME = '')",
      "TRANSCODE != 'Transfer'",
      "(STATUS IS NULL OR STATUS != 'V')",
    ];
    final params = <Object?>[];
    if (years != null && years.isNotEmpty) {
      where.add(
        "CAST(strftime('%Y', TRANSDATE) AS INTEGER) IN (${List.filled(years.length, '?').join(',')})",
      );
      params.addAll(years);
    }
    if (categoryIds != null && categoryIds.isNotEmpty) {
      where.add(
          'CATEGID IN (${List.filled(categoryIds.length, '?').join(',')})');
      params.addAll(categoryIds);
    }
    if (payeeIds != null && payeeIds.isNotEmpty) {
      where.add('PAYEEID IN (${List.filled(payeeIds.length, '?').join(',')})');
      params.addAll(payeeIds);
    }
    if (accountIds != null && accountIds.isNotEmpty) {
      // Transfers are already excluded above (TRANSCODE != 'Transfer'), so
      // every remaining row's own account is always ACCOUNTID - never
      // TOACCOUNTID, which only a transfer ever populates.
      where.add(
          'ACCOUNTID IN (${List.filled(accountIds.length, '?').join(',')})');
      params.addAll(accountIds);
    }
    final whereSql = 'WHERE ${where.join(' AND ')}';
    final rows = db.query(
      'SELECT * FROM CHECKINGACCOUNT_V1 $whereSql ORDER BY TRANSDATE ASC, TRANSID ASC LIMIT ?',
      [...params, limit],
    );
    return rows.map(MoneyTransaction.fromRow).toList();
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
  /// the tab once an account had years of history. Only web callers (see
  /// transactions_screen.dart) still pass a bounded window - two months as
  /// of 2026-08-04 (previously one) - rather than relying on this method to
  /// stay cheap with no bounds at all; passing neither [from] nor [to] still
  /// works but is exactly as expensive as before (every matching row walked
  /// into a Dart object). Desktop *and Android* callers pass no bounds at
  /// all deliberately (Android added 2026-08-04, same day as the 2-month
  /// web window) - safe there because that per-row walk runs as native
  /// AOT-compiled Dart against native FFI SQLite on both platforms
  /// (`sqlite3_flutter_libs` bundles native sqlite3 for Android/desktop
  /// alike - see pubspec.yaml), not web's slower dart2js/Wasm stack, and
  /// this app's real per-account transaction counts are in the low
  /// thousands even after 13 years - nowhere near where an O(n) walk would
  /// be felt, on a phone or a PC.
  List<TransactionWithBalance> getTransactionsWithRunningBalance(
    int accountId, {
    DateTime? from,
    DateTime? to,
  }) {
    final accountRows = db.query(
        'SELECT INITIALBAL FROM ACCOUNTLIST_V1 WHERE ACCOUNTID = ?',
        [accountId]);
    var running =
        (accountRows.isEmpty ? 0 : accountRows.first['INITIALBAL'] as num?)
                ?.toDouble() ??
            0;

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
      'TRANSAMOUNT = ?, TOTRANSAMOUNT = ?, STATUS = ?, CATEGID = ?, TRANSDATE = ?, NOTES = ? '
      'WHERE TRANSID = ?',
      [
        tx.accountId,
        tx.toAccountId,
        tx.payeeId,
        transCodeToString(tx.transCode),
        tx.amount,
        tx.toAmount,
        tx.status,
        tx.categoryId,
        _isoDate(tx.date),
        tx.notes ?? '',
        tx.id,
      ],
    );
  }

  void deleteTransaction(int transId) {
    db.execute('DELETE FROM CHECKINGACCOUNT_V1 WHERE TRANSID = ?', [transId]);
    db.execute(
        'DELETE FROM APP_TRANSACTION_BILL_LINKS WHERE TRANSID = ?', [transId]);
    db.execute(
        'DELETE FROM APP_PAUSED_TRANSACTIONS WHERE TRANSID = ?', [transId]);
  }

  /// Recreates [tx] as a brand-new transaction with the same field values,
  /// reconciled/paused status, and recurring-bill link (if any) it had
  /// right before being deleted - powers "Annuler" on
  /// TransactionEditorSheet's post-delete SnackBar. A fresh TRANSID is
  /// unavoidable (MMEX has no way to reuse a deleted one), so the caller
  /// must capture everything ([tx] itself, plus [billId]/[occurrenceIndex]/
  /// [occurrenceTotal]/[wasReconciledBeforePause]) *before* calling
  /// [deleteTransaction] - all of it (including the
  /// APP_TRANSACTION_BILL_LINKS/APP_PAUSED_TRANSACTIONS rows) is gone
  /// afterward. Returns the new transaction's id.
  int restoreTransaction(
    MoneyTransaction tx, {
    int? billId,
    int? occurrenceIndex,
    int? occurrenceTotal,
    bool? wasReconciledBeforePause,
  }) {
    final newId = insertTransaction(
      accountId: tx.accountId,
      payeeId: tx.payeeId,
      transCode: tx.transCode,
      amount: tx.amount,
      date: tx.date,
      categoryId: tx.categoryId,
      toAccountId: tx.toAccountId,
      toAmount: tx.toAmount,
      notes: tx.notes,
      reconciled: tx.isReconciled,
    );
    // insertTransaction only knows 'R'/'' (via the reconciled bool) - void
    // ('V', "en pause") needs a direct follow-up write, same as
    // TransactionEditorSheet._save's own status handling.
    if (tx.isVoid) {
      db.execute('UPDATE CHECKINGACCOUNT_V1 SET STATUS = ? WHERE TRANSID = ?',
          ['V', newId]);
      syncPausedTracking(newId,
          paused: true, reconciled: wasReconciledBeforePause ?? false);
    }
    if (billId != null) {
      _linkTransactionToBill(newId, billId,
          occurrenceIndex: occurrenceIndex, occurrenceTotal: occurrenceTotal);
    }
    return newId;
  }

  /// Whether [transId] was reconciled right before being paused - only
  /// meaningful while it's currently paused (`tx.isVoid`). Used to seed
  /// [TransactionEditorSheet]'s "Pointée" checkbox correctly when opening
  /// an already-paused transaction, since its *live* status is 'V' (not
  /// 'R') while paused - see [APP_PAUSED_TRANSACTIONS] in [ensureAppSchema].
  bool wasReconciledBeforePause(int transId) {
    final rows = db.query(
      'SELECT WAS_RECONCILED FROM APP_PAUSED_TRANSACTIONS WHERE TRANSID = ?',
      [transId],
    );
    return rows.isNotEmpty && (rows.first['WAS_RECONCILED'] as int) != 0;
  }

  /// Keeps [APP_PAUSED_TRANSACTIONS] in sync with what
  /// [TransactionEditorSheet._save] just wrote to STATUS itself (that save
  /// already computes and writes the real 'V'/'R'/'' value in one go, so
  /// this is bookkeeping only, never a second STATUS write).
  void syncPausedTracking(int transId,
      {required bool paused, required bool reconciled}) {
    if (paused) {
      db.execute(
        'INSERT OR REPLACE INTO APP_PAUSED_TRANSACTIONS (TRANSID, WAS_RECONCILED) VALUES (?, ?)',
        [transId, reconciled ? 1 : 0],
      );
    } else {
      db.execute(
          'DELETE FROM APP_PAUSED_TRANSACTIONS WHERE TRANSID = ?', [transId]);
    }
  }

  /// The recurring template [transId] was originally recorded from, if
  /// any - see [APP_TRANSACTION_BILL_LINKS] in [ensureAppSchema]. Used to
  /// offer syncing an amount edit back to the template (see
  /// bill_amount_sync.dart).
  int? billIdForTransaction(int transId) {
    final rows = db.query(
        'SELECT BILLID FROM APP_TRANSACTION_BILL_LINKS WHERE TRANSID = ?',
        [transId]);
    return rows.isEmpty ? null : rows.first['BILLID'] as int;
  }

  /// How many real ledger transactions share [payeeId] and [categoryId] -
  /// "identical" for the purposes of a bulk category reassignment (see
  /// [bulkReassignTransactionCategory]): same payee and same current
  /// category, regardless of account or amount - a payee's category is
  /// normally stable across both (groceries vary in amount every time but
  /// stay the same category; the same payee can pay from more than one of
  /// the user's own accounts).
  int countTransactionsMatching(
      {required int payeeId, required int categoryId}) {
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
    final params = <Object?>[
      _isoDate(start),
      _isoDate(DateTime(anchor.year, anchor.month + 1, 1))
    ];
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
    final params = <Object?>[
      _isoDate(start),
      _isoDateExclusiveUpper(anchorDay)
    ];
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

  /// Net signed totals bucketed by calendar day for transactions already
  /// recorded with a date *after* [after], through [end] (both inclusive
  /// of the bucketed range) - the future-dated counterpart to
  /// [dailyNetTotals], reusing its exact same query/filtering (just a
  /// different day window) since a postdated real transaction (e.g. a bill
  /// paid a few days ahead of its due date) is stored identically to any
  /// other. Used by the forecast chart so that kind of entry shows up on
  /// its own real date instead of being folded entirely into "today"'s
  /// balance - which used to make an account with any postdated entry look
  /// already overdrawn today, before its actual due date, even though the
  /// balance as of today was fine (found 2026-08-18 on a real account with
  /// two postdated withdrawals ~2 weeks out).
  Map<DateTime, double> futureDailyNet({
    required DateTime after,
    required DateTime end,
    int? accountId,
  }) {
    final start = _addDays(after, 1);
    if (start.isAfter(end)) return {};
    final days = _daysBetween(start, end) + 1;
    return dailyNetTotals(anchor: end, days: days, accountId: accountId);
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
    return _dailyNetForBills(getBillDeposits(),
        start: start, end: anchorDay, days: days, accountId: accountId);
  }

  /// Scenario-aware counterpart to [recurringDailyNet] - same signature and
  /// bucketing, but projects [scenarioId]'s effective bill set (see
  /// [_effectiveBillsForScenario]) instead of the unmodified real one, and
  /// also folds in the scenario's one-off events. Day-level counterpart to
  /// [simulatedMonthlyNet]/[simulatedPeriodNet] - see
  /// [_SimulationChart]'s own doc comment for why the chart wants day
  /// granularity at all (2026-09-02 user request: match the dashboard's own
  /// day-by-day forecast chart instead of a monthly-bucketed one).
  Map<DateTime, double> simulatedDailyNet({
    required int scenarioId,
    required DateTime anchor,
    required int days,
    int? accountId,
  }) {
    final anchorDay = DateTime(anchor.year, anchor.month, anchor.day);
    final start = _addDays(anchorDay, -(days - 1));
    final effective = _effectiveBillsForScenario(scenarioId);
    final result = Map<DateTime, double>.from(_dailyNetForBills(
      effective.bills,
      start: start,
      end: anchorDay,
      days: days,
      accountId: accountId,
      disabledFromByBillId: effective.disabledFromByBillId,
    ));

    for (final event in getSimOneOffEvents(scenarioId)) {
      if (accountId != null && event.accountId != accountId) continue;
      final bucket = DateTime(event.date.year, event.date.month, event.date.day);
      final current = result[bucket];
      if (current == null) continue;
      final signed =
          event.transCode == TransCode.deposit ? event.amount : -event.amount;
      result[bucket] = current + signed;
    }
    return result;
  }

  /// Shared bucketing core behind [recurringDailyNet] and [simulatedDailyNet] -
  /// same role as [_monthlyNetForBills], just bucketed by calendar day
  /// instead of month.
  Map<DateTime, double> _dailyNetForBills(
    List<BillDeposit> bills, {
    required DateTime start,
    required DateTime end,
    required int days,
    int? accountId,
    Map<int, DateTime> disabledFromByBillId = const {},
  }) {
    final result = <DateTime, double>{
      for (var i = 0; i < days; i++) _addDays(start, i): 0.0,
    };

    for (final bill in bills) {
      if (bill.paused) continue;
      final involvesAccount = accountId == null ||
          bill.accountId == accountId ||
          bill.toAccountId == accountId;
      if (!involvesAccount) continue;
      if (accountId == null && bill.transCode == TransCode.transfer) continue;

      final signedAmount = _billSignedAmount(bill, accountId);
      final disabledFrom = disabledFromByBillId[bill.id];
      for (final occurrence in _occurrencesInRange(bill, start, end)) {
        if (disabledFrom != null && !occurrence.isBefore(disabledFrom)) {
          continue;
        }
        final bucket =
            DateTime(occurrence.year, occurrence.month, occurrence.day);
        final current = result[bucket];
        if (current == null) continue;
        final jitter = bill.variancePercent > 0
            ? _seededMonthlyJitter(bill.id, bucket, bill.variancePercent)
            : 0.0;
        final growth = _annualGrowthFactor(bill, occurrence);
        result[bucket] = current + signedAmount * growth * (1 + jitter);
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
      result[categoryId] =
          (result[categoryId] ?? 0) + signedAmount * occurrenceCount;
    }
    return result;
  }

  /// Projects [accountId]'s balance forward from today to [targetDate]
  /// using known recurring transactions ([recurringDailyNet]) plus any real
  /// transaction already recorded with a future date on or before
  /// [targetDate] ([futureDailyNet]) - the same mechanical projection the
  /// forecast chart uses ([ForecastChart._buildPoints]), collapsed to a
  /// single final figure. Returns the real balance as of today ([today]'s
  /// asOf) if [targetDate] isn't in the future.
  ///
  /// Starts from the real balance *as of today* ([accountBalance] with
  /// `asOf: today`), not the all-transactions total with no `asOf` - the
  /// latter includes postdated entries regardless of date, which used to
  /// make this projection overshoot before an already-recorded future
  /// transaction's own date (found 2026-08-18, same bug as
  /// [ForecastChart._buildPoints]'s "today" point - see its doc comment).
  /// Never double-counts a postdated entry: recording a recurring bill's
  /// occurrence always advances its own next-occurrence date past it (see
  /// [recordBillOccurrence]/[catchUpBillDeposit]), so [recurringDailyNet]
  /// can't also re-project something [futureDailyNet] already counts as a
  /// real transaction.
  double forecastAccountBalance(int accountId, DateTime targetDate) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(targetDate.year, targetDate.month, targetDate.day);
    final todayBalance = accountBalance(accountId, asOf: today);
    if (!target.isAfter(today)) return todayBalance;

    final recurring = recurringDailyNet(
      anchor: target,
      days: _daysBetween(today, target) + 1,
      accountId: accountId,
    );
    final futureReal =
        futureDailyNet(after: today, end: target, accountId: accountId);
    var total = todayBalance;
    var cursor = _addDays(today, 1);
    while (!cursor.isAfter(target)) {
      total += (recurring[cursor] ?? 0.0) + (futureReal[cursor] ?? 0.0);
      cursor = _addDays(cursor, 1);
    }
    return total;
  }

  /// Scenario-aware counterpart to [forecastAccountBalance] - same
  /// single-figure projection to one specific date, but sourced from
  /// [scenarioId]'s effective bill set ([simulatedDailyNet]) instead of the
  /// unmodified real one. Used to work out what a scenario's own
  /// calculated balance would be at "Jour de prévision du solde" before
  /// deciding whether to apply [SimScenario.assumedFinalBalance] there -
  /// see `_SimulationChart`'s own doc comment for the full "uniquement si
  /// positif" rule (2026-09-02 user request).
  double forecastAccountBalanceForScenario({
    required int scenarioId,
    required int accountId,
    required DateTime targetDate,
  }) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(targetDate.year, targetDate.month, targetDate.day);
    final todayBalance = accountBalance(accountId, asOf: today);
    if (!target.isAfter(today)) return todayBalance;

    final simulated = simulatedDailyNet(
      scenarioId: scenarioId,
      anchor: target,
      days: _daysBetween(today, target) + 1,
      accountId: accountId,
    );
    final futureReal =
        futureDailyNet(after: today, end: target, accountId: accountId);
    var total = todayBalance;
    var cursor = _addDays(today, 1);
    while (!cursor.isAfter(target)) {
      total += (simulated[cursor] ?? 0.0) + (futureReal[cursor] ?? 0.0);
      cursor = _addDays(cursor, 1);
    }
    return total;
  }

  /// [simulatedDailyNet] with [assumedFinalBalance] (see
  /// [SimScenario.assumedFinalBalance]'s own doc comment) re-applied at
  /// *every* monthly occurrence of [forecastDay] within [anchor]/[days]'s
  /// window, not just once - extracted here as its own method (rather than
  /// inline in `_SimulationChart`) so the "reporté toutes les fins de
  /// mois, sauf si le solde est négatif" rule is directly unit-tested
  /// (test/sim_scenario_test.dart) like every other piece of the
  /// simulator's math - "extrêmement fiable" was an explicit requirement
  /// (2026-09-02).
  ///
  /// Why recurring rather than a single date (2026-09-03 user correction of
  /// the original one-shot design): the user's real bank balance almost
  /// never matches a naive recurring-only projection several years out -
  /// in practice it hovers close to the same "slightly positive or
  /// slightly negative" figure every month, because real life (extra
  /// discretionary spending or saving) keeps nudging it back there. Walks
  /// month-by-month in chronological order, each checkpoint's decision
  /// based on the *running* total so far - which already includes every
  /// earlier checkpoint's own pin, exactly like the real account carries
  /// its actual balance from one month into the next: if that running
  /// total is already positive, it's reset to [assumedFinalBalance]; if
  /// it's zero or negative, it's left alone and the (possibly negative)
  /// calculated figure shows through untouched for that month - this must
  /// never be a way to make a genuinely bad trajectory look fine.
  ///
  /// [accountsForTotal] is only consulted when [accountId] is null ("tous
  /// les comptes") - same summing convention as
  /// `_SimulationChart._startingBalance`. Both returned lists are empty
  /// when [assumedFinalBalance] is null (nothing to apply) or [forecastDay]
  /// has no occurrence at all inside [anchor]/[days]'s window - the caller
  /// can tell "nothing to show" from "some months negative" by checking
  /// whether both lists are empty.
  ({Map<DateTime, double> net, List<DateTime> appliedDates, List<DateTime> ignoredDates})
      simulatedDailyNetWithAssumedFinalBalance({
    required int scenarioId,
    required double? assumedFinalBalance,
    required DateTime anchor,
    required int days,
    int? accountId,
    List<Account> accountsForTotal = const [],
    required int forecastDay,
  }) {
    final net = simulatedDailyNet(
        scenarioId: scenarioId, anchor: anchor, days: days, accountId: accountId);
    if (assumedFinalBalance == null) {
      return (net: net, appliedDates: const [], ignoredDates: const []);
    }

    final anchorDay = DateTime(anchor.year, anchor.month, anchor.day);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final accountIds = accountId != null
        ? [accountId]
        : accountsForTotal.map((a) => a.id).toList();

    var runningTotal = accountIds.fold(
        0.0, (sum, id) => sum + accountBalance(id, asOf: today));
    final futureReal = <DateTime, double>{};
    for (final id in accountIds) {
      futureDailyNet(after: today, end: anchorDay, accountId: id)
          .forEach((k, v) => futureReal[k] = (futureReal[k] ?? 0) + v);
    }

    final appliedDates = <DateTime>[];
    final ignoredDates = <DateTime>[];
    var cursor = _addDays(today, 1);
    var checkpoint = nextForecastDay(today, forecastDay);
    while (!checkpoint.isAfter(anchorDay)) {
      while (!cursor.isAfter(checkpoint)) {
        runningTotal += (net[cursor] ?? 0.0) + (futureReal[cursor] ?? 0.0);
        cursor = _addDays(cursor, 1);
      }
      if (runningTotal > 0) {
        final delta = assumedFinalBalance - runningTotal;
        net[checkpoint] = (net[checkpoint] ?? 0) + delta;
        runningTotal = assumedFinalBalance;
        appliedDates.add(checkpoint);
      } else {
        ignoredDates.add(checkpoint);
      }
      checkpoint = nextForecastDay(_addDays(checkpoint, 1), forecastDay);
    }

    return (net: net, appliedDates: appliedDates, ignoredDates: ignoredDates);
  }

  /// First future calendar day [accountId]'s projected running balance dips
  /// below zero, projecting forward from today with the same mechanical
  /// simulation [forecastAccountBalance] uses (known recurring bills via
  /// [recurringDailyNet] plus already-recorded future-dated transactions via
  /// [futureDailyNet]), day by day up to [horizonDays] ahead. Returns null
  /// if the balance is already negative today - that's a current fact, not
  /// a future risk to date, same distinction [QueryKind.outlook]'s own
  /// crossesNegativeOn draws (see query_executor.dart) - or if it stays
  /// non-negative for the whole horizon.
  DateTime? forecastNegativeDate(int accountId, {int horizonDays = 365}) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final current = accountBalance(accountId, asOf: today);
    if (current < 0) return null;

    final target = _addDays(today, horizonDays);
    final recurring = recurringDailyNet(
      anchor: target,
      days: horizonDays + 1,
      accountId: accountId,
    );
    final futureReal =
        futureDailyNet(after: today, end: target, accountId: accountId);

    var cumulative = current;
    var cursor = _addDays(today, 1);
    while (!cursor.isAfter(target)) {
      cumulative += (recurring[cursor] ?? 0.0) + (futureReal[cursor] ?? 0.0);
      if (cumulative < 0) return cursor;
      cursor = _addDays(cursor, 1);
    }
    return null;
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
          : (payees[bill.payeeId]?.name ?? 'Tiers inconnu');

      for (final occurrence in _occurrencesInRange(bill, start, end)) {
        result.add(RecurringOccurrence(
            date: occurrence, label: label, signedAmount: signedAmount));
      }
    }
    result.sort((a, b) => a.date.compareTo(b.date));
    return result;
  }

  /// Every individual recurring-bill occurrence within [start, end)
  /// (half-open, matching every other period-based query here) as a plain
  /// filterable/groupable row - the "opérations récurrentes" schedule
  /// itself (BILLSDEPOSITS_V1), never the ledger. See
  /// [recurringCategorySpendForPeriod]/ad_hoc_query.dart for why: an
  /// explicit 2026-08-07 decision that "opérations récurrentes" questions
  /// must answer purely from the schedule, matching the "Opérations
  /// récurrentes" screen and the dashboard's own "Prévu" figures, never
  /// mixed with what's separately been recorded in the ledger. Paused
  /// bills are excluded, same as every other recurring-projection method
  /// here. Unlike [recurringOccurrencesInRange] (signed net amount, transfer-
  /// aware, built for the forecast chart), this keeps each bill's raw
  /// [BillDeposit.amount] (always positive) and [BillDeposit.transCode]
  /// separate - mirrors CHECKINGACCOUNT_V1's own TRANSAMOUNT/TRANSCODE
  /// shape, so ad_hoc_query.dart's filter/group/metric logic applies
  /// identically to either source. Only ever matches a bill by its
  /// [BillDeposit.accountId] (the transfer's *source* side), never
  /// [BillDeposit.toAccountId] either - same convention the ledger-based
  /// queries use (a transfer is one CHECKINGACCOUNT_V1 row, matched by
  /// ACCOUNTID only), so filtering by account behaves identically
  /// regardless of which source a query ends up reading from.
  List<RecurringScheduleRow> recurringScheduleRows({
    required DateTime start,
    required DateTime end,
  }) {
    final inclusiveEnd = _addDays(end, -1);
    final result = <RecurringScheduleRow>[];
    for (final bill in getBillDeposits()) {
      if (bill.paused) continue;
      for (final occurrence in _occurrencesInRange(bill, start, inclusiveEnd)) {
        result.add(RecurringScheduleRow(
          accountId: bill.accountId,
          categoryId: bill.categoryId,
          payeeId: bill.payeeId,
          transCode: bill.transCode,
          amount: bill.amount,
          date: occurrence,
        ));
      }
    }
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
  Map<int, double> categorySpendForPeriod(DateTime start, DateTime end,
      {int? accountId}) {
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

  /// Same shape as [categorySpendForPeriod] restricted to withdrawals, but
  /// computed from the recurring bill *schedule* itself
  /// ([recurringScheduleRows]/BILLSDEPOSITS_V1) - the "dépenses récurrentes"
  /// natural-language question (QueryKind.expenseTotal/QueryKind.adHoc with
  /// recurringOnly). Explicit 2026-08-07 decision (reversing an earlier
  /// "read what was actually recorded in the ledger" design, after that
  /// answered a completely different, wrong-looking total than the
  /// "Opérations récurrentes" screen for the same account/period): this
  /// must match that screen and the dashboard's own "Prévu" figures
  /// exactly, with nothing from the ledger mixed in - a bill not yet due
  /// this period still counts here, the same way it already does there.
  Map<int, double> recurringCategorySpendForPeriod(DateTime start, DateTime end,
      {int? accountId}) {
    final totals = <int, double>{};
    for (final row in recurringScheduleRows(start: start, end: end)) {
      if (row.transCode != TransCode.withdrawal) continue;
      if (accountId != null && row.accountId != accountId) continue;
      final categId = row.categoryId;
      if (categId == null) continue;
      totals[categId] = (totals[categId] ?? 0) + row.amount;
    }
    return totals;
  }

  /// One [categorySpendForPeriod] call per calendar month between [start]
  /// and [end] (exclusive), summed across every category when [categoryId]
  /// is null or rolled up into [categoryId] and its subcategories otherwise -
  /// the "dépenses ... par mois" natural-language question, where a single
  /// total would hide how spending moved from one month to the next. Keyed
  /// by each month's 1st; a month with genuinely zero spend still gets an
  /// entry (0.0) rather than being silently skipped, so a real gap shows as
  /// one instead of looking like missing data.
  Map<DateTime, double> categorySpendByMonth(
    DateTime start,
    DateTime end, {
    int? categoryId,
    int? accountId,
  }) {
    final categories = getCategories(onlyActive: false);
    final result = <DateTime, double>{};
    var cursor = DateTime(start.year, start.month, 1);
    while (cursor.isBefore(end)) {
      final monthEnd = DateTime(cursor.year, cursor.month + 1, 1);
      final totals =
          categorySpendForPeriod(cursor, monthEnd, accountId: accountId);
      result[cursor] = categoryId == null
          ? totals.values.fold(0.0, (a, b) => a + b)
          : rolledUpSpend(categoryId, totals, categories);
      cursor = monthEnd;
    }
    return result;
  }

  /// Same idea as [categorySpendForPeriod] but for a single payee instead
  /// of every category - "combien j'ai dépensé chez X" (natural-language
  /// query feature). Withdrawals only, same exclusions (voided, deleted).
  double payeeSpendForPeriod(int payeeId, DateTime start, DateTime end,
      {int? accountId}) {
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
    int limit = 500,
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
    int limit = 500,
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
  Map<int, DateTime> lastSpendDatePerCategory(DateTime start, DateTime end,
      {int? accountId}) {
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
    final rows = db.query(
        'SELECT * FROM BILLSDEPOSITS_V1 ORDER BY NEXTOCCURRENCEDATE ASC');
    final pausedIds = getPausedBillIds();
    final increaseByBillId = {
      for (final r in db.query(
          'SELECT BILLID, PERCENT, ANCHOR_DATE FROM APP_BILL_ANNUAL_INCREASE'))
        r['BILLID'] as int: (
          percent: (r['PERCENT'] as num).toDouble(),
          anchor: DateTime.tryParse(r['ANCHOR_DATE'] as String? ?? ''),
        ),
    };
    return rows.map((row) {
      final billId = row['BDID'] as int;
      final increase = increaseByBillId[billId];
      return BillDeposit.fromRow(
        row,
        paused: pausedIds.contains(billId),
        annualIncreasePercent: increase?.percent ?? 0,
        annualIncreaseAnchor: increase?.anchor,
      );
    }).toList();
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
    final rows = db.query(
        "SELECT INFOVALUE FROM INFOTABLE_V1 WHERE INFONAME = '$_pausedBillsInfoName'");
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
    final existing = db.query(
        "SELECT INFOID FROM INFOTABLE_V1 WHERE INFONAME = '$_pausedBillsInfoName'");
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

  /// [billId]'s "augmentation annuelle" - see [BillDeposit.annualIncreasePercent]'s
  /// own doc comment. Null if none is configured (0%, no compounding).
  ({double percent, DateTime anchor})? getBillAnnualIncrease(int billId) {
    final rows = db.query(
        'SELECT PERCENT, ANCHOR_DATE FROM APP_BILL_ANNUAL_INCREASE WHERE BILLID = ?',
        [billId]);
    if (rows.isEmpty) return null;
    final anchor =
        DateTime.tryParse(rows.first['ANCHOR_DATE'] as String? ?? '');
    if (anchor == null) return null;
    return (percent: (rows.first['PERCENT'] as num).toDouble(), anchor: anchor);
  }

  /// Sets/replaces [billId]'s annual increase. [percent] of exactly 0
  /// still writes a row (rather than clearing it) so an explicit "no
  /// increase" is distinguishable from "never configured" if that ever
  /// matters later - clearing is [clearBillAnnualIncrease] instead.
  void setBillAnnualIncrease(int billId,
      {required double percent, required DateTime anchor}) {
    db.execute(
        'DELETE FROM APP_BILL_ANNUAL_INCREASE WHERE BILLID = ?', [billId]);
    db.execute(
      'INSERT INTO APP_BILL_ANNUAL_INCREASE (BILLID, PERCENT, ANCHOR_DATE) VALUES (?, ?, ?)',
      [billId, percent, anchor.toIso8601String()],
    );
  }

  void clearBillAnnualIncrease(int billId) {
    db.execute(
        'DELETE FROM APP_BILL_ANNUAL_INCREASE WHERE BILLID = ?', [billId]);
  }

  /// A suggested annual-increase percentage for [billId], computed from
  /// this account+payee+category's *real* transaction history - never from
  /// [APP_TRANSACTION_BILL_LINKS] (which only covers transactions recorded
  /// by this app from the day that table was added on, so a bill that
  /// predates it - the common case for a file imported from years of real
  /// MMEX desktop use - would show almost no history there). Matches by
  /// [BillDeposit.payeeId] + [BillDeposit.accountId] + [BillDeposit.transCode]
  /// + [BillDeposit.categoryId] instead, the same identity [_billLabel]-style
  /// UI already uses to name a bill, plus category - not perfectly precise
  /// (an unrelated payment sharing the same payee *and* category would
  /// still count too) but the only thing that actually reaches back before
  /// this app existed, and the result is always a *suggestion* the user
  /// reviews before saving, never applied silently. Category matters: a
  /// payee is very often a whole bank or company with several unrelated
  /// real bills under it (a mortgage, several separate insurance premiums,
  /// ...) - payee alone used to silently mix all of them together (found
  /// 2026-09 via a real user report of a nonsensical suggested rate).
  ///
  /// Compound annual growth rate between the very first and very last
  /// matching transaction on record: `(last/first)^(1/yearsSpan) - 1`. Null
  /// when there's fewer than 2 matching transactions, or when they don't
  /// span at least 3 years (2026-09 user decision: one or two isolated
  /// data points aren't statistically meaningful for a rate that then gets
  /// compounded over a multi-decade simulation).
  ({double percent, DateTime anchor, double yearsSpan})? suggestedAnnualIncrease(
      int billId) {
    BillDeposit? bill;
    for (final b in getBillDeposits()) {
      if (b.id == billId) {
        bill = b;
        break;
      }
    }
    if (bill == null || bill.transCode == TransCode.transfer) return null;
    // Also filtered by category, not just payee+account+transcode (found
    // 2026-09 via a real user report: a bank ("Crédit Agricole") is a
    // single payee for *several* completely different real bills - the
    // mortgage itself, several separate insurance premiums - so payee alone
    // silently mixed a mortgage's real installment history together with
    // unrelated insurance payments, producing a nonsensical suggested rate
    // (-43.8%/an on a fixed-rate mortgage that doesn't change at all).
    // `CATEGID IS ?` (not `= ?`) so this still matches correctly when the
    // bill has no category at all (both sides null) - SQLite's IS, unlike
    // plain `=`, compares NULL to NULL as true.
    //
    // Category still isn't always enough: found the same day, on the same
    // user's real data, that *two separate loans to the same bank* (a
    // mortgage "Prêt appart" and a works loan "Prêt travaux") share payee +
    // account + category + transcode, distinguished only by NOTES - without
    // this extra filter their histories got interleaved by date, still
    // producing a nonsensical rate (-27%/an on two loans that are each
    // individually flat). MMEX has no real link from a real transaction
    // back to the bill template it came from, so this is a heuristic like
    // the category filter above, not a guaranteed-correct join - only
    // applied when the bill actually has notes to match on, so bills
    // without this ambiguity (the common case) aren't restricted further.
    final notes = bill.notes;
    final matchNotes = notes != null && notes.trim().isNotEmpty;
    final rows = db.query(
      'SELECT TRANSDATE, TRANSAMOUNT FROM CHECKINGACCOUNT_V1 '
      'WHERE PAYEEID = ? AND ACCOUNTID = ? AND TRANSCODE = ? AND CATEGID IS ? '
      "AND UPPER(TRIM(STATUS)) != 'V' AND (DELETEDTIME IS NULL OR DELETEDTIME = '') "
      '${matchNotes ? 'AND NOTES = ? ' : ''}'
      'ORDER BY TRANSDATE',
      [
        bill.payeeId,
        bill.accountId,
        transCodeToString(bill.transCode),
        bill.categoryId,
        if (matchNotes) notes,
      ],
    );
    if (rows.length < 2) return null;
    final firstDate = DateTime.tryParse(rows.first['TRANSDATE'] as String? ?? '');
    final lastDate = DateTime.tryParse(rows.last['TRANSDATE'] as String? ?? '');
    final firstAmount = (rows.first['TRANSAMOUNT'] as num?)?.toDouble();
    final lastAmount = (rows.last['TRANSAMOUNT'] as num?)?.toDouble();
    if (firstDate == null ||
        lastDate == null ||
        firstAmount == null ||
        firstAmount <= 0 ||
        lastAmount == null) {
      return null;
    }
    final yearsSpan = lastDate.difference(firstDate).inDays / 365.25;
    if (yearsSpan < 3) return null;
    final percent =
        (pow(lastAmount / firstAmount, 1 / yearsSpan) - 1).toDouble() * 100;
    // A category match alone still can't rule out a one-off outlier sharing
    // it (an early repayment, a claim refund posted under the same
    // category...) - a genuine metered/indexed increase realistically
    // never compounds past ±30%/an over a multi-year span, so anything
    // beyond that is far more likely contaminated data than a real rate.
    // Never applied silently either way (see this method's own doc
    // comment) - this only decides whether there's anything worth
    // suggesting at all.
    if (percent.abs() > 30) return null;
    return (percent: percent, anchor: lastDate, yearsSpan: yearsSpan);
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
    db.execute(
        'DELETE FROM APP_BILL_OCCURRENCE_TOTALS WHERE BILLID = ?', [bdId]);
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
    final rows =
        db.query('SELECT BILLID, TOTAL FROM APP_BILL_OCCURRENCE_TOTALS');
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
  ///
  /// [splitInto] (2026-09-02 user request - "je découpe Axeria en 2 ou 3
  /// paiements plutôt qu'un seul pour faciliter ma trésorerie, à présent je
  /// le fais manuellement") - when greater than 1, records this SAME
  /// occurrence as [splitInto] smaller transactions instead of one,
  /// [date]/[date]+1 month/[date]+2 months/... (see
  /// [recurrenceMonthSpan]/`_RecordOccurrenceDialog` for why the UI caps
  /// this below the bill's own period, so installments never run into its
  /// next real due date), each labeled "(i/N)" in its notes and linked to
  /// the same occurrence index/total as a single unsplit occurrence would
  /// be - this only changes how *this* due amount is realized into
  /// transactions, never the template's own schedule (still exactly one
  /// cycle advance below, regardless of [splitInto]) or remaining-occurrence
  /// count. Amounts are split cents-exactly (see [_splitAmountEvenly]) so
  /// they always sum back to [bill]'s real total, never silently losing or
  /// gaining a cent to rounding. Returns the first installment's
  /// transaction id (same single-int contract as the unsplit case, the only
  /// one an existing caller has ever needed).
  int recordBillOccurrence(BillDeposit bill,
      {required DateTime date, bool reconciled = false, int splitInto = 1}) {
    final installments = splitInto < 1 ? 1 : splitInto;
    final total = billOccurrenceTotals()[bill.id];
    final hasFixedCount =
        !periodUsesXParam(bill.period) && bill.numOccurrences >= 0;
    final occurrenceIndex = (hasFixedCount && total != null)
        ? total - bill.numOccurrences + 1
        : null;
    final occurrenceTotal = hasFixedCount ? total : null;

    final amounts = _splitAmountEvenly(bill.amount, installments);
    final toAmounts = _splitAmountEvenly(bill.toAmount, installments);
    int? firstTransId;
    for (var i = 0; i < installments; i++) {
      final transId = insertTransaction(
        accountId: bill.accountId,
        payeeId: bill.payeeId,
        transCode: bill.transCode,
        amount: amounts[i],
        date: i == 0 ? date : _addMonths(date, i),
        categoryId: bill.categoryId,
        toAccountId: bill.toAccountId,
        toAmount: toAmounts[i],
        notes: installments == 1
            ? bill.notes
            : '${(bill.notes ?? '').isEmpty ? '' : '${bill.notes} '}(${i + 1}/$installments)',
        reconciled: reconciled,
      );
      _linkTransactionToBill(
        transId,
        bill.id,
        occurrenceIndex: occurrenceIndex,
        occurrenceTotal: occurrenceTotal,
      );
      firstTransId ??= transId;
    }
    // The recorded date may be earlier than the template's own scheduled
    // occurrence (recording a bill a little early/late) - always advance
    // from at least the template's own anchor so the schedule can't get
    // stuck repeating the same "next occurrence" forever.
    final advanceFrom =
        date.isAfter(bill.nextOccurrence) ? date : bill.nextOccurrence;
    _applyScheduleAdvance(bill, _advanceSchedule(bill, advanceFrom));
    return firstTransId!;
  }

  /// Splits [total] into [parts] amounts that sum back to exactly [total] -
  /// never drops or invents a cent the way naively dividing a double and
  /// rounding each share independently could. Works in integer cents
  /// (rounding [total] to the nearest cent first) and hands the leftover
  /// cents from that division to the first few installments, one cent
  /// each, so e.g. 100.00 split 3 ways is [33.34, 33.33, 33.33] - not
  /// [33.33, 33.33, 33.33] (short a cent) or [33.34, 33.34, 33.34] (over by
  /// two).
  List<double> _splitAmountEvenly(double total, int parts) {
    final totalCents = (total * 100).round();
    final baseCents = totalCents ~/ parts;
    final remainderCents = totalCents - baseCents * parts;
    return [
      for (var i = 0; i < parts; i++)
        (baseCents + (i < remainderCents ? 1 : 0)) / 100,
    ];
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
  List<int> catchUpBillDeposit(BillDeposit bill, DateTime asOf,
      {bool reconciled = false}) {
    final advance = _advanceSchedule(bill, asOf);
    final ids = <int>[];
    final total = billOccurrenceTotals()[bill.id];
    final hasFixedCount =
        !periodUsesXParam(bill.period) && bill.numOccurrences >= 0;
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
        occurrenceIndex:
            (hasFixedCount && total != null) ? total - remaining + 1 : null,
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

      if (period == RecurrencePeriod.inXDays ||
          period == RecurrencePeriod.inXMonths) {
        final x = count > 0 ? count : 1;
        cursor = period == RecurrencePeriod.inXDays
            ? _addDays(cursor, x)
            : _addMonths(cursor, x);
        period = RecurrencePeriod.none;
        count = 1;
        continue;
      }
      if (period == RecurrencePeriod.everyXDays ||
          period == RecurrencePeriod.everyXMonths) {
        final x = count > 0 ? count : 1;
        cursor = period == RecurrencePeriod.everyXDays
            ? _addDays(cursor, x)
            : _addMonths(cursor, x);
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
    return _monthlyNetForBills(getBillDeposits(),
        start: start, end: end, months: months, accountId: accountId);
  }

  /// Average pay-cycle amount of real cash flow the recurring-bill schedule
  /// alone never explains, over the last [months] pay cycles up to
  /// [anchor] - what actually happened minus what the recurring schedule
  /// alone would have predicted for those same cycles, averaged. Grounds a
  /// simulation's "dépenses imprévues" adjustment in this account's own
  /// real history instead of a guessed number (2026-09-02 user report: a
  /// projection built purely from known recurring bills was consistently
  /// too optimistic - real life always has some non-recurring spending/
  /// income, groceries fluctuating, unplanned repairs..., that no bill
  /// schedule predicts). Negative when history shows more unplanned
  /// spending than the recurring schedule accounts for (the common case);
  /// positive if this account tends to end up better off than the
  /// schedule alone suggests. 0 if [months] <= 0.
  ///
  /// [startDay] required, not defaulted to the calendar month's 1st -
  /// **must** be the same "Jour de prévision du solde" [_SimulationChart]
  /// itself buckets by (see [recurringPeriodNet]'s own doc comment for
  /// why). Found 2026-09-02 comparing a user's real multi-year balance
  /// history against this figure: computing the "real" and "recurring"
  /// sides on plain calendar months here, while the chart itself had
  /// already moved to pay-cycle buckets, meant a bill landing near the
  /// pay-cycle boundary (salary, in this case) could fall in a different
  /// bucket on each side of the subtraction - silently skewing the
  /// suggested adjustment for accounts whose real "month" doesn't start on
  /// the 1st, exactly the situation this setting exists to describe.
  double historicalDiscretionaryMonthlyAverage({
    int? accountId,
    required DateTime anchor,
    required int startDay,
    int months = 12,
  }) {
    if (months <= 0) return 0;
    final windows = _consecutiveWindowsEndingAt(anchor, months, startDay);
    final real = _realNetByWindows(windows, accountId: accountId);
    final recurring =
        _netForBillsByWindows(getBillDeposits(), windows, accountId: accountId);
    var totalResidual = 0.0;
    for (final w in windows) {
      final key = w.lastIncludedDay;
      totalResidual += (real[key] ?? 0) - (recurring[key] ?? 0);
    }
    return totalResidual / months;
  }

  /// Shared bucketing core behind [recurringMonthlyNet] and
  /// [simulatedMonthlyNet] - given an already-resolved list of bill-shaped
  /// templates (real ones for the former; real (possibly overridden) plus
  /// virtual ones for the latter, see [_effectiveBillsForScenario]),
  /// projects each forward and buckets signed amounts by month. One
  /// mechanism behind both, so a fix to the projection math can never
  /// apply to only one of them.
  Map<DateTime, double> _monthlyNetForBills(
    List<BillDeposit> bills, {
    required DateTime start,
    required DateTime end,
    required int months,
    int? accountId,
    Map<int, DateTime> disabledFromByBillId = const {},
  }) {
    final result = <DateTime, double>{
      for (var i = 0; i < months; i++)
        DateTime(start.year, start.month + i, 1): 0.0,
    };

    for (final bill in bills) {
      if (bill.paused) continue;
      final involvesAccount = accountId == null ||
          bill.accountId == accountId ||
          bill.toAccountId == accountId;
      if (!involvesAccount) continue;
      if (accountId == null && bill.transCode == TransCode.transfer) continue;

      final signedAmount = _billSignedAmount(bill, accountId);
      final disabledFrom = disabledFromByBillId[bill.id];
      for (final occurrence in _occurrencesInRange(bill, start, end)) {
        if (disabledFrom != null && !occurrence.isBefore(disabledFrom)) {
          continue;
        }
        final bucket = DateTime(occurrence.year, occurrence.month, 1);
        final current = result[bucket];
        if (current == null) continue;
        final jitter = bill.variancePercent > 0
            ? _seededMonthlyJitter(bill.id, bucket, bill.variancePercent)
            : 0.0;
        final growth = _annualGrowthFactor(bill, occurrence);
        result[bucket] = current + signedAmount * growth * (1 + jitter);
      }
    }
    return result;
  }

  /// Deterministic, reproducible "noise" for [BillDeposit.variancePercent] -
  /// the same (billId, month) always yields the same jitter, so re-running
  /// the exact same projection (a screen rebuild, reopening the app) never
  /// silently redraws a different curve - only an actual change to the
  /// scenario's own settings does, preserving the "100% reliable" property
  /// the rest of this simulation engine is explicitly built for. Uniformly
  /// distributed in [-variancePercent/100, +variancePercent/100] - applied
  /// as a multiplier on the occurrence's own signed amount, never on its
  /// own an invented number (it's proportional to a real configured value).
  double _seededMonthlyJitter(
      int billId, DateTime month, double variancePercent) {
    final seed = billId * 1000003 + month.year * 100 + month.month;
    final fraction = Random(seed).nextDouble() * 2 - 1; // [-1, 1)
    return fraction * (variancePercent / 100);
  }

  /// Compounded "augmentation annuelle" multiplier for one occurrence of
  /// [bill] - see [BillDeposit.annualIncreasePercent]'s own doc comment.
  /// 1.0 (no change) whenever it's not configured. Otherwise
  /// `(1 + percent/100) ^ yearsElapsed`, where [yearsElapsed] counts how
  /// many times [BillDeposit.annualIncreaseAnchor]'s month/day has been
  /// reached on or before [occurrence] - so the very first anniversary
  /// itself already carries the first bump (a bill due exactly on its
  /// anchor date has already "had its birthday" that day), and every
  /// occurrence between two anniversaries shares the same, already-bumped
  /// amount rather than drifting continuously.
  double _annualGrowthFactor(BillDeposit bill, DateTime occurrence) {
    final anchor = bill.annualIncreaseAnchor;
    if (bill.annualIncreasePercent == 0 || anchor == null) return 1.0;
    var years = occurrence.year - anchor.year;
    if (occurrence.month < anchor.month ||
        (occurrence.month == anchor.month && occurrence.day < anchor.day)) {
      years -= 1;
    }
    if (years <= 0) return 1.0;
    return pow(1 + bill.annualIncreasePercent / 100, years).toDouble();
  }

  /// Public wrapper around the private occurrence-projection engine, for
  /// callers outside this file that need to project a single bill-shaped
  /// template (real or, via [SimVirtualBill.toBillDeposit], scenario-only)
  /// without going through a whole [_monthlyNetForBills] bucketing pass -
  /// currently unused internally, kept for future simulation UI code that
  /// wants to show individual occurrence dates for a scenario adjustment.
  List<DateTime> occurrencesForBill(
          BillDeposit bill, DateTime start, DateTime end) =>
      _occurrencesInRange(bill, start, end);

  // ---- Long-term "what if" scenarios (PLAN_SIMULATION_LONG_TERME.md,
  // phase 1) - this app's own tables, never touching BILLSDEPOSITS_V1/
  // CHECKINGACCOUNT_V1. Same CRUD shape as the budget scenarios above. ----

  List<SimScenario> getSimScenarios() {
    final rows =
        db.query('SELECT * FROM APP_SIM_SCENARIOS ORDER BY UPDATED_AT DESC');
    return rows.map(SimScenario.fromRow).toList();
  }

  int createSimScenario(String name) {
    final now = DateTime.now().toIso8601String();
    return db.execute(
      'INSERT INTO APP_SIM_SCENARIOS (NAME, CREATED_AT, UPDATED_AT) VALUES (?, ?, ?)',
      [name, now, now],
    );
  }

  void renameSimScenario(int scenarioId, String name) {
    db.execute(
      'UPDATE APP_SIM_SCENARIOS SET NAME = ?, UPDATED_AT = ? WHERE SCENARIOID = ?',
      [name, DateTime.now().toIso8601String(), scenarioId],
    );
  }

  /// [scenarioId]'s "solde final supposé" for one specific [accountId] -
  /// see [_SimulationChart]'s own doc comment for how and when this
  /// actually gets applied. Falls back to the legacy scenario-wide
  /// [SimScenario.assumedFinalBalance] column when this account has no row
  /// of its own yet (2026-09: that column used to be the only place this
  /// lived, applying the same value to every account at once - never
  /// silently drop a value someone already had set there before this
  /// account-by-account version existed). That fallback stops applying the
  /// moment this account gets its own explicit value (including an
  /// explicit "cleared"/null, tracked by the row existing at all - see
  /// [setSimAssumedFinalBalance]).
  double? getSimAssumedFinalBalance(int scenarioId, int accountId) {
    final rows = db.query(
      'SELECT AMOUNT FROM APP_SIM_ASSUMED_FINAL_BALANCES WHERE SCENARIOID = ? AND ACCOUNTID = ?',
      [scenarioId, accountId],
    );
    if (rows.isNotEmpty) return (rows.first['AMOUNT'] as num?)?.toDouble();
    final scenarioRows = db.query(
      'SELECT ASSUMED_FINAL_BALANCE FROM APP_SIM_SCENARIOS WHERE SCENARIOID = ?',
      [scenarioId],
    );
    if (scenarioRows.isEmpty) return null;
    return (scenarioRows.first['ASSUMED_FINAL_BALANCE'] as num?)?.toDouble();
  }

  /// Sets/clears [accountId]'s "solde final supposé" within [scenarioId].
  /// Pass null to clear it (back to "no adjustment" for this account,
  /// regardless of what the legacy scenario-wide value above says - see
  /// [getSimAssumedFinalBalance]'s own doc comment on why a cleared row
  /// still needs to exist rather than just being deleted).
  void setSimAssumedFinalBalance(int scenarioId, int accountId, double? value) {
    db.execute(
      'DELETE FROM APP_SIM_ASSUMED_FINAL_BALANCES WHERE SCENARIOID = ? AND ACCOUNTID = ?',
      [scenarioId, accountId],
    );
    db.execute(
      'INSERT INTO APP_SIM_ASSUMED_FINAL_BALANCES (SCENARIOID, ACCOUNTID, AMOUNT) VALUES (?, ?, ?)',
      [scenarioId, accountId, value],
    );
    db.execute(
      'UPDATE APP_SIM_SCENARIOS SET UPDATED_AT = ? WHERE SCENARIOID = ?',
      [DateTime.now().toIso8601String(), scenarioId],
    );
  }

  /// Creates a new scenario named [newName], deep-copying every adjustment
  /// saved under [sourceScenarioId] - bill overrides, virtual bills,
  /// one-off events, and every "solde final supposé" (both the current
  /// per-account rows and the legacy scenario-wide fallback column, so a
  /// duplicate behaves identically to its source until independently
  /// edited - see [getSimAssumedFinalBalance]'s own doc comment on that
  /// fallback). "Dupliquer ce scénario" (2026-09-03 user request): lets a
  /// variant ("et si je pars 2 ans plus tôt ?") start from a known-good
  /// scenario instead of rebuilding every adjustment from scratch. Returns
  /// the new scenario's id. Never touches [sourceScenarioId] itself.
  int duplicateSimScenario(int sourceScenarioId, String newName) {
    final newId = createSimScenario(newName);

    for (final o in getSimBillOverrides(sourceScenarioId)) {
      upsertSimBillOverride(newId, o.billId,
          disabledFrom: o.disabledFrom, amountOverride: o.amountOverride);
    }
    for (final v in getSimVirtualBills(sourceScenarioId)) {
      addSimVirtualBill(
        scenarioId: newId,
        accountId: v.accountId,
        label: v.label,
        transCode: v.transCode,
        amount: v.amount,
        startDate: v.startDate,
        period: v.period,
        numOccurrences: v.numOccurrences,
        variancePercent: v.variancePercent,
        annualIncreasePercent: v.annualIncreasePercent,
        annualIncreaseAnchor: v.annualIncreaseAnchor,
      );
    }
    for (final e in getSimOneOffEvents(sourceScenarioId)) {
      addSimOneOffEvent(
        scenarioId: newId,
        accountId: e.accountId,
        label: e.label,
        transCode: e.transCode,
        amount: e.amount,
        date: e.date,
      );
    }
    final balanceRows = db.query(
      'SELECT ACCOUNTID, AMOUNT FROM APP_SIM_ASSUMED_FINAL_BALANCES WHERE SCENARIOID = ?',
      [sourceScenarioId],
    );
    for (final row in balanceRows) {
      db.execute(
        'INSERT INTO APP_SIM_ASSUMED_FINAL_BALANCES (SCENARIOID, ACCOUNTID, AMOUNT) VALUES (?, ?, ?)',
        [newId, row['ACCOUNTID'], row['AMOUNT']],
      );
    }
    final legacyRows = db.query(
      'SELECT ASSUMED_FINAL_BALANCE FROM APP_SIM_SCENARIOS WHERE SCENARIOID = ?',
      [sourceScenarioId],
    );
    final legacyValue = legacyRows.isEmpty
        ? null
        : legacyRows.first['ASSUMED_FINAL_BALANCE'];
    if (legacyValue != null) {
      db.execute(
        'UPDATE APP_SIM_SCENARIOS SET ASSUMED_FINAL_BALANCE = ? WHERE SCENARIOID = ?',
        [legacyValue, newId],
      );
    }
    return newId;
  }

  /// Deletes [scenarioId] and every adjustment saved under it - other
  /// scenarios (and the real recurring bills/transactions) are untouched.
  void deleteSimScenario(int scenarioId) {
    db.execute('DELETE FROM APP_SIM_BILL_OVERRIDES WHERE SCENARIOID = ?',
        [scenarioId]);
    db.execute(
        'DELETE FROM APP_SIM_VIRTUAL_BILLS WHERE SCENARIOID = ?', [scenarioId]);
    db.execute('DELETE FROM APP_SIM_ONE_OFF_EVENTS WHERE SCENARIOID = ?',
        [scenarioId]);
    db.execute(
        'DELETE FROM APP_SIM_ASSUMED_FINAL_BALANCES WHERE SCENARIOID = ?',
        [scenarioId]);
    db.execute(
        'DELETE FROM APP_SIM_SCENARIOS WHERE SCENARIOID = ?', [scenarioId]);
  }

  List<SimBillOverride> getSimBillOverrides(int scenarioId) {
    final rows = db.query(
      'SELECT * FROM APP_SIM_BILL_OVERRIDES WHERE SCENARIOID = ?',
      [scenarioId],
    );
    return rows.map(SimBillOverride.fromRow).toList();
  }

  /// One override per (scenario, bill) - a second call for the same pair
  /// replaces the first (`INSERT ... ON CONFLICT DO UPDATE`), never leaves
  /// stale duplicate rows behind. Pass both [disabledFrom]/[amountOverride]
  /// as null (both defaults) to mean "no change at all" - equivalent to,
  /// but distinct from, [deleteSimBillOverride]: a caller can use either
  /// depending on whether it wants to keep a "touched but reset" row
  /// around (this) or remove the row entirely (that).
  void upsertSimBillOverride(
    int scenarioId,
    int billId, {
    DateTime? disabledFrom,
    double? amountOverride,
  }) {
    db.execute(
      'INSERT INTO APP_SIM_BILL_OVERRIDES (SCENARIOID, BILLID, DISABLED_FROM, AMOUNT_OVERRIDE) '
      'VALUES (?, ?, ?, ?) '
      'ON CONFLICT(SCENARIOID, BILLID) DO UPDATE SET '
      'DISABLED_FROM = excluded.DISABLED_FROM, AMOUNT_OVERRIDE = excluded.AMOUNT_OVERRIDE',
      [scenarioId, billId, disabledFrom?.toIso8601String(), amountOverride],
    );
  }

  void deleteSimBillOverride(int scenarioId, int billId) {
    db.execute(
      'DELETE FROM APP_SIM_BILL_OVERRIDES WHERE SCENARIOID = ? AND BILLID = ?',
      [scenarioId, billId],
    );
  }

  List<SimVirtualBill> getSimVirtualBills(int scenarioId) {
    final rows = db.query(
      'SELECT * FROM APP_SIM_VIRTUAL_BILLS WHERE SCENARIOID = ?',
      [scenarioId],
    );
    return rows.map(SimVirtualBill.fromRow).toList();
  }

  int addSimVirtualBill({
    required int scenarioId,
    required int accountId,
    required String label,
    required TransCode transCode,
    required double amount,
    required DateTime startDate,
    required RecurrencePeriod period,
    int numOccurrences = -1,
    double variancePercent = 0,
    double annualIncreasePercent = 0,
    DateTime? annualIncreaseAnchor,
  }) {
    return db.execute(
      'INSERT INTO APP_SIM_VIRTUAL_BILLS '
      '(SCENARIOID, ACCOUNTID, LABEL, TRANSCODE, AMOUNT, START_DATE, PERIOD, NUM_OCCURRENCES, VARIANCE_PERCENT, ANNUAL_INCREASE_PERCENT, ANNUAL_INCREASE_ANCHOR) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        scenarioId,
        accountId,
        label,
        transCodeToString(transCode),
        amount,
        startDate.toIso8601String(),
        period.name,
        numOccurrences,
        variancePercent,
        annualIncreasePercent,
        annualIncreaseAnchor?.toIso8601String(),
      ],
    );
  }

  void deleteSimVirtualBill(int virtualBillId) {
    db.execute('DELETE FROM APP_SIM_VIRTUAL_BILLS WHERE VIRTUALBILLID = ?',
        [virtualBillId]);
  }

  List<SimOneOffEvent> getSimOneOffEvents(int scenarioId) {
    final rows = db.query(
      'SELECT * FROM APP_SIM_ONE_OFF_EVENTS WHERE SCENARIOID = ?',
      [scenarioId],
    );
    return rows.map(SimOneOffEvent.fromRow).toList();
  }

  int addSimOneOffEvent({
    required int scenarioId,
    required int accountId,
    required String label,
    required TransCode transCode,
    required double amount,
    required DateTime date,
  }) {
    return db.execute(
      'INSERT INTO APP_SIM_ONE_OFF_EVENTS (SCENARIOID, ACCOUNTID, LABEL, TRANSCODE, AMOUNT, DATE) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [
        scenarioId,
        accountId,
        label,
        transCodeToString(transCode),
        amount,
        date.toIso8601String()
      ],
    );
  }

  void deleteSimOneOffEvent(int eventId) {
    db.execute(
        'DELETE FROM APP_SIM_ONE_OFF_EVENTS WHERE EVENTID = ?', [eventId]);
  }

  /// Merges the real recurring bills with [scenarioId]'s overrides/virtual
  /// bills into a single bill-shaped list [_monthlyNetForBills] can project
  /// exactly like it already does for the unmodified real schedule - a
  /// disabled real bill is dropped from [disabledFromByBillId] (checked
  /// per-occurrence, not per-bill, so occurrences before the disable date
  /// still count), an amount-overridden one is swapped via
  /// [BillDeposit.copyWith], and each virtual bill is appended via
  /// [SimVirtualBill.toBillDeposit]. A real bill the user already paused
  /// (see [BillDeposit.paused]) is included here unchanged - still excluded
  /// downstream by [_monthlyNetForBills]'s own `if (bill.paused) continue`,
  /// same as every other caller of that method.
  ({List<BillDeposit> bills, Map<int, DateTime> disabledFromByBillId})
      _effectiveBillsForScenario(int scenarioId) {
    final overridesByBillId = {
      for (final o in getSimBillOverrides(scenarioId)) o.billId: o,
    };
    final disabledFromByBillId = <int, DateTime>{};
    final bills = <BillDeposit>[];
    for (final bill in getBillDeposits()) {
      final override = overridesByBillId[bill.id];
      if (override == null) {
        bills.add(bill);
        continue;
      }
      if (override.disabledFrom != null) {
        disabledFromByBillId[bill.id] = override.disabledFrom!;
      }
      bills.add(override.amountOverride != null
          ? bill.copyWith(amount: override.amountOverride)
          : bill);
    }
    for (final virtual in getSimVirtualBills(scenarioId)) {
      bills.add(virtual.toBillDeposit());
    }
    return (bills: bills, disabledFromByBillId: disabledFromByBillId);
  }

  /// Scenario-aware counterpart to [recurringMonthlyNet] - same signature
  /// and bucketing, but projects [scenarioId]'s effective bill set (see
  /// [_effectiveBillsForScenario]) instead of the unmodified real one, and
  /// also folds in the scenario's one-off events. Never writes anything -
  /// purely a read/compute, safe to call as often as the UI needs to
  /// re-project after an edit. 100% deterministic Dart arithmetic over
  /// already-fetched rows, no AI involved anywhere in this path (fiabilité
  /// explicitly requested by the user, 2026-09-02) - see
  /// PLAN_SIMULATION_LONG_TERME.md.
  Map<DateTime, double> simulatedMonthlyNet({
    required int scenarioId,
    required DateTime anchor,
    required int months,
    int? accountId,
  }) {
    final start = DateTime(anchor.year, anchor.month - months + 1, 1);
    final end = DateTime(anchor.year, anchor.month + 1, 0);
    final effective = _effectiveBillsForScenario(scenarioId);
    final result = Map<DateTime, double>.from(_monthlyNetForBills(
      effective.bills,
      start: start,
      end: end,
      months: months,
      accountId: accountId,
      disabledFromByBillId: effective.disabledFromByBillId,
    ));

    for (final event in getSimOneOffEvents(scenarioId)) {
      if (accountId != null && event.accountId != accountId) continue;
      if (event.date.isBefore(start) || event.date.isAfter(end)) continue;
      final bucket = DateTime(event.date.year, event.date.month, 1);
      final current = result[bucket];
      if (current == null) continue;
      final signed =
          event.transCode == TransCode.deposit ? event.amount : -event.amount;
      result[bucket] = current + signed;
    }
    return result;
  }

  // ---- Pay-cycle ("Jour de prévision du solde") bucketing for the
  // simulation screen only (2026-09-02 user request) - a parallel set of
  // methods, deliberately never replacing the calendar-month ones above:
  // the user asked to try this scoped to just the simulation chart first,
  // to see whether it actually explains the "uneven" curve they noticed,
  // before deciding whether it's worth applying anywhere else
  // (recurringMonthlyNet/simulatedMonthlyNet/monthlyNetTotals keep every
  // other caller - the dashboard forecast chart, "opérations récurrentes"
  // totals - on calendar months, unchanged). See budget_period.dart's
  // BudgetWindow, already built for exactly this "month starts on a chosen
  // day, not the 1st" concept (reused here rather than reinvented).

  /// [count] consecutive [BudgetWindow]s, oldest first, the last one being
  /// whichever contains [anchor].
  List<BudgetWindow> _consecutiveWindowsEndingAt(
      DateTime anchor, int count, int startDay) {
    final windows = <BudgetWindow>[budgetWindowContaining(anchor, startDay)];
    for (var i = 1; i < count; i++) {
      windows.insert(0, previousBudgetWindow(windows.first, startDay));
    }
    return windows;
  }

  /// Pay-cycle counterpart to [_monthlyNetForBills] - same role, just
  /// bucketed by arbitrary consecutive [windows] instead of fixed calendar
  /// months.
  ///
  /// Keyed by each window's [BudgetWindow.lastIncludedDay], **not**
  /// [BudgetWindow.start] - found 2026-09-02 comparing the simulation chart
  /// against the dashboard's own day-by-day forecast: [_SimulationChart]
  /// plots a *cumulative* running balance, so the value at a given bucket
  /// already includes that whole window's cash flow - it's the balance
  /// *as of the window's last day*, not its first. Keying by [start]
  /// instead would label that cumulative value with a date up to a whole
  /// pay-cycle too early (e.g. a window running 24 Oct-23 Nov keyed "24
  /// Oct" while showing the balance as of ~23 Nov) - barely noticeable
  /// with calendar months (both ends fall in the same named month) but a
  /// full, confusing month off with a custom [startDay].
  Map<DateTime, double> _netForBillsByWindows(
    List<BillDeposit> bills,
    List<BudgetWindow> windows, {
    int? accountId,
    Map<int, DateTime> disabledFromByBillId = const {},
  }) {
    if (windows.isEmpty) return {};
    final result = <DateTime, double>{
      for (final w in windows) w.lastIncludedDay: 0.0,
    };
    final rangeStart = windows.first.start;
    final rangeEnd = windows.last.lastIncludedDay;

    for (final bill in bills) {
      if (bill.paused) continue;
      final involvesAccount = accountId == null ||
          bill.accountId == accountId ||
          bill.toAccountId == accountId;
      if (!involvesAccount) continue;
      if (accountId == null && bill.transCode == TransCode.transfer) continue;

      final signedAmount = _billSignedAmount(bill, accountId);
      final disabledFrom = disabledFromByBillId[bill.id];
      for (final occurrence
          in _occurrencesInRange(bill, rangeStart, rangeEnd)) {
        if (disabledFrom != null && !occurrence.isBefore(disabledFrom)) {
          continue;
        }
        BudgetWindow? window;
        for (final w in windows) {
          if (w.contains(occurrence)) {
            window = w;
            break;
          }
        }
        if (window == null) continue;
        final key = window.lastIncludedDay;
        final jitter = bill.variancePercent > 0
            ? _seededMonthlyJitter(bill.id, key, bill.variancePercent)
            : 0.0;
        final growth = _annualGrowthFactor(bill, occurrence);
        result[key] = result[key]! + signedAmount * growth * (1 + jitter);
      }
    }
    return result;
  }

  /// Pay-cycle counterpart to [monthlyNetTotals] - real transaction totals
  /// (not projected recurring bills) bucketed by arbitrary consecutive
  /// [windows] instead of calendar months, keyed the same way
  /// [_netForBillsByWindows] is (each window's [BudgetWindow.lastIncludedDay]).
  /// Backs [historicalDiscretionaryMonthlyAverage]'s "what actually
  /// happened" side.
  Map<DateTime, double> _realNetByWindows(
    List<BudgetWindow> windows, {
    int? accountId,
  }) {
    if (windows.isEmpty) return {};
    final where = <String>[
      'TRANSDATE >= ?',
      'TRANSDATE < ?',
      "UPPER(TRIM(STATUS)) != 'V'",
      "(DELETEDTIME IS NULL OR DELETEDTIME = '')",
    ];
    final params = <Object?>[
      _isoDate(windows.first.start),
      _isoDate(windows.last.end),
    ];
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
      for (final w in windows) w.lastIncludedDay: 0.0,
    };
    for (final row in rows) {
      final date = DateTime.tryParse(row['TRANSDATE'] as String? ?? '');
      if (date == null) continue;
      BudgetWindow? window;
      for (final w in windows) {
        if (w.contains(date)) {
          window = w;
          break;
        }
      }
      if (window == null) continue;
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
      final key = window.lastIncludedDay;
      result[key] = (result[key] ?? 0) + signed;
    }
    return result;
  }

  /// Pay-cycle counterpart to [recurringMonthlyNet] - see this section's
  /// own header comment.
  Map<DateTime, double> recurringPeriodNet({
    required DateTime anchor,
    required int periods,
    required int startDay,
    int? accountId,
  }) {
    final windows = _consecutiveWindowsEndingAt(anchor, periods, startDay);
    return _netForBillsByWindows(getBillDeposits(), windows,
        accountId: accountId);
  }

  /// Pay-cycle counterpart to [simulatedMonthlyNet] - see this section's
  /// own header comment.
  Map<DateTime, double> simulatedPeriodNet({
    required int scenarioId,
    required DateTime anchor,
    required int periods,
    required int startDay,
    int? accountId,
  }) {
    final windows = _consecutiveWindowsEndingAt(anchor, periods, startDay);
    final effective = _effectiveBillsForScenario(scenarioId);
    final result = Map<DateTime, double>.from(_netForBillsByWindows(
      effective.bills,
      windows,
      accountId: accountId,
      disabledFromByBillId: effective.disabledFromByBillId,
    ));

    for (final event in getSimOneOffEvents(scenarioId)) {
      if (accountId != null && event.accountId != accountId) continue;
      BudgetWindow? window;
      for (final w in windows) {
        if (w.contains(event.date)) {
          window = w;
          break;
        }
      }
      if (window == null) continue;
      final key = window.lastIncludedDay;
      final current = result[key];
      if (current == null) continue;
      final signed =
          event.transCode == TransCode.deposit ? event.amount : -event.amount;
      result[key] = current + signed;
    }
    return result;
  }

  /// Never emits an occurrence before [BillDeposit.nextOccurrence]: MMEX
  /// advances that date past every occurrence it already executed, so
  /// anything earlier is already a real transaction in the ledger. Without
  /// this floor, walking backward to cover [rangeStart] would regenerate
  /// the most recently completed occurrence as if it were still pending -
  /// double-counting it once as real history and once as a projection.
  List<DateTime> _occurrencesInRange(
      BillDeposit bill, DateTime rangeStart, DateTime rangeEnd) {
    final occurrences = <DateTime>[];
    final effectiveStart = rangeStart.isBefore(bill.nextOccurrence)
        ? bill.nextOccurrence
        : rangeStart;
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
        if (!occurrence.isBefore(effectiveStart) &&
            !occurrence.isAfter(rangeEnd)) {
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
    if (dayStep == null) {
      return occurrences; // RecurrencePeriod.none: one-off, not recurring.
    }
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
    return DateTime(
        year, month, date.day > lastDayOfMonth ? lastDayOfMonth : date.day);
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

  DateTime _lastDayOfMonth(DateTime date) =>
      DateTime(date.year, date.month + 1, 0);

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
        db.execute(
            'UPDATE APP_BUDGET_ENVELOPES SET AMOUNT = ? WHERE ENVELOPEID = ?',
            [amount, id]);
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
    db.execute(
        'DELETE FROM APP_BUDGET_ENVELOPES WHERE ACCOUNTID = ?', [accountId]);
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
    db.execute('DELETE FROM APP_BUDGET_SCENARIO_AMOUNTS WHERE SCENARIOID = ?',
        [scenarioId]);
    db.execute(
        'DELETE FROM APP_BUDGET_SCENARIO_CATEGORIES WHERE SCENARIOID = ?',
        [scenarioId]);
    db.execute(
        'DELETE FROM APP_BUDGET_SCENARIO_VIRTUAL_CATEGORIES WHERE SCENARIOID = ?',
        [scenarioId]);
    db.execute(
        'DELETE FROM APP_BUDGET_SCENARIOS WHERE SCENARIOID = ?', [scenarioId]);
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
    return {
      for (final row in rows)
        row['CATEGID'] as int: (row['AMOUNT'] as num).toDouble()
    };
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
      [
        DateTime.now().toIso8601String(),
        DateTime.now().toIso8601String(),
        scenarioId
      ],
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
    return {
      for (final row in rows)
        row['CATEGID'] as int: (row['VISIBLE'] as int) == 1
    };
  }

  void setBudgetScenarioCategoryVisible(
      int scenarioId, int categoryId, bool visible) {
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
  int createVirtualBudgetCategory(int scenarioId, String name,
      {int? parentCategId}) {
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
      totals[tx.categoryId!] =
          (totals[tx.categoryId!] ?? 0) + tx.signedAmountFor(accountId);
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
      final factor =
          recurrencePeriodToMonthlyFactor(bill.period, bill.numOccurrences);
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
    final parent =
        category.parentId == null ? null : categoriesById[category.parentId];
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
    final categoriesById = {
      for (final c in getCategories(onlyActive: false)) c.id: c
    };

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
    final categoriesById = {
      for (final c in getCategories(onlyActive: false)) c.id: c
    };
    var total = 0.0;
    for (final bill in getBillDeposits()) {
      if (bill.paused) continue;
      if (_isSavingsCategory(bill.categoryId, categoriesById)) continue;
      final isIncoming = bill.transCode == TransCode.deposit ||
          (bill.transCode == TransCode.transfer &&
              (accountId == null || bill.toAccountId == accountId));
      if (!isIncoming) continue;
      if (bill.transCode == TransCode.deposit &&
          accountId != null &&
          bill.accountId != accountId) {
        continue;
      }
      final factor =
          recurrencePeriodToMonthlyFactor(bill.period, bill.numOccurrences);
      if (factor <= 0) continue;
      total +=
          (bill.transCode == TransCode.transfer ? bill.toAmount : bill.amount) *
              factor;
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
    final categoriesById = {
      for (final c in getCategories(onlyActive: false)) c.id: c
    };
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
      if (bill.transCode == TransCode.deposit &&
          accountId != null &&
          bill.accountId != accountId) {
        continue;
      }
      final factor =
          recurrencePeriodToMonthlyFactor(bill.period, bill.numOccurrences);
      if (factor <= 0) continue;
      totals[categoryId] = (totals[categoryId] ?? 0) +
          (bill.transCode == TransCode.transfer ? bill.toAmount : bill.amount) *
              factor;
    }
    return totals;
  }

  // ---- Currencies ----------------------------------------------------

  CurrencyFormat? getCurrency(int currencyId) {
    final rows = db.query(
        'SELECT * FROM CURRENCYFORMATS_V1 WHERE CURRENCYID = ?', [currencyId]);
    if (rows.isEmpty) return null;
    return CurrencyFormat.fromRow(rows.first);
  }

  CurrencyFormat? getBaseCurrency() {
    final infoRows = db.query(
        "SELECT INFOVALUE FROM INFOTABLE_V1 WHERE INFONAME = 'BASECURRENCYID'");
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

  RecurringOccurrence(
      {required this.date, required this.label, required this.signedAmount});
}

/// One occurrence of a recurring bill, shaped like a CHECKINGACCOUNT_V1 row
/// (unsigned [amount] + [transCode], not a net-signed figure) - see
/// [MmexRepository.recurringScheduleRows].
class RecurringScheduleRow {
  final int accountId;
  final int? categoryId;
  final int payeeId;
  final TransCode transCode;
  final double amount;
  final DateTime date;

  RecurringScheduleRow({
    required this.accountId,
    required this.categoryId,
    required this.payeeId,
    required this.transCode,
    required this.amount,
    required this.date,
  });
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
