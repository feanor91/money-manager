import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/mmex_repository.dart';
import '../models/budget_period.dart' show nextForecastDay;
import '../models/currency.dart';
import '../state/database_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/account_balance_card.dart';
import '../widgets/bento_card.dart';
import '../widgets/budget_preview_card.dart';
import '../widgets/category_spend_analyzer.dart';
import '../widgets/category_spend_bar_chart.dart';
import '../widgets/forecast_chart.dart';
import '../widgets/nl_query_dialog.dart';
import '../widgets/responsive_body.dart';
import '../widgets/transaction_entry_flow.dart';
import '../widgets/transaction_tile.dart';
import '../widgets/webdav_conflict_dialog.dart';
import 'accounts_screen.dart' show openAccountEditor;

/// Same convention as transactions_screen.dart / webdav_settings_card.dart -
/// re-declared locally rather than shared, per this codebase's existing
/// pattern for this one-line platform check.
bool get _isAndroidPlatform =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final dbProvider = context.watch<DatabaseProvider>();
    final repo = dbProvider.repository!;
    final currency = repo.getBaseCurrency();

    final allAccountsById = {for (final a in repo.getAccounts()) a.id: a};
    final unorderedAccounts = repo
        .getAccounts(onlyOpen: true)
        .where((a) => !dbProvider.isAccountHidden(a.id))
        .toList();
    final accounts =
        dbProvider.sortByAccountOrder(unorderedAccounts, (a) => a.id);
    final balances = {
      for (final a in accounts) a.id: repo.accountBalance(a.id)
    };

    if (accounts.isEmpty) {
      final isBrandNew = allAccountsById.isEmpty;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Tableau de bord'),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Paramètres',
              onPressed: () => Navigator.of(context).pushNamed('/settings'),
            ),
          ],
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: isBrandNew
                  ? [
                      const Text('Bienvenue dans Money Manager !',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 12),
                      Text(
                        'Créez votre premier compte pour commencer.',
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: () => openAccountEditor(context, repo),
                        icon: const Icon(Icons.add),
                        label: const Text('Créer mon premier compte'),
                      ),
                    ]
                  : [
                      const Text('Tous les comptes sont masqués.'),
                      const SizedBox(height: 12),
                      Text(
                        'Réactivez-en un depuis l\'onglet Comptes.',
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                    ],
            ),
          ),
        ),
      );
    }

    // Fall back to the first visible account if the persisted selection
    // points at a hidden, closed, or deleted one.
    final selectedAccountId =
        accounts.any((a) => a.id == dbProvider.selectedAccountId)
            ? dbProvider.selectedAccountId!
            : accounts.first.id;
    final scopedBalance = balances[selectedAccountId] ?? 0;

    final now = DateTime.now();
    final forecastDate = nextForecastDay(now, dbProvider.forecastDay);
    final forecastDateLabel =
        'Prév. au ${DateFormat('d MMM', 'fr_FR').format(forecastDate)}';
    final forecastBalances = {
      for (final a in accounts)
        a.id: repo.forecastAccountBalance(a.id, forecastDate)
    };
    final categories = {for (final c in repo.getCategories()) c.id: c};
    final recentTx =
        repo.getTransactions(accountId: selectedAccountId, limit: 6);
    final payees = {for (final p in repo.getPayees(onlyActive: false)) p.id: p};

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        tooltip: 'Nouvelle transaction',
        // Android gets an extra "Par la voix" choice first (same mechanic as
        // TransactionsScreen's own FAB) - everywhere else this stays exactly
        // the single direct tap it always was, since there'd be nothing else
        // to choose from there.
        onPressed: () => _isAndroidPlatform
            ? _showAddChoice(context, selectedAccountId)
            : openTransactionEditor(context,
                defaultAccountId: selectedAccountId),
        child: const Icon(Icons.add),
      ),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            // The theme's AppBarTheme is deliberately transparent (fine for
            // a non-pinned bar, or one nothing scrolls behind for long) -
            // but a *pinned* bar has content sliding under it continuously,
            // so without an opaque background here the scrolled-away
            // content stays visible right through it instead of
            // disappearing behind it.
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            title: const Text('Tableau de bord'),
            actions: [
              PopupMenuButton<AppPalette>(
                icon: const Icon(Icons.palette_outlined),
                tooltip: 'Palette de couleurs',
                onSelected: (p) => dbProvider.setPalette(p),
                itemBuilder: (context) => [
                  for (final palette in AppPalette.values)
                    PopupMenuItem(
                      value: palette,
                      child: Row(
                        children: [
                          Container(
                            width: 18,
                            height: 18,
                            decoration: BoxDecoration(
                                color: palette.seed, shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 12),
                          Text(palette.label),
                          if (dbProvider.palette == palette) ...[
                            const Spacer(),
                            const Icon(Icons.check, size: 18),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.query_stats),
                tooltip: 'Analyser les dépenses par catégorie',
                onPressed: () => openCategorySpendAnalyzer(
                  context: context,
                  repo: repo,
                  accountId: selectedAccountId,
                  categories: categories.values.toList(),
                  currency: currency,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chat_bubble_outline),
                tooltip: 'Poser une question',
                onPressed: () => openNlQueryDialog(
                  context: context,
                  repo: repo,
                  defaultAccountId: selectedAccountId,
                  forecastDay: dbProvider.forecastDay,
                ),
              ),
              if (dbProvider.webDavConfigured)
                IconButton(
                  icon: switch (dbProvider.syncStatus) {
                    SyncStatus.syncing => const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    SyncStatus.conflictPending ||
                    SyncStatus.remoteMissing ||
                    SyncStatus.error =>
                      Icon(Icons.sync_problem_outlined,
                          color: Theme.of(context).colorScheme.error),
                    SyncStatus.idle => const Icon(Icons.cloud_sync_outlined),
                  },
                  tooltip: switch (dbProvider.syncStatus) {
                    SyncStatus.syncing => 'Synchronisation en cours',
                    SyncStatus.conflictPending => 'Conflit de synchronisation à résoudre',
                    SyncStatus.remoteMissing => 'Fichier distant introuvable',
                    SyncStatus.error => 'Échec de la dernière synchronisation',
                    SyncStatus.idle => 'Synchroniser avec le serveur',
                  },
                  onPressed: dbProvider.syncStatus == SyncStatus.syncing
                      ? null
                      : () => handleWebDavSyncTap(context),
                ),
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Paramètres',
                onPressed: () => Navigator.of(context).pushNamed('/settings'),
              ),
            ],
          ),
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(
              child: ResponsiveBody(
                maxWidth: 1400,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    IntrinsicHeight(
                      child: _TotalBalanceCard(
                        total: scopedBalance,
                        currency: currency,
                        label: accounts
                            .firstWhere((a) => a.id == selectedAccountId)
                            .name,
                        forecastBalance: forecastBalances[selectedAccountId],
                        forecastLabel: forecastDateLabel,
                      ),
                    ),
                    const SizedBox(height: AppTheme.gridGap),
                    _DashboardChartSection(
                      repository: repo,
                      scopedBalance: scopedBalance,
                      currency: currency,
                      selectedAccountId: selectedAccountId,
                    ),
                    const SizedBox(height: AppTheme.gridGap),
                    LayoutBuilder(builder: (context, constraints) {
                      final wide = constraints.maxWidth > 800;
                      // A horizontal carousel of fixed-width cards always
                      // crops the last one somewhere - fine on desktop where
                      // it reads as "scroll for more", but on a narrow screen
                      // it just looks broken. Below the wide breakpoint, show
                      // every account as a full-width tile stacked instead -
                      // no cropping, no scrolling. Drag-to-reorder only
                      // applies to the wide carousel; narrow order follows
                      // the same saved order but isn't itself draggable.
                      final accountsGrid = wide
                          ? SizedBox(
                              height: 168,
                              child: ReorderableListView.builder(
                                scrollDirection: Axis.horizontal,
                                buildDefaultDragHandles: false,
                                itemCount: accounts.length,
                                onReorderItem: (oldIndex, newIndex) {
                                  final reordered = [...accounts];
                                  final moved = reordered.removeAt(oldIndex);
                                  reordered.insert(newIndex, moved);
                                  dbProvider.setAccountOrder(
                                      reordered.map((a) => a.id).toList());
                                },
                                itemBuilder: (context, i) {
                                  final account = accounts[i];
                                  return Padding(
                                    key: ValueKey(account.id),
                                    padding: const EdgeInsets.only(
                                        right: AppTheme.gridGap),
                                    child: SizedBox(
                                      width: 210,
                                      child: Stack(
                                        children: [
                                          AccountBalanceCard(
                                            account: account,
                                            balance: balances[account.id] ?? 0,
                                            currency: currency,
                                            selected:
                                                account.id == selectedAccountId,
                                            onTap: () => dbProvider
                                                .selectAccount(account.id),
                                            forecastBalance:
                                                forecastBalances[account.id],
                                            forecastLabel: forecastDateLabel,
                                          ),
                                          Positioned(
                                            top: 6,
                                            right: 6,
                                            child: ReorderableDragStartListener(
                                              index: i,
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.all(4),
                                                decoration: BoxDecoration(
                                                  color: Colors.grey
                                                      .withValues(alpha: 0.15),
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                ),
                                                child: Icon(
                                                    Icons.drag_indicator,
                                                    size: 18,
                                                    color: AppTheme.accent),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            )
                          : Wrap(
                              spacing: AppTheme.gridGap,
                              runSpacing: AppTheme.gridGap,
                              children: [
                                for (final account in accounts)
                                  SizedBox(
                                    width: constraints.maxWidth < 380
                                        ? constraints.maxWidth
                                        : (constraints.maxWidth -
                                                AppTheme.gridGap) /
                                            2,
                                    height: 140,
                                    child: AccountBalanceCard(
                                      account: account,
                                      balance: balances[account.id] ?? 0,
                                      currency: currency,
                                      selected: account.id == selectedAccountId,
                                      onTap: () =>
                                          dbProvider.selectAccount(account.id),
                                      forecastBalance:
                                          forecastBalances[account.id],
                                      forecastLabel: forecastDateLabel,
                                    ),
                                  ),
                              ],
                            );
                      final spendCard = SizedBox(
                        height: 320,
                        child: BudgetPreviewCard(
                          repository: repo,
                          currency: currency,
                          accountId: selectedAccountId,
                          forecastDay: dbProvider.forecastDay,
                        ),
                      );
                      final recentCard = SizedBox(
                        height: 320,
                        child: BentoCard(
                          title: 'Transactions récentes',
                          child: ListView.builder(
                            itemCount: recentTx.length,
                            itemBuilder: (context, i) {
                              final tx = recentTx[i];
                              return TransactionTile(
                                transaction: tx,
                                payee: payees[tx.payeeId],
                                category: tx.categoryId != null
                                    ? categories[tx.categoryId]
                                    : null,
                                fromAccount: allAccountsById[tx.accountId],
                                toAccount: tx.toAccountId != null
                                    ? allAccountsById[tx.toAccountId]
                                    : null,
                                viewpointAccountId: selectedAccountId,
                                currency: currency,
                                onToggleReconciled: (value) {
                                  repo.setReconciled(tx.id, value);
                                  dbProvider.touch();
                                },
                              );
                            },
                          ),
                        ),
                      );

                      if (wide) {
                        return Column(
                          children: [
                            accountsGrid,
                            const SizedBox(height: AppTheme.gridGap),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: spendCard),
                                const SizedBox(width: AppTheme.gridGap),
                                Expanded(child: recentCard),
                              ],
                            ),
                          ],
                        );
                      }
                      return Column(
                        children: [
                          accountsGrid,
                          const SizedBox(height: AppTheme.gridGap),
                          spendCard,
                          const SizedBox(height: AppTheme.gridGap),
                          recentCard,
                        ],
                      );
                    }),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Same choice-sheet mechanic as TransactionsScreen's own FAB, minus the
/// "opération récurrente" option that only makes sense from that screen -
/// only shown at all when [_isAndroidPlatform], see the FAB above.
Future<void> _showAddChoice(BuildContext context, int? accountId) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.receipt_long_outlined),
            title: const Text('Nouvelle transaction'),
            onTap: () => Navigator.of(context).pop('transaction'),
          ),
          ListTile(
            leading: const Icon(Icons.mic_outlined),
            title: const Text('Par la voix'),
            onTap: () => Navigator.of(context).pop('voice'),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted || choice == null) return;
  if (choice == 'voice') {
    await startVoiceEntry(context, accountId);
  } else {
    await openTransactionEditor(context, defaultAccountId: accountId);
  }
}

/// Toggles the dashboard's headline chart between the balance forecast
/// ([ForecastChart]) and a per-category spent-vs-planned bar chart
/// ([CategorySpendBarChart]) - one or the other, never both at once, same
/// "show one or the other" convention as ForecastChart's own chart/table
/// toggle (`_showAsTable`) just one level up, since these are two whole
/// different widgets rather than two views of the same data.
class _DashboardChartSection extends StatefulWidget {
  final MmexRepository repository;
  final double scopedBalance;
  final CurrencyFormat? currency;
  final int selectedAccountId;

  const _DashboardChartSection({
    required this.repository,
    required this.scopedBalance,
    required this.currency,
    required this.selectedAccountId,
  });

  @override
  State<_DashboardChartSection> createState() => _DashboardChartSectionState();
}

class _DashboardChartSectionState extends State<_DashboardChartSection> {
  bool _showSpendChart = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      // Narrow widths need extra room: the duration dropdown and axis
      // labels can wrap onto more lines than they do on a wide desktop
      // layout.
      final chartHeight = constraints.maxWidth < 480 ? 460.0 : 400.0;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              tooltip: _showSpendChart
                  ? 'Afficher la prévision de solde'
                  : 'Afficher les dépenses par catégorie',
              onPressed: () => setState(() => _showSpendChart = !_showSpendChart),
              icon: Icon(_showSpendChart ? Icons.show_chart : Icons.bar_chart),
            ),
          ),
          SizedBox(
            height: chartHeight,
            child: _showSpendChart
                ? CategorySpendBarChart(
                    repository: widget.repository,
                    currency: widget.currency,
                    accountId: widget.selectedAccountId,
                  )
                : ForecastChart(
                    repository: widget.repository,
                    startingBalance: widget.scopedBalance,
                    currency: widget.currency,
                    accountId: widget.selectedAccountId,
                  ),
          ),
        ],
      );
    });
  }
}

