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

/// How many months [period] spans, for the periods with a fixed monthly
/// interval - null for every other period (weekly/daily-stepped, or the "X
/// jours/mois" periods, whose interval isn't fixed by the period itself at
/// all - see [periodUsesXParam]). Used to cap "Répartir en X fois" when
/// recording an occurrence (see recurring_screen.dart's
/// `_RecordOccurrenceDialog._maxSplitInto`, 2026-09-02 user request):
/// the installment count may go up to (and including) this span - a
/// 3-month period can take 3 monthly installments, a 6-month one 6, and so
/// on - since the last of X monthly installments starting on the due date
/// lands X-1 months later, still strictly before the next due date exactly
/// [this span] months out.
int? recurrenceMonthSpan(RecurrencePeriod period) {
  switch (period) {
    case RecurrencePeriod.monthly:
    case RecurrencePeriod.monthlyLastDay:
    case RecurrencePeriod.monthlyLastBusinessDay:
      return 1;
    case RecurrencePeriod.biMonthly:
      return 2;
    case RecurrencePeriod.quarterly:
      return 3;
    case RecurrencePeriod.fourMonths:
      return 4;
    case RecurrencePeriod.halfYearly:
      return 6;
    case RecurrencePeriod.yearly:
      return 12;
    default:
      return null;
  }
}

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
/// an offset marking whether the occurrence auto-executes - confirmed
/// against the real MMEX source (REPEAT_AUTO enum + billsdepositsdialog.cpp,
/// v1.9.2): +100 = REPEAT_AUTO_MANUAL, the "en attente de saisie du paiement
/// par l'utilisateur" checkbox (asks for confirmation before inserting);
/// +200 = REPEAT_AUTO_SILENT, "exécution automatique de l'opération" (no
/// prompt at all). Anything else falls back to manual/"none".
({RecurrencePeriod period, RecurrenceAutoExecute autoExecute}) decodeRepeats(int repeats) {
  int base = repeats;
  var auto = RecurrenceAutoExecute.manual;
  if (repeats >= 200) {
    base = repeats - 200;
    auto = RecurrenceAutoExecute.silent;
  } else if (repeats >= 100) {
    base = repeats - 100;
    auto = RecurrenceAutoExecute.notify;
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
    case RecurrenceAutoExecute.notify:
      return base + 100;
    case RecurrenceAutoExecute.silent:
      return base + 200;
  }
}

/// How much of a category's ongoing monthly cost one occurrence of this
/// period represents - used to auto-derive a budget envelope's target
/// straight from existing recurring transactions instead of asking the
/// user to type the same amount twice (see
/// MmexRepository.categoryMonthlyRecurringTotals). [numOccurrences] is
/// only meaningful for the "every X ..." periods (see [periodUsesXParam])
/// where it holds the interval, not a count.
///
/// The two "dans X ..." one-shot periods return 0: they fire exactly
/// twice then stop (see [periodIsFixedTwoShot]), so they're not a stable
/// ongoing cost worth folding into a monthly budget target. "Aucune"
/// (a one-off, never repeats) returns 0 for the same reason.
double recurrencePeriodToMonthlyFactor(RecurrencePeriod period, int numOccurrences) {
  switch (period) {
    case RecurrencePeriod.daily:
      return 30;
    case RecurrencePeriod.weekly:
      return 52 / 12;
    case RecurrencePeriod.biWeekly:
      return 26 / 12;
    case RecurrencePeriod.fourWeeks:
      return 13 / 12;
    case RecurrencePeriod.monthly:
    case RecurrencePeriod.monthlyLastDay:
    case RecurrencePeriod.monthlyLastBusinessDay:
      return 1;
    case RecurrencePeriod.biMonthly:
      return 1 / 2;
    case RecurrencePeriod.quarterly:
      return 1 / 3;
    case RecurrencePeriod.fourMonths:
      return 1 / 4;
    case RecurrencePeriod.halfYearly:
      return 1 / 6;
    case RecurrencePeriod.yearly:
      return 1 / 12;
    case RecurrencePeriod.everyXDays:
      return numOccurrences > 0 ? 30 / numOccurrences : 0;
    case RecurrencePeriod.everyXMonths:
      return numOccurrences > 0 ? 1 / numOccurrences : 0;
    case RecurrencePeriod.none:
    case RecurrencePeriod.inXDays:
    case RecurrencePeriod.inXMonths:
      return 0;
  }
}
