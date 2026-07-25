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
