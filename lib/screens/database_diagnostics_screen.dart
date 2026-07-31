import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/database_diagnostics.dart';
import '../data/mmex_repository.dart';
import '../models/account.dart';
import '../models/category.dart';
import '../models/currency.dart';
import '../models/payee.dart';
import '../models/transaction.dart';
import '../state/database_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/responsive_body.dart';
import 'transactions_screen.dart' show TransactionEditorSheet;

/// Read-only report of database integrity anomalies (orphaned references,
/// malformed categories, recurring-bill inconsistencies, probable
/// duplicate transactions, orphaned transfers...) - see
/// lib/data/database_diagnostics.dart for the checks themselves. Nothing
/// here offers a one-click fix: this screen only ever reads the database,
/// on purpose (see the doc comment on runDatabaseDiagnostics). Findings
/// tied to a real transaction render as an actual ledger-style row -
/// tapping one opens the exact same editor as the Transactions screen
/// (TransactionEditorSheet, shared rather than reimplemented) so a real
/// problem can be fixed on the spot instead of just being described.
class DatabaseDiagnosticsScreen extends StatefulWidget {
  const DatabaseDiagnosticsScreen({super.key});

  @override
  State<DatabaseDiagnosticsScreen> createState() => _DatabaseDiagnosticsScreenState();
}

class _DatabaseDiagnosticsScreenState extends State<DatabaseDiagnosticsScreen> {
  int? _selectedYear;

  Future<void> _openEditor(MmexRepository repo, DatabaseProvider dbProvider, MoneyTransaction tx) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => TransactionEditorSheet(existing: tx, repo: repo),
    );
    dbProvider.touch();
  }

  @override
  Widget build(BuildContext context) {
    final dbProvider = context.watch<DatabaseProvider>();
    final repo = dbProvider.repository!;
    final findings = runDatabaseDiagnostics(repo);
    final txById = loadTransactionsForFindings(repo, findings);
    final accountsById = {for (final a in repo.getAccounts()) a.id: a};
    final categoriesById = {for (final c in repo.getCategories(onlyActive: false)) c.id: c};
    final payeesById = {for (final p in repo.getPayees(onlyActive: false)) p.id: p};
    final currency = repo.getBaseCurrency();

    final datedFindings = findings.where((f) => f.transactionIds.isNotEmpty).toList();
    final undatedFindings = findings.where((f) => f.transactionIds.isEmpty).toList();

    final findingsByYear = <int, List<DiagnosticFinding>>{};
    for (final f in datedFindings) {
      final tx = txById[f.transactionIds.first];
      if (tx == null) continue;
      findingsByYear.putIfAbsent(tx.date.year, () => []).add(f);
    }
    final years = findingsByYear.keys.toList()..sort((a, b) => b.compareTo(a));
    final visibleYears = _selectedYear == null ? years : [_selectedYear!];

    final errorCount = findings.where((f) => f.severity == DiagnosticSeverity.error).length;
    final warningCount = findings.where((f) => f.severity == DiagnosticSeverity.warning).length;
    final infoCount = findings.where((f) => f.severity == DiagnosticSeverity.info).length;

    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostic de la base')),
      body: ResponsiveBody(
        maxWidth: 800,
        child: findings.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Aucune anomalie détectée.',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (errorCount > 0) _CountChip(count: errorCount, color: AppTheme.negative, label: 'à corriger'),
                      if (warningCount > 0)
                        _CountChip(count: warningCount, color: AppTheme.warning, label: 'à vérifier'),
                      if (infoCount > 0)
                        _CountChip(
                            count: infoCount,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            label: 'information'),
                    ],
                  ),
                  if (years.length > 1) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Text('Année : '),
                        DropdownButton<int?>(
                          value: _selectedYear,
                          items: [
                            const DropdownMenuItem(value: null, child: Text('Toutes')),
                            for (final y in years) DropdownMenuItem(value: y, child: Text('$y')),
                          ],
                          onChanged: (y) => setState(() => _selectedYear = y),
                        ),
                      ],
                    ),
                  ],
                  for (final year in visibleYears) ...[
                    const SizedBox(height: 16),
                    Text('$year', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: Column(
                          children: [
                            for (final f in findingsByYear[year]!)
                              _DatedFindingBlock(
                                finding: f,
                                txById: txById,
                                accountsById: accountsById,
                                categoriesById: categoriesById,
                                payeesById: payeesById,
                                currency: currency,
                                onTapTx: (tx) => _openEditor(repo, dbProvider, tx),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (undatedFindings.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text('Autres anomalies (non liées à une transaction)',
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 4),
                    for (final category in DiagnosticCategory.values)
                      if (undatedFindings.where((f) => f.category == category).toList()
                          case final items when items.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(category.label, style: Theme.of(context).textTheme.bodySmall),
                        const SizedBox(height: 4),
                        Card(
                          child: Column(children: [for (final f in items) _UndatedFindingTile(finding: f)]),
                        ),
                      ],
                  ],
                ],
              ),
      ),
    );
  }
}

