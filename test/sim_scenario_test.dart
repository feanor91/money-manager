import 'package:flutter_test/flutter_test.dart';

import 'package:money_manager/data/mmex_database.dart';
import 'package:money_manager/data/mmex_repository.dart';
import 'package:money_manager/models/budget_period.dart' show nextForecastDay;
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

  group('duplicateSimScenario (2026-09-03, "Dupliquer ce scénario")', () {
    test('deep-copies bill overrides, virtual bills, one-off events and '
        'per-account assumed final balances into a new, independent '
        'scenario - the source is left untouched', () {
      final billId = repo.insertBillDeposit(
        accountId: accountId,
        payeeId: -1,
        transCode: TransCode.withdrawal,
        amount: 100,
        nextOccurrence: DateTime(2026, 1, 1),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
      );
      final sourceId = repo.createSimScenario('Original');
      repo.upsertSimBillOverride(sourceId, billId,
          disabledFrom: DateTime(2035, 1, 1), amountOverride: 50);
      repo.addSimVirtualBill(
        scenarioId: sourceId,
        accountId: accountId,
        label: 'Pension',
        transCode: TransCode.deposit,
        amount: 1200,
        startDate: DateTime(2035, 1, 1),
        period: RecurrencePeriod.monthly,
        numOccurrences: 24,
        variancePercent: 5,
        annualIncreasePercent: 2,
        annualIncreaseAnchor: DateTime(2035, 1, 1),
      );
      repo.addSimOneOffEvent(
        scenarioId: sourceId,
        accountId: accountId,
        label: 'Capital départ',
        transCode: TransCode.deposit,
        amount: 50000,
        date: DateTime(2035, 6, 1),
      );
      repo.setSimAssumedFinalBalance(sourceId, accountId, 2000);
      repo.setSimAssumedFinalBalance(sourceId, otherAccountId, -100);
      repo.setSimMeanReversion(sourceId, accountId,
          enabled: false, equilibrium: 300, strength: 0.4, noisePercent: 60);

      final newId = repo.duplicateSimScenario(sourceId, 'Original (copie)');

      expect(repo.getSimScenarios().map((s) => s.name),
          containsAll(['Original', 'Original (copie)']));
      expect(newId, isNot(sourceId));

      final override = repo.getSimBillOverrides(newId).single;
      expect(override.billId, billId);
      expect(override.disabledFrom, DateTime(2035, 1, 1));
      expect(override.amountOverride, 50.0);

      final virtual = repo.getSimVirtualBills(newId).single;
      expect(virtual.label, 'Pension');
      expect(virtual.amount, 1200.0);
      expect(virtual.numOccurrences, 24);
      expect(virtual.variancePercent, 5.0);
      expect(virtual.annualIncreasePercent, 2.0);
      expect(virtual.annualIncreaseAnchor, DateTime(2035, 1, 1));
      // A fresh row of its own, not literally sharing the source's id.
      expect(virtual.id, isNot(repo.getSimVirtualBills(sourceId).single.id));

      final event = repo.getSimOneOffEvents(newId).single;
      expect(event.label, 'Capital départ');
      expect(event.amount, 50000.0);

      expect(repo.getSimAssumedFinalBalance(newId, accountId), 2000.0);
      expect(repo.getSimAssumedFinalBalance(newId, otherAccountId), -100.0);

      final reversion = repo.getSimMeanReversion(newId, accountId)!;
      expect(reversion.enabled, isFalse);
      expect(reversion.equilibrium, 300.0);
      expect(reversion.strength, 0.4);
      expect(reversion.noisePercent, 60.0);

      // The source scenario is completely unaffected by the copy.
      expect(repo.getSimBillOverrides(sourceId), hasLength(1));
      expect(repo.getSimVirtualBills(sourceId), hasLength(1));
      expect(repo.getSimOneOffEvents(sourceId), hasLength(1));
      expect(repo.getSimAssumedFinalBalance(sourceId, accountId), 2000.0);
    });

    test('a scenario with nothing set duplicates into an equally empty one',
        () {
      final sourceId = repo.createSimScenario('Vide');
      final newId = repo.duplicateSimScenario(sourceId, 'Vide (copie)');

      expect(repo.getSimBillOverrides(newId), isEmpty);
      expect(repo.getSimVirtualBills(newId), isEmpty);
      expect(repo.getSimOneOffEvents(newId), isEmpty);
      expect(repo.getSimAssumedFinalBalance(newId, accountId), isNull);
    });

    test('editing the duplicate never changes the source - independent rows, '
        'not shared references', () {
      final billId = repo.insertBillDeposit(
        accountId: accountId,
        payeeId: -1,
        transCode: TransCode.withdrawal,
        amount: 100,
        nextOccurrence: DateTime(2026, 1, 1),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
      );
      final sourceId = repo.createSimScenario('Original');
      repo.upsertSimBillOverride(sourceId, billId, amountOverride: 50);
      final newId = repo.duplicateSimScenario(sourceId, 'Original (copie)');

      repo.upsertSimBillOverride(newId, billId, amountOverride: 999);

      expect(repo.getSimBillOverrides(sourceId).single.amountOverride, 50.0);
      expect(repo.getSimBillOverrides(newId).single.amountOverride, 999.0);
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

  group('historicalDiscretionaryMonthlyStdev', () {
    test('0 when the residual is identical every month - nothing to '
        'measure spread from', () {
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
        repo.insertTransaction(
          accountId: accountId,
          payeeId: -1,
          transCode: TransCode.withdrawal,
          amount: 150,
          date: DateTime(2025, m, 15),
        );
      }

      expect(
          repo.historicalDiscretionaryMonthlyStdev(
              accountId: accountId,
              anchor: DateTime(2025, 12, 1),
              months: 12,
              startDay: 1),
          0.0);
    });

    test('reflects real month-to-month spread when the discretionary '
        'residual alternates', () {
      repo.insertBillDeposit(
        accountId: accountId,
        payeeId: -1,
        transCode: TransCode.deposit,
        amount: 3000,
        nextOccurrence: DateTime(2025, 1, 1),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
      );
      // Alternates -100 / +100 discretionary residual every other month -
      // average 0, but real, measurable spread.
      for (var m = 1; m <= 12; m++) {
        repo.insertTransaction(
          accountId: accountId,
          payeeId: -1,
          transCode: TransCode.deposit,
          amount: 3000,
          date: DateTime(2025, m, 1),
        );
        repo.insertTransaction(
          accountId: accountId,
          payeeId: -1,
          transCode: m.isOdd ? TransCode.withdrawal : TransCode.deposit,
          amount: 100,
          date: DateTime(2025, m, 15),
        );
      }

      final average = repo.historicalDiscretionaryMonthlyAverage(
          accountId: accountId,
          anchor: DateTime(2025, 12, 1),
          months: 12,
          startDay: 1);
      final stdev = repo.historicalDiscretionaryMonthlyStdev(
          accountId: accountId,
          anchor: DateTime(2025, 12, 1),
          months: 12,
          startDay: 1);

      expect(average, 0.0);
      expect(stdev, 100.0); // every residual is exactly ±100 from the mean
    });

    test('0 when months <= 0 or fewer than 2 data points', () {
      expect(
          repo.historicalDiscretionaryMonthlyStdev(
              accountId: accountId,
              anchor: DateTime(2025, 12, 1),
              months: 0,
              startDay: 1),
          0.0);
      expect(
          repo.historicalDiscretionaryMonthlyStdev(
              accountId: accountId,
              anchor: DateTime(2025, 12, 1),
              months: 1,
              startDay: 1),
          0.0);
    });
  });

  group('historicalEquilibriumBalance', () {
    test('averages the real balance as of the pay-cycle date itself, not '
        'a delta', () {
      // initialBalance 1000, then a net +100 each month via a deposit -
      // balance at the 1st of each month climbs 1000, 1100, 1200, ...
      for (var m = 1; m <= 3; m++) {
        repo.insertTransaction(
          accountId: accountId,
          payeeId: -1,
          transCode: TransCode.deposit,
          amount: 100,
          date: DateTime(2025, m, 1),
        );
      }

      final equilibrium = repo.historicalEquilibriumBalance(
          accountId: accountId,
          anchor: DateTime(2025, 3, 1),
          months: 3,
          startDay: 1);

      // Windows ending at 2025-01-31, 2025-02-28, 2025-03-31: balances
      // 1100, 1200, 1300 respectively (the first month's deposit already
      // landed by its own window's last day).
      expect(equilibrium, 1200.0);
    });

    test('0 when months <= 0', () {
      expect(
          repo.historicalEquilibriumBalance(
              accountId: accountId,
              anchor: DateTime(2025, 12, 1),
              months: 0,
              startDay: 1),
          0.0);
    });
  });

  group('mean reversion CRUD ("retour à l\'équilibre", replacing "solde '
      'final supposé", 2026-09-04)', () {
    test('a fresh scenario/account pair has no configuration', () {
      final id = repo.createSimScenario('S');
      expect(repo.getSimMeanReversion(id, accountId), isNull);
    });

    test('setting is readable back, including a null equilibrium meaning '
        '"always use the auto-computed suggestion"', () {
      final id = repo.createSimScenario('S');
      repo.setSimMeanReversion(id, accountId,
          enabled: true, equilibrium: null, strength: 0.4, noisePercent: 80);

      final saved = repo.getSimMeanReversion(id, accountId)!;
      expect(saved.enabled, isTrue);
      expect(saved.equilibrium, isNull);
      expect(saved.strength, 0.4);
      expect(saved.noisePercent, 80.0);
    });

    test('setSimMeanReversionEnabled toggles enabled without touching the '
        'other saved values - the whole point of the 2026-09-04 request '
        '("il faut pouvoir activer ou désactiver")', () {
      final id = repo.createSimScenario('S');
      repo.setSimMeanReversion(id, accountId,
          enabled: true, equilibrium: 250, strength: 0.6, noisePercent: 120);

      repo.setSimMeanReversionEnabled(id, accountId, false);
      var saved = repo.getSimMeanReversion(id, accountId)!;
      expect(saved.enabled, isFalse);
      expect(saved.equilibrium, 250.0);
      expect(saved.strength, 0.6);
      expect(saved.noisePercent, 120.0);

      repo.setSimMeanReversionEnabled(id, accountId, true);
      saved = repo.getSimMeanReversion(id, accountId)!;
      expect(saved.enabled, isTrue);
      expect(saved.equilibrium, 250.0);
    });

    test('deleteSimMeanReversion removes the row entirely, unlike disabling',
        () {
      final id = repo.createSimScenario('S');
      repo.setSimMeanReversion(id, accountId,
          enabled: true, equilibrium: 250, strength: 0.5, noisePercent: 100);

      repo.deleteSimMeanReversion(id, accountId);

      expect(repo.getSimMeanReversion(id, accountId), isNull);
    });

    test('a second call for the same (scenario, account) pair replaces '
        'rather than duplicates', () {
      final id = repo.createSimScenario('S');
      repo.setSimMeanReversion(id, accountId,
          enabled: true, equilibrium: 100, strength: 0.5, noisePercent: 100);
      repo.setSimMeanReversion(id, accountId,
          enabled: false, equilibrium: 200, strength: 0.3, noisePercent: 50);

      final saved = repo.getSimMeanReversion(id, accountId)!;
      expect(saved.enabled, isFalse);
      expect(saved.equilibrium, 200.0);
      expect(saved.strength, 0.3);
      expect(saved.noisePercent, 50.0);
    });

    test('is independent per account within the same scenario', () {
      final id = repo.createSimScenario('S');
      repo.setSimMeanReversion(id, accountId,
          enabled: true, equilibrium: 100, strength: 0.5, noisePercent: 100);

      expect(repo.getSimMeanReversion(id, otherAccountId), isNull);
    });
  });

  group('simulatedDailyNetWithMeanReversion (2026-09-04, replacing '
      '"solde final supposé")', () {
    test('enabled: false returns the plain simulatedDailyNet series '
        'unchanged, with no applied dates - "activer/désactiver" must be '
        'a true no-op when off', () {
      final id = repo.createSimScenario('S');
      final today = DateTime.now();
      final todayMidnight = DateTime(today.year, today.month, today.day);
      final anchor = todayMidnight.add(const Duration(days: 60));
      final plain = repo.simulatedDailyNet(
          scenarioId: id, anchor: anchor, days: 61, accountId: accountId);

      final result = repo.simulatedDailyNetWithMeanReversion(
        scenarioId: id,
        accountId: accountId,
        enabled: false,
        equilibrium: 0,
        strength: 0.9,
        noiseAmount: 500,
        anchor: anchor,
        days: 61,
        forecastDay: todayMidnight.day,
      );

      expect(result.appliedDates, isEmpty);
      expect(result.net, plain);
    });

    test('pulls the running balance toward equilibrium by exactly '
        '[strength] of the gap, from above', () {
      final id = repo.createSimScenario('S');
      // accountId starts at 1000 (see setUp) - well above an equilibrium
      // of 200, so every checkpoint should pull it down.
      final today = DateTime.now();
      final todayMidnight = DateTime(today.year, today.month, today.day);
      final checkpoint = todayMidnight.add(const Duration(days: 5));
      final forecastDay = checkpoint.day;

      final result = repo.simulatedDailyNetWithMeanReversion(
        scenarioId: id,
        accountId: accountId,
        enabled: true,
        equilibrium: 200,
        strength: 0.5,
        noiseAmount: 0,
        anchor: checkpoint,
        days: checkpoint.difference(todayMidnight).inDays + 1,
        forecastDay: forecastDay,
      );

      expect(result.appliedDates, [checkpoint]);
      // gap = 1000 - 200 = 800; correction = -0.5 * 800 = -400.
      expect(result.net[checkpoint], -400.0);
    });

    test('pulls upward just as readily when the running balance is below '
        'equilibrium - unlike the old mechanism, never gated on sign', () {
      final id = repo.createSimScenario('S');
      // otherAccountId starts at 0 (see setUp) - below an equilibrium of
      // 500.
      final today = DateTime.now();
      final todayMidnight = DateTime(today.year, today.month, today.day);
      final checkpoint = todayMidnight.add(const Duration(days: 5));
      final forecastDay = checkpoint.day;

      final result = repo.simulatedDailyNetWithMeanReversion(
        scenarioId: id,
        accountId: otherAccountId,
        enabled: true,
        equilibrium: 500,
        strength: 0.5,
        noiseAmount: 0,
        anchor: checkpoint,
        days: checkpoint.difference(todayMidnight).inDays + 1,
        forecastDay: forecastDay,
      );

      expect(result.appliedDates, [checkpoint]);
      // gap = 0 - 500 = -500; correction = -0.5 * -500 = +250.
      expect(result.net[checkpoint], 250.0);
    });

    test('strength 0 never moves the balance even far from equilibrium - '
        'the "no effect" end of the slider', () {
      final id = repo.createSimScenario('S');
      final today = DateTime.now();
      final todayMidnight = DateTime(today.year, today.month, today.day);
      final checkpoint = todayMidnight.add(const Duration(days: 5));

      final result = repo.simulatedDailyNetWithMeanReversion(
        scenarioId: id,
        accountId: accountId,
        enabled: true,
        equilibrium: 999999,
        strength: 0,
        noiseAmount: 0,
        anchor: checkpoint,
        days: checkpoint.difference(todayMidnight).inDays + 1,
        forecastDay: checkpoint.day,
      );

      expect(result.net[checkpoint], 0.0);
    });

    test('the same (scenario, account, month) always yields the same '
        'noise - reproducible across rebuilds, same reliability guarantee '
        'as bill variance jitter', () {
      final id = repo.createSimScenario('S');
      final today = DateTime.now();
      final todayMidnight = DateTime(today.year, today.month, today.day);
      final checkpoint = todayMidnight.add(const Duration(days: 5));

      ({Map<DateTime, double> net, List<DateTime> appliedDates}) run() =>
          repo.simulatedDailyNetWithMeanReversion(
            scenarioId: id,
            accountId: accountId,
            enabled: true,
            equilibrium: 1000, // equal to the starting balance - no pull
            strength: 0.5,
            noiseAmount: 300,
            anchor: checkpoint,
            days: checkpoint.difference(todayMidnight).inDays + 1,
            forecastDay: checkpoint.day,
          );

      final first = run().net[checkpoint];
      final second = run().net[checkpoint];
      expect(first, second);
      expect(first, inInclusiveRange(-300.0, 300.0));
    });

    test('recovers over successive checkpoints - each one judges the '
        '*running* total, which already includes the previous pull', () {
      final id = repo.createSimScenario('S');
      final today = DateTime.now();
      final todayMidnight = DateTime(today.year, today.month, today.day);
      final forecastDay = todayMidnight.day;
      var checkpoint = nextForecastDay(todayMidnight, forecastDay);
      final checkpoints = <DateTime>[];
      for (var i = 0; i < 3; i++) {
        checkpoints.add(checkpoint);
        checkpoint = nextForecastDay(
            checkpoint.add(const Duration(days: 1)), forecastDay);
      }
      final anchor = checkpoints.last;

      final result = repo.simulatedDailyNetWithMeanReversion(
        scenarioId: id,
        accountId: accountId,
        enabled: true,
        equilibrium: 200,
        strength: 0.5,
        noiseAmount: 0,
        anchor: anchor,
        days: anchor.difference(todayMidnight).inDays + 1,
        forecastDay: forecastDay,
      );

      expect(result.appliedDates, checkpoints);
      // Start 1000 -> gap 800 -> correction -400 -> running 600.
      expect(result.net[checkpoints[0]], -400.0);
      // running 600 -> gap 400 -> correction -200 -> running 400.
      expect(result.net[checkpoints[1]], -200.0);
      // running 400 -> gap 200 -> correction -100 -> running 300.
      expect(result.net[checkpoints[2]], -100.0);
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

  group('assumedFinalBalance (solde final supposé, 2026-09-02, made '
      'per-account 2026-09)', () {
    test('a fresh scenario has no assumed final balance', () {
      repo.createSimScenario('S');
      expect(repo.getSimScenarios().single.assumedFinalBalance, isNull);
    });

    test('per-account setting is readable back, and passing null clears it',
        () {
      final id = repo.createSimScenario('S');
      repo.setSimAssumedFinalBalance(id, accountId, 45000);
      expect(repo.getSimAssumedFinalBalance(id, accountId), 45000.0);

      repo.setSimAssumedFinalBalance(id, accountId, null);
      expect(repo.getSimAssumedFinalBalance(id, accountId), isNull);
    });

    test('a different account is entirely independent', () {
      final id = repo.createSimScenario('S');
      repo.setSimAssumedFinalBalance(id, accountId, 45000);
      expect(repo.getSimAssumedFinalBalance(id, otherAccountId), isNull);
    });

    test(
        'falls back to the legacy scenario-wide column when this account '
        'has no row of its own yet - never silently loses a value set '
        'before the per-account version existed', () {
      final id = repo.createSimScenario('S');
      repo.db.execute(
          'UPDATE APP_SIM_SCENARIOS SET ASSUMED_FINAL_BALANCE = ? WHERE SCENARIOID = ?',
          [12000.0, id]);
      expect(repo.getSimAssumedFinalBalance(id, accountId), 12000.0);

      // Once this account gets its own explicit value, the legacy fallback
      // no longer applies to it, even if cleared back to null.
      repo.setSimAssumedFinalBalance(id, accountId, null);
      expect(repo.getSimAssumedFinalBalance(id, accountId), isNull);
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

  group('simulatedDailyNetWithAssumedFinalBalance (2026-09-03: recurs '
      'monthly, not just once)', () {
    test('both lists stay empty and the net series is unchanged when '
        'assumedFinalBalance is null', () {
      final id = repo.createSimScenario('S');
      final today = DateTime.now();
      final todayMidnight = DateTime(today.year, today.month, today.day);
      final anchor = todayMidnight.add(const Duration(days: 30));
      final plain = repo.simulatedDailyNet(
          scenarioId: id, anchor: anchor, days: 31, accountId: accountId);

      final result = repo.simulatedDailyNetWithAssumedFinalBalance(
        scenarioId: id,
        assumedFinalBalance: null,
        anchor: anchor,
        days: 31,
        accountId: accountId,
        forecastDay: todayMidnight.day,
      );

      expect(result.appliedDates, isEmpty);
      expect(result.ignoredDates, isEmpty);
      expect(result.net, plain);
    });

    test('is re-applied at every monthly occurrence of forecastDay while '
        'the running balance stays positive - "reportée toutes les fins de '
        'mois" (2026-09-03 user correction of the original one-shot design)',
        () {
      final id = repo.createSimScenario('S');
      final today = DateTime.now();
      final todayMidnight = DateTime(today.year, today.month, today.day);
      final forecastDay = todayMidnight.day;
      final checkpoints = <DateTime>[];
      var checkpoint = nextForecastDay(todayMidnight, forecastDay);
      for (var i = 0; i < 3; i++) {
        checkpoints.add(checkpoint);
        checkpoint = nextForecastDay(
            checkpoint.add(const Duration(days: 1)), forecastDay);
      }
      final anchor = checkpoints.last;
      final days = anchor.difference(todayMidnight).inDays + 1;

      final result = repo.simulatedDailyNetWithAssumedFinalBalance(
        scenarioId: id,
        assumedFinalBalance: 1500,
        anchor: anchor,
        days: days,
        accountId: accountId,
        forecastDay: forecastDay,
      );

      expect(result.appliedDates, checkpoints);
      expect(result.ignoredDates, isEmpty);
      // First checkpoint: 1500 (assumed) - 1000 (starting balance).
      expect(result.net[checkpoints[0]], 500.0);
      // No further real movement in between - already pinned to 1500, so
      // later checkpoints reset to the very same figure: delta 0.
      expect(result.net[checkpoints[1]], 0.0);
      expect(result.net[checkpoints[2]], 0.0);
    });

    test('never applies at a month whose running balance is already '
        'negative or zero - the real (bad) trajectory shows through '
        'untouched for that month, exactly the point of the whole feature',
        () {
      final id = repo.createSimScenario('S');
      final today = DateTime.now();
      final todayMidnight = DateTime(today.year, today.month, today.day);
      final checkpoint = todayMidnight.add(const Duration(days: 5));
      final forecastDay = checkpoint.day;
      repo.addSimOneOffEvent(
        scenarioId: id,
        accountId: otherAccountId,
        label: 'Grosse dépense',
        transCode: TransCode.withdrawal,
        amount: 2000,
        date: todayMidnight.add(const Duration(days: 2)),
      );

      final result = repo.simulatedDailyNetWithAssumedFinalBalance(
        scenarioId: id,
        assumedFinalBalance: 50000, // a very optimistic assumption
        anchor: checkpoint,
        days: checkpoint.difference(todayMidnight).inDays + 1,
        accountId: otherAccountId,
        forecastDay: forecastDay,
      );
      final plain = repo.simulatedDailyNet(
          scenarioId: id,
          anchor: checkpoint,
          days: checkpoint.difference(todayMidnight).inDays + 1,
          accountId: otherAccountId);

      expect(result.appliedDates, isEmpty);
      expect(result.ignoredDates, [checkpoint]);
      expect(result.net, plain); // never touched - no silent optimism
    });

    test('a month that recovers to positive after an earlier negative one '
        'gets pinned again - each checkpoint judges the *running* total, '
        'not a single fixed one', () {
      final id = repo.createSimScenario('S');
      final today = DateTime.now();
      final todayMidnight = DateTime(today.year, today.month, today.day);
      final checkpoint1 = todayMidnight.add(const Duration(days: 5));
      final forecastDay = checkpoint1.day;
      final checkpoint2 =
          nextForecastDay(checkpoint1.add(const Duration(days: 1)), forecastDay);
      // otherAccountId starts at 0 - a withdrawal before checkpoint1 pushes
      // it negative there, then a deposit before checkpoint2 brings it back
      // positive.
      repo.addSimOneOffEvent(
        scenarioId: id,
        accountId: otherAccountId,
        label: 'Grosse dépense',
        transCode: TransCode.withdrawal,
        amount: 500,
        date: todayMidnight.add(const Duration(days: 1)),
      );
      repo.addSimOneOffEvent(
        scenarioId: id,
        accountId: otherAccountId,
        label: 'Rentrée d\'argent',
        transCode: TransCode.deposit,
        amount: 1000,
        date: checkpoint1.add(const Duration(days: 1)),
      );
      final days = checkpoint2.difference(todayMidnight).inDays + 1;

      final result = repo.simulatedDailyNetWithAssumedFinalBalance(
        scenarioId: id,
        assumedFinalBalance: 2000,
        anchor: checkpoint2,
        days: days,
        accountId: otherAccountId,
        forecastDay: forecastDay,
      );

      expect(result.ignoredDates, [checkpoint1]); // -500, still negative
      expect(result.appliedDates, [checkpoint2]); // -500 + 1000 = 500, positive
      expect(result.net[checkpoint1], 0.0); // untouched
      expect(result.net[checkpoint2], 1500.0); // 2000 (assumed) - 500 (running)
    });

    test('both lists stay empty when forecastDay never occurs inside the '
        'charted window', () {
      final id = repo.createSimScenario('S');
      final today = DateTime.now();
      final todayMidnight = DateTime(today.year, today.month, today.day);
      // A single-day window containing only today, with a forecastDay
      // that's guaranteed to differ from today's own day-of-month - its
      // next real occurrence (this month or, if already past, next month)
      // can then never land on today itself, regardless of which real
      // calendar date this test happens to run on.
      final otherDay = todayMidnight.day == 1 ? 2 : 1;

      final result = repo.simulatedDailyNetWithAssumedFinalBalance(
        scenarioId: id,
        assumedFinalBalance: 5000,
        anchor: todayMidnight,
        days: 1,
        accountId: accountId,
        forecastDay: otherDay,
      );

      expect(result.appliedDates, isEmpty);
      expect(result.ignoredDates, isEmpty);
    });

    test('accountId: null sums across accountsForTotal for the running '
        'total, same convention as "tous les comptes" everywhere else', () {
      final id = repo.createSimScenario('S');
      final today = DateTime.now();
      final todayMidnight = DateTime(today.year, today.month, today.day);
      final checkpoint = todayMidnight.add(const Duration(days: 5));
      final forecastDay = checkpoint.day;

      final result = repo.simulatedDailyNetWithAssumedFinalBalance(
        scenarioId: id,
        assumedFinalBalance: 1200,
        anchor: checkpoint,
        days: checkpoint.difference(todayMidnight).inDays + 1,
        accountId: null,
        accountsForTotal: repo.getAccounts(),
        forecastDay: forecastDay,
      );

      expect(result.appliedDates, [checkpoint]);
      expect(result.net[checkpoint], 200.0); // 1200 (assumed) - 1000 (1000 + 0)
    });
  });
}
