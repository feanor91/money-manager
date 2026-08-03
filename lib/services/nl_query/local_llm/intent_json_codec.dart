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
/// model's response isn't valid JSON, names an unrecognized "kind", or asks
/// for [QueryKind.payeeSpend] without a payee name that actually resolves,
/// this returns a null intent so the caller falls back to the rule-based
/// parser (or an "I didn't understand" message) rather than acting on a
/// half-broken guess.
({QueryIntent? intent, bool periodWasExplicit}) decodeIntentJson(
  String rawResponse, {
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

  int? resolveName(String? name, Iterable<MapEntry<int, String>> candidates) {
    if (name == null || name.trim().isEmpty) return null;
    return bestNameMatch(foldDiacritics(name), candidates);
  }

  final categoryId = resolveName(json['category'] as String?, categories.map((c) => MapEntry(c.id, c.name)));
  final accountId = resolveName(json['account'] as String?, accounts.map((a) => MapEntry(a.id, a.name)));
  final payeeId = resolveName(json['payee'] as String?, payees.map((p) => MapEntry(p.id, p.name)));

  if (kind == QueryKind.payeeSpend && payeeId == null) {
    // The model asked for a payee breakdown but named nobody we recognize -
    // safer to say "not understood" than silently answer for the wrong
    // (or no) payee.
    return (intent: null, periodWasExplicit: periodWasExplicit);
  }

  final rawTopN = json['topN'];
  final topN = switch (rawTopN) {
    int n => n,
    String s => int.tryParse(s) ?? 5,
    _ => 5,
  };

  final asOf =
      (kind == QueryKind.balance && periodWasExplicit) ? period.end.subtract(const Duration(days: 1)) : null;

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
    case 'expenseTotal':
      return QueryKind.expenseTotal;
    case 'incomeTotal':
      return QueryKind.incomeTotal;
    case 'incomeVsExpense':
      return QueryKind.incomeVsExpense;
    case 'balance':
      return QueryKind.balance;
    case 'topExpenses':
      return QueryKind.topExpenses;
    case 'payeeSpend':
      return QueryKind.payeeSpend;
    case 'outlook':
      return QueryKind.outlook;
    default:
      return null;
  }
}

/// The grammar (see local_llm_engine.dart) only guarantees *some* valid
/// JSON value, and a model can still preface it with stray text despite
/// instructions not to - trims to the outermost {...} span defensively.
String _extractJsonObject(String raw) {
  final start = raw.indexOf('{');
  final end = raw.lastIndexOf('}');
  if (start == -1 || end == -1 || end < start) return raw;
  return raw.substring(start, end + 1);
}
