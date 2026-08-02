/// What kind of question is being asked - see [QueryIntent].
enum QueryKind {
  /// "Quelles ont été mes dépenses en juillet ?" - total spend over a
  /// period, optionally narrowed to one category.
  expenseTotal,

  /// "Combien j'ai touché en revenus ce mois-ci ?"
  incomeTotal,

  /// "Revenus et dépenses de ce mois" - both totals side by side, plus the
  /// net difference.
  incomeVsExpense,

  /// "Quel est le solde de mon compte courant ?" (optionally "au 15 juin").
  balance,

  /// "Mes plus grosses dépenses du mois dernier" - a ranked list of
  /// individual withdrawals, not a total.
  topExpenses,

  /// "Combien j'ai dépensé chez Carrefour ?" - total spend at one payee.
  payeeSpend,
}

/// A half-open date window [start, end) plus a human-readable French label
/// describing it, so the answer can say "en juillet 2026" or "sur les 3
/// derniers mois" instead of just printing raw dates.
class DateRange {
  final DateTime start;
  final DateTime end;
  final String label;

  const DateRange({required this.start, required this.end, required this.label});

  bool contains(DateTime day) => !day.isBefore(start) && day.isBefore(end);
}

/// A structured, unambiguous natural-language question, however it was
/// produced (the rule-based parser, or - desktop/Windows only - a local
/// LLM extracting the same structure). Deliberately holds no free text and
/// no SQL: every field is either a resolved id (validated against the
/// database's real categories/accounts/payees) or a plain value, so
/// executing it (see query_executor.dart) is always the same deterministic
/// repository calls regardless of which parser produced it.
class QueryIntent {
  final QueryKind kind;
  final DateRange period;
  final int? categoryId;
  final int? accountId;
  final int? payeeId;
  final int topN;

  /// Only meaningful for [QueryKind.balance] - defaults to "right now" (the
  /// end of [period]) when null, see query_executor.dart.
  final DateTime? asOf;

  const QueryIntent({
    required this.kind,
    required this.period,
    this.categoryId,
    this.accountId,
    this.payeeId,
    this.topN = 5,
    this.asOf,
  });
}
