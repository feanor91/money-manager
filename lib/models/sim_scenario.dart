import 'bill_deposit.dart';
import 'recurrence.dart';
import 'transaction.dart';

/// A named, saveable long-term "what if" scenario (see APP_SIM_SCENARIOS) -
/// phase 1 of PLAN_SIMULATION_LONG_TERME.md. A scenario on its own is just a
/// name; what it actually changes lives in [SimBillOverride]/[SimVirtualBill]/
/// [SimOneOffEvent] rows underneath it, all referencing this by
/// [SimScenario.id] - same split as [BudgetScenario]/APP_BUDGET_SCENARIO_AMOUNTS.
class SimScenario {
  final int id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// "Solde final supposé" (2026-09-02 user request, corrected to recur
  /// monthly on 2026-09-03) - a balance the user trusts more than the raw
  /// projection, re-applied at *every* monthly occurrence of the app's
  /// existing "Jour de prévision du solde" setting (see
  /// MmexRepository.simulatedDailyNetWithAssumedFinalBalance), not just
  /// once: the user's real account tends to hover near this same figure
  /// every month regardless of what a naive multi-year recurring-only
  /// projection says. Null (the default) means no adjustment. Only ever
  /// *applied* at a given month if the running balance there is already
  /// positive - see the doc comment on where it's consumed for why: this
  /// must never be a way to paper over a genuinely negative trajectory.
  ///
  /// **Legacy** (2026-09): superseded by the per-account
  /// APP_SIM_ASSUMED_FINAL_BALANCES table (see
  /// MmexRepository.getSimAssumedFinalBalance/setSimAssumedFinalBalance) -
  /// the app never writes here anymore, this column only still gets *read*,
  /// as a one-time fallback default for whichever account has no row of its
  /// own yet, so a value set before the per-account version existed is
  /// never silently lost.
  final double? assumedFinalBalance;

  const SimScenario({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.assumedFinalBalance,
  });

