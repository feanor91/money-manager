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
  /// can mention where the money actually went.
  final Map<int, double>? categoryBreakdown;

  /// [QueryKind.topExpenses] - individual withdrawals, biggest first.
  final List<MoneyTransaction>? transactions;

  const QueryAnswer({
    this.total,
    this.income,
    this.expense,
    this.categoryBreakdown,
    this.transactions,
  });
}

/// Executes [intent] against [repo] - always the same deterministic
/// repository calls regardless of whether [intent] was produced by the
/// rule-based parser or (desktop/Windows only) a local LLM: the model never
/// computes a number itself, it only ever picks which of these calls to
//// make. [now] is only used as the default "as of" moment for
/// [QueryKind.balance] when the question didn't name a period (overridable
/// for tests).
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
        return QueryAnswer(total: rolledUpSpend(intent.categoryId!, totals, categories));
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
      final transactions = repo.topExpenses(
        intent.period.start,
        intent.period.end,
        accountId: intent.accountId,
        limit: intent.topN,
      );
      return QueryAnswer(transactions: transactions);

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
      return QueryAnswer(total: total);
  }
}
