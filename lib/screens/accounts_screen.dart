import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:money_manager_core/data/mmex_repository.dart';
import 'package:money_manager_core/models/account.dart';
import 'package:money_manager_core/models/currency.dart';
import '../state/api_session_provider.dart';
import '../state/database_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/account_balance_card.dart';
import '../widgets/responsive_body.dart';

/// Regroupe ce qu'il faut pour dessiner l'écran, qu'il vienne du fichier
/// local ([_AccountsScreenState._localData]) ou du serveur API
/// ([_AccountsScreenState._loadViaApi]) - étape 4 du chantier
/// client/serveur (voir PLAN_ARCHITECTURE_CLIENT_SERVEUR.md). Les deux
/// chemins alimentent exactement le même arbre de widgets plus bas, pour
/// ne pas dupliquer tout l'affichage.
class _AccountsData {
  final List<Account> accounts;
  final CurrencyFormat? currency;
  final double Function(int accountId) balanceOf;

  _AccountsData({required this.accounts, required this.currency, required this.balanceOf});
}

class AccountsScreen extends StatefulWidget {
  const AccountsScreen({super.key});

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  Future<_AccountsData>? _apiFuture;

  _AccountsData _localData(MmexRepository repo) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return _AccountsData(
      accounts: repo.getAccounts(),
      currency: repo.getBaseCurrency(),
      balanceOf: (id) => repo.accountBalance(id, asOf: today),
    );
  }

  /// Lecture seule - les écritures (ajouter/modifier/supprimer un compte,
  /// masquer/réafficher) continuent de passer par le fichier local même
  /// en mode API, voir [openAccountEditor]. Ça veut dire qu'une
  /// modification faite ici ne se reflète pas automatiquement dans cette
  /// vue tant qu'on n'a pas rafraîchi manuellement - limitation connue
  /// d'un premier pilote en lecture seule, pas un bug (voir la nuance du
  /// plan sur la bascule des écritures, jamais progressive comme les
  /// lectures).
  Future<_AccountsData> _loadViaApi(ApiSessionProvider session) async {
    final accounts = await session.getAccounts();
    final currency = await session.getBaseCurrency();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final balances = await Future.wait(
        [for (final a in accounts) session.accountBalance(a.id, asOf: today)]);
    final balanceById = {for (var i = 0; i < accounts.length; i++) accounts[i].id: balances[i]};
    return _AccountsData(
      accounts: accounts,
      currency: currency,
      balanceOf: (id) => balanceById[id] ?? 0,
    );
  }

  void _refreshApi(ApiSessionProvider session) {
    setState(() => _apiFuture = _loadViaApi(session));
  }

  @override
  Widget build(BuildContext context) {
    final dbProvider = context.watch<DatabaseProvider>();
    final apiSession = context.watch<ApiSessionProvider>();
    final repo = dbProvider.repository!;

    if (apiSession.useApiForAccounts) {
      _apiFuture ??= _loadViaApi(apiSession);
      return Scaffold(
        appBar: AppBar(
          title: const Text('Comptes (via API)'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Rafraîchir',
              onPressed: () => _refreshApi(apiSession),
            ),
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Paramètres',
              onPressed: () => Navigator.of(context).pushNamed('/settings'),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => openAccountEditor(context, repo),
          icon: const Icon(Icons.add),
          label: const Text('Nouveau compte'),
        ),
        body: FutureBuilder<_AccountsData>(
          future: _apiFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(child: Text('Erreur : ${snapshot.error}'));
            }
            return _buildBody(context, dbProvider, repo, snapshot.data!);
          },
        ),
      );
    }

    _apiFuture = null; // en attente d'une prochaine bascule vers l'API
    return Scaffold(
      appBar: AppBar(
        title: const Text('Comptes'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Paramètres',
            onPressed: () => Navigator.of(context).pushNamed('/settings'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => openAccountEditor(context, repo),
        icon: const Icon(Icons.add),
        label: const Text('Nouveau compte'),
      ),
      body: _buildBody(context, dbProvider, repo, _localData(repo)),
    );
  }

  Widget _buildBody(BuildContext context, DatabaseProvider dbProvider, MmexRepository repo,
      _AccountsData data) {
    final accounts = data.accounts;
    final visible = accounts.where((a) => !dbProvider.isAccountHidden(a.id)).toList();
    final hidden = accounts.where((a) => dbProvider.isAccountHidden(a.id)).toList();

    if (accounts.isEmpty) {
      return const Center(child: Text('Aucun compte'));
    }
    return ResponsiveBody(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          if (visible.isNotEmpty) ...[
            _SectionHeader('Visibles (${visible.length})'),
            const SizedBox(height: 8),
            for (final account in visible)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _AccountRow(
                  account: account,
                  balance: data.balanceOf(account.id),
                  currency: data.currency,
                  hidden: false,
                  onTap: () => openAccountEditor(context, repo, existing: account),
                  onToggleHidden: () => dbProvider.setAccountHidden(account.id, true),
                ),
              ),
          ],
          if (hidden.isNotEmpty) ...[
            const SizedBox(height: 8),
            _SectionHeader('Masqués (${hidden.length})'),
            const SizedBox(height: 8),
            for (final account in hidden)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _AccountRow(
                  account: account,
                  balance: data.balanceOf(account.id),
                  currency: data.currency,
                  hidden: true,
                  onTap: () => openAccountEditor(context, repo, existing: account),
                  onToggleHidden: () => dbProvider.setAccountHidden(account.id, false),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Shared with DashboardScreen's "create your first account" prompt on a
/// freshly created, empty database - same fields, same repository call,
/// rather than a second bespoke form for what's the same underlying action.
Future<void> openAccountEditor(BuildContext context, MmexRepository repo,
    {Account? existing}) async {
  final dbProvider = context.read<DatabaseProvider>();
  final nameController = TextEditingController(text: existing?.name ?? '');
  final balanceController = TextEditingController(
    text: existing != null ? existing.initialBalance.toStringAsFixed(2) : '0',
  );
  String type = existing?.type ?? 'Checking';

  await showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text(existing == null ? 'Nouveau compte' : 'Modifier le compte'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Nom')),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: type,
              decoration: const InputDecoration(labelText: 'Type'),
              items: const [
                'Checking',
                'Savings',
                'Credit Card',
                'Cash',
                'Loan',
                'Term',
                'Asset',
                'Investment'
              ].map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
              onChanged: (v) => setDialogState(() => type = v ?? type),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: balanceController,
              decoration: const InputDecoration(labelText: 'Solde initial'),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
          ],
        ),
        actions: [
          if (existing != null)
            TextButton(
              onPressed: () {
                repo.deleteAccount(existing.id);
                Navigator.of(context).pop();
                dbProvider.touch();
              },
              child: const Text('Supprimer'),
            ),
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Annuler')),
          FilledButton(
            onPressed: () {
              final balance =
                  double.tryParse(balanceController.text.replaceAll(',', '.')) ?? 0;
              if (existing == null) {
                repo.insertAccount(
                  name: nameController.text,
                  type: type,
                  initialBalance: balance,
                  currencyId: repo.getDefaultCurrency()?.id ?? 1,
                );
              } else {
                repo.updateAccount(Account(
                  id: existing.id,
                  name: nameController.text,
                  type: type,
                  status: existing.status,
                  initialBalance: balance,
                  currencyId: existing.currencyId,
                  favorite: existing.favorite,
                ));
              }
              Navigator.of(context).pop();
              dbProvider.touch();
            },
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    ),
  );
}

class _SectionHeader extends StatelessWidget {
  final String label;

  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
        color: Colors.grey[500],
      ),
    );
  }
}

