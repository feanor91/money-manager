import 'package:flutter_test/flutter_test.dart';
import 'package:money_manager/services/nl_query/name_matcher.dart';
import 'package:money_manager/utils/list_utils.dart';

void main() {
  // Real callers always pass already-folded (lowercased, accent-stripped)
  // text (see rule_based_query_parser.dart/intent_json_codec.dart) -
  // bestNameMatch itself only folds the candidate names, not [text].
  int? match(String rawText, List<MapEntry<int, String>> candidates) =>
      bestNameMatch(foldDiacritics(rawText), candidates);

  test('exact full-name match still wins over any partial match', () {
    final candidates = [
      const MapEntry(1, 'Cabinet Vétérinaire Martin'),
      const MapEntry(2, 'Martin'),
    ];
    expect(match('combien chez Martin', candidates), 2);
  });

  test('partial match: a shortened mention finds the full multi-word name '
      '(2026-09-02 user request)', () {
    final candidates = [
      const MapEntry(1, 'Cabinet Vétérinaire Martin & Associés'),
      const MapEntry(2, 'Carrefour'),
    ];
    expect(match('combien chez Martin', candidates), 1);
  });

  test('partial match picks the candidate with the most shared words', () {
    final candidates = [
      const MapEntry(1, 'Réparation Voiture Garage Dupont'),
      const MapEntry(2, 'Atelier'),
    ];
    expect(match('reparation voiture au garage', candidates), 1);
  });

  test('no shared word at all -> null, even with a misspelled/abbreviated word', () {
    final candidates = [const MapEntry(1, 'Cabinet Vétérinaire Martin')];
    expect(match('frais de veto', candidates), isNull);
  });

  test('words shorter than 3 characters never contribute to a partial match', () {
    final candidates = [const MapEntry(1, 'Le Du')];
    expect(match('le prix du pain', candidates), isNull);
  });

  test('generic finance-question vocabulary never triggers a partial match '
      'on its own - "Autres dépenses" must not swallow every expense '
      'question just because the word "dépenses" is what made it '
      'recognized as one', () {
    final candidates = [const MapEntry(1, 'Autres dépenses')];
    expect(match('quelles ont ete mes depenses ce mois-ci', candidates), isNull);
  });
}
