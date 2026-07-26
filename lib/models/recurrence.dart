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
}

// Ground truth: MMEX's own REPEAT_TYPE enum (Model_Billsdeposits.h, stable
// releases - not the in-progress 2026 rewrite, which uses a different
// internal representation). Verified against the actual file format by
// cross-checking against real bills: code 4 was previously mis-mapped here
// to "monthly, last day" - it's actually "every 2 months", and the real
// "last day of month" is code 15, not 4. That bug silently mis-scheduled
// any bimonthly bill (confirmed: 2 in this project's own test database) as
// monthly instead.
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
  // 11-14 (REPEAT_IN_X_DAYS/MONTHS, REPEAT_EVERY_X_DAYS/MONTHS) are not yet
  // supported - see ROADMAP.md. They reuse NUMOCCURRENCES as the "every N
  // days/months" interval itself rather than a remaining-occurrences
  // counter, which conflicts with how this app currently uses that field
  // for "durée limitée" and needs its own UI, not just a mapping entry.
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
  }
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
