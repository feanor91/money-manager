enum RecurrenceAutoExecute { manual, silent, notify }

enum RecurrencePeriod {
  none,
  weekly,
  biWeekly,
  monthly,
  monthlyLastDay,
  quarterly,
  halfYearly,
  yearly,
  fourMonths,
  fourWeeks,
  daily,
}

const _periodBaseCodes = <RecurrencePeriod, int>{
  RecurrencePeriod.none: 0,
  RecurrencePeriod.weekly: 1,
  RecurrencePeriod.biWeekly: 2,
  RecurrencePeriod.monthly: 3,
  RecurrencePeriod.monthlyLastDay: 4,
  RecurrencePeriod.quarterly: 5,
  RecurrencePeriod.halfYearly: 6,
  RecurrencePeriod.yearly: 7,
  RecurrencePeriod.fourMonths: 8,
  RecurrencePeriod.fourWeeks: 9,
  RecurrencePeriod.daily: 10,
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
    case RecurrencePeriod.monthlyLastDay:
      return 'Mensuelle (dernier jour)';
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
  }
}

/// MMEX encodes REPEATS as a base period code (0-15) plus an offset marking
/// whether the occurrence auto-executes: +100 = silently, +200 = with a
/// confirmation prompt. Anything else falls back to manual/"none".
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
