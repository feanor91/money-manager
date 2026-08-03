import '../../data/mmex_repository.dart';
import '../../models/category.dart';
import '../../models/transaction.dart';
import 'query_intent.dart';

/// The raw numeric/list result of running a [QueryIntent] - deliberately
/// just plain data, no formatting: see answer_formatter.dart for turning
/// this into a French sentence. Only the fields relevant to the intent's
/// [QueryIntent.kind] are populated; the rest stay null.
class QueryAnswer {
  /// [QueryKind.expenseTotal] (rolled up into the chosen category and its
  /// subcategories if one was named, otherwise every withdrawal in the
  /// period), [QueryKind.payeeSpend], or [QueryKind.balance].
  final double? total;

  /// [QueryKind.incomeTotal] and [QueryKind.incomeVsExpense].
  final double? income;

  /// [QueryKind.incomeVsExpense] only.
  final double? expense;

  /// [QueryKind.expenseTotal] when no single category was named - the
  /// biggest few categories behind [total], richest-first, so the answer
  /// can mention where the money actually went. Also [QueryKind.topExpenses],
  /// where this *is* the answer (categories ranked by total, not a single
  /// number) rather than just supporting detail.
  final Map<int, double>? categoryBreakdown;

  /// Individual withdrawals backing up [total] - detail behind
  /// [QueryKind.expenseTotal] (when a single category was named) and
  /// [QueryKind.payeeSpend], biggest first. Deliberately capped to a
  /// handful rather than every matching transaction (see
  /// [MmexRepository.transactionsForCategories]/[MmexRepository.transactionsForPayee]).
  final List<MoneyTransaction>? transactions;

  /// [QueryKind.outlook] only - the projected balance at the end of
  /// [QueryIntent.period], starting from [total] (today's real balance,
  /// future-dated entries included) plus known recurring bills between now
  /// and then. For [QueryKind.outlook], [categoryBreakdown] holds the
  /// biggest recurring-category contributors to that projection (negative
  /// values only, richest-first) instead of historical spend.
  final double? forecastTotal;

  /// [QueryKind.outlook] only - the first day the running projection dips
  /// below zero, if it does at all (null if it stays non-negative
  /// throughout, or was already negative today - see
  /// [answer_formatter.dart] for how those two are told apart).
  final DateTime? forecastCrossesNegativeOn;

  const QueryAnswer({
    this.total,
    this.income,
    this.expense,
    this.categoryBreakdown,
    this.transactions,
    this.forecastTotal,
    this.forecastCrossesNegativeOn,
  });
}

/// See mmex_repository.dart's/forecast_chart.dart's own copies of this - a
/// calendar-day (not elapsed-time) step, safe across DST transitions.
DateTime _addDays(DateTime date, int days) => DateTime(date.year, date.month, date.day + days);

