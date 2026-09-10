import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:money_manager_core/data/mmex_repository.dart';
import 'package:money_manager_core/models/payee.dart';
import '../state/api_session_provider.dart';
import '../state/database_provider.dart';
import '../widgets/responsive_body.dart';
import '../widgets/searchable_select_field.dart';

/// Bundle des données nécessaires pour dessiner l'écran, qu'elles viennent
/// du fichier local ou du serveur API - étape 4 du chantier client/serveur
/// (voir PLAN_ARCHITECTURE_CLIENT_SERVEUR.md), même principe
/// qu'AccountsScreen/CategoriesScreen.
class _PayeesData {
  final List<Payee> payees;
  final int Function(int payeeId) usageCountOf;

  _PayeesData({required this.payees, required this.usageCountOf});
}

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
  Future<_PayeesData>? _apiFuture;
  _PayeesData? _lastData;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  _PayeesData _localData(MmexRepository repo) {
    return _PayeesData(
      payees: repo.getPayees(onlyActive: false),
      usageCountOf: repo.payeeUsageCount,
    );
  }

  /// Lecture seule - voir AccountsScreen._loadViaApi pour la même nuance
  /// (les écritures continuent de passer par le fichier local même en
  /// mode API, pas de rafraîchissement automatique après une modification).
  Future<_PayeesData> _loadViaApi(ApiSessionProvider session) async {
    final payees = await session.getPayees(onlyActive: false);
    final counts = await Future.wait([for (final p in payees) session.payeeUsageCount(p.id)]);
    final countById = {for (var i = 0; i < payees.length; i++) payees[i].id: counts[i]};
    return _PayeesData(payees: payees, usageCountOf: (id) => countById[id] ?? 0);
  }

  void _refreshApi(ApiSessionProvider session) {
    setState(() => _apiFuture = _loadViaApi(session));
  }

  @override
  Widget build(BuildContext context) {
    final dbProvider = context.watch<DatabaseProvider>();
    final apiSession = context.watch<ApiSessionProvider>();
    final repo = dbProvider.repository!;

    if (apiSession.useApiForPayees) {
      _apiFuture ??= _loadViaApi(apiSession);
      return Scaffold(
        appBar: AppBar(
          title: const Text('Tiers (via API)'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Rafraîchir',
              onPressed: () => _refreshApi(apiSession),
            ),
          ],
        ),
        body: FutureBuilder<_PayeesData>(
          future: _apiFuture,
          builder: (context, snapshot) {
            if (snapshot.hasData) _lastData = snapshot.data;
            if (_lastData == null) {
              if (snapshot.hasError) {
                return Center(child: Text('Erreur : ${snapshot.error}'));
              }
              return const Center(child: CircularProgressIndicator());
            }
            return _buildBody(context, dbProvider, repo, _lastData!, apiSession: apiSession);
          },
        ),
      );
    }

    _apiFuture = null;
    return Scaffold(
      appBar: AppBar(title: const Text('Tiers')),
      body: _buildBody(context, dbProvider, repo, _localData(repo)),
    );
  }

  Widget _buildBody(
      BuildContext context, DatabaseProvider dbProvider, MmexRepository repo, _PayeesData data,
      {ApiSessionProvider? apiSession}) {
    final all = [...data.payees]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    final query = _search.trim().toLowerCase();
    final visible =
        query.isEmpty ? all : all.where((p) => p.name.toLowerCase().contains(query)).toList();

    return ResponsiveBody(
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
                        usageCount: data.usageCountOf(payee.id),
                        repo: repo,
                        allPayees: all,
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

class _PayeeRow extends StatelessWidget {
  final Payee payee;
  final int usageCount;
  final MmexRepository repo;
  final List<Payee> allPayees;
  final ApiSessionProvider? apiSession;
  final VoidCallback onChanged;

  const _PayeeRow({
    super.key,
    required this.payee,
    required this.usageCount,
    required this.repo,
    required this.allPayees,
    this.apiSession,
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
        await _renamePayee(context, repo, payee, apiSession: apiSession);
        onChanged();
      case 'merge':
        await _mergePayee(context, repo, payee, allPayees, apiSession: apiSession);
        onChanged();
      case 'delete':
        if (usageCount != 0) return;
        await _deletePayee(context, repo, payee, apiSession: apiSession);
        onChanged();
    }
  }
}

Future<void> _renamePayee(BuildContext context, MmexRepository repo, Payee payee,
    {ApiSessionProvider? apiSession}) async {
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
  if (apiSession != null && apiSession.useApiForPayees && apiSession.isConnected) {
    await apiSession.renamePayee(payee.id, trimmed);
  } else {
    repo.renamePayee(payee.id, trimmed);
  }
}

Future<void> _mergePayee(
  BuildContext context,
  MmexRepository repo,
  Payee source,
  List<Payee> allPayees, {
  ApiSessionProvider? apiSession,
}) async {
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
  if (apiSession != null && apiSession.useApiForPayees && apiSession.isConnected) {
    await apiSession.mergePayees(fromId: source.id, toId: target!.id);
  } else {
    repo.mergePayees(fromId: source.id, toId: target!.id);
  }
}

Future<void> _deletePayee(BuildContext context, MmexRepository repo, Payee payee,
    {ApiSessionProvider? apiSession}) async {
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
    if (apiSession != null && apiSession.useApiForPayees && apiSession.isConnected) {
      await apiSession.deletePayee(payee.id);
    } else {
      repo.deletePayee(payee.id);
    }
  }
}
