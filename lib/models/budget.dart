/// A per-account budget envelope: this app's own simplified budget
/// (BudgetScreen) doesn't fit MMEX's real year/period-based budgeting
/// model - it needs an account dimension MMEX's schema has no column for
/// - so it's backed by its own dedicated table instead (APP_BUDGET_
/// ENVELOPES, created by MmexRepository.ensureAppSchema; prefixed APP_ so
/// it reads as obviously not part of MMEX's own schema if the file is
/// ever opened in real MMEX desktop). Just a constant monthly amount per
/// (account, category) pair - no year or period concept to expose.
class BudgetEnvelope {
  final int id;
  final int accountId;
  final int categoryId;
  final double amount;
  final bool active;

  /// Custom display label for this envelope, independent of its category's
  /// own name - null (the default, set at creation) means "use the
  /// category's name", so renaming an envelope never touches the category
  /// itself or anything else that shows it (transactions, recurring bills...).
  final String? name;

  const BudgetEnvelope({
    required this.id,
    required this.accountId,
    required this.categoryId,
    required this.amount,
    required this.active,
    this.name,
  });

  factory BudgetEnvelope.fromRow(Map<String, Object?> row) {
    return BudgetEnvelope(
      id: row['ENVELOPEID'] as int,
      accountId: row['ACCOUNTID'] as int,
      categoryId: row['CATEGID'] as int,
      amount: (row['AMOUNT'] as num?)?.toDouble() ?? 0,
      active: (row['ACTIVE'] as int? ?? 1) == 1,
      name: row['NAME'] as String?,
    );
  }
}

/// A named, saveable "what if" budget - see APP_BUDGET_SCENARIOS. Its
/// per-category simulated amounts live separately (APP_BUDGET_SCENARIO_
/// AMOUNTS, see MmexRepository.getBudgetScenarioAmounts) since a scenario
/// on its own is just a name, an account, and an averaging period.
class BudgetScenario {
  final int id;
  final int accountId;
  final String name;
  final int periodMonths;
  final DateTime createdAt;
  final DateTime updatedAt;

  const BudgetScenario({
    required this.id,
    required this.accountId,
    required this.name,
    required this.periodMonths,
    required this.createdAt,
    required this.updatedAt,
  });

  factory BudgetScenario.fromRow(Map<String, Object?> row) {
    return BudgetScenario(
      id: row['SCENARIOID'] as int,
      accountId: row['ACCOUNTID'] as int,
      name: row['NAME'] as String? ?? '',
      periodMonths: row['PERIOD_MONTHS'] as int? ?? 12,
      createdAt: DateTime.tryParse(row['CREATED_AT'] as String? ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(row['UPDATED_AT'] as String? ?? '') ?? DateTime.now(),
    );
  }
}
