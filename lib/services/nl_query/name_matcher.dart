import '../../utils/list_utils.dart';

/// The id whose name is the *longest* match found as a whole word/phrase in
/// [text] - longest wins so a subcategory ("Restaurant") is preferred over
/// a parent category name that happens to also appear ("Alimentation"), and
/// so a two-word account/payee name is preferred over a shorter unrelated
/// one that happens to be a substring. Names shorter than 3 characters are
/// ignored - too likely to false-positive on ordinary words. Shared by the
/// rule-based parser and (desktop/Windows only) the local-LLM intent codec,
/// so a category/account/payee name is resolved the exact same way
/// regardless of which parser is answering the question.
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
  return best?.key;
}
