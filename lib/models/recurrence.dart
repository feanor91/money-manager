enum RecurrenceAutoExecute { manual, silent, notify }

enum RecurrencePeriod {
  none,
  weekly,
  biWeekly,
  monthly,
  biMonthly,
  quarterly,
  halfYearly,
  yearly,
  fourMonths,
  fourWeeks,
  daily,
  monthlyLastDay,
  monthlyLastBusinessDay,
  inXDays,
  inXMonths,
  everyXDays,
  everyXMonths,
}

/// True for the 4 periods (MMEX codes 11-14) that store their day/month
/// interval in the NUMOCCURRENCES column instead of a remaining-occurrences
/// count - see [periodIsFixedTwoShot] and `MmexRepository._advanceSchedule`.
bool periodUsesXParam(RecurrencePeriod period) =>
    period == RecurrencePeriod.inXDays ||
    period == RecurrencePeriod.inXMonths ||
    period == RecurrencePeriod.everyXDays ||
    period == RecurrencePeriod.everyXMonths;

/// True for "dans X jours/mois" (MMEX codes 11-12): per MMEX's own
/// Repeat constructor, these always fire exactly twice (X apart), then the
/// schedule collapses to a plain one-off and is deleted after the second
/// firing - unlike "tous les X jours/mois" (13-14), which repeat forever.
bool periodIsFixedTwoShot(RecurrencePeriod period) =>
    period == RecurrencePeriod.inXDays || period == RecurrencePeriod.inXMonths;

// Ground truth: MMEX's own REPEAT_TYPE enum (Model_Billsdeposits.h, stable
// releases - not the in-progress 2026 rewrite, which uses a different
// internal representation, though it preserves the same on-disk codes -
// see src/data/_DataEnum.cpp RepeatFreq::s_choice_a in moneymanagerex/).
// Verified against the actual file format by cross-checking against real
// bills: code 4 was previously mis-mapped here to "monthly, last day" -
// it's actually "every 2 months", and the real "last day of month" is code
// 15, not 4. That bug silently mis-scheduled any bimonthly bill (confirmed:
// 2 in this project's own test database) as monthly instead.
const _periodBaseCodes = <RecurrencePeriod, int>{
  RecurrencePeriod.none: 0,
  RecurrencePeriod.weekly: 1,
  RecurrencePeriod.biWeekly: 2,
  RecurrencePeriod.monthly: 3,
  RecurrencePeriod.biMonthly: 4,
  RecurrencePeriod.quarterly: 5,
  RecurrencePeriod.halfYearly: 6,
  RecurrencePeriod.yearly: 7,
  RecurrencePeriod.fourMonths: 8,
  RecurrencePeriod.fourWeeks: 9,
  RecurrencePeriod.daily: 10,
  RecurrencePeriod.inXDays: 11,
  RecurrencePeriod.inXMonths: 12,
  RecurrencePeriod.everyXDays: 13,
  RecurrencePeriod.everyXMonths: 14,
  RecurrencePeriod.monthlyLastDay: 15,
  RecurrencePeriod.monthlyLastBusinessDay: 16,
};

String recurrencePeriodLabel(RecurrencePeriod period) {
  switch (period) {
    case RecurrencePeriod.none:
      return 'Aucune';
    case RecurrencePeriod.weekly:
      return 'Hebdomadaire';
    case RecurrencePeriod.biWeekly:
      return 'Toutes les 2 semaines';
    case RecurrencePeriod.monthly:
      return 'Mensuelle';
    case RecurrencePeriod.biMonthly:
      return 'Tous les 2 mois';
    case RecurrencePeriod.quarterly:
      return 'Trimestrielle';
    case RecurrencePeriod.halfYearly:
      return 'Semestrielle';
    case RecurrencePeriod.yearly:
      return 'Annuelle';
    case RecurrencePeriod.fourMonths:
      return 'Tous les 4 mois';
    case RecurrencePeriod.fourWeeks:
      return 'Toutes les 4 semaines';
    case RecurrencePeriod.daily:
      return 'Quotidienne';
    case RecurrencePeriod.monthlyLastDay:
      return 'Mensuelle (dernier jour du mois)';
    case RecurrencePeriod.monthlyLastBusinessDay:
      return 'Mensuelle (dernier jour ouvré)';
    case RecurrencePeriod.inXDays:
      return 'Dans (n) jours';
    case RecurrencePeriod.inXMonths:
      return 'Dans (n) mois';
    case RecurrencePeriod.everyXDays:
      return 'Tous les (n) jours';
    case RecurrencePeriod.everyXMonths:
      return 'Tous les (n) mois';
  }
}

/// Same as [recurrencePeriodLabel] but with the "(n)" placeholder filled in
/// for the 4 periods that need it - see [periodUsesXParam].
String recurrencePeriodLabelWithX(RecurrencePeriod period, int x) {
  final label = recurrencePeriodLabel(period);
  return periodUsesXParam(period) ? label.replaceFirst('(n)', '$x') : label;
}

/// MMEX encodes REPEATS as a base period code (see [_periodBaseCodes]) plus
/// an offset marking whether the occurrence auto-executes: +100 = silently,
/// +200 = with a confirmation prompt. Anything else falls back to
/// manual/"none".
({RecurrencePeriod period, RecurrenceAutoExecute autoExecute}) decodeRepeats(int repeats) {
  int base = repeats;
  var auto = RecurrenceAutoExecute.manual;
  if (repeats >= 200) {
    base = repeats - 200;
    auto = RecurrenceAutoExecute.notify;
  } else if (repeats >= 100) {
    base = repeats - 100;
    auto = RecurrenceAutoExecute.silent;
  }
  final period = _periodBaseCodes.entries
      .firstWhere((e) => e.value == base, orElse: () => const MapEntry(RecurrencePeriod.monthly, 3))
      .key;
  return (period: period, autoExecute: auto);
}

int encodeRepeats(RecurrencePeriod period, RecurrenceAutoExecute autoExecute) {
  final base = _periodBaseCodes[period] ?? 3;
  switch (autoExecute) {
    case RecurrenceAutoExecute.manual:
      return base;
    case RecurrenceAutoExecute.silent:
      return base + 100;
    case RecurrenceAutoExecute.notify:
      return base + 200;
  }
}