  factory SimScenario.fromRow(Map<String, Object?> row) {
    return SimScenario(
      id: row['SCENARIOID'] as int,
      name: row['NAME'] as String? ?? '',
      createdAt: DateTime.tryParse(row['CREATED_AT'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(row['UPDATED_AT'] as String? ?? '') ??
          DateTime.now(),
      assumedFinalBalance: (row['ASSUMED_FINAL_BALANCE'] as num?)?.toDouble(),
    );
  }
}

/// One scenario's change to a real recurring bill (BILLSDEPOSITS_V1) -
/// never mutates the real bill, purely read when projecting a scenario (see
/// MmexRepository.simulatedMonthlyNet). Deliberately minimal: two
/// independent, composable primitives rather than one "amount changes to X
/// starting on date Y" field - covering that composite case is just
/// [disabledFrom] on the real bill plus a same-shaped [SimVirtualBill]
/// starting on that date with the new amount, using the two primitives
/// together rather than a third, more complex one.
class SimBillOverride {
  final int scenarioId;
  final int billId;

  /// Every projected occurrence on or after this date is excluded - null
  /// means the bill is never disabled by this scenario. Occurrences
  /// *before* this date still count normally, so "stop this bill on
  /// retirement day" is expressed directly rather than needing to also
  /// touch the bill's own schedule.
  final DateTime? disabledFrom;

  /// Replaces the bill's real amount for every projected occurrence
  /// (regardless of date) - null means use the real BILLSDEPOSITS_V1
  /// amount unchanged. Deliberately flat, not itself date-scoped - see this
  /// class's own doc comment for how to express a change that also starts
  /// on a specific date.
  final double? amountOverride;

  const SimBillOverride({
    required this.scenarioId,
    required this.billId,
    this.disabledFrom,
    this.amountOverride,
  });

  factory SimBillOverride.fromRow(Map<String, Object?> row) {
    return SimBillOverride(
      scenarioId: row['SCENARIOID'] as int,
      billId: row['BILLID'] as int,
      disabledFrom: DateTime.tryParse(row['DISABLED_FROM'] as String? ?? ''),
      amountOverride: (row['AMOUNT_OVERRIDE'] as num?)?.toDouble(),
    );
  }
}

/// A recurring operation that exists only inside a scenario, never in the
/// real BILLSDEPOSITS_V1 - e.g. "pension de retraite +1200€/mois à partir
/// de 2035". [id] is assigned by SQLite (APP_SIM_VIRTUAL_BILLS.VIRTUALBILLID,
/// its own autoincrement space, distinct from real BDIDs) - [toBillDeposit]
/// negates it before handing the result to the same occurrence-projection
/// code real bills go through, so a virtual bill's synthetic id can never
/// collide with a real one there (same negative-id convention
/// APP_BUDGET_SCENARIO_VIRTUAL_CATEGORIES already uses for virtual
/// categories).
class SimVirtualBill {
  final int id;
  final int scenarioId;
  final int accountId;
  final String label;
  final TransCode transCode;
  final double amount;
  final DateTime startDate;
  final RecurrencePeriod period;

  /// Same encoding as [BillDeposit.numOccurrences] - -1 repeats forever,
  /// otherwise a remaining count (or, for [periodUsesXParam] periods, the
  /// day/month interval X). A virtual bill never "catches up" real
  /// occurrences the way a real one does, so there's nothing here for that
  /// count to ever decrement in place - it's re-read fresh from this row
  /// every time a scenario is projected.
  final int numOccurrences;

  /// See [BillDeposit.variancePercent] - 0 (the default) means the exact
  /// same amount every occurrence, same as before this field existed.
  final double variancePercent;

  /// See [BillDeposit.annualIncreasePercent]/[annualIncreaseAnchor] - always
  /// manual here (no real transaction history to suggest one from, unlike
  /// a real bill).
  final double annualIncreasePercent;
  final DateTime? annualIncreaseAnchor;

  const SimVirtualBill({
    required this.id,
    required this.scenarioId,
    required this.accountId,
    required this.label,
    required this.transCode,
    required this.amount,
    required this.startDate,
    required this.period,
    this.numOccurrences = -1,
    this.variancePercent = 0,
    this.annualIncreasePercent = 0,
    this.annualIncreaseAnchor,
  });

  /// Reuses the exact same occurrence-projection code real bills go
  /// through (MmexRepository's private `_occurrencesInRange`, via
  /// [MmexRepository.occurrencesForBill]) rather than a second, parallel
  /// implementation - one mechanism to keep correct/tested, not two that
  /// could quietly drift apart.
  BillDeposit toBillDeposit() => BillDeposit(
        id: -id,
        accountId: accountId,
        payeeId: -1,
        transCode: transCode,
        amount: amount,
        toAmount: amount,
        nextOccurrence: startDate,
        period: period,
        autoExecute: RecurrenceAutoExecute.manual,
        numOccurrences: numOccurrences,
        notes: label,
        variancePercent: variancePercent,
        annualIncreasePercent: annualIncreasePercent,
        annualIncreaseAnchor: annualIncreaseAnchor,
      );

  factory SimVirtualBill.fromRow(Map<String, Object?> row) {
    return SimVirtualBill(
      id: row['VIRTUALBILLID'] as int,
      scenarioId: row['SCENARIOID'] as int,
      accountId: row['ACCOUNTID'] as int,
      label: row['LABEL'] as String? ?? '',
      transCode:
          transCodeFromString(row['TRANSCODE'] as String? ?? 'Withdrawal'),
      amount: (row['AMOUNT'] as num?)?.toDouble() ?? 0,
      startDate: DateTime.tryParse(row['START_DATE'] as String? ?? '') ??
          DateTime.now(),
      // Only ever written by [MmexRepository.addSimVirtualBill] as
      // `period.name`, so a mismatch here would mean a hand-edited or
      // otherwise corrupted row - falls back to `none` rather than
      // throwing (RecurrencePeriod.values.byName throws on an unrecognized
      // name) and taking the whole screen down over one bad row.
      period:
          RecurrencePeriod.values.asNameMap()[row['PERIOD'] as String? ?? ''] ??
              RecurrencePeriod.none,
      numOccurrences: (row['NUM_OCCURRENCES'] as num?)?.toInt() ?? -1,
      variancePercent: (row['VARIANCE_PERCENT'] as num?)?.toDouble() ?? 0,
      annualIncreasePercent:
          (row['ANNUAL_INCREASE_PERCENT'] as num?)?.toDouble() ?? 0,
      annualIncreaseAnchor:
          DateTime.tryParse(row['ANNUAL_INCREASE_ANCHOR'] as String? ?? ''),
    );
  }
}

/// A single hypothetical transaction, not a recurring one - e.g. "capital de
/// départ à la retraite +50000€ le 01/06/2035".
class SimOneOffEvent {
  final int id;
  final int scenarioId;
  final int accountId;
  final String label;
  final TransCode transCode;
  final double amount;
  final DateTime date;

  const SimOneOffEvent({
    required this.id,
    required this.scenarioId,
    required this.accountId,
    required this.label,
    required this.transCode,
    required this.amount,
    required this.date,
  });

  factory SimOneOffEvent.fromRow(Map<String, Object?> row) {
    return SimOneOffEvent(
      id: row['EVENTID'] as int,
      scenarioId: row['SCENARIOID'] as int,
      accountId: row['ACCOUNTID'] as int,
      label: row['LABEL'] as String? ?? '',
      transCode:
          transCodeFromString(row['TRANSCODE'] as String? ?? 'Withdrawal'),
      amount: (row['AMOUNT'] as num?)?.toDouble() ?? 0,
      date: DateTime.tryParse(row['DATE'] as String? ?? '') ?? DateTime.now(),
    );
  }
}
