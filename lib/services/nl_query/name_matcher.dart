import '../../utils/list_utils.dart';

/// Generic French finance-question vocabulary - the same kind of word
/// [rule_based_query_parser.dart]'s own `_mentionsExpense`/`_mentionsIncome`/
/// etc. regexes look for to decide *what kind* of question is being asked,
/// not a word that meaningfully identifies *which* category/account/payee.
/// Excluded from the partial-match fallback below only (never the exact
/// full-name match above it, which stays exact on purpose): without this,
/// a category like "Autres dépenses" partial-matched *every* expense
/// question purely because the word "dépenses" is what made the question
/// recognized as an expense question in the first place - found 2026-09-02
/// while adding partial matching, via a widget test asking "Quelles ont été
/// mes dépenses ce mois-ci ?" unexpectedly narrowing to that category
/// instead of answering with the total across every category.
const _genericFinanceWords = {
  'depense', 'depenses', 'revenu', 'revenus', 'solde', 'balance', 'compte',
  'comptes', 'mois', 'annee', 'annees', 'jour', 'jours', 'argent',
  'transaction', 'transactions', 'operation', 'operations', 'achat',
  'achats', 'banque', 'montant', 'total', 'totaux', 'paiement',
  'paiements', 'virement', 'virements', 'autre', 'autres', 'chaque',
};

/// The id whose name is the *longest* match found as a whole word/phrase in
/// [text] - longest wins so a subcategory ("Restaurant") is preferred over
/// a parent category name that happens to also appear ("Alimentation"), and
/// so a two-word account/payee name is preferred over a shorter unrelated
/// one that happens to be a substring. Names shorter than 3 characters are
/// ignored - too likely to false-positive on ordinary words. Shared by the
/// rule-based parser and (desktop/Windows only) the local-LLM intent codec,
/// so a category/account/payee name is resolved the exact same way
/// regardless of which parser is answering the question.
///
/// Falls back to a *partial* match (2026-09-02 user request: "chez Martin"
/// should find payee "Cabinet Vétérinaire Martin & Associés" even though
/// the question never names it in full) when no candidate's full name
/// appears verbatim - the candidate sharing the most/longest whole words
/// with [text] wins, so a longer, more specific overlap always beats a
/// short generic one. Still word-boundary based, not spelling-tolerant: a
/// misspelled or abbreviated single word ("Véto" for "Vétérinaire") still
/// won't match - only genuinely shared whole words do.
int? bestNameMatch(String text, Iterable<MapEntry<int, String>> candidates) {
  MapEntry<int, String>? best;
  for (final candidate in candidates) {
    final name = candidate.value.trim();
    if (name.length < 3) continue;
    final normalized = foldDiacritics(name);
    if (RegExp('\\b${RegExp.escape(normalized)}\\b').hasMatch(text)) {
      if (best == null || normalized.length > foldDiacritics(best.value).length) {
        best = candidate;
      }
    }
  }
  if (best != null) return best.key;

  MapEntry<int, String>? bestPartial;
  var bestScore = 0;
  for (final candidate in candidates) {
    final name = candidate.value.trim();
    if (name.length < 3) continue;
    final normalized = foldDiacritics(name);
    final words = normalized
        .split(RegExp(r'[^a-z0-9]+'))
        .where((w) => w.length >= 3 && !_genericFinanceWords.contains(w));
    var score = 0;
    for (final word in words) {
      if (RegExp('\\b${RegExp.escape(word)}\\b').hasMatch(text)) {
        score += word.length;
      }
    }
    if (score > bestScore) {
      bestScore = score;
      bestPartial = candidate;
    }
  }
  return bestPartial?.key;
}
