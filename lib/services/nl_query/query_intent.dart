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

  /// "Mes plus grosses dépenses du mois dernier" - the biggest spending
  /// *categories* over the period, ranked by their total (not individual
  /// withdrawals: ranking single transactions let one big one-off
  /// purchase crowd out a category like "Alimentation" that actually
  /// costs more in aggregate across many smaller ones).
  topExpenses,

  /// "Combien j'ai dépensé chez Carrefour ?" - total spend at one payee.
  payeeSpend,

  /// "Mes dépenses de nourriture par mois depuis janvier" - one total per
  /// calendar month across [QueryIntent.period], optionally narrowed to one
  /// category (every category combined otherwise) - see
  /// MmexRepository.categorySpendByMonth. Distinct from [topExpenses]: this
  /// tracks one thing (or everything) over time, not several things ranked
  /// against each other at a single point in time.
  expenseByMonth,

  /// "Pourquoi vais-je finir le mois en négatif ?" - projects the balance
  /// forward to the end of [QueryIntent.period], using the same known-
  /// recurring-bills projection the forecast chart uses, and - when that
  /// lands negative - which recurring categories weigh the most between now
  /// and then. Unlike every other kind, an unqualified question here does
  /// *not* default [period] to the current calendar month - it defaults to
  /// "d'ici mon prochain jour de prévision" (Settings' forecast day, the
  /// same one the dashboard's own forecast figures use), applied by the
  /// caller (see nl_query_dialog.dart) rather than the rule-based
  /// parser/local LLM, neither of which know that setting. Never explains a
  /// one-off future transaction the user hasn't told the app about some
  /// other way; there's nothing to reason from for that.
  outlook,

  /// A generic filter+aggregate question - the (desktop/Windows-only) local
  /// LLM's ONLY vocabulary for anything shaped like "how much/how many did I
  /// [QueryIntent.adHocMetric] on [QueryIntent.adHocTransactionType]
  /// transactions matching these filters, optionally broken down by
  /// [QueryIntent.adHocGroupBy]". Replaces expenseTotal/incomeTotal/
  /// topExpenses/payeeSpend/expenseByMonth in the *model's* own vocabulary
  /// specifically (decodeIntentJson never emits those kind strings to
  /// describe a new intent any more) - they remain live QueryKind values
  /// because the rule-based parser (identical on every platform, including
  /// web/Android where this local LLM path doesn't exist at all) still
  /// produces them unchanged. See ad_hoc_query.dart for how this executes -
  /// the model never writes or sees SQL, only picks these enum values plus
  /// the same resolved category/account/payee ids and period every other
  /// kind already uses.
  adHoc,
}

/// What to compute per [AdHocGroupBy] bucket (or overall, when it's
/// [AdHocGroupBy.none]) - [QueryKind.adHoc] only.
enum AdHocMetric { sum, count, average }

/// Which CHECKINGACCOUNT_V1.TRANSCODE value(s) an ad hoc query counts -
/// [QueryKind.adHoc] only. [any] adds no TRANSCODE filter at all (every
/// transaction, transfers included); the other three each add their own
/// exact-match filter.
enum AdHocTransactionType { withdrawal, deposit, transfer, any }

/// How to bucket an ad hoc query's rows - [QueryKind.adHoc] only.
/// [category]/[payee]/[account] group by the literal CATEGID/PAYEEID/
/// ACCOUNTID as stored (no parent/child roll-up merging - that stays the
/// separate, orthogonal role of [QueryIntent.categoryId] as a *filter*).
/// [month] zero-fills any month with no matching transaction, same
/// convention as [QueryKind.expenseByMonth]/MmexRepository.categorySpendByMonth.
enum AdHocGroupBy { none, category, month, payee, account }

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

  /// Only meaningful for [QueryKind.expenseTotal]/[QueryKind.adHoc] -
  /// "dépenses récurrentes" narrows the total (and its category breakdown/
  /// detail transactions) to ones actually linked to a recurring bill,
  /// instead of every withdrawal in the period. See
  /// MmexRepository.recurringCategorySpendForPeriod (expenseTotal) /
  /// ad_hoc_query.dart (adHoc).
  final bool recurringOnly;

  /// Only meaningful for [QueryKind.adHoc] - see ad_hoc_query.dart. Null for
  /// every other kind.
  final AdHocMetric? adHocMetric;
  final AdHocTransactionType? adHocTransactionType;
  final AdHocGroupBy? adHocGroupBy;

  /// [QueryKind.adHoc] only - optional cap on the number of groups returned
  /// (an explicit "top N" in the question), highest-value first. `null`
  /// means no cap at all, every group shown - deliberately a *separate*
  /// field from [topN] (always defaulted to 5, reserved for the older
  /// [QueryKind.topExpenses]) specifically so adHoc never inherits that
  /// implicit default: a plain "mes dépenses par catégorie" should show
  /// every category, not silently just the biggest 5.
  final int? adHocLimit;

  const QueryIntent({
    required this.kind,
    required this.period,
    this.categoryId,
    this.accountId,
    this.payeeId,
    this.topN = 5,
    this.asOf,
    this.recurringOnly = false,
    this.adHocMetric,
    this.adHocTransactionType,
    this.adHocGroupBy,
    this.adHocLimit,
  });

  /// Copies every field except the ones explicitly overridden. Use this
  /// instead of manually reconstructing a `QueryIntent(...)` (see
  /// nl_query_dialog.dart's account-default/outlook-period rebuilds) - a
  /// manual reconstruction silently drops any field it forgets to list
  /// (confirmed: both existing call sites already dropped [recurringOnly]
  /// this same way, silently discarding "dépenses récurrentes" the moment
  /// the account got defaulted - the common case). Only ever needs to *set*
  /// a field here, never null one back out, so the plain `?? this.x`
  /// pattern is sufficient - no unset-sentinel needed.
  QueryIntent copyWith({
    QueryKind? kind,
    DateRange? period,
    int? categoryId,
    int? accountId,
    int? payeeId,
    int? topN,
    DateTime? asOf,
    bool? recurringOnly,
    AdHocMetric? adHocMetric,
    AdHocTransactionType? adHocTransactionType,
    AdHocGroupBy? adHocGroupBy,
    int? adHocLimit,
  }) {
    return QueryIntent(
      kind: kind ?? this.kind,
      period: period ?? this.period,
      categoryId: categoryId ?? this.categoryId,
      accountId: accountId ?? this.accountId,
      payeeId: payeeId ?? this.payeeId,
      topN: topN ?? this.topN,
      asOf: asOf ?? this.asOf,
      recurringOnly: recurringOnly ?? this.recurringOnly,
      adHocMetric: adHocMetric ?? this.adHocMetric,
      adHocTransactionType: adHocTransactionType ?? this.adHocTransactionType,
      adHocGroupBy: adHocGroupBy ?? this.adHocGroupBy,
      adHocLimit: adHocLimit ?? this.adHocLimit,
    );
  }
}