/// Executes [intent] against [repo] - always the same deterministic
/// repository calls regardless of whether [intent] was produced by the
/// rule-based parser or (desktop/Windows only) a local LLM: the model never
/// computes a number itself, it only ever picks which of these calls to
//// make. [now] is the default "as of"/"today" moment for
/// [QueryKind.balance] (when the question didn't name a period) and
/// [QueryKind.outlook] (always - "today" is the whole premise), overridable
/// for tests.
QueryAnswer runQuery(QueryIntent intent, MmexRepository repo, {DateTime? now}) {
  switch (intent.kind) {
    case QueryKind.expenseTotal:
      final totals = repo.categorySpendForPeriod(
        intent.period.start,
        intent.period.end,
        accountId: intent.accountId,
      );
      if (intent.categoryId != null) {
        final categories = repo.getCategories(onlyActive: false);
        final categoryIds = [
          intent.categoryId!,
          for (final c in categories)
            if (c.parentId == intent.categoryId) c.id,
        ];
        final transactions = repo.transactionsForCategories(
          categoryIds,
          intent.period.start,
          intent.period.end,
          accountId: intent.accountId,
        );
        return QueryAnswer(
          total: rolledUpSpend(intent.categoryId!, totals, categories),
          transactions: transactions,
        );
      }
      final total = totals.values.fold(0.0, (a, b) => a + b);
      final sorted = totals.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      final breakdown = {for (final e in sorted.take(3)) e.key: e.value};
      return QueryAnswer(total: total, categoryBreakdown: breakdown);

    case QueryKind.incomeTotal:
      final income = repo.incomeForPeriod(
        intent.period.start,
        intent.period.end,
        accountId: intent.accountId,
      );
      return QueryAnswer(income: income);

    case QueryKind.incomeVsExpense:
      final income = repo.incomeForPeriod(
        intent.period.start,
        intent.period.end,
        accountId: intent.accountId,
      );
      final totals = repo.categorySpendForPeriod(
        intent.period.start,
        intent.period.end,
        accountId: intent.accountId,
      );
      final expense = totals.values.fold(0.0, (a, b) => a + b);
      return QueryAnswer(income: income, expense: expense);

    case QueryKind.balance:
      final accountId = intent.accountId;
      if (accountId == null) {
        throw ArgumentError(
            'QueryKind.balance requires a resolved accountId - callers must '
            'resolve a default (e.g. the dashboard\'s selected account) '
            'before calling runQuery, never guess silently.');
      }
      final asOf = intent.asOf ?? now ?? DateTime.now();
      return QueryAnswer(total: repo.accountBalance(accountId, asOf: asOf));

    case QueryKind.topExpenses:
      final totals = repo.categorySpendForPeriod(
        intent.period.start,
        intent.period.end,
        accountId: intent.accountId,
      );
      final sorted = totals.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      final breakdown = {for (final e in sorted.take(intent.topN)) e.key: e.value};
      return QueryAnswer(categoryBreakdown: breakdown);

    case QueryKind.payeeSpend:
      final payeeId = intent.payeeId;
      if (payeeId == null) {
        throw ArgumentError(
            'QueryKind.payeeSpend requires a resolved payeeId - the rule-based '
            'parser only ever produces this kind together with one.');
      }
      final total = repo.payeeSpendForPeriod(
        payeeId,
        intent.period.start,
        intent.period.end,
        accountId: intent.accountId,
      );
      final transactions = repo.transactionsForPayee(
        payeeId,
        intent.period.start,
        intent.period.end,
        accountId: intent.accountId,
      );
      return QueryAnswer(total: total, transactions: transactions);

    case QueryKind.outlook:
      final accountId = intent.accountId;
      if (accountId == null) {
        throw ArgumentError(
            'QueryKind.outlook requires a resolved accountId - callers must '
            'resolve a default (e.g. the dashboard\'s selected account) '
            'before calling runQuery, never guess silently.');
      }
      final asOfNow = now ?? DateTime.now();
      final today = DateTime(asOfNow.year, asOfNow.month, asOfNow.day);
      // period.end is exclusive - the outlook's target is the period's
      // actual last day, same convention the rule-based parser already
      // uses for QueryKind.balance's asOf.
      final targetEnd = intent.period.end.subtract(const Duration(days: 1));
      final current = repo.accountBalance(accountId);

      if (!targetEnd.isAfter(today)) {
        // The asked-about period is already over (or ends today) - nothing
        // ahead to project, so no "why" breakdown either.
        return QueryAnswer(total: current, forecastTotal: current);
      }

      final windowStart = _addDays(today, 1);
      final daysAhead = targetEnd.difference(today).inDays;
      final recurring = repo.recurringDailyNet(
        anchor: targetEnd,
        days: daysAhead + 1,
        accountId: accountId,
      );
      var cumulative = current;
      DateTime? crossesNegativeOn;
      var cursor = windowStart;
      while (!cursor.isAfter(targetEnd)) {
        final wasNonNegative = cumulative >= 0;
        cumulative += recurring[cursor] ?? 0.0;
        if (wasNonNegative && cumulative < 0 && crossesNegativeOn == null) {
          crossesNegativeOn = cursor;
        }
        cursor = _addDays(cursor, 1);
      }

      final categoryNet = repo.recurringCategoryNet(
        start: windowStart,
        end: targetEnd,
        accountId: accountId,
      );
      final sorted = categoryNet.entries.where((e) => e.value < 0).toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      final breakdown = {for (final e in sorted.take(intent.topN)) e.key: e.value};

      return QueryAnswer(
        total: current,
        forecastTotal: cumulative,
        categoryBreakdown: breakdown,
        forecastCrossesNegativeOn: crossesNegativeOn,
      );
  }
}
