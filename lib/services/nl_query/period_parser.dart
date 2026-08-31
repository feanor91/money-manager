import 'package:intl/intl.dart';

import '../../utils/list_utils.dart';
import 'query_intent.dart';

const _monthNames = {
  'janvier': 1,
  'fevrier': 2,
  'mars': 3,
  'avril': 4,
  'mai': 5,
  'juin': 6,
  'juillet': 7,
  'aout': 8,
  'septembre': 9,
  'octobre': 10,
  'novembre': 11,
  'decembre': 12,
};

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

String _monthLabel(int year, int month) {
  final formatted = DateFormat('MMMM yyyy', 'fr_FR').format(DateTime(year, month));
  return formatted[0].toUpperCase() + formatted.substring(1);
}

/// Parses a French period expression out of [rawText] relative to [now]
/// (defaults to the real current time - overridable so tests aren't tied to
/// whatever day they happen to run on). Returns null when nothing
/// recognizable is found; callers should fall back to an explicit default
/// (the current month) rather than guessing silently, and say so in the
/// answer so the user knows which period was actually used.
DateRange? parsePeriod(String rawText, {DateTime? now}) {
  final today = _dateOnly(now ?? DateTime.now());
  final text = foldDiacritics(rawText);

  // Explicit range: "du 01/06/2026 au 30/06/2026", "entre le 1/6 et le 30/6/2026".
  final rangeMatch = RegExp(
    r'(?:du|entre(?: le)?)\s*(\d{1,2})[/\-](\d{1,2})[/\-](\d{2,4})\s*'
    r'(?:au|et(?: le)?)\s*(\d{1,2})[/\-](\d{1,2})[/\-](\d{2,4})',
  ).firstMatch(text);
  if (rangeMatch != null) {
    final start = _parseDmy(rangeMatch, 1);
    final endInclusive = _parseDmy(rangeMatch, 4);
    if (start != null && endInclusive != null && !endInclusive.isBefore(start)) {
      final end = endInclusive.add(const Duration(days: 1));
      return DateRange(
        start: start,
        end: end,
        label: '${DateFormat('d MMMM yyyy', 'fr_FR').format(start)} au '
            '${DateFormat('d MMMM yyyy', 'fr_FR').format(endInclusive)}',
      );
    }
  }

  if (RegExp(r"aujourd'?hui").hasMatch(text)) {
    return DateRange(
        start: today, end: today.add(const Duration(days: 1)), label: "aujourd'hui");
  }
  if (RegExp(r'\bhier\b').hasMatch(text)) {
    final yesterday = today.subtract(const Duration(days: 1));
    return DateRange(start: yesterday, end: today, label: 'hier');
  }

  if (RegExp(r'semaine derniere|semaine precedente').hasMatch(text)) {
    final startOfThisWeek = today.subtract(Duration(days: today.weekday - 1));
    final start = startOfThisWeek.subtract(const Duration(days: 7));
    return DateRange(start: start, end: startOfThisWeek, label: 'la semaine dernière');
  }
  if (RegExp(r'cette semaine|semaine en cours').hasMatch(text)) {
    final start = today.subtract(Duration(days: today.weekday - 1));
    return DateRange(
        start: start, end: start.add(const Duration(days: 7)), label: 'cette semaine');
  }

  // "12 derniers mois" (original phrasing) or "sur 12 mois"/"sur 1 an(s)"
  // (2026-08-31 user report: "analyse mes revenus sur 1 ans mois par mois"
  // silently fell back to the current-month default, since only the
  // "derniers" phrasing was recognized) - two separate alternatives rather
  // than making "derniers" unconditionally optional, so this doesn't start
  // matching an unrelated "il y a 3 mois j'ai..." kind of mention elsewhere
  // in a longer question.
  final lastNMonths =
      RegExp(r'(\d+)\s*derniers?\s*mois|sur\s+(\d+)\s*mois').firstMatch(text);
  if (lastNMonths != null) {
    final n = int.tryParse(lastNMonths.group(1) ?? lastNMonths.group(2) ?? '') ?? 1;
    final start = DateTime(today.year, today.month - n + 1, 1);
    final end = DateTime(today.year, today.month + 1, 1);
    return DateRange(start: start, end: end, label: 'les $n derniers mois');
  }
  final lastNYears =
      RegExp(r'(\d+)\s*derniers?\s*ans?|sur\s+(\d+)\s*ans?').firstMatch(text);
  if (lastNYears != null) {
    final n = int.tryParse(lastNYears.group(1) ?? lastNYears.group(2) ?? '') ?? 1;
    final start = DateTime(today.year, today.month - (n * 12) + 1, 1);
    final end = DateTime(today.year, today.month + 1, 1);
    return DateRange(
        start: start, end: end, label: 'les $n derniers an${n > 1 ? 's' : ''}');
  }
  final lastNDays = RegExp(r'(\d+)\s*derniers?\s*jours?').firstMatch(text);
  if (lastNDays != null) {
    final n = int.tryParse(lastNDays.group(1)!) ?? 1;
    final start = today.subtract(Duration(days: n));
    return DateRange(
        start: start, end: today.add(const Duration(days: 1)), label: 'les $n derniers jours');
  }

  if (RegExp(r'mois dernier|mois precedent|mois passe').hasMatch(text)) {
    final prevMonth = DateTime(today.year, today.month - 1, 1);
    return DateRange(
      start: prevMonth,
      end: DateTime(today.year, today.month, 1),
      label: _monthLabel(prevMonth.year, prevMonth.month),
    );
  }
  if (RegExp(r'ce mois|mois[ -]ci|mois en cours|mois courant').hasMatch(text)) {
    return DateRange(
      start: DateTime(today.year, today.month, 1),
      end: DateTime(today.year, today.month + 1, 1),
      label: _monthLabel(today.year, today.month),
    );
  }

  // Open-ended, unlike "cette année" below: stops at today, not the end of
  // December - "depuis janvier" asked in March shouldn't claim anything
  // about April onward.
  if (RegExp(r"depuis (?:le debut de l'?annee|janvier)").hasMatch(text)) {
    return DateRange(
      start: DateTime(today.year, 1, 1),
      end: today.add(const Duration(days: 1)),
      label: "depuis le début de l'année",
    );
  }
  if (RegExp(r'annee derniere|annee precedente|annee passee').hasMatch(text)) {
    return DateRange(
      start: DateTime(today.year - 1, 1, 1),
      end: DateTime(today.year, 1, 1),
      label: '${today.year - 1}',
    );
  }
  if (RegExp(r'cette annee|annee en cours|annee courante').hasMatch(text)) {
    return DateRange(
      start: DateTime(today.year, 1, 1),
      end: DateTime(today.year + 1, 1, 1),
      label: '${today.year}',
    );
  }

  for (final entry in _monthNames.entries) {
    final match = RegExp('\\b${entry.key}\\b(?:\\s+(\\d{4}))?').firstMatch(text);
    if (match == null) continue;
    final month = entry.value;
    var year = int.tryParse(match.group(1) ?? '') ?? today.year;
    // No explicit year and this month hasn't happened yet this year -
    // almost certainly means last year's occurrence, not a future one.
    if (match.group(1) == null &&
        DateTime(year, month, 1).isAfter(DateTime(today.year, today.month, 1))) {
      year -= 1;
    }
    return DateRange(
      start: DateTime(year, month, 1),
      end: DateTime(year, month + 1, 1),
      label: _monthLabel(year, month),
    );
  }

  final yearMatch = RegExp(r'\b(20\d{2})\b').firstMatch(text);
  if (yearMatch != null) {
    final year = int.parse(yearMatch.group(1)!);
    return DateRange(
        start: DateTime(year, 1, 1), end: DateTime(year + 1, 1, 1), label: '$year');
  }

  return null;
}

/// The calendar month containing [now] (defaults to right now) - the
/// documented default period whenever a question doesn't mention one at
/// all, so the answer can explicitly say e.g. "pas de période reconnue,
/// voici pour août 2026" instead of silently guessing.
DateRange currentMonthRange({DateTime? now}) {
  final today = _dateOnly(now ?? DateTime.now());
  return DateRange(
    start: DateTime(today.year, today.month, 1),
    end: DateTime(today.year, today.month + 1, 1),
    label: _monthLabel(today.year, today.month),
  );
}

DateTime? _parseDmy(RegExpMatch m, int startGroup) {
  final day = int.tryParse(m.group(startGroup)!);
  final month = int.tryParse(m.group(startGroup + 1)!);
  var year = int.tryParse(m.group(startGroup + 2)!);
  if (day == null || month == null || year == null) return null;
  if (year < 100) year += 2000;
  return DateTime(year, month, day);
}
