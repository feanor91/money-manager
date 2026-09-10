class Category {
  final int id;
  final String name;
  final int? parentId;
  final bool active;

  const Category({
    required this.id,
    required this.name,
    required this.active,
    this.parentId,
  });

  factory Category.fromRow(Map<String, Object?> row) {
    final parent = row['PARENTID'] as int?;
    return Category(
      id: row['CATEGID'] as int,
      name: row['CATEGNAME'] as String? ?? '',
      active: (row['ACTIVE'] as int? ?? 1) == 1,
      parentId: (parent == null || parent == -1) ? null : parent,
    );
  }
}

/// What still references a category - see [MmexRepository.categoryUsage].
/// A category can be safely hard-deleted only when every count here is 0.
class CategoryUsage {
  final int childCategoryCount;
  final int transactionCount;
  final int recurringCount;
  final int budgetEntryCount;
  final int payeeDefaultCount;

  const CategoryUsage({
    required this.childCategoryCount,
    required this.transactionCount,
    required this.recurringCount,
    required this.budgetEntryCount,
    required this.payeeDefaultCount,
  });

  bool get canDelete =>
      childCategoryCount == 0 &&
      transactionCount == 0 &&
      recurringCount == 0 &&
      budgetEntryCount == 0 &&
      payeeDefaultCount == 0;

  bool get isLeaf => childCategoryCount == 0;

  /// True if anything other than subcategories references it - i.e. it
  /// could still be merged away (subcategories don't block a merge in the
  /// same way they block a delete, since merge doesn't touch them).
  bool get isReferencedElsewhere =>
      transactionCount > 0 ||
      recurringCount > 0 ||
      budgetEntryCount > 0 ||
      payeeDefaultCount > 0;
}

/// Sums [rawSpend] for [categoryId] together with every direct child it
/// has (MMEX categories only nest one level deep, so this doesn't need to
/// recurse) - a budget envelope on a parent category ("Alimentation")
/// should capture spending recorded against its subcategories too
/// ("Alimentation:Restaurant"), not just the parent's own direct
/// transactions.
double rolledUpSpend(int categoryId, Map<int, double> rawSpend, List<Category> allCategories) {
  var total = rawSpend[categoryId] ?? 0;
  for (final c in allCategories) {
    if (c.parentId == categoryId) total += rawSpend[c.id] ?? 0;
  }
  return total;
}

/// "Parent:Child" style path MMEX uses to display a category, walking up
/// the parent chain (guards against accidental cycles with a hop limit).
String categoryFullPath(int? categoryId, Map<int, Category> categoriesById) {
  if (categoryId == null) return '';
  final segments = <String>[];
  var current = categoriesById[categoryId];
  var hops = 0;
  while (current != null && hops < 10) {
    segments.add(current.name);
    current = current.parentId != null ? categoriesById[current.parentId] : null;
    hops++;
  }
  return segments.reversed.join(':');
}
