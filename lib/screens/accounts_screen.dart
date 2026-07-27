import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/mmex_repository.dart';
import '../models/account.dart';
import '../models/currency.dart';
import '../state/database_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/account_balance_card.dart';
import '../widgets/responsive_body.dart';

class AccountsScreen extends StatefulWidget {
  const AccountsScreen({super.key});

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  @override
  Widget build(BuildContext context) {
    final dbProvider = context.watch<DatabaseProvider>();
    final repo = dbProvider.repository!;
    final currency = repo.getBaseCurrency();
    final accounts = repo.getAccounts();
    final visible =
        accounts.where((a) => !dbProvider.isAccountHidden(a.id)).toList();
    final hidden =
        accounts.where((a) => dbProvider.isAccountHidden(a.id)).toList();

    return Scaffold(
      backgroundColor: const Color(0xFFF4F5F9),
      appBar: AppBar(title: const Text('Comptes')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(context, repo),
        icon: const Icon(Icons.add),
        label: const Text('Nouveau compte'),
      ),
      body: accounts.isEmpty
          ? const Center(child: Text('Aucun compte'))
          : ResponsiveBody(
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
                          balance: repo.accountBalance(account.id),
                          currency: currency,
                          hidden: false,
                          onTap: () =>
                              _openEditor(context, repo, existing: account),
                          onToggleHidden: () =>
                              dbProvider.setAccountHidden(account.id, true),
                        ),
                      ),
                  ],
                  if (hidden.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _SectionHeader('Masques (${hidden.length})'),
                    const SizedBox(height: 8),
                    for (final account in hidden)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _AccountRow(
                          account: account,
                          balance: repo.accountBalance(account.id),
                          currency: currency,
                          hidden: true,
                          onTap: () =>
                              _openEditor(context, repo, existing: account),
                          onToggleHidden: () =>
                              dbProvider.setAccountHidden(account.id, false),
                        ),
                      ),
                  ],
                ],
              ),
            ),
    );
  }

  Future<void> _openEditor(BuildContext context, MmexRepository repo,
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
          title:
              Text(existing == null ? 'Nouveau compte' : 'Modifier le compte'),
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
                ]
                    .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                    .toList(),
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
                final balance = double.tryParse(balanceController.text) ?? 0;
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
                                'Masque',
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
                      hidden ? 'Reafficher ce compte' : 'Masquer ce compte',
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
