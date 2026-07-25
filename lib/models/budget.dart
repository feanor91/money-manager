enum BudgetPeriod { none, weekly, biWeekly, monthly, quarterly, halfYearly, yearly }

BudgetPeriod budgetPeriodFromString(String period) {
  switch (period) {
    case 'Weekly':
      return BudgetPeriod.weekly;
    case 'Bi-Weekly':
      return BudgetPeriod.biWeekly;
    case 'Monthly':
      return BudgetPeriod.monthly;
    case 'Quarterly':
      return BudgetPeriod.quarterly;
    case 'Half-Yearly':
      return BudgetPeriod.halfYearly;
    case 'Yearly':
      return BudgetPeriod.yearly;
    default:
      return BudgetPeriod.none;
  }
}

/// Converts a budget entry's amount + period into an equivalent monthly amount.
double budgetPeriodToMonthlyFactor(BudgetPeriod period) {
  switch (period) {
    case BudgetPeriod.weekly:
      return 52 / 12;
    case BudgetPeriod.biWeekly:
      return 26 / 12;
    case BudgetPeriod.monthly:
      return 1;
    case BudgetPeriod.quarterly:
      return 1 / 3;
    case BudgetPeriod.halfYearly:
      return 1 / 6;
    case BudgetPeriod.yearly:
      return 1 / 12;
    case BudgetPeriod.none:
      return 0;
  }
}

class BudgetYear {
  final int id;
  final String name;

  const BudgetYear({required this.id, required this.name});

  factory BudgetYear.fromRow(Map<String, Object?> row) {
    return BudgetYear(
      id: row['BUDGETYEARID'] as int,
      name: row['BUDGETYEARNAME'] as String? ?? '',
    );
  }
}

class BudgetEntry {
  final int id;
  final int budgetYearId;
  final int categoryId;
  final BudgetPeriod period;
  final double amount;
  final bool active;

  const BudgetEntry({
    required this.id,
    required this.budgetYearId,
    required this.categoryId,
    required this.period,
    required this.amount,
    required this.active,
  });

  double get monthlyAmount => amount * budgetPeriodToMonthlyFactor(period);

  factory BudgetEntry.fromRow(Map<String, Object?> row) {
    return BudgetEntry(
      id: row['BUDGETENTRYID'] as int,
      budgetYearId: row['BUDGETYEARID'] as int,
      categoryId: row['CATEGID'] as int,
      period: budgetPeriodFromString(row['PERIOD'] as String? ?? ''),
      amount: (row['AMOUNT'] as num?)?.toDouble() ?? 0,
      active: (row['ACTIVE'] as int? ?? 1) == 1,
    );
  }
}