class _TotalBalanceCard extends StatelessWidget {
  final double total;
  final CurrencyFormat? currency;
  final String label;

  /// Projected total on [forecastLabel]'s date - see
  /// [AccountBalanceCard.forecastBalance] for the rationale.
  final double? forecastBalance;
  final String? forecastLabel;

  const _TotalBalanceCard({
    required this.total,
    required this.label,
    this.currency,
    this.forecastBalance,
    this.forecastLabel,
  });

  @override
  Widget build(BuildContext context) {
    return BentoCard(
      color: AppTheme.accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label,
              style: const TextStyle(
                  color: Colors.white70, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (forecastBalance != null) ...[
            Text(
              currency?.format(forecastBalance!) ??
                  forecastBalance!.toStringAsFixed(2),
              style: TextStyle(
                color: forecastBalance! < 0 ? AppTheme.negative : Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w800,
                letterSpacing: -1,
              ),
            ),
            const SizedBox(height: 2),
            Text(forecastLabel ?? '',
                style: const TextStyle(color: Colors.white70, fontSize: 11)),
            const SizedBox(height: 6),
            Text(
              'Solde actuel : ${currency?.format(total) ?? total.toStringAsFixed(2)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: total < 0 ? AppTheme.negative : Colors.white70,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ] else
            Text(
              currency?.format(total) ?? total.toStringAsFixed(2),
              style: TextStyle(
                color: total < 0 ? AppTheme.negative : Colors.white,
                fontSize: 34,
                fontWeight: FontWeight.w800,
                letterSpacing: -1,
              ),
            ),
        ],
      ),
    );
  }
}
