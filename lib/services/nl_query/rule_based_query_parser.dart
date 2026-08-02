import '../../models/account.dart';
import '../../models/category.dart';
import '../../models/payee.dart';
import '../../utils/list_utils.dart';
import 'name_matcher.dart';
import 'period_parser.dart';
import 'query_intent.dart';

/// The rule-based (no AI - fully local, free, identical on web/Android/
/// desktop) question parser: recognizes a fixed set of common French
/// phrasings and maps them to a [QueryIntent]. `intent` is null when the
/// question doesn't match any recognized pattern at all, so the caller can
/// show a helpful "essaie plutôt..." message instead of guessing wrong.
/// `periodWasExplicit` is false when no period was mentioned at all and
/// [QueryIntent.period] silently fell back to the current month - the
/// caller should say so in the answer rather than pretending the question
/// specified it.
({QueryIntent? intent, bool periodWasExplicit}) parseQuestion(
  String question, {
  required List<Category> categories,
  required List<Account> accounts,
  required List<Payee> payees,
  DateTime? now,
}) {
  final text = foldDiacritics(question);
  if (text.trim().isEmpty) return (intent: null, periodWasExplicit: false);

  final explicitPeriod = parsePeriod(text, now: now);
  final period = explicitPeriod ?? currentMonthRange(now: now);
  final periodWasExplicit = explicitPeriod != null;

  final accountId = bestNameMatch(text, accounts.map((a) => MapEntry(a.id, a.name)));
  final payeeId = RegExp(r'\bchez\b').hasMatch(text)
      ? bestNameMatch(text, payees.map((p) => MapEntry(p.id, p.name)))
      : null;

  QueryIntent intent;

  if (RegExp(r'plus (?:gross|grand)es? depenses|top\s*\d*\s*depenses').hasMatch(text)) {
    final topMatch = RegExp(r'top\s*(\d+)').firstMatch(text);
    final n = int.tryParse(topMatch?.group(1) ?? '') ?? 5;
    intent = QueryIntent(
        kind: QueryKind.topExpenses, period: period, accountId: accountId, topN: n);
  } else if (payeeId != null) {
    intent = QueryIntent(
        kind: QueryKind.payeeSpend, period: period, accountId: accountId, payeeId: payeeId);
  } else if (RegExp(r'\bsolde\b|\bbalance\b').hasMatch(text)) {
    // A mentioned period ("le solde en juillet") means "as of the end of
    // that period"; no period at all means "right now" (executor default).
    final asOf = periodWasExplicit ? period.end.subtract(const Duration(days: 1)) : null;
    intent = QueryIntent(kind: QueryKind.balance, period: period, accountId: accountId, asOf: asOf);
  } else if (_mentionsIncome(text) && _mentionsExpense(text)) {
    intent = QueryIntent(kind: QueryKind.incomeVsExpense, period: period, accountId: accountId);
  } else if (_mentionsIncome(text)) {
    intent = QueryIntent(kind: QueryKind.incomeTotal, period: period, accountId: accountId);
  } else if (_mentionsExpense(text)) {
    final categoryId = bestNameMatch(text, categories.map((c) => MapEntry(c.id, c.name)));
    intent = QueryIntent(
        kind: QueryKind.expenseTotal,
        period: period,
        accountId: accountId,
        categoryId: categoryId);
  } else {
    return (intent: null, periodWasExplicit: periodWasExplicit);
  }

  return (intent: intent, periodWasExplicit: periodWasExplicit);
}

bool _mentionsExpense(String text) => RegExp(
      r'depense|sortie|sorties|debit|debite',
    ).hasMatch(text);

bool _mentionsIncome(String text) => RegExp(
      r'revenu|rentree|salaire|encaisse|recette|gagne|touche',
    ).hasMatch(text);
