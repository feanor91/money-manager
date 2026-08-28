import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/mmex_repository.dart';
import '../models/payee.dart';
import '../state/database_provider.dart';
import '../widgets/responsive_body.dart';
import '../widgets/searchable_select_field.dart';

/// "Gestion des tiers" (Paramètres) - 2026-08-23 user request: a flat list
/// of every payee with how many real records reference it, rename in
/// place, and delete only when that count is exactly 0. Merge (2026-08-28
/// user request, e.g. several statement-line payees like "CB AMINE VIANDE
/// FACT xxxxx" all really meaning the same "Boucherie") re-points every
/// real transaction/recurring bill to the target payee - same shape as
/// CategoriesScreen's own merge, unlike everything else here which stays
/// deliberately simpler (no archive/active toggle - payees don't have that
/// concept in this app).
class PayeesScreen extends StatefulWidget {
  const PayeesScreen({super.key});

  @override
  State<PayeesScreen> createState() => _PayeesScreenState();
}

class _PayeesScreenState extends State<PayeesScreen> {
  final _searchController = TextEditingController();
  String _search = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dbProvider = context.watch<DatabaseProvider>();
    final repo = dbProvider.repository!;
    final all = repo.getPayees(onlyActive: false)..sort((a, b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    final query = _search.trim().toLowerCase();
    final visible =
        query.isEmpty ? all : all.where((p) => p.name.toLowerCase().contains(query)).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Tiers')),
      body: ResponsiveBody(
        maxWidth: 800,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: TextField(
                controller: _searchController,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Rechercher un tiers',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _search = v),
              ),
            ),
            Expanded(
              child: visible.isEmpty
                  ? const Center(child: Text('Aucun tiers'))
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final payee = visible[index];
                        return _PayeeRow(
                          key: ValueKey(payee.id),
                          payee: payee,
                          usageCount: repo.payeeUsageCount(payee.id),
                          repo: repo,
                          allPayees: all,
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

class _PayeeRow extends StatelessWidget {
  final Payee payee;
  final int usageCount;
  final MmexRepository repo;
  final List<Payee> allPayees;
  final VoidCallback onChanged;

  const _PayeeRow({
    super.key,
    required this.payee,
    required this.usageCount,
    required this.repo,
    required this.allPayees,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        title: Text(payee.name),
        subtitle: Text(
          usageCount == 0 ? 'Aucune opération' : '$usageCount opération(s)/échéance(s)',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (action) => _handle(context, action),
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'rename', child: Text('Renommer')),
            const PopupMenuItem(value: 'merge', child: Text('Fusionner avec...')),
            PopupMenuItem(
              value: 'delete',
              enabled: usageCount == 0,
              child: Text(
                'Supprimer',
                style: TextStyle(
                  color: usageCount == 0 ? theme.colorScheme.error : theme.disabledColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handle(BuildContext context, String action) async {
    switch (action) {
      case 'rename':
        await _renamePayee(context, repo, payee);
        onChanged();
      case 'merge':
        await _mergePayee(context, repo, payee, allPayees);
        onChanged();
      case 'delete':
        if (usageCount != 0) return;
        await _deletePayee(context, repo, payee);
        onChanged();
    }
  }
}

Future<void> _renamePayee(BuildContext context, MmexRepository repo, Payee payee) async {
  final controller = TextEditingController(text: payee.name);
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Renommer le tiers'),
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
  if (trimmed == null || trimmed.isEmpty || trimmed == payee.name) return;
  repo.renamePayee(payee.id, trimmed);
}

Future<void> _mergePayee(
  BuildContext context,
  MmexRepository repo,
  Payee source,
  List<Payee> allPayees,
) async {
  final options = allPayees.where((p) => p.id != source.id).toList();

  Payee? target;
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
                'Les opérations et opérations récurrentes de "${source.name}" '
                'seront transférées vers le tiers choisi, puis '
                '"${source.name}" sera supprimé.',
              ),
              const SizedBox(height: 16),
              SearchableSelectField<Payee>(
                label: 'Fusionner vers',
                options: options,
                labelOf: (p) => p.name,
                onSelected: (p) => setDialogState(() => target = p),
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
  repo.mergePayees(fromId: source.id, toId: target!.id);
}

Future<void> _deletePayee(BuildContext context, MmexRepository repo, Payee payee) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Supprimer le tiers'),
      content: Text('Supprimer définitivement "${payee.name}" ? Il n\'est utilisé par aucune '
          'opération ni opération récurrente.'),
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
    repo.deletePayee(payee.id);
  }
}