class _AccountRow extends StatelessWidget {
  final Account account;
  final double balance;
  final CurrencyFormat? currency;
  final bool hidden;
  final VoidCallback onTap;
  final VoidCallback onToggleHidden;

  const _AccountRow({
    required this.account,
    required this.balance,
    required this.hidden,
    required this.onTap,
    required this.onToggleHidden,
    this.currency,
  });

  @override
  Widget build(BuildContext context) {
    final positive = balance >= 0;
    return Material(
      color: Theme.of(context).cardColor,
      borderRadius: BorderRadius.circular(AppTheme.cardRadius),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        onTap: onTap,
        child: Opacity(
          opacity: hidden ? 0.55 : 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppTheme.accent.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(iconForAccountType(account.type),
                      color: AppTheme.accent, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        account.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text(
                            account.type,
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey[600]),
                          ),
                          if (hidden) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.grey[200],
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                'Masqué',
                                style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.grey[700],
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  currency?.format(balance) ?? balance.toStringAsFixed(2),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: positive ? AppTheme.positive : AppTheme.negative,
                  ),
                ),
                IconButton(
                  tooltip:
                      hidden ? 'Réafficher ce compte' : 'Masquer ce compte',
                  icon: Icon(
                      hidden
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 20),
                  color: hidden ? Colors.grey[500] : AppTheme.accent,
                  onPressed: onToggleHidden,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
