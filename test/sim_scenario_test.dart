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
}
