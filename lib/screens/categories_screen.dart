import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/mmex_repository.dart';
import '../models/category.dart';
import '../state/database_provider.dart';
import '../widgets/responsive_body.dart';
import '../widgets/searchable_select_field.dart';

class CategoriesScreen extends StatefulWidget {
  const CategoriesScreen({super.key});

  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends State<CategoriesScreen> {
  final _searchController = TextEditingController();
  String _search = '';
  bool _showArchived = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dbProvider = context.watch<DatabaseProvider>();
    final repo = dbProvider.repository!;
    // When showing archived too, onlyActive:false returns everything so
    // archived categories can still be found and reactivated from here.
    final all = repo.getCategories(onlyActive: !_showArchived);
    final byParent = <int?, List<Category>>{};
    for (final c in all) {
      byParent.putIfAbsent(c.parentId, () => []).add(c);
    }
    final parents = byParent[null] ?? const <Category>[];

    final query = _search.trim().toLowerCase();
    bool matches(Category c) => c.name.toLowerCase().contains(query);
    final visibleParents = query.isEmpty
        ? parents
        : parents.where((p) {
            final children = byParent[p.id] ?? const <Category>[];
            return matches(p) || children.any(matches);
          }).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Categories')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addCategory(context, repo, parentId: null),
        icon: const Icon(Icons.add),
        label: const Text('Nouvelle categorie'),
      ),
      body: ResponsiveBody(
        maxWidth: 800,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Rechercher une categorie',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (v) => setState(() => _search = v),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Tooltip(
                    message: 'Afficher les categories archivees',
                    child: FilterChip(
                      label: const Text('Archivees'),
                      selected: _showArchived,
                      onSelected: (v) => setState(() => _showArchived = v),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: visibleParents.isEmpty
                  ? const Center(child: Text('Aucune categorie'))
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 96),
                      itemCount: visibleParents.length,
                      itemBuilder: (context, index) {
                        final parent = visibleParents[index];
                        final allChildren = byParent[parent.id] ?? const <Category>[];
                        final children = query.isEmpty || matches(parent)
                            ? allChildren
                            : allChildren.where(matches).toList();
                        return _CategoryGroup(
                          key: ValueKey(parent.id),
                          parent: parent,
                          children: children,
                          repo: repo,
                          initiallyExpanded: query.isNotEmpty,
                          onChanged: () => dbProvider.touch(),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryGroup extends StatelessWidget {
  final Category parent;
  final List<Category> children;
  final MmexRepository repo;
  final bool initiallyExpanded;
  final VoidCallback onChanged;

  const _CategoryGroup({
    super.key,
    required this.parent,
    required this.children,
    required this.repo,
    required this.initiallyExpanded,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final usage = repo.categoryUsage(parent.id);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          title: _CategoryTitle(category: parent, usage: usage),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _CategoryMenu(
                category: parent,
                usage: usage,
                repo: repo,
                onChanged: onChanged,
                allowAddChild: true,
              ),
              const Icon(Icons.expand_more),
            ],
          ),
          children: [
            for (final child in children)
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: ListTile(
                  title: _CategoryTitle(category: child, usage: repo.categoryUsage(child.id)),
                  trailing: _CategoryMenu(
                    category: child,
                    usage: repo.categoryUsage(child.id),
                    repo: repo,
                    onChanged: onChanged,
                    allowAddChild: false,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _addCategory(context, repo, parentId: parent.id),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Ajouter une sous-categorie'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryTitle extends StatelessWidget {
  final Category category;
  final CategoryUsage usage;

  const _CategoryTitle({required this.category, required this.usage});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Flexible(
          child: Text(
            category.name,
            overflow: TextOverflow.ellipsis,
            style: category.active
                ? null
                : TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        if (!category.active) ...[
          const SizedBox(width: 8),
          const Chip(
            label: Text('Archivee', style: TextStyle(fontSize: 11)),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: EdgeInsets.zero,
          ),
        ],
        if (usage.transactionCount > 0) ...[
          const SizedBox(width: 8),
          Text(
            '${usage.transactionCount} operation(s)',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

class _CategoryMenu extends StatelessWidget {
  final Category category;
  final CategoryUsage usage;
  final MmexRepository repo;
  final VoidCallback onChanged;
  final bool allowAddChild;

  const _CategoryMenu({
    required this.category,
    required this.usage,
    required this.repo,
    required this.onChanged,
    required this.allowAddChild,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      onSelected: (action) => _handle(context, action),
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'rename', child: Text('Renommer')),
        if (allowAddChild)
          const PopupMenuItem(value: 'add_child', child: Text('Ajouter une sous-categorie')),
        if (!allowAddChild)
          const PopupMenuItem(value: 'move', child: Text('Deplacer vers...')),
        PopupMenuItem(
          value: 'merge',
          enabled: usage.isLeaf,
          child: Text(
            'Fusionner avec...',
            style: usage.isLeaf
                ? null
                : TextStyle(color: Theme.of(context).disabledColor),
          ),
        ),
        PopupMenuItem(
          value: 'toggle_active',
          child: Text(category.active ? 'Archiver' : 'Reactiver'),
        ),
        PopupMenuItem(
          value: 'delete',
          child: Text(
            'Supprimer',
            style: TextStyle(
              color: usage.canDelete ? Theme.of(context).colorScheme.error : Theme.of(context).disabledColor,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _handle(BuildContext context, String action) async {
    switch (action) {
      case 'rename':
        await _renameCategory(context, repo, category);
        onChanged();
      case 'add_child':
        await _addCategory(context, repo, parentId: category.id);
        onChanged();
      case 'move':
        await _moveCategory(context, repo, category);
        onChanged();
      case 'merge':
        if (!usage.isLeaf) return;
        await _mergeCategory(context, repo, category);
        onChanged();
      case 'toggle_active':
        repo.setCategoryActive(category.id, !category.active);
        onChanged();
      case 'delete':
        await _deleteCategory(context, repo, category, usage);
        onChanged();
    }
  }
}

Future<void> _addCategory(BuildContext context, MmexRepository repo, {int? parentId}) async {
  final controller = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(parentId == null ? 'Nouvelle categorie' : 'Nouvelle sous-categorie'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Nom'),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: const Text('Ajouter'),
        ),
      ],
    ),
  );
  final trimmed = name?.trim();
  if (trimmed == null || trimmed.isEmpty) return;
  repo.insertCategory(name: trimmed, parentId: parentId);
}

Future<void> _renameCategory(BuildContext context, MmexRepository repo, Category category) async {
  final controller = TextEditingController(text: category.name);
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Renommer la categorie'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Nom'),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: const Text('Enregistrer'),
        ),
      ],
    ),
  );
  final trimmed = name?.trim();
  if (trimmed == null || trimmed.isEmpty || trimmed == category.name) return;
  repo.renameCategory(category.id, trimmed);
}

/// Sentinel returned by [_moveCategory]'s picker for "no parent" - CATEGID
/// is a real DB autoincrement id (always positive), so -1 can never
/// collide with an actual category, same convention CATEGORY_V1.PARENTID
/// itself already uses for "no parent".
const _topLevelSentinel = Category(id: -1, name: 'Aucune (categorie mere)', active: true);

Future<void> _moveCategory(BuildContext context, MmexRepository repo, Category category) async {
  final topLevel = repo
      .getCategories(onlyActive: false)
      .where((c) => c.parentId == null && c.id != category.parentId)
      .toList();
  final options = [_topLevelSentinel, ...topLevel];

  Category? target;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text('Deplacer "${category.name}"'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Ses operations, echeances et budgets restent lies a cette '
                'categorie - seule sa categorie mere change.',
              ),
              const SizedBox(height: 16),
              SearchableSelectField<Category>(
                label: 'Nouvelle categorie mere',
                options: options,
                labelOf: (c) => c.name,
                onSelected: (c) => setDialogState(() => target = c),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Annuler')),
          FilledButton(
            onPressed: target == null ? null : () => Navigator.of(context).pop(true),
            child: const Text('Deplacer'),
          ),
        ],
      ),
    ),
  );
  if (confirmed != true || target == null) return;
  final chosen = target!;
  repo.moveCategory(category.id, chosen.id == _topLevelSentinel.id ? null : chosen.id);
}

Future<void> _mergeCategory(BuildContext context, MmexRepository repo, Category source) async {
  final categories = repo.getCategories(onlyActive: false);
  final categoriesById = {for (final c in categories) c.id: c};
  final options = categories.where((c) => c.id != source.id).toList();

  Category? target;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text('Fusionner "${source.name}"'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Les operations, echeances, budgets et tiers associes a '
                '"${source.name}" seront transferes vers la categorie '
                'choisie, puis "${source.name}" sera supprimee.',
              ),
              const SizedBox(height: 16),
              SearchableSelectField<Category>(
                label: 'Fusionner vers',
                options: options,
                labelOf: (c) => categoryFullPath(c.id, categoriesById),
                onSelected: (c) => setDialogState(() => target = c),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Annuler')),
          FilledButton(
            onPressed: target == null ? null : () => Navigator.of(context).pop(true),
            child: const Text('Fusionner'),
          ),
        ],
      ),
    ),
  );
  if (confirmed != true || target == null) return;
  repo.mergeCategories(fromId: source.id, toId: target!.id);
}

Future<void> _deleteCategory(
  BuildContext context,
  MmexRepository repo,
  Category category,
  CategoryUsage usage,
) async {
  if (!usage.canDelete) {
    final reasons = <String>[
      if (usage.childCategoryCount > 0) '${usage.childCategoryCount} sous-categorie(s)',
      if (usage.transactionCount > 0) '${usage.transactionCount} operation(s)',
      if (usage.recurringCount > 0) '${usage.recurringCount} operation(s) recurrente(s)',
      if (usage.budgetEntryCount > 0) '${usage.budgetEntryCount} ligne(s) de budget',
      if (usage.payeeDefaultCount > 0) '${usage.payeeDefaultCount} tiers par defaut',
    ];
    final archiveInstead = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Impossible de supprimer'),
        content: Text(
          '"${category.name}" est encore utilisee par : ${reasons.join(', ')}.\n\n'
          'Vous pouvez l\'archiver a la place : elle disparaitra des listes de '
          'choix sans toucher a son historique.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Fermer')),
          if (category.active)
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Archiver'),
            ),
        ],
      ),
    );
    if (archiveInstead == true) {
      repo.setCategoryActive(category.id, false);
    }
    return;
  }

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Supprimer la categorie'),
      content: Text('Supprimer definitivement "${category.name}" ?'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Annuler')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Supprimer'),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    repo.deleteCategory(category.id);
  }
}
