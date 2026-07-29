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
