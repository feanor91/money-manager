import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:money_manager_core/data/mmex_repository.dart';
import 'package:money_manager_core/models/category.dart';
import '../state/api_session_provider.dart';
import '../state/database_provider.dart';
import '../widgets/refreshing_overlay.dart';
import '../widgets/responsive_body.dart';
import '../widgets/searchable_select_field.dart';

/// Bundle des données nécessaires pour dessiner l'écran, qu'elles viennent
/// du fichier local ou du serveur API - étape 4 du chantier client/serveur
/// (voir PLAN_ARCHITECTURE_CLIENT_SERVEUR.md), même principe que
/// AccountsScreen. [usageOf] est une fonction plutôt qu'un accès direct -
/// synchrone (appel direct à `repo.categoryUsage`) en local, déjà résolue
/// à l'avance (une map) en mode API, puisqu'on ne peut pas faire un appel
/// réseau à chaque item construit dans la liste.
class _CategoriesData {
  final List<Category> categories;
  final CategoryUsage Function(int categoryId) usageOf;

  _CategoriesData({required this.categories, required this.usageOf});
}

class CategoriesScreen extends StatefulWidget {
  const CategoriesScreen({super.key});

  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends State<CategoriesScreen> {
  final _searchController = TextEditingController();
  String _search = '';
  bool _showArchived = false;
  Future<_CategoriesData>? _apiFuture;
  _CategoriesData? _lastData;
  ({bool showArchived, int dataVersion})? _apiFutureKey;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  _CategoriesData _localData(MmexRepository repo) {
    // When showing archived too, onlyActive:false returns everything so
    // archived categories can still be found and reactivated from here.
    return _CategoriesData(
      categories: repo.getCategories(onlyActive: !_showArchived),
      usageOf: repo.categoryUsage,
    );
  }

  Future<_CategoriesData> _loadViaApi(ApiSessionProvider session) async {
    final categories = await session.getCategories(onlyActive: !_showArchived);
    final usages = await Future.wait([for (final c in categories) session.categoryUsage(c.id)]);
    final usageById = {for (var i = 0; i < categories.length; i++) categories[i].id: usages[i]};
    return _CategoriesData(
      categories: categories,
      usageOf: (id) =>
          usageById[id] ??
          const CategoryUsage(
              childCategoryCount: 0,
              transactionCount: 0,
              recurringCount: 0,
              budgetEntryCount: 0,
              payeeDefaultCount: 0),
    );
  }

  void _refreshApi(ApiSessionProvider session) {
    session.bumpDataVersion();
    setState(() {
      _apiFutureKey = (showArchived: _showArchived, dataVersion: session.dataVersion);
      _apiFuture = _loadViaApi(session);
    });
  }

  @override
  Widget build(BuildContext context) {
    final dbProvider = context.watch<DatabaseProvider>();
    final apiSession = context.watch<ApiSessionProvider>();
    final repo = dbProvider.repository!;

    if (apiSession.useApiForCategories) {
      final key = (showArchived: _showArchived, dataVersion: apiSession.dataVersion);
      if (_apiFuture == null || _apiFutureKey != key) {
        _apiFutureKey = key;
        _apiFuture = _loadViaApi(apiSession);
      }
      return Scaffold(
        appBar: AppBar(
          title: const Text('Catégories (via API)'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Rafraîchir',
              onPressed: () => _refreshApi(apiSession),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () async {
            await _addCategory(context, repo, parentId: null, apiSession: apiSession);
            _refreshApi(apiSession);
          },
          icon: const Icon(Icons.add),
          label: const Text('Nouvelle catégorie'),
        ),
        body: FutureBuilder<_CategoriesData>(
          future: _apiFuture,
          builder: (context, snapshot) {
            if (snapshot.hasData) _lastData = snapshot.data;
            if (_lastData == null) {
              if (snapshot.hasError) {
                return Center(child: Text('Erreur : ${snapshot.error}'));
              }
              return const Center(child: CircularProgressIndicator());
            }
            return RefreshingOverlay(
              refreshing: snapshot.connectionState != ConnectionState.done,
              child: _buildBody(context, dbProvider, repo, _lastData!, apiSession: apiSession),
            );
          },
        ),
      );
    }

    _apiFuture = null;
    return Scaffold(
      appBar: AppBar(title: const Text('Catégories')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await _addCategory(context, repo, parentId: null);
          dbProvider.touch();
        },
        icon: const Icon(Icons.add),
        label: const Text('Nouvelle catégorie'),
      ),
      body: _buildBody(context, dbProvider, repo, _localData(repo)),
    );
  }

  Widget _buildBody(
      BuildContext context, DatabaseProvider dbProvider, MmexRepository repo, _CategoriesData data,
      {ApiSessionProvider? apiSession}) {
    final all = data.categories;
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

    return ResponsiveBody(
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
                      hintText: 'Rechercher une catégorie',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => setState(() => _search = v),
                  ),
                ),
                const SizedBox(width: 12),
                Tooltip(
                  message: 'Afficher les catégories archivées',
                  child: FilterChip(
                    label: const Text('Archivées'),
                    selected: _showArchived,
                    onSelected: (v) => setState(() => _showArchived = v),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: visibleParents.isEmpty
                ? const Center(child: Text('Aucune catégorie'))
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
                        usageOf: data.usageOf,
                        initiallyExpanded: query.isNotEmpty,
                        apiSession: apiSession,
                        onChanged: () {
                          if (apiSession != null) {
                            _refreshApi(apiSession);
                          } else {
                            dbProvider.touch();
                          }
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _CategoryGroup extends StatelessWidget {
  final Category parent;
  final List<Category> children;
  final MmexRepository repo;
  final CategoryUsage Function(int categoryId) usageOf;
  final bool initiallyExpanded;
  final ApiSessionProvider? apiSession;
  final VoidCallback onChanged;

  const _CategoryGroup({
    super.key,
    required this.parent,
    required this.children,
    required this.repo,
    required this.usageOf,
    required this.initiallyExpanded,
    this.apiSession,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final usage = usageOf(parent.id);
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
                apiSession: apiSession,
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
                  title: _CategoryTitle(category: child, usage: usageOf(child.id)),
                  trailing: _CategoryMenu(
                    category: child,
                    usage: usageOf(child.id),
                    repo: repo,
                    apiSession: apiSession,
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
                  onPressed: () async {
                    await _addCategory(context, repo, parentId: parent.id, apiSession: apiSession);
                    onChanged();
                  },
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Ajouter une sous-catégorie'),
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
            label: Text('Archivée', style: TextStyle(fontSize: 11)),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: EdgeInsets.zero,
          ),
        ],
        if (usage.transactionCount > 0) ...[
          const SizedBox(width: 8),
          Text(
            '${usage.transactionCount} opération(s)',
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
  final ApiSessionProvider? apiSession;
  final VoidCallback onChanged;
  final bool allowAddChild;

  const _CategoryMenu({
    required this.category,
    required this.usage,
    required this.repo,
    this.apiSession,
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
          const PopupMenuItem(value: 'add_child', child: Text('Ajouter une sous-catégorie')),
        if (!allowAddChild)
          const PopupMenuItem(value: 'move', child: Text('Déplacer vers...')),
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
          child: Text(category.active ? 'Archiver' : 'Réactiver'),
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

  bool get _useApi =>
      apiSession != null && apiSession!.useApiForCategories && apiSession!.isConnected;

  Future<void> _handle(BuildContext context, String action) async {
    switch (action) {
      case 'rename':
        await _renameCategory(context, repo, category, apiSession: apiSession);
        onChanged();
      case 'add_child':
        await _addCategory(context, repo, parentId: category.id, apiSession: apiSession);
        onChanged();
      case 'move':
        await _moveCategory(context, repo, category, apiSession: apiSession);
        onChanged();
      case 'merge':
        if (!usage.isLeaf) return;
        await _mergeCategory(context, repo, category, apiSession: apiSession);
        onChanged();
      case 'toggle_active':
        if (_useApi) {
          await apiSession!.setCategoryActive(category.id, !category.active);
        } else {
          repo.setCategoryActive(category.id, !category.active);
        }
        onChanged();
      case 'delete':
        await _deleteCategory(context, repo, category, usage, apiSession: apiSession);
        onChanged();
    }
  }
}

Future<void> _addCategory(BuildContext context, MmexRepository repo,
    {int? parentId, ApiSessionProvider? apiSession}) async {
  final controller = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(parentId == null ? 'Nouvelle catégorie' : 'Nouvelle sous-catégorie'),
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
  if (apiSession != null && apiSession.useApiForCategories && apiSession.isConnected) {
    await apiSession.insertCategory(name: trimmed, parentId: parentId);
  } else {
    repo.insertCategory(name: trimmed, parentId: parentId);
  }
}

Future<void> _renameCategory(BuildContext context, MmexRepository repo, Category category,
    {ApiSessionProvider? apiSession}) async {
  final controller = TextEditingController(text: category.name);
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Renommer la catégorie'),
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
  if (apiSession != null && apiSession.useApiForCategories && apiSession.isConnected) {
    await apiSession.renameCategory(category.id, trimmed);
  } else {
    repo.renameCategory(category.id, trimmed);
  }
}

/// Sentinel returned by [_moveCategory]'s picker for "no parent" - CATEGID
/// is a real DB autoincrement id (always positive), so -1 can never
/// collide with an actual category, same convention CATEGORY_V1.PARENTID
/// itself already uses for "no parent".
const _topLevelSentinel = Category(id: -1, name: 'Aucune (catégorie mère)', active: true);

Future<void> _moveCategory(BuildContext context, MmexRepository repo, Category category,
    {ApiSessionProvider? apiSession}) async {
  final useApi = apiSession != null && apiSession.useApiForCategories && apiSession.isConnected;
  final allCategories =
      useApi ? await apiSession.getCategories(onlyActive: false) : repo.getCategories(onlyActive: false);
  if (!context.mounted) return;
  final topLevel =
      allCategories.where((c) => c.parentId == null && c.id != category.parentId).toList();
  final options = [_topLevelSentinel, ...topLevel];

  Category? target;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text('Déplacer "${category.name}"'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Ses opérations, échéances et budgets restent liés à cette '
                'catégorie - seule sa catégorie mère change.',
              ),
              const SizedBox(height: 16),
              SearchableSelectField<Category>(
                label: 'Nouvelle catégorie mère',
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
            child: const Text('Déplacer'),
          ),
        ],
      ),
    ),
  );
  if (confirmed != true || target == null) return;
  final chosen = target!;
  final newParentId = chosen.id == _topLevelSentinel.id ? null : chosen.id;
  if (useApi) {
    await apiSession.moveCategory(category.id, newParentId);
  } else {
    repo.moveCategory(category.id, newParentId);
  }
}

Future<void> _mergeCategory(BuildContext context, MmexRepository repo, Category source,
    {ApiSessionProvider? apiSession}) async {
  final useApi = apiSession != null && apiSession.useApiForCategories && apiSession.isConnected;
  final categories =
      useApi ? await apiSession.getCategories(onlyActive: false) : repo.getCategories(onlyActive: false);
  if (!context.mounted) return;
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
                'Les opérations, échéances, budgets et tiers associés à '
                '"${source.name}" seront transférés vers la catégorie '
                'choisie, puis "${source.name}" sera supprimée.',
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
  if (useApi) {
    await apiSession.mergeCategories(fromId: source.id, toId: target!.id);
  } else {
    repo.mergeCategories(fromId: source.id, toId: target!.id);
  }
}

Future<void> _deleteCategory(
  BuildContext context,
  MmexRepository repo,
  Category category,
  CategoryUsage usage, {
  ApiSessionProvider? apiSession,
}) async {
  if (!usage.canDelete) {
    final reasons = <String>[
      if (usage.childCategoryCount > 0) '${usage.childCategoryCount} sous-catégorie(s)',
      if (usage.transactionCount > 0) '${usage.transactionCount} opération(s)',
      if (usage.recurringCount > 0) '${usage.recurringCount} opération(s) récurrente(s)',
      if (usage.budgetEntryCount > 0) '${usage.budgetEntryCount} ligne(s) de budget',
      if (usage.payeeDefaultCount > 0) '${usage.payeeDefaultCount} tiers par défaut',
    ];
    final archiveInstead = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Impossible de supprimer'),
        content: Text(
          '"${category.name}" est encore utilisée par : ${reasons.join(', ')}.\n\n'
          'Vous pouvez l\'archiver à la place : elle disparaîtra des listes de '
          'choix sans toucher à son historique.',
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
      if (apiSession != null && apiSession.useApiForCategories && apiSession.isConnected) {
        await apiSession.setCategoryActive(category.id, false);
      } else {
        repo.setCategoryActive(category.id, false);
      }
    }
    return;
  }

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Supprimer la catégorie'),
      content: Text('Supprimer définitivement "${category.name}" ?'),
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
    if (apiSession != null && apiSession.useApiForCategories && apiSession.isConnected) {
      await apiSession.deleteCategory(category.id);
    } else {
      repo.deleteCategory(category.id);
    }
  }
}
