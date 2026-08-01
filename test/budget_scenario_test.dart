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
  late int expenseCategoryId;
  late int incomeCategoryId;

  setUp(() async {
    db = await openBlankTestDb();
    repo = MmexRepository(db);
    accountId = repo.insertAccount(
        name: 'Compte test', type: 'Checking', initialBalance: 1000, currencyId: 2);
    expenseCategoryId =
        db.execute("INSERT INTO CATEGORY_V1 (CATEGNAME, ACTIVE) VALUES ('Test Dépense', 1)");
    incomeCategoryId =
        db.execute("INSERT INTO CATEGORY_V1 (CATEGNAME, ACTIVE) VALUES ('Test Revenu', 1)");
  });

  tearDown(() {
    db.dispose();
  });

  test('a fresh account has no scenarios', () {
    expect(repo.getBudgetScenarios(accountId), isEmpty);
  });

  test('creating a scenario makes it listable and gives it defaults', () {
    final id = repo.createBudgetScenario(accountId: accountId, name: 'Optimiste');
    final scenarios = repo.getBudgetScenarios(accountId);
    expect(scenarios, hasLength(1));
    expect(scenarios.single.id, id);
    expect(scenarios.single.name, 'Optimiste');
    expect(scenarios.single.periodMonths, 12);
    expect(repo.getBudgetScenarioAmounts(id), isEmpty);
  });

  test('scenarios are scoped per account', () {
    final otherAccountId = repo.insertAccount(
        name: 'Autre compte', type: 'Checking', initialBalance: 0, currencyId: 2);
    repo.createBudgetScenario(accountId: accountId, name: 'A');
    repo.createBudgetScenario(accountId: otherAccountId, name: 'B');
    expect(repo.getBudgetScenarios(accountId).map((s) => s.name), ['A']);
    expect(repo.getBudgetScenarios(otherAccountId).map((s) => s.name), ['B']);
  });

  test('renaming and changing the period update the same row', () {
    final id = repo.createBudgetScenario(accountId: accountId, name: 'Brouillon');
    repo.renameBudgetScenario(id, 'Version finale');
    repo.setBudgetScenarioPeriodMonths(id, 6);
    final scenario = repo.getBudgetScenarios(accountId).single;
    expect(scenario.name, 'Version finale');
    expect(scenario.periodMonths, 6);
  });

  test('upserting a simulated amount is readable back by category id', () {
    final id = repo.createBudgetScenario(accountId: accountId, name: 'S');
    repo.upsertBudgetScenarioAmount(scenarioId: id, categoryId: expenseCategoryId, amount: -250);
    expect(repo.getBudgetScenarioAmounts(id), {expenseCategoryId: -250.0});

    // Upsert again overwrites rather than duplicating.
    repo.upsertBudgetScenarioAmount(scenarioId: id, categoryId: expenseCategoryId, amount: -300);
    expect(repo.getBudgetScenarioAmounts(id), {expenseCategoryId: -300.0});
  });

  test('deleting one amount leaves the others alone', () {
    final id = repo.createBudgetScenario(accountId: accountId, name: 'S');
    repo.upsertBudgetScenarioAmount(scenarioId: id, categoryId: expenseCategoryId, amount: -250);
    repo.upsertBudgetScenarioAmount(scenarioId: id, categoryId: incomeCategoryId, amount: 2000);
    repo.deleteBudgetScenarioAmount(id, expenseCategoryId);
    expect(repo.getBudgetScenarioAmounts(id), {incomeCategoryId: 2000.0});
  });

  test('deleting a scenario also deletes its amounts, not other scenarios\''
      ' amounts', () {
    final id1 = repo.createBudgetScenario(accountId: accountId, name: 'S1');
    final id2 = repo.createBudgetScenario(accountId: accountId, name: 'S2');
    repo.upsertBudgetScenarioAmount(scenarioId: id1, categoryId: expenseCategoryId, amount: -100);
    repo.upsertBudgetScenarioAmount(scenarioId: id2, categoryId: expenseCategoryId, amount: -200);

    repo.deleteBudgetScenario(id1);

    expect(repo.getBudgetScenarios(accountId).map((s) => s.id), [id2]);
    expect(repo.getBudgetScenarioAmounts(id1), isEmpty);
    expect(repo.getBudgetScenarioAmounts(id2), {expenseCategoryId: -200.0});
  });

  test('a fresh scenario has no category visibility overrides', () {
    final id = repo.createBudgetScenario(accountId: accountId, name: 'S');
    expect(repo.getBudgetScenarioCategoryOverrides(id), isEmpty);
  });

  test('setting category visibility is readable back and overwrites on repeat', () {
    final id = repo.createBudgetScenario(accountId: accountId, name: 'S');
    repo.setBudgetScenarioCategoryVisible(id, expenseCategoryId, false);
    repo.setBudgetScenarioCategoryVisible(id, incomeCategoryId, true);
    expect(repo.getBudgetScenarioCategoryOverrides(id), {
      expenseCategoryId: false,
      incomeCategoryId: true,
    });

    // Flipping it back overwrites rather than duplicating.
    repo.setBudgetScenarioCategoryVisible(id, expenseCategoryId, true);
    expect(repo.getBudgetScenarioCategoryOverrides(id), {
      expenseCategoryId: true,
      incomeCategoryId: true,
    });
  });

  test('category visibility overrides are independent per scenario', () {
    final id1 = repo.createBudgetScenario(accountId: accountId, name: 'S1');
    final id2 = repo.createBudgetScenario(accountId: accountId, name: 'S2');
    repo.setBudgetScenarioCategoryVisible(id1, expenseCategoryId, false);

    expect(repo.getBudgetScenarioCategoryOverrides(id1), {expenseCategoryId: false});
    expect(repo.getBudgetScenarioCategoryOverrides(id2), isEmpty);
  });

  test('deleting a scenario also deletes its category visibility overrides', () {
    final id = repo.createBudgetScenario(accountId: accountId, name: 'S');
    repo.setBudgetScenarioCategoryVisible(id, expenseCategoryId, false);

    repo.deleteBudgetScenario(id);

    expect(repo.getBudgetScenarioCategoryOverrides(id), isEmpty);
  });

  test('a fresh scenario is not fixed', () {
    repo.createBudgetScenario(accountId: accountId, name: 'S');
    expect(repo.getBudgetScenarios(accountId).single.isFixed, isFalse);
  });

  test('fixBudgetScenario freezes categories with no saved amount yet, leaves existing ones alone', () {
    final id = repo.createBudgetScenario(accountId: accountId, name: 'S');
    repo.upsertBudgetScenarioAmount(scenarioId: id, categoryId: expenseCategoryId, amount: -100);

    repo.fixBudgetScenario(id, {expenseCategoryId: -100, incomeCategoryId: 2000});

    expect(repo.getBudgetScenarioAmounts(id), {expenseCategoryId: -100.0, incomeCategoryId: 2000.0});
    final scenario = repo.getBudgetScenarios(accountId).single;
    expect(scenario.isFixed, isTrue);
    expect(scenario.fixedAt, isNotNull);
  });

  test('unfixBudgetScenario removes only the auto-frozen amounts, not a manually-typed one', () {
    final id = repo.createBudgetScenario(accountId: accountId, name: 'S');
    repo.upsertBudgetScenarioAmount(scenarioId: id, categoryId: expenseCategoryId, amount: -100);
    // incomeCategoryId has no saved amount yet, so fixing auto-freezes it.
    repo.fixBudgetScenario(id, {expenseCategoryId: -100, incomeCategoryId: 2000});

    repo.unfixBudgetScenario(id);

    expect(repo.getBudgetScenarioAmounts(id), {expenseCategoryId: -100.0});
    expect(repo.getBudgetScenarios(accountId).single.isFixed, isFalse);
  });

  test('editing an amount after fixing marks it manual, so a later défixer keeps it', () {
    final id = repo.createBudgetScenario(accountId: accountId, name: 'S');
    repo.fixBudgetScenario(id, {expenseCategoryId: -50}); // auto-frozen (not yet manual)

    repo.upsertBudgetScenarioAmount(scenarioId: id, categoryId: expenseCategoryId, amount: -75);
    repo.unfixBudgetScenario(id);

    expect(repo.getBudgetScenarioAmounts(id), {expenseCategoryId: -75.0});
  });

  test('creating a virtual budget category gives it a negative id, listable by scenario', () {
    final id = repo.createBudgetScenario(accountId: accountId, name: 'S');
    final virtualId = repo.createVirtualBudgetCategory(id, 'Projet imaginaire');

    expect(virtualId, lessThan(0));
    final list = repo.getVirtualBudgetCategories(id);
    expect(list, hasLength(1));
    expect(list.single.id, virtualId);
    expect(list.single.name, 'Projet imaginaire');
    expect(list.single.parentCategId, isNull);
  });

  test('a virtual subcategory records which real category it subdivides', () {
    final id = repo.createBudgetScenario(accountId: accountId, name: 'S');
    final virtualId = repo.createVirtualBudgetCategory(id, 'Chantale', parentCategId: incomeCategoryId);

    final list = repo.getVirtualBudgetCategories(id);
    expect(list.single.id, virtualId);
    expect(list.single.parentCategId, incomeCategoryId);
  });

  test('virtual budget categories are scoped per scenario', () {
    final id1 = repo.createBudgetScenario(accountId: accountId, name: 'S1');
    final id2 = repo.createBudgetScenario(accountId: accountId, name: 'S2');
    final virtualId = repo.createVirtualBudgetCategory(id1, 'A');

    expect(repo.getVirtualBudgetCategories(id1).map((v) => v.id), [virtualId]);
    expect(repo.getVirtualBudgetCategories(id2), isEmpty);
  });

  test('deleting a scenario also deletes its virtual budget categories', () {
    final id = repo.createBudgetScenario(accountId: accountId, name: 'S');
    repo.createVirtualBudgetCategory(id, 'A');

    repo.deleteBudgetScenario(id);

    expect(repo.getVirtualBudgetCategories(id), isEmpty);
  });

  test('categoryMonthlyRecurringIncomeTotals picks up a monthly recurring deposit', () {
    repo.insertBillDeposit(
      accountId: accountId,
      payeeId: -1,
      transCode: TransCode.deposit,
      amount: 1500,
      nextOccurrence: DateTime.now(),
      period: RecurrencePeriod.monthly,
      autoExecute: RecurrenceAutoExecute.manual,
      categoryId: incomeCategoryId,
    );

    expect(repo.categoryMonthlyRecurringIncomeTotals(accountId: accountId), {incomeCategoryId: 1500.0});
  });

  test('categoryMonthlyRecurringIncomeTotals ignores a paused recurring deposit', () {
    final billId = repo.insertBillDeposit(
      accountId: accountId,
      payeeId: -1,
      transCode: TransCode.deposit,
      amount: 1500,
      nextOccurrence: DateTime.now(),
      period: RecurrencePeriod.monthly,
      autoExecute: RecurrenceAutoExecute.manual,
      categoryId: incomeCategoryId,
    );
    repo.setBillPaused(billId, true);

    expect(repo.categoryMonthlyRecurringIncomeTotals(accountId: accountId), isEmpty);
  });

  test('categoryNetTotalsForPeriod signs income positive and expense'
      ' negative, and excludes a voided transaction', () {
    final now = DateTime.now();
    repo.insertTransaction(
      accountId: accountId,
      payeeId: -1,
      transCode: TransCode.withdrawal,
      amount: 42,
      date: now,
      categoryId: expenseCategoryId,
    );
    repo.insertTransaction(
      accountId: accountId,
      payeeId: -1,
      transCode: TransCode.deposit,
      amount: 1500,
      date: now,
      categoryId: incomeCategoryId,
    );
    // A voided withdrawal must not count, same as MMEX's own totals.
    final voidedId = repo.insertTransaction(
      accountId: accountId,
      payeeId: -1,
      transCode: TransCode.withdrawal,
      amount: 999,
      date: now,
      categoryId: expenseCategoryId,
    );
    db.execute('UPDATE CHECKINGACCOUNT_V1 SET STATUS = ? WHERE TRANSID = ?', ['V', voidedId]);

    final totals = repo.categoryNetTotalsForPeriod(
      DateTime(now.year, now.month, 1),
      DateTime(now.year, now.month + 1, 1),
      accountId: accountId,
    );

    expect(totals[expenseCategoryId], -42.0);
    expect(totals[incomeCategoryId], 1500.0);
  });
}
