import 'package:flutter_test/flutter_test.dart';

import 'package:money_manager_core/data/mmex_database.dart';
import 'package:money_manager_core/data/mmex_repository.dart';
import 'package:money_manager_core/models/recurrence.dart';
import 'package:money_manager_core/models/transaction.dart';

import 'test_helpers.dart';

/// "Créer un scénario de simulation" (2026-09 user request): bridges the
/// Budget screen's per-category-group simulated targets onto a long-term
/// [MmexRepository.applyBudgetTargetsToSimScenario] scenario - an existing
/// real bill gets overridden (never duplicated as a parallel virtual one),
/// a category group with no real bill behind it becomes a virtual one.
void main() {
  late MmexDatabase db;
  late MmexRepository repo;
  late int accountId;

  setUp(() async {
    db = await openBlankTestDb();
    repo = MmexRepository(db);
    accountId = repo.insertAccount(
        name: 'Compte test', type: 'Checking', initialBalance: 0, currencyId: 2);
  });

  tearDown(() => db.dispose());

  test('a category fed by a single real bill overrides that bill, never '
      'creates a virtual one', () {
    final categoryId = repo.insertCategory(name: 'Assurance');
    final billId = repo.insertBillDeposit(
      accountId: accountId,
      payeeId: -1,
      transCode: TransCode.withdrawal,
      amount: 40,
      categoryId: categoryId,
      nextOccurrence: DateTime(2026, 1, 5),
      period: RecurrencePeriod.monthly,
      autoExecute: RecurrenceAutoExecute.manual,
    );
    final scenarioId = repo.createSimScenario('Scénario');

    final result = repo.applyBudgetTargetsToSimScenario(
      simScenarioId: scenarioId,
      accountId: accountId,
      targetsByGroup: {categoryId: -60}, // simulated 60/mois, negative = expense
      categoryIdsByGroup: {categoryId: [categoryId]},
      categoryNames: {categoryId: 'Assurance'},
    );

    expect(result.billsOverridden, 1);
    expect(result.virtualBillsUpserted, 0);
    final overrides = repo.getSimBillOverrides(scenarioId);
    expect(overrides, hasLength(1));
    expect(overrides.single.billId, billId);
    expect(overrides.single.amountOverride, 60);
    expect(repo.getSimVirtualBills(scenarioId), isEmpty);
  });

  test('a real bill living on a SUBCATEGORY is found and overridden when '
      'the budget target is rolled up on its PARENT - regression test for '
      'the 2026-09 live report: "Crédits" (parent, target 1539.33) wrongly '
      'spawned a whole new virtual bill on top of the real "Crédits:Credit '
      'immobilier" (child) mortgage bill instead of adjusting it, because '
      'the lookup was keyed on the parent id alone', () {
    final parentId = repo.insertCategory(name: 'Crédits');
    final childId = repo.insertCategory(name: 'Credit immobilier', parentId: parentId);
    final billId = repo.insertBillDeposit(
      accountId: accountId,
      payeeId: -1,
      transCode: TransCode.withdrawal,
      amount: 1218.08,
      categoryId: childId,
      nextOccurrence: DateTime(2026, 1, 5),
      period: RecurrencePeriod.monthly,
      autoExecute: RecurrenceAutoExecute.manual,
    );
    final scenarioId = repo.createSimScenario('Scénario');

    final result = repo.applyBudgetTargetsToSimScenario(
      simScenarioId: scenarioId,
      accountId: accountId,
      targetsByGroup: {parentId: -1539.33},
      categoryIdsByGroup: {
        parentId: [parentId, childId],
      },
      categoryNames: {parentId: 'Crédits'},
    );

    expect(result.billsOverridden, 1);
    expect(result.virtualBillsUpserted, 0);
    final overrides = repo.getSimBillOverrides(scenarioId);
    expect(overrides, hasLength(1));
    expect(overrides.single.billId, billId);
    expect(overrides.single.amountOverride, closeTo(1539.33, 0.01));
    expect(repo.getSimVirtualBills(scenarioId), isEmpty);
  });

  test('a target matching the real bill total clears a stale override '
      'from an earlier run instead of leaving it stuck', () {
    final categoryId = repo.insertCategory(name: 'Assurance');
    final billId = repo.insertBillDeposit(
      accountId: accountId,
      payeeId: -1,
      transCode: TransCode.withdrawal,
      amount: 40,
      categoryId: categoryId,
      nextOccurrence: DateTime(2026, 1, 5),
      period: RecurrencePeriod.monthly,
      autoExecute: RecurrenceAutoExecute.manual,
    );
    final scenarioId = repo.createSimScenario('Scénario');
    repo.upsertSimBillOverride(scenarioId, billId, amountOverride: 999);

    final result = repo.applyBudgetTargetsToSimScenario(
      simScenarioId: scenarioId,
      accountId: accountId,
      targetsByGroup: {categoryId: -40}, // matches the real bill exactly
      categoryIdsByGroup: {categoryId: [categoryId]},
      categoryNames: {categoryId: 'Assurance'},
    );

    expect(result.billsReverted, 1);
    expect(result.billsOverridden, 0);
    expect(repo.getSimBillOverrides(scenarioId), isEmpty);
  });

  test('several bills feeding the same category are overridden '
      'proportionally to their real weight', () {
    final categoryId = repo.insertCategory(name: 'Crédits');
    final bigId = repo.insertBillDeposit(
      accountId: accountId,
      payeeId: -1,
      transCode: TransCode.withdrawal,
      amount: 800,
      categoryId: categoryId,
      nextOccurrence: DateTime(2026, 1, 5),
      period: RecurrencePeriod.monthly,
      autoExecute: RecurrenceAutoExecute.manual,
    );
    final smallId = repo.insertBillDeposit(
      accountId: accountId,
      payeeId: -1,
      transCode: TransCode.withdrawal,
      amount: 200,
      categoryId: categoryId,
      nextOccurrence: DateTime(2026, 1, 5),
      period: RecurrencePeriod.monthly,
      autoExecute: RecurrenceAutoExecute.manual,
    );
    final scenarioId = repo.createSimScenario('Scénario');

    // Real total: 1000/mois - simulated: 1100/mois (+10%), same ratio
    // should apply to both bills (880/220).
    final result = repo.applyBudgetTargetsToSimScenario(
      simScenarioId: scenarioId,
      accountId: accountId,
      targetsByGroup: {categoryId: -1100},
      categoryIdsByGroup: {categoryId: [categoryId]},
      categoryNames: {categoryId: 'Crédits'},
    );

    expect(result.billsOverridden, 2);
    final overrides = {for (final o in repo.getSimBillOverrides(scenarioId)) o.billId: o};
    expect(overrides[bigId]!.amountOverride, closeTo(880, 0.01));
    expect(overrides[smallId]!.amountOverride, closeTo(220, 0.01));
  });

  test('a category with no real bill behind it becomes a virtual bill', () {
    final categoryId = repo.insertCategory(name: 'Courses maison');
    final scenarioId = repo.createSimScenario('Scénario');

    final result = repo.applyBudgetTargetsToSimScenario(
      simScenarioId: scenarioId,
      accountId: accountId,
      targetsByGroup: {categoryId: -350},
      categoryIdsByGroup: {categoryId: [categoryId]},
      categoryNames: {categoryId: 'Courses maison'},
    );

    expect(result.virtualBillsUpserted, 1);
    final bills = repo.getSimVirtualBills(scenarioId);
    expect(bills, hasLength(1));
    expect(bills.single.label, 'Budget : Courses maison');
    expect(bills.single.amount, 350);
    expect(bills.single.transCode, TransCode.withdrawal);
  });

  test('an income target (positive) becomes a Deposit virtual bill', () {
    final categoryId = repo.insertCategory(name: 'Freelance');
    final scenarioId = repo.createSimScenario('Scénario');

    repo.applyBudgetTargetsToSimScenario(
      simScenarioId: scenarioId,
      accountId: accountId,
      targetsByGroup: {categoryId: 500},
      categoryIdsByGroup: {categoryId: [categoryId]},
      categoryNames: {categoryId: 'Freelance'},
    );

    final bill = repo.getSimVirtualBills(scenarioId).single;
    expect(bill.transCode, TransCode.deposit);
    expect(bill.amount, 500);
  });

  test('re-running with a changed target updates the same virtual bill '
      'instead of creating a second one', () {
    final categoryId = repo.insertCategory(name: 'Courses maison');
    final scenarioId = repo.createSimScenario('Scénario');

    repo.applyBudgetTargetsToSimScenario(
      simScenarioId: scenarioId,
      accountId: accountId,
      targetsByGroup: {categoryId: -350},
      categoryIdsByGroup: {categoryId: [categoryId]},
      categoryNames: {categoryId: 'Courses maison'},
    );
    final result = repo.applyBudgetTargetsToSimScenario(
      simScenarioId: scenarioId,
      accountId: accountId,
      targetsByGroup: {categoryId: -400},
      categoryIdsByGroup: {categoryId: [categoryId]},
      categoryNames: {categoryId: 'Courses maison'},
    );

    expect(result.virtualBillsUpserted, 1);
    final bills = repo.getSimVirtualBills(scenarioId);
    expect(bills, hasLength(1));
    expect(bills.single.amount, 400);
  });

  test('a target dropped back to ~0 removes the generated virtual bill', () {
    final categoryId = repo.insertCategory(name: 'Courses maison');
    final scenarioId = repo.createSimScenario('Scénario');

    repo.applyBudgetTargetsToSimScenario(
      simScenarioId: scenarioId,
      accountId: accountId,
      targetsByGroup: {categoryId: -350},
      categoryIdsByGroup: {categoryId: [categoryId]},
      categoryNames: {categoryId: 'Courses maison'},
    );
    final result = repo.applyBudgetTargetsToSimScenario(
      simScenarioId: scenarioId,
      accountId: accountId,
      targetsByGroup: {categoryId: 0},
      categoryIdsByGroup: {categoryId: [categoryId]},
      categoryNames: {categoryId: 'Courses maison'},
    );

    expect(result.virtualBillsRemoved, 1);
    expect(repo.getSimVirtualBills(scenarioId), isEmpty);
  });

  test('a negative (virtual budget) category id always goes through the '
      'virtual-bill path even if a real bill happens to share the account', () {
    const virtualCategoryId = -1;
    final scenarioId = repo.createSimScenario('Scénario');

    final result = repo.applyBudgetTargetsToSimScenario(
      simScenarioId: scenarioId,
      accountId: accountId,
      targetsByGroup: {virtualCategoryId: -120},
      categoryIdsByGroup: {virtualCategoryId: [virtualCategoryId]},
      categoryNames: {virtualCategoryId: 'Part de Julien'},
    );

    expect(result.virtualBillsUpserted, 1);
    expect(repo.getSimVirtualBills(scenarioId).single.label, 'Budget : Part de Julien');
  });

  test('a transfer-funded income category has no Deposit bill to match '
      '(transfers are deliberately excluded), so it falls to the '
      'virtual-bill path rather than overriding the transfer', () {
    final categoryId = repo.insertCategory(name: 'Virement interne');
    final otherAccountId = repo.insertAccount(
        name: 'Autre compte', type: 'Checking', initialBalance: 0, currencyId: 2);
    repo.insertBillDeposit(
      accountId: otherAccountId,
      toAccountId: accountId,
      payeeId: -1,
      transCode: TransCode.transfer,
      amount: 200,
      categoryId: categoryId,
      nextOccurrence: DateTime(2026, 1, 5),
      period: RecurrencePeriod.monthly,
      autoExecute: RecurrenceAutoExecute.manual,
    );
    final scenarioId = repo.createSimScenario('Scénario');

    final result = repo.applyBudgetTargetsToSimScenario(
      simScenarioId: scenarioId,
      accountId: accountId,
      targetsByGroup: {categoryId: 200},
      categoryIdsByGroup: {categoryId: [categoryId]},
      categoryNames: {categoryId: 'Virement interne'},
    );

    // No Deposit bill exists for this category (only a Transfer, which is
    // deliberately not matched) - falls to the virtual-bill path instead.
    expect(result.billsOverridden, 0);
    expect(result.virtualBillsUpserted, 1);
  });
}