class _CountChip extends StatelessWidget {
  final int count;
  final Color color;
  final String label;

  const _CountChip({required this.count, required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text('$count $label', style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12)),
    );
  }
}

(IconData, Color) _severityIconColor(BuildContext context, DiagnosticSeverity severity) {
  return switch (severity) {
    DiagnosticSeverity.error => (Icons.error_outline, AppTheme.negative),
    DiagnosticSeverity.warning => (Icons.warning_amber_rounded, AppTheme.warning),
    DiagnosticSeverity.info => (Icons.info_outline, Theme.of(context).colorScheme.onSurfaceVariant),
  };
}

/// A finding tied to one or more real transactions: the reason it was
/// flagged, followed by each transaction rendered as its own tappable row.
class _DatedFindingBlock extends StatelessWidget {
  final DiagnosticFinding finding;
  final Map<int, MoneyTransaction> txById;
  final Map<int, Account> accountsById;
  final Map<int, Category> categoriesById;
  final Map<int, Payee> payeesById;
  final CurrencyFormat? currency;
  final ValueChanged<MoneyTransaction> onTapTx;

  const _DatedFindingBlock({
    required this.finding,
    required this.txById,
    required this.accountsById,
    required this.categoriesById,
    required this.payeesById,
    required this.currency,
    required this.onTapTx,
  });

  @override
  Widget build(BuildContext context) {
    final (icon, color) = _severityIconColor(context, finding.severity);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(finding.message,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
              ),
            ],
          ),
          for (final id in finding.transactionIds)
            if (txById[id] case final tx?)
              _TxRow(
                tx: tx,
                accountsById: accountsById,
                categoriesById: categoriesById,
                payeesById: payeesById,
                currency: currency,
                onTap: () => onTapTx(tx),
              ),
        ],
      ),
    );
  }
}

class _UndatedFindingTile extends StatelessWidget {
  final DiagnosticFinding finding;

  const _UndatedFindingTile({required this.finding});

  @override
  Widget build(BuildContext context) {
    final (icon, color) = _severityIconColor(context, finding.severity);
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(finding.message),
    );
  }
}

/// One transaction, rendered like a compact ledger row (date, tiers or
/// virement, catégorie, montant) - unlike the real ledger this can mix
/// several accounts in the same list, so the account name is shown too.
class _TxRow extends StatelessWidget {
  static final _dateFormat = DateFormat('dd/MM/yy');

  final MoneyTransaction tx;
  final Map<int, Account> accountsById;
  final Map<int, Category> categoriesById;
  final Map<int, Payee> payeesById;
  final CurrencyFormat? currency;
  final VoidCallback onTap;

  const _TxRow({
    required this.tx,
    required this.accountsById,
    required this.categoriesById,
    required this.payeesById,
    required this.currency,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accountName = accountsById[tx.accountId]?.name ?? 'Compte introuvable';

    final String detail;
    if (tx.transCode == TransCode.transfer) {
      final toName =
          tx.toAccountId == null ? 'compte introuvable' : (accountsById[tx.toAccountId]?.name ?? 'compte introuvable');
      detail = '$accountName → $toName';
    } else {
      final payeeName = payeesById[tx.payeeId]?.name ?? 'Payé inconnu';
      final categoryPath = categoryFullPath(tx.categoryId, categoriesById);
      detail = [accountName, payeeName, if (categoryPath.isNotEmpty) categoryPath].join(' · ');
    }

    final amount = tx.signedAmountFor(tx.accountId);
    final amountColor = amount < 0 ? AppTheme.negative : AppTheme.positive;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          children: [
            Icon(
              tx.isReconciled ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 16,
              color: tx.isReconciled ? AppTheme.positive : scheme.outlineVariant,
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 62,
              child: Text(
                _dateFormat.format(tx.date),
                style: Theme.of(context).textTheme.bodySmall,
                softWrap: false,
                overflow: TextOverflow.clip,
              ),
            ),
            Expanded(
              child: Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            Text(
              currency?.format(amount) ?? amount.toStringAsFixed(2),
              style: TextStyle(fontWeight: FontWeight.w600, color: amountColor),
            ),
          ],
        ),
      ),
    );
  }
}
