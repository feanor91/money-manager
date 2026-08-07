import 'dart:convert';

import '../../../models/account.dart';
import '../../../models/category.dart';
import '../../../models/payee.dart';
import '../../../utils/list_utils.dart';
import '../name_matcher.dart';
import '../period_parser.dart';
import '../query_intent.dart';

/// Turns the local LLM's raw text response into a [QueryIntent] - the only
/// place (desktop/Windows only) where a model's output ever gets turned
/// into something the app acts on, so every field is validated the same
/// deterministic way the rule-based parser already validates its own
/// matches: a category/account/payee name the model mentions is resolved
/// against the *real* database rows via [bestNameMatch] (never trusted as
/// an id the model invented), and a period phrase is resolved via
/// [parsePeriod] (never trusted as dates the model computed itself). If the
/// model's response isn't valid JSON, names an unrecognized "kind" (see
/// [_kindFromString] - this notably includes every *retired* kind string
/// like "expenseTotal", which the model is no longer taught to produce but
/// could still drift back to out of habit), or asks for [QueryKind.adHoc]
/// without a fully-resolved metric/transactionType/groupBy, this returns a
/// null intent so the caller falls back to the rule-based parser (or an "I
/// didn't understand" message) rather than acting on a half-broken guess.
({QueryIntent? intent, bool periodWasExplicit}) decodeIntentJson(
  String rawResponse, {
  required String question,
  required List<Category> categories,
  required List<Account> accounts,
  required List<Payee> payees,
  DateTime? now,
}) {
  final Map<String, dynamic> json;
  try {
    final decoded = jsonDecode(_extractJsonObject(rawResponse));
    if (decoded is! Map<String, dynamic>) {
      return (intent: null, periodWasExplicit: false);
    }
    json = decoded;
  } catch (_) {
    return (intent: null, periodWasExplicit: false);
  }

  final kind = _kindFromString(json['kind'] as String?);
  if (kind == null) return (intent: null, periodWasExplicit: false);

  final periodText = json['period'] as String?;
  final explicitPeriod =
      (periodText != null && periodText.trim().isNotEmpty) ? parsePeriod(periodText, now: now) : null;
  final period = explicitPeriod ?? currentMonthRange(now: now);
  final periodWasExplicit = explicitPeriod != null;

  // Matched against the full original [question], not the model's own
  // "account"/"category"/"payee" field - found 2026-08-07 answering a
  // completely different account than the one actually asked about
  // ("compte Boursorama" answered as "Crédit Agricole Compte commun"):
  // the small on-device model can mis-copy the name it's supposed to be
  // quoting verbatim (see _systemPrompt's "recopie seulement ce que dit
  // la question"), and bestNameMatch happily resolves whatever it *did*
  // write to a real, but wrong, account. The field is still used as the
  // signal for *whether* a name was mentioned at all (a null field means
  // no filter, even if some unrelated word in the question happens to
  // collide with a real name) - only the text actually searched for a
  // match changes, to the one source the model can't have transcribed
  // wrong: the user's own words.
  final foldedQuestion = foldDiacritics(question);
  int? resolveName(String? mentioned, Iterable<MapEntry<int, String>> candidates) {
    if (mentioned == null || mentioned.trim().isEmpty) return null;
    return bestNameMatch(foldedQuestion, candidates);
  }

  final categoryId = resolveName(json['category'] as String?, categories.map((c) => MapEntry(c.id, c.name)));
  final accountId = resolveName(json['account'] as String?, accounts.map((a) => MapEntry(a.id, a.name)));
  final payeeId = resolveName(json['payee'] as String?, payees.map((p) => MapEntry(p.id, p.name)));

  final rawTopN = json['topN'];
  final topN = switch (rawTopN) {
    int n => n,
    String s => int.tryParse(s) ?? 5,
    _ => 5,
  };

  final asOf =
      (kind == QueryKind.balance && periodWasExplicit) ? period.end.subtract(const Duration(days: 1)) : null;

  if (kind == QueryKind.adHoc) {
    final metric = _adHocMetricFromString(json['metric'] as String?);
    final transactionType = _adHocTransactionTypeFromString(json['transactionType'] as String?);
    final groupBy = _adHocGroupByFromString(json['groupBy'] as String?);
    // Required - a missing/garbage value means the model didn't follow the
    // schema, don't guess (same fail-closed principle the old payeeSpend
    // check used to apply). recurringOnly stays optional: a boolean
    // defaulting safely to false is much lower-risk than guessing the
    // wrong metric/type/grouping would be.
    if (metric == null || transactionType == null || groupBy == null) {
      return (intent: null, periodWasExplicit: periodWasExplicit);
    }
    // A category/account/payee the model *did* name, but that resolved to
    // nobody real, must fail closed too - generalizes the old payeeSpend-
    // only guard to all three filters, now that adHoc treats them on equal
    // footing. Silently dropping the filter instead (as an unresolved
    // *category* used to do for expenseTotal) would answer a broader
    // question than the one actually asked ("dépenses chez Auchan" -> a
    // total across every payee) while looking exactly like a real answer -
    // exactly the kind of confidently-wrong result this app never allows.
    bool namedButUnresolved(String? raw, int? resolved) =>
        raw != null && raw.trim().isNotEmpty && resolved == null;
    if (namedButUnresolved(json['category'] as String?, categoryId) ||
        namedButUnresolved(json['account'] as String?, accountId) ||
        namedButUnresolved(json['payee'] as String?, payeeId)) {
      return (intent: null, periodWasExplicit: periodWasExplicit);
    }
    return (
      intent: QueryIntent(
        kind: kind,
        period: period,
        categoryId: categoryId,
        accountId: accountId,
        payeeId: payeeId,
        recurringOnly: json['recurringOnly'] == true,
        adHocMetric: metric,
        adHocTransactionType: transactionType,
        adHocGroupBy: groupBy,
        adHocLimit: _adHocLimitFromJson(rawTopN),
      ),
      periodWasExplicit: periodWasExplicit,
    );
  }

  final intent = QueryIntent(
    kind: kind,
    period: period,
    categoryId: categoryId,
    accountId: accountId,
    payeeId: payeeId,
    topN: topN,
    asOf: asOf,
  );
  return (intent: intent, periodWasExplicit: periodWasExplicit);
}

