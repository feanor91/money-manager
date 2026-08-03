import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:money_manager/services/nl_query/period_parser.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('fr_FR');
  });

  // A Wednesday, so "cette semaine"/"la semaine dernière" tests use a
  // separate fixed Monday instead of depending on this date's weekday.
  final now = DateTime(2026, 8, 5, 10);

  test('no recognizable period returns null', () {
    expect(parsePeriod('bonjour, comment ça va ?', now: now), isNull);
  });

  test("ce mois-ci / mois en cours -> current month", () {
    final range = parsePeriod('mes dépenses de ce mois-ci', now: now)!;
    expect(range.start, DateTime(2026, 8, 1));
    expect(range.end, DateTime(2026, 9, 1));
    expect(range.label, 'Août 2026');
  });

  test('mois dernier -> previous month', () {
    final range = parsePeriod('mes dépenses le mois dernier', now: now)!;
    expect(range.start, DateTime(2026, 7, 1));
    expect(range.end, DateTime(2026, 8, 1));
    expect(range.label, 'Juillet 2026');
  });

  test('named month without year, still ahead this year -> assumed last year', () {
    // "décembre" (month 12) hasn't happened yet relative to August 2026, so
    // this must mean December 2025, not a future December 2026.
    final range = parsePeriod('mes dépenses en décembre', now: now)!;
    expect(range.start, DateTime(2025, 12, 1));
    expect(range.end, DateTime(2026, 1, 1));
  });

  test('named month without year, already passed this year -> this year', () {
    final range = parsePeriod('mes dépenses en juillet', now: now)!;
    expect(range.start, DateTime(2026, 7, 1));
    expect(range.end, DateTime(2026, 8, 1));
  });

  test('named month with explicit year always wins, regardless of ordering', () {
    final range = parsePeriod('mes dépenses en décembre 2026', now: now)!;
    expect(range.start, DateTime(2026, 12, 1));
    expect(range.end, DateTime(2027, 1, 1));
  });

  test('cette année -> current calendar year', () {
    final range = parsePeriod('mes dépenses cette année', now: now)!;
    expect(range.start, DateTime(2026, 1, 1));
    expect(range.end, DateTime(2027, 1, 1));
    expect(range.label, '2026');
  });

  test("l'année dernière -> previous calendar year", () {
    final range = parsePeriod("mes dépenses l'année dernière", now: now)!;
    expect(range.start, DateTime(2025, 1, 1));
    expect(range.end, DateTime(2026, 1, 1));
  });

  test('bare year -> that whole calendar year', () {
    final range = parsePeriod('mes dépenses en 2024', now: now)!;
    expect(range.start, DateTime(2024, 1, 1));
    expect(range.end, DateTime(2025, 1, 1));
  });

  test('les 3 derniers mois -> rolling 3-month window including current month', () {
    final range = parsePeriod('mes dépenses sur les 3 derniers mois', now: now)!;
    expect(range.start, DateTime(2026, 6, 1));
    expect(range.end, DateTime(2026, 9, 1));
  });

  test('les 10 derniers jours -> rolling day window including today', () {
    final range = parsePeriod('mes dépenses sur les 10 derniers jours', now: now)!;
    expect(range.start, DateTime(2026, 7, 26));
    expect(range.end, DateTime(2026, 8, 6));
  });

  test("aujourd'hui -> just today", () {
    final range = parsePeriod("mes dépenses d'aujourd'hui", now: now)!;
    expect(range.start, DateTime(2026, 8, 5));
    expect(range.end, DateTime(2026, 8, 6));
  });

  test('hier -> just yesterday', () {
    final range = parsePeriod('mes dépenses d\'hier', now: now)!;
    expect(range.start, DateTime(2026, 8, 4));
    expect(range.end, DateTime(2026, 8, 5));
  });

  test('explicit dd/mm/yyyy range', () {
    final range = parsePeriod('du 01/06/2026 au 30/06/2026', now: now)!;
    expect(range.start, DateTime(2026, 6, 1));
    expect(range.end, DateTime(2026, 7, 1)); // exclusive upper bound
  });

  group('week ranges (fixed Monday anchor)', () {
    final monday = DateTime(2026, 8, 3, 9); // confirmed Monday

    test('cette semaine -> Monday through next Monday', () {
      final range = parsePeriod('mes dépenses cette semaine', now: monday)!;
      expect(range.start, DateTime(2026, 8, 3));
      expect(range.end, DateTime(2026, 8, 10));
    });

    test('la semaine dernière -> the previous Monday-to-Monday window', () {
      final range = parsePeriod('mes dépenses la semaine dernière', now: monday)!;
      expect(range.start, DateTime(2026, 7, 27));
      expect(range.end, DateTime(2026, 8, 3));
    });
  });

  test('accents are not required - "annee derniere" without accents still matches', () {
    final range = parsePeriod('mes depenses annee derniere', now: now)!;
    expect(range.start, DateTime(2025, 1, 1));
  });
}
