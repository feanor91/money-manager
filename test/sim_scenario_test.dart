import 'package:flutter_test/flutter_test.dart';

import 'package:money_manager/data/mmex_database.dart';
import 'package:money_manager/data/mmex_repository.dart';
import 'package:money_manager/models/recurrence.dart';
import 'package:money_manager/models/transaction.dart';

import 'test_helpers.dart';

void main() {
  late MmexDatabase db;
  late MmexRepository repo;
  late int accountId;
  late int otherAccountId;

  setUp(() async {
    db = await openBlankTestDb();
    repo = MmexRepository(db);
    accountId = repo.insertAccount(
        name: 'Compte test', type: 'Checking', initialBalance: 1000, currencyId: 2);
    otherAccountId = repo.insertAccount(
        name: 'Autre compte', type: 'Checking', initialBalance: 0, currencyId: 2);
  });

  tearDown(() {
    db.dispose();
  });

  group('scenario CRUD', () {
    test('starts with no scenarios', () {
      expect(repo.getSimScenarios(), isEmpty);
    });

    test('creating a scenario makes it listable', () {
      final id = repo.createSimScenario('Retraite optimiste');
      final scenarios = repo.getSimScenarios();
      expect(scenarios, hasLength(1));
      expect(scenarios.single.id, id);
      expect(scenarios.single.name, 'Retraite optimiste');
    });

    test('renaming updates the same row', () {
      final id = repo.createSimScenario('Brouillon');
      repo.renameSimScenario(id, 'Version finale');
      expect(repo.getSimScenarios().single.name, 'Version finale');
    });

    test('deleting a scenario removes its overrides, virtual bills and '
        'events, not another scenario\'s', () {
      final billId = repo.insertBillDeposit(
        accountId: accountId,
        payeeId: -1,
        transCode: TransCode.withdrawal,
        amount: 100,
        nextOccurrence: DateTime(2026, 1, 1),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
      );
      final id1 = repo.createSimScenario('S1');
      final id2 = repo.createSimScenario('S2');
      repo.upsertSimBillOverride(id1, billId, amountOverride: 50);
      repo.upsertSimBillOverride(id2, billId, amountOverride: 75);
      repo.addSimVirtualBill(
        scenarioId: id1,
        accountId: accountId,
        label: 'Pension',
        transCode: TransCode.deposit,
        amount: 1200,
        startDate: DateTime(2035, 1, 1),
        period: RecurrencePeriod.monthly,
      );
      repo.addSimOneOffEvent(
        scenarioId: id1,
        accountId: accountId,
        label: 'Capital départ',
        transCode: TransCode.deposit,
        amount: 50000,
        date: DateTime(2035, 6, 1),
      );

      repo.deleteSimScenario(id1);

      expect(repo.getSimScenarios().map((s) => s.id), [id2]);
      expect(repo.getSimBillOverrides(id1), isEmpty);
      expect(repo.getSimBillOverrides(id2), hasLength(1));
      expect(repo.getSimVirtualBills(id1), isEmpty);
      expect(repo.getSimOneOffEvents(id1), isEmpty);
    });
  });

  group('bill overrides', () {
    test('upserting an override is readable back, a second call for the '
        'same bill replaces rather than duplicates', () {
      final billId = repo.insertBillDeposit(
        accountId: accountId,
        payeeId: -1,
        transCode: TransCode.withdrawal,
        amount: 100,
        nextOccurrence: DateTime(2026, 1, 1),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
      );
      final id = repo.createSimScenario('S');
      repo.upsertSimBillOverride(id, billId,
          disabledFrom: DateTime(2035, 1, 1), amountOverride: 80);
      var overrides = repo.getSimBillOverrides(id);
      expect(overrides, hasLength(1));
      expect(overrides.single.billId, billId);
      expect(overrides.single.disabledFrom, DateTime(2035, 1, 1));
      expect(overrides.single.amountOverride, 80.0);

      repo.upsertSimBillOverride(id, billId, amountOverride: 90);
      overrides = repo.getSimBillOverrides(id);
      expect(overrides, hasLength(1));
      expect(overrides.single.amountOverride, 90.0);
      expect(overrides.single.disabledFrom, isNull);
    });

    test('deleting one override leaves others alone', () {
      final billId1 = repo.insertBillDeposit(
        accountId: accountId,
        payeeId: -1,
        transCode: TransCode.withdrawal,
        amount: 100,
        nextOccurrence: DateTime(2026, 1, 1),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
      );
      final billId2 = repo.insertBillDeposit(
        accountId: accountId,
        payeeId: -1,
        transCode: TransCode.withdrawal,
        amount: 50,
        nextOccurrence: DateTime(2026, 1, 1),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
      );
      final id = repo.createSimScenario('S');
      repo.upsertSimBillOverride(id, billId1, amountOverride: 10);
      repo.upsertSimBillOverride(id, billId2, amountOverride: 20);

      repo.deleteSimBillOverride(id, billId1);

      expect(repo.getSimBillOverrides(id).map((o) => o.billId), [billId2]);
    });
  });

  group('virtual bills and one-off events', () {
    test('a virtual bill is listable by scenario and independent of others', () {
      final id1 = repo.createSimScenario('S1');
      final id2 = repo.createSimScenario('S2');
      final virtualId = repo.addSimVirtualBill(
        scenarioId: id1,
        accountId: accountId,
        label: 'Pension',
        transCode: TransCode.deposit,
        amount: 1200,
        startDate: DateTime(2035, 1, 1),
        period: RecurrencePeriod.monthly,
      );

      final list = repo.getSimVirtualBills(id1);
      expect(list, hasLength(1));
      expect(list.single.id, virtualId);
      expect(list.single.label, 'Pension');
      expect(list.single.amount, 1200.0);
      expect(repo.getSimVirtualBills(id2), isEmpty);
    });

    test('a one-off event is listable by scenario and independent of others', () {
      final id1 = repo.createSimScenario('S1');
      final id2 = repo.createSimScenario('S2');
      final eventId = repo.addSimOneOffEvent(
        scenarioId: id1,
        accountId: accountId,
        label: 'Capital départ',
        transCode: TransCode.deposit,
        amount: 50000,
        date: DateTime(2035, 6, 1),
      );

      final list = repo.getSimOneOffEvents(id1);
      expect(list, hasLength(1));
      expect(list.single.id, eventId);
      expect(list.single.amount, 50000.0);
      expect(repo.getSimOneOffEvents(id2), isEmpty);
    });
  });

  group('simulatedMonthlyNet', () {
    test('with no adjustments at all, matches recurringMonthlyNet exactly '
        '- a scenario with nothing changed must project identically to the '
        'real schedule', () {
      repo.insertBillDeposit(
        accountId: accountId,
        payeeId: -1,
        transCode: TransCode.deposit,
        amount: 3000,
        nextOccurrence: DateTime(2026, 1, 1),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
      );
      final id = repo.createSimScenario('S');

      final real = repo.recurringMonthlyNet(
          anchor: DateTime(2026, 6, 1), months: 12, accountId: accountId);
      final simulated = repo.simulatedMonthlyNet(
          scenarioId: id, anchor: DateTime(2026, 6, 1), months: 12, accountId: accountId);

      expect(simulated, real);
    });

    test('disabling a bill excludes occurrences on/after that date, keeps '
        'the ones before', () {
      repo.insertBillDeposit(
        accountId: accountId,
        payeeId: -1,
        transCode: TransCode.deposit,
        amount: 3000,
        nextOccurrence: DateTime(2026, 1, 1),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
      );
      final billId = repo.getBillDeposits().single.id;
      final id = repo.createSimScenario('S');
      repo.upsertSimBillOverride(id, billId, disabledFrom: DateTime(2026, 4, 1));

      final result = repo.simulatedMonthlyNet(
          scenarioId: id, anchor: DateTime(2026, 6, 1), months: 6, accountId: accountId);

      expect(result[DateTime(2026, 1, 1)], 3000.0);
      expect(result[DateTime(2026, 2, 1)], 3000.0);
      expect(result[DateTime(2026, 3, 1)], 3000.0);
      expect(result[DateTime(2026, 4, 1)], 0.0);
      expect(result[DateTime(2026, 5, 1)], 0.0);
      expect(result[DateTime(2026, 6, 1)], 0.0);
    });

    test('an amount override replaces every projected occurrence\'s amount', () {
      repo.insertBillDeposit(
        accountId: accountId,
        payeeId: -1,
        transCode: TransCode.withdrawal,
        amount: 800,
        nextOccurrence: DateTime(2026, 1, 1),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
      );
      final billId = repo.getBillDeposits().single.id;
      final id = repo.createSimScenario('S');
      repo.upsertSimBillOverride(id, billId, amountOverride: 400);

      final result = repo.simulatedMonthlyNet(
          scenarioId: id, anchor: DateTime(2026, 3, 1), months: 3, accountId: accountId);

      expect(result[DateTime(2026, 1, 1)], -400.0);
      expect(result[DateTime(2026, 2, 1)], -400.0);
      expect(result[DateTime(2026, 3, 1)], -400.0);
    });

    test('a virtual bill projects like a real recurring one from its start '
        'date, and is absent from the plain recurringMonthlyNet baseline', () {
      final id = repo.createSimScenario('S');
      repo.addSimVirtualBill(
        scenarioId: id,
        accountId: accountId,
        label: 'Pension',
        transCode: TransCode.deposit,
        amount: 1200,
        startDate: DateTime(2026, 2, 1),
        period: RecurrencePeriod.monthly,
      );

      final result = repo.simulatedMonthlyNet(
          scenarioId: id, anchor: DateTime(2026, 4, 1), months: 4, accountId: accountId);

      expect(result[DateTime(2026, 1, 1)], 0.0);
      expect(result[DateTime(2026, 2, 1)], 1200.0);
      expect(result[DateTime(2026, 3, 1)], 1200.0);
      expect(result[DateTime(2026, 4, 1)], 1200.0);

      final baseline = repo.recurringMonthlyNet(
          anchor: DateTime(2026, 4, 1), months: 4, accountId: accountId);
      expect(baseline.values.every((v) => v == 0.0), isTrue);
    });

    test('a one-off event adds to exactly one bucket, in and out of range', () {
      final id = repo.createSimScenario('S');
      repo.addSimOneOffEvent(
        scenarioId: id,
        accountId: accountId,
        label: 'Capital départ',
        transCode: TransCode.deposit,
        amount: 50000,
        date: DateTime(2026, 3, 15),
      );

      final result = repo.simulatedMonthlyNet(
          scenarioId: id, anchor: DateTime(2026, 4, 1), months: 4, accountId: accountId);

      expect(result[DateTime(2026, 1, 1)], 0.0);
      expect(result[DateTime(2026, 2, 1)], 0.0);
      expect(result[DateTime(2026, 3, 1)], 50000.0);
      expect(result[DateTime(2026, 4, 1)], 0.0);
    });

    test('a withdrawal one-off event is signed negative', () {
      final id = repo.createSimScenario('S');
      repo.addSimOneOffEvent(
        scenarioId: id,
        accountId: accountId,
        label: 'Grosse dépense',
        transCode: TransCode.withdrawal,
        amount: 2000,
        date: DateTime(2026, 3, 15),
      );

      final result = repo.simulatedMonthlyNet(
          scenarioId: id, anchor: DateTime(2026, 3, 1), months: 3, accountId: accountId);

      expect(result[DateTime(2026, 3, 1)], -2000.0);
    });

    test('an event on another account is ignored when scoped to accountId', () {
      final id = repo.createSimScenario('S');
      repo.addSimOneOffEvent(
        scenarioId: id,
        accountId: otherAccountId,
        label: 'Ailleurs',
        transCode: TransCode.deposit,
        amount: 999,
        date: DateTime(2026, 3, 15),
      );

      final result = repo.simulatedMonthlyNet(
          scenarioId: id, anchor: DateTime(2026, 3, 1), months: 3, accountId: accountId);

      expect(result[DateTime(2026, 3, 1)], 0.0);
    });

    test('combining a disabled real bill, a virtual replacement and a '
        'one-off event projects the full retirement-style scenario '
        'correctly in one pass', () {
      repo.insertBillDeposit(
        accountId: accountId,
        payeeId: -1,
        transCode: TransCode.deposit,
        amount: 3000,
        nextOccurrence: DateTime(2026, 1, 1),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
        notes: 'Salaire',
      );
      final salaryId = repo.getBillDeposits().single.id;
      final id = repo.createSimScenario('Retraite');
      // Salary stops in month 3 of the window...
      repo.upsertSimBillOverride(id, salaryId, disabledFrom: DateTime(2026, 3, 1));
      // ...replaced by a smaller pension from the same date.
      repo.addSimVirtualBill(
        scenarioId: id,
        accountId: accountId,
        label: 'Pension',
        transCode: TransCode.deposit,
        amount: 1800,
        startDate: DateTime(2026, 3, 1),
        period: RecurrencePeriod.monthly,
      );
      // Plus a one-off lump sum the month retirement starts.
      repo.addSimOneOffEvent(
        scenarioId: id,
        accountId: accountId,
        label: 'Capital départ',
        transCode: TransCode.deposit,
        amount: 20000,
        date: DateTime(2026, 3, 1),
      );

      final result = repo.simulatedMonthlyNet(
          scenarioId: id, anchor: DateTime(2026, 4, 1), months: 4, accountId: accountId);

      expect(result[DateTime(2026, 1, 1)], 3000.0);
      expect(result[DateTime(2026, 2, 1)], 3000.0);
      expect(result[DateTime(2026, 3, 1)], 1800.0 + 20000.0);
      expect(result[DateTime(2026, 4, 1)], 1800.0);
    });

    test('a paused real bill stays excluded, same as recurringMonthlyNet', () {
      repo.insertBillDeposit(
        accountId: accountId,
        payeeId: -1,
        transCode: TransCode.deposit,
        amount: 3000,
        nextOccurrence: DateTime(2026, 1, 1),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
      );
      final billId = repo.getBillDeposits().single.id;
      repo.setBillPaused(billId, true);
      final id = repo.createSimScenario('S');

      final result = repo.simulatedMonthlyNet(
          scenarioId: id, anchor: DateTime(2026, 3, 1), months: 3, accountId: accountId);

      expect(result.values.every((v) => v == 0.0), isTrue);
    });
  });

  group('variancePercent (2026-09-02, "dépenses imprévues" jitter)', () {
    test('0 (the default) behaves exactly like before this field existed - '
        'the exact same amount every occurrence', () {
      final id = repo.createSimScenario('S');
      repo.addSimVirtualBill(
        scenarioId: id,
        accountId: accountId,
        label: 'Dépenses imprévues (historique)',
        transCode: TransCode.withdrawal,
        amount: 200,
        startDate: DateTime(2026, 1, 1),
        period: RecurrencePeriod.monthly,
      );

      final result = repo.simulatedMonthlyNet(
          scenarioId: id, anchor: DateTime(2026, 6, 1), months: 6, accountId: accountId);

      expect(result.values.every((v) => v == -200.0), isTrue);
    });

    test('a positive variance makes at least one month differ from the flat '
        'amount, while staying deterministic across repeated calls', () {
      final id = repo.createSimScenario('S');
      repo.addSimVirtualBill(
        scenarioId: id,
        accountId: accountId,
        label: 'Dépenses imprévues (historique)',
        transCode: TransCode.withdrawal,
        amount: 200,
        // Well before the projected window below, so every bucket in it
        // has an occurrence - a start date falling mid-window would
        // legitimately leave earlier buckets at 0 (no occurrence yet),
        // which isn't what this test is checking.
        startDate: DateTime(2020, 1, 1),
        period: RecurrencePeriod.monthly,
        variancePercent: 20,
      );

      final first = repo.simulatedMonthlyNet(
          scenarioId: id, anchor: DateTime(2027, 1, 1), months: 24, accountId: accountId);
      final second = repo.simulatedMonthlyNet(
          scenarioId: id, anchor: DateTime(2027, 1, 1), months: 24, accountId: accountId);

      // Deterministic/reproducible - the whole point of seeding on
      // (billId, month) rather than a fresh Random() each call.
      expect(first, second);
      // With ±20% jitter over 24 months, at least one month must differ
      // from the flat -200 baseline, and every value must stay within the
      // configured bound.
      expect(first.values.any((v) => v != -200.0), isTrue);
      for (final v in first.values) {
        expect(v, inInclusiveRange(-240.0, -160.0));
      }
    });

    test('a real bill (never assigned a variance) is never jittered', () {
      repo.insertBillDeposit(
        accountId: accountId,
        payeeId: -1,
        transCode: TransCode.deposit,
        amount: 3000,
        nextOccurrence: DateTime(2026, 1, 1),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
      );
      final id = repo.createSimScenario('S');

      final result = repo.simulatedMonthlyNet(
          scenarioId: id, anchor: DateTime(2026, 12, 1), months: 12, accountId: accountId);

      expect(result.values.every((v) => v == 3000.0), isTrue);
    });
  });

  group('historicalDiscretionaryMonthlyAverage', () {
    test('0 when real history exactly matches the recurring schedule '
        '(nothing discretionary happened)', () {
      repo.insertBillDeposit(
        accountId: accountId,
        payeeId: -1,
        transCode: TransCode.deposit,
        amount: 3000,
        nextOccurrence: DateTime(2025, 1, 1),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
      );
      for (var m = 1; m <= 12; m++) {
        repo.insertTransaction(
          accountId: accountId,
          payeeId: -1,
          transCode: TransCode.deposit,
          amount: 3000,
          date: DateTime(2025, m, 1),
        );
      }

      final average = repo.historicalDiscretionaryMonthlyAverage(
          accountId: accountId,
          anchor: DateTime(2025, 12, 1),
          months: 12,
          startDay: 1);

      expect(average, 0.0);
    });

    test('negative when real spending exceeds what the recurring schedule '
        'alone explains - the common "dépenses imprévues" case', () {
      repo.insertBillDeposit(
        accountId: accountId,
        payeeId: -1,
        transCode: TransCode.deposit,
        amount: 3000,
        nextOccurrence: DateTime(2025, 1, 1),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
      );
      for (var m = 1; m <= 12; m++) {
        repo.insertTransaction(
          accountId: accountId,
          payeeId: -1,
          transCode: TransCode.deposit,
          amount: 3000,
          date: DateTime(2025, m, 1),
        );
        // 150 of real, unplanned spending every month, on top of the
        // recurring 3000 income - never in BILLSDEPOSITS_V1.
        repo.insertTransaction(
          accountId: accountId,
          payeeId: -1,
          transCode: TransCode.withdrawal,
          amount: 150,
          date: DateTime(2025, m, 15),
        );
      }

      final average = repo.historicalDiscretionaryMonthlyAverage(
          accountId: accountId,
          anchor: DateTime(2025, 12, 1),
          months: 12,
          startDay: 1);

      expect(average, -150.0);
    });

    test('0 when months <= 0, never divides by zero', () {
      expect(
          repo.historicalDiscretionaryMonthlyAverage(
              accountId: accountId,
              anchor: DateTime(2025, 12, 1),
              months: 0,
              startDay: 1),
          0.0);
    });
  });

  group('recurringPeriodNet / simulatedPeriodNet (pay-cycle bucketing, '
      '2026-09-02 - "mon mois se termine le 24")', () {
    test('startDay: 1 sums to the exact same per-period totals as the '
        'calendar-month version, in order (keys differ on purpose - see '
        '_netForBillsByWindows: each is now the window\'s *last* day, not '
        'its first, so a chart plotting a cumulative running balance labels '
        'each point with the date that balance is actually as of)', () {
      repo.insertBillDeposit(
        accountId: accountId,
        payeeId: -1,
        transCode: TransCode.deposit,
        amount: 3000,
        nextOccurrence: DateTime(2026, 1, 1),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
      );

      final calendar = repo.recurringMonthlyNet(
          anchor: DateTime(2026, 6, 1), months: 6, accountId: accountId);
      final period = repo.recurringPeriodNet(
          anchor: DateTime(2026, 6, 1), periods: 6, startDay: 1, accountId: accountId);

      List<double> valuesInOrder(Map<DateTime, double> m) =>
          (m.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
              .map((e) => e.value)
              .toList();

      expect(valuesInOrder(period), valuesInOrder(calendar));
      // With startDay 1, a calendar month's *last* day and a pay-cycle
      // window's *last included day* are the exact same date.
      expect(period.keys.toSet(), calendar.keys.map((k) {
        final lastDay = DateTime(k.year, k.month + 1, 0).day;
        return DateTime(k.year, k.month, lastDay);
      }).toSet());
    });

    test('an occurrence before startDay counts in the previous pay-cycle '
        'window, not the calendar month it falls in - keyed by that '
        "window's last included day", () {
      repo.insertBillDeposit(
        accountId: accountId,
        payeeId: -1,
        transCode: TransCode.withdrawal,
        amount: 100,
        nextOccurrence: DateTime(2026, 3, 20),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
      );

      final result = repo.recurringPeriodNet(
          anchor: DateTime(2026, 3, 20), periods: 1, startDay: 25, accountId: accountId);

      // The pay-cycle window containing 20 March runs 25 Feb - 24 Mar
      // (since 20 March is before this month's own 25th) - keyed by its
      // last included day, 24 March.
      expect(result.keys.single, DateTime(2026, 3, 24));
      expect(result.values.single, -100.0);
    });

    test('an occurrence on/after startDay counts in that month\'s own '
        "pay-cycle window, keyed by that window's last included day", () {
      repo.insertBillDeposit(
        accountId: accountId,
        payeeId: -1,
        transCode: TransCode.withdrawal,
        amount: 100,
        nextOccurrence: DateTime(2026, 3, 25),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
      );

      final result = repo.recurringPeriodNet(
          anchor: DateTime(2026, 3, 25), periods: 1, startDay: 25, accountId: accountId);

      // Window runs 25 March - 24 April - keyed by 24 April.
      expect(result.keys.single, DateTime(2026, 4, 24));
      expect(result.values.single, -100.0);
    });

    test('simulatedPeriodNet buckets a one-off event into the correct '
        "pay-cycle window, keyed by that window's last included day", () {
      final id = repo.createSimScenario('S');
      repo.addSimOneOffEvent(
        scenarioId: id,
        accountId: accountId,
        label: 'Prime',
        transCode: TransCode.deposit,
        amount: 500,
        date: DateTime(2026, 3, 22),
      );

      final result = repo.simulatedPeriodNet(
          scenarioId: id,
          anchor: DateTime(2026, 3, 22),
          periods: 1,
          startDay: 25,
          accountId: accountId);

      expect(result.keys.single, DateTime(2026, 3, 24));
      expect(result.values.single, 500.0);
    });
  });

  group('assumedFinalBalance (solde final supposé, 2026-09-02)', () {
    test('a fresh scenario has no assumed final balance', () {
      repo.createSimScenario('S');
      expect(repo.getSimScenarios().single.assumedFinalBalance, isNull);
    });

    test('setting is readable back, and passing null clears it', () {
      final id = repo.createSimScenario('S');
      repo.setSimScenarioAssumedFinalBalance(id, 45000);
      expect(repo.getSimScenarios().single.assumedFinalBalance, 45000.0);

      repo.setSimScenarioAssumedFinalBalance(id, null);
      expect(repo.getSimScenarios().single.assumedFinalBalance, isNull);
    });
  });

  group('forecastAccountBalanceForScenario', () {
    test("returns today's real balance when targetDate isn't in the future",
        () {
      final id = repo.createSimScenario('S');
      final balance = repo.forecastAccountBalanceForScenario(
          scenarioId: id, accountId: accountId, targetDate: DateTime.now());
      expect(balance, 1000.0);
    });

    test("projects a scenario's virtual bill forward to a future date", () {
      final id = repo.createSimScenario('S');
      final today = DateTime.now();
      final todayMidnight = DateTime(today.year, today.month, today.day);
      repo.addSimVirtualBill(
        scenarioId: id,
        accountId: accountId,
        label: 'Pension',
        transCode: TransCode.deposit,
        amount: 500,
        startDate: todayMidnight.add(const Duration(days: 5)),
        period: RecurrencePeriod.monthly,
      );

      final balance = repo.forecastAccountBalanceForScenario(
        scenarioId: id,
        accountId: accountId,
        targetDate: todayMidnight.add(const Duration(days: 10)),
      );

      expect(balance, 1500.0);
    });

    test('a disabled real bill is excluded here, unlike the real, unmodified '
        'forecastAccountBalance', () {
      final today = DateTime.now();
      final todayMidnight = DateTime(today.year, today.month, today.day);
      repo.insertBillDeposit(
        accountId: accountId,
        payeeId: -1,
        transCode: TransCode.withdrawal,
        amount: 200,
        nextOccurrence: todayMidnight.add(const Duration(days: 3)),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
      );
      final billId = repo.getBillDeposits().single.id;
      final id = repo.createSimScenario('S');
      repo.upsertSimBillOverride(id, billId, disabledFrom: todayMidnight);
      final target = todayMidnight.add(const Duration(days: 10));

      final scenarioBalance = repo.forecastAccountBalanceForScenario(
          scenarioId: id, accountId: accountId, targetDate: target);
      final realBalance = repo.forecastAccountBalance(accountId, target);

      expect(scenarioBalance, 1000.0);
      expect(realBalance, 800.0);
    });
  });

  group('simulatedDailyNetWithAssumedFinalBalance', () {
    test('applied is false and the net series is unchanged when '
        'assumedFinalBalance is null', () {
      final id = repo.createSimScenario('S');
      final today = DateTime.now();
      final todayMidnight = DateTime(today.year, today.month, today.day);
      final anchor = todayMidnight.add(const Duration(days: 30));
      final target = todayMidnight.add(const Duration(days: 5));
      final plain = repo.simulatedDailyNet(
          scenarioId: id, anchor: anchor, days: 31, accountId: accountId);

      final result = repo.simulatedDailyNetWithAssumedFinalBalance(
        scenarioId: id,
        assumedFinalBalance: null,
        anchor: anchor,
        days: 31,
        accountId: accountId,
        targetDate: target,
      );

      expect(result.applied, isFalse);
      expect(result.net, plain);
    });

    test('applies the assumption and injects the delta at the target date '
        "when the scenario's own calculated balance there is already "
        'positive - the "uniquement si positif" rule\'s positive branch', () {
      final id = repo.createSimScenario('S');
      final today = DateTime.now();
      final todayMidnight = DateTime(today.year, today.month, today.day);
      final anchor = todayMidnight.add(const Duration(days: 30));
      final target = todayMidnight.add(const Duration(days: 5));

      final result = repo.simulatedDailyNetWithAssumedFinalBalance(
        scenarioId: id,
        assumedFinalBalance: 1500,
        anchor: anchor,
        days: 31,
        accountId: accountId,
        targetDate: target,
      );

      expect(result.calculatedAtTarget, 1000.0);
      expect(result.applied, isTrue);
      expect(result.net[target], 500.0); // 1500 (assumed) - 1000 (calculated)
    });

    test('never applies the assumption when the calculated balance at the '
        'target date is already negative - the rule\'s "laisser le solde '
        'calculé" branch, exactly the point of the whole feature', () {
      final id = repo.createSimScenario('S');
      final today = DateTime.now();
      final todayMidnight = DateTime(today.year, today.month, today.day);
      repo.addSimOneOffEvent(
        scenarioId: id,
        accountId: otherAccountId,
        label: 'Grosse dépense',
        transCode: TransCode.withdrawal,
        amount: 2000,
        date: todayMidnight.add(const Duration(days: 2)),
      );
      final anchor = todayMidnight.add(const Duration(days: 30));
      final target = todayMidnight.add(const Duration(days: 5));

      final result = repo.simulatedDailyNetWithAssumedFinalBalance(
        scenarioId: id,
        assumedFinalBalance: 50000, // a very optimistic assumption
        anchor: anchor,
        days: 31,
        accountId: otherAccountId,
        targetDate: target,
      );
      final plain = repo.simulatedDailyNet(
          scenarioId: id, anchor: anchor, days: 31, accountId: otherAccountId);

      expect(result.calculatedAtTarget, -2000.0);
      expect(result.applied, isFalse);
      expect(result.net, plain); // never touched - no silent optimism
    });

    test('applied is false when the target date falls outside the charted '
        'window', () {
      final id = repo.createSimScenario('S');
      final today = DateTime.now();
      final todayMidnight = DateTime(today.year, today.month, today.day);
      final anchor = todayMidnight.add(const Duration(days: 10));
      final outsideTarget = todayMidnight.add(const Duration(days: 60));

      final result = repo.simulatedDailyNetWithAssumedFinalBalance(
        scenarioId: id,
        assumedFinalBalance: 5000,
        anchor: anchor,
        days: 11,
        accountId: accountId,
        targetDate: outsideTarget,
      );

      expect(result.applied, isFalse);
    });

    test('accountId: null sums across accountsForTotal for the calculated '
        'figure, same convention as "tous les comptes" everywhere else', () {
      final id = repo.createSimScenario('S');
      final today = DateTime.now();
      final todayMidnight = DateTime(today.year, today.month, today.day);
      final anchor = todayMidnight.add(const Duration(days: 30));
      final target = todayMidnight.add(const Duration(days: 5));

      final result = repo.simulatedDailyNetWithAssumedFinalBalance(
        scenarioId: id,
        assumedFinalBalance: null,
        anchor: anchor,
        days: 31,
        accountId: null,
        accountsForTotal: repo.getAccounts(),
        targetDate: target,
      );

      expect(result.calculatedAtTarget, 1000.0); // 1000 + 0
    });
  });
}