QueryKind? _kindFromString(String? s) {
  switch (s) {
    case 'adHoc':
      return QueryKind.adHoc;
    case 'balance':
      return QueryKind.balance;
    case 'outlook':
      return QueryKind.outlook;
    case 'incomeVsExpense':
      return QueryKind.incomeVsExpense;
    default:
      // Includes every retired kind string ("expenseTotal", "topExpenses",
      // "payeeSpend", "incomeTotal", "expenseByMonth") on purpose - those
      // QueryKind values still exist (the rule-based parser still produces
      // them), but the model is no longer taught them and must not be able
      // to trigger them just by drifting back to an old habit.
      return null;
  }
}

AdHocMetric? _adHocMetricFromString(String? s) => switch (s) {
      'sum' => AdHocMetric.sum,
      'count' => AdHocMetric.count,
      'average' => AdHocMetric.average,
      _ => null,
    };

AdHocTransactionType? _adHocTransactionTypeFromString(String? s) => switch (s) {
      'withdrawal' => AdHocTransactionType.withdrawal,
      'deposit' => AdHocTransactionType.deposit,
      'transfer' => AdHocTransactionType.transfer,
      'any' => AdHocTransactionType.any,
      _ => null,
    };

AdHocGroupBy? _adHocGroupByFromString(String? s) => switch (s) {
      'none' => AdHocGroupBy.none,
      'category' => AdHocGroupBy.category,
      'month' => AdHocGroupBy.month,
      'payee' => AdHocGroupBy.payee,
      'account' => AdHocGroupBy.account,
      _ => null,
    };

/// Unlike the shared `topN` parsing above (which defaults to 5 for the
/// older fixed kinds), this deliberately has NO default - `null` means "no
/// cap requested", not "cap at 5". See QueryIntent.adHocLimit.
int? _adHocLimitFromJson(Object? raw) => switch (raw) {
      int n => n,
      String s => int.tryParse(s),
      _ => null,
    };

/// The grammar (see local_llm_engine.dart) only guarantees *some* valid
/// JSON value, and a model can still preface it with stray text despite
/// instructions not to - trims to the outermost {...} span defensively.
String _extractJsonObject(String raw) {
  final start = raw.indexOf('{');
  final end = raw.lastIndexOf('}');
  if (start == -1 || end == -1 || end < start) return raw;
  return raw.substring(start, end + 1);
}
