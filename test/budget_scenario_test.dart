import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:money_manager/data/mmex_database.dart';
import 'package:money_manager/data/mmex_database_io.dart' as io_db;
import 'package:money_manager/data/mmex_repository.dart';
import 'package:money_manager/models/transaction.dart';

/// A blank-but-real MMEX database, in memory - loads the same schema
/// asset used to create a brand-new .mmb (see blank_database.dart), minus
/// its rootBundle dependency (a plain repository test doesn't need Flutter
/// asset bindings), plus this app's own APP_ tables.
Future<MmexDatabase> _openBlankDb() async {
  final db = await io_db.openFromPath(':memory:');
  final sql = File('assets/mmex_blank_schema.sql').readAsStringSync();
  // See blank_database.dart's initializeBlankSchema for why comment lines
  // are stripped before splitting on ';', not after.
  final withoutComments =
      sql.split('\n').where((line) => !line.trim().startsWith('--')).join('\n');
  db.transaction(() {
    for (final statement in withoutComments.split(';')) {
      final trimmed = statement.trim();
      if (trimmed.isEmpty) continue;
      db.execute(trimmed);
    }
  });
  MmexRepository(db).ensureAppSchema();
  return db;
}

void main() {
  late MmexDatabase db;
  late MmexRepository repo;
  late int accountId;
  late int expenseCategoryId;
  late int incomeCategoryId;

  setUp(() async {
    db = await _openBlankDb();
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
