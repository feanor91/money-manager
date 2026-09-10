import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'package:money_manager_core/data/mmex_repository.dart';
import 'package:money_manager_core/models/account.dart';
import 'package:money_manager_core/models/budget_period.dart' show nextForecastDay;
import 'package:money_manager_core/models/category.dart';
import 'package:money_manager_core/models/currency.dart';
import 'package:money_manager_core/models/payee.dart';
import 'package:money_manager_core/models/transaction.dart';
import '../state/api_session_provider.dart';
import '../state/database_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/account_balance_card.dart';
import '../widgets/bento_card.dart';
import '../widgets/budget_preview_card.dart';
import '../widgets/category_spend_analyzer.dart';
import '../widgets/category_spend_bar_chart.dart';
import '../widgets/forecast_chart.dart';
import '../widgets/nl_query_dialog.dart';
import '../widgets/refreshing_overlay.dart';
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

/// Données brutes du tableau de bord (étape 4) - le graphique de
/// prévision (ForecastChart) reste toujours local, voir
/// PLAN_ARCHITECTURE_CLIENT_SERVEUR.md. [balances] est asOf aujourd'hui
/// (voir la remarque sur "Solde actuel" plus bas), [forecastBalances]/
/// [negativeDates] sont la projection au jour de prévision configuré.
class _DashboardData {
  final List<Account> accounts;
  final Map<int, Account> allAccountsById;
  final int? selectedAccountId;
  final CurrencyFormat? currency;
  final Map<int, double> balances;
  final Map<int, double> forecastBalances;
  final Map<int, DateTime?> negativeDates;
  final Map<int, Category> categories;
  final List<MoneyTransaction> recentTx;
  final Map<int, Payee> payees;

  const _DashboardData({
    required this.accounts,
    required this.allAccountsById,
    required this.selectedAccountId,
    required this.currency,
    required this.balances,
    required this.forecastBalances,
    required this.negativeDates,
    required this.categories,
    required this.recentTx,
    required this.payees,
  });
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Future<_DashboardData>? _apiFuture;
  _DashboardData? _lastData;
  ({int? selectedAccountId, int forecastDay, int dataVersion})? _apiFutureKey;

  /// La liste des comptes elle-même vient maintenant aussi du serveur en
  /// mode API (2026-09-10, demande explicite de l'utilisateur après un
  /// test avec un fichier local vide/factice : auparavant, cette liste
  /// restait toujours locale, donc un fichier local vide faisait
  /// systématiquement passer le tableau de bord sur l'écran "Bienvenue,
  /// créez votre premier compte" même connecté au serveur avec de vrais
  /// comptes - voir PLAN_ARCHITECTURE_CLIENT_SERVEUR.md). L'ordre/le
  /// masquage des comptes restent des préférences locales
  /// ([DatabaseProvider]), appliquées ici quelle que soit la source des
  /// comptes eux-mêmes.
  _DashboardData _localData(MmexRepository repo, DatabaseProvider dbProvider) {
    final allAccountsById = {for (final a in repo.getAccounts()) a.id: a};
    final unorderedAccounts = repo
        .getAccounts(onlyOpen: true)
        .where((a) => !dbProvider.isAccountHidden(a.id))
        .toList();
    final accounts = dbProvider.sortByAccountOrder(unorderedAccounts, (a) => a.id);
    final selectedAccountId = accounts.any((a) => a.id == dbProvider.selectedAccountId)
        ? dbProvider.selectedAccountId
        : (accounts.isEmpty ? null : accounts.first.id);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final forecastDate = nextForecastDay(now, dbProvider.forecastDay);
    return _DashboardData(
      accounts: accounts,
      allAccountsById: allAccountsById,
      selectedAccountId: selectedAccountId,
      currency: repo.getBaseCurrency(),
      // asOf: today, not the plain all-transactions total - the latter
      // includes any transaction already recorded with a future date (e.g.
      // a bill paid ahead of its due date), which made "Solde actuel" show
      // an account as already overdrawn before that transaction's own date
      // (found 2026-08-18, same bug as ForecastChart's "today" point - see
      // its doc comment). Those entries still show up in full, on their
      // own date, in the forecast chart/"Prév." figures below.
      balances: {for (final a in accounts) a.id: repo.accountBalance(a.id, asOf: today)},
      forecastBalances: {
        for (final a in accounts) a.id: repo.forecastAccountBalance(a.id, forecastDate)
      },
      negativeDates: {for (final a in accounts) a.id: repo.forecastNegativeDate(a.id)},
      categories: {for (final c in repo.getCategories()) c.id: c},
      recentTx: selectedAccountId == null
          ? const []
          : repo.getTransactions(accountId: selectedAccountId, limit: 6),
      payees: {for (final p in repo.getPayees(onlyActive: false)) p.id: p},
    );
  }

  /// Lecture seule - "Nouvelle transaction", pointer une opération,
  /// l'analyseur de dépenses et "Poser une question" continuent de passer
  /// par le dépôt local même en mode API, voir chaque `repo.xxx` dans
  /// [_buildScaffold].
  Future<_DashboardData> _loadViaApi(ApiSessionProvider session, DatabaseProvider dbProvider) async {
    // Tous les appels indépendants partent en parallèle (Future.wait) plutôt
    // qu'en séquence - un aller-retour réseau à la fois pouvait facilement
    // cumuler plusieurs dizaines/centaines de ms par écran (et jusqu'à 3 par
    // compte pour les soldes, avant ce correctif) - trouvé lent en testant
    // en conditions réelles (2026-09-10, retour utilisateur "temps de
    // réponse catastrophiques").
    final results = await Future.wait([
      session.getAccounts(),
      session.getAccounts(onlyOpen: true),
      session.getBaseCurrency(),
      session.getCategories(),
      session.getPayees(onlyActive: false),
    ]);
    final allAccounts = results[0] as List<Account>;
    final allAccountsById = {for (final a in allAccounts) a.id: a};
    final unorderedAccounts =
        (results[1] as List<Account>).where((a) => !dbProvider.isAccountHidden(a.id)).toList();
    final accounts = dbProvider.sortByAccountOrder(unorderedAccounts, (a) => a.id);
    final selectedAccountId = accounts.any((a) => a.id == dbProvider.selectedAccountId)
        ? dbProvider.selectedAccountId
        : (accounts.isEmpty ? null : accounts.first.id);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final forecastDate = nextForecastDay(now, dbProvider.forecastDay);

    final currency = results[2] as CurrencyFormat?;
    final categories = results[3] as List<Category>;
    final payees = results[4] as List<Payee>;

    final balancesList = await Future.wait([for (final a in accounts) session.accountBalance(a.id, asOf: today)]);
    final forecastBalancesList =
        await Future.wait([for (final a in accounts) session.forecastAccountBalance(a.id, forecastDate)]);
    final negativeDatesList =
        await Future.wait([for (final a in accounts) session.forecastNegativeDate(a.id)]);
    final balances = {for (var i = 0; i < accounts.length; i++) accounts[i].id: balancesList[i]};
    final forecastBalances = {
      for (var i = 0; i < accounts.length; i++) accounts[i].id: forecastBalancesList[i]
    };
    final negativeDates = {
      for (var i = 0; i < accounts.length; i++) accounts[i].id: negativeDatesList[i]
    };
    final recentTx = selectedAccountId == null
        ? const <MoneyTransaction>[]
        : await session.getTransactions(accountId: selectedAccountId, limit: 6);
    return _DashboardData(
      accounts: accounts,
      allAccountsById: allAccountsById,
      selectedAccountId: selectedAccountId,
      currency: currency,
      balances: balances,
      forecastBalances: forecastBalances,
      negativeDates: negativeDates,
      categories: {for (final c in categories) c.id: c},
      recentTx: recentTx,
      payees: {for (final p in payees) p.id: p},
    );
  }

  void _refreshApi(ApiSessionProvider session, DatabaseProvider dbProvider) {
    // bumpDataVersion() prévient aussi tous les autres écrans (même cachés
    // derrière l'IndexedStack) qu'une écriture vient d'avoir lieu quelque
    // part - voir sa doc dans ApiSessionProvider.
    session.bumpDataVersion();
    setState(() => _apiFuture = _loadViaApi(session, dbProvider));
  }

  @override
  Widget build(BuildContext context) {
    final dbProvider = context.watch<DatabaseProvider>();
    final apiSession = context.watch<ApiSessionProvider>();
    final repo = dbProvider.repository!;

    if (apiSession.useApiForDashboard && apiSession.isConnected) {
      final key = (
        selectedAccountId: dbProvider.selectedAccountId,
        forecastDay: dbProvider.forecastDay,
        dataVersion: apiSession.dataVersion,
      );
      if (_apiFuture == null || _apiFutureKey != key) {
        _apiFutureKey = key;
        _apiFuture = _loadViaApi(apiSession, dbProvider);
      }
      return FutureBuilder<_DashboardData>(
        future: _apiFuture,
        builder: (context, snapshot) {
          // Garde les dernières données affichées pendant un
          // rafraîchissement (après une écriture, par ex.) plutôt que de
          // faire disparaître toute la page pour un simple spinner - trouvé
          // désagréable en testant (2026-09-10). Le spinner plein écran ne
          // s'affiche donc que pour le tout premier chargement, jamais un
          // rafraîchissement.
          if (snapshot.hasData) _lastData = snapshot.data;
          if (_lastData == null) {
            if (snapshot.hasError) {
              return Scaffold(body: Center(child: Text('Erreur : ${snapshot.error}')));
            }
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          return RefreshingOverlay(
            refreshing: snapshot.connectionState != ConnectionState.done,
            child: _buildContent(context, dbProvider, repo, _lastData!,
                apiSession: apiSession,
                apiRefresh: () => _refreshApi(apiSession, dbProvider)),
          );
        },
      );
    }

    _apiFuture = null;
    return _buildContent(context, dbProvider, repo, _localData(repo, dbProvider),
        apiSession: apiSession);
  }

  Widget _buildContent(
    BuildContext context,
    DatabaseProvider dbProvider,
    MmexRepository repo,
    _DashboardData data, {
    ApiSessionProvider? apiSession,
    VoidCallback? apiRefresh,
  }) {
    if (data.accounts.isEmpty) {
      final isBrandNew = data.allAccountsById.isEmpty;
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
                        onPressed: () async {
                          await openAccountEditor(context, repo, apiSession: apiSession);
                          apiRefresh?.call();
                        },
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

    final forecastDate = nextForecastDay(DateTime.now(), dbProvider.forecastDay);
    final forecastDateLabel =
        'Prév. au ${DateFormat('d MMM', 'fr_FR').format(forecastDate)}';
    return _buildScaffold(
      context,
      dbProvider,
      repo,
      data.accounts,
      data.allAccountsById,
      data.selectedAccountId!,
      forecastDateLabel,
      data,
      apiSession: apiSession,
      apiRefresh: apiRefresh,
    );
  }

  Widget _buildScaffold(
    BuildContext context,
    DatabaseProvider dbProvider,
    MmexRepository repo,
    List<Account> accounts,
    Map<int, Account> allAccountsById,
    int selectedAccountId,
    String forecastDateLabel,
    _DashboardData data, {
    ApiSessionProvider? apiSession,
    VoidCallback? apiRefresh,
  }) {
    final currency = data.currency;
    final balances = data.balances;
    final forecastBalances = data.forecastBalances;
    final negativeDates = data.negativeDates;
    final categories = data.categories;
    final recentTx = data.recentTx;
    final payees = data.payees;
    final scopedBalance = balances[selectedAccountId] ?? 0;

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        tooltip: 'Nouvelle transaction',
        // Android gets an extra "Par la voix" choice first (same mechanic as
        // TransactionsScreen's own FAB) - everywhere else this stays exactly
        // the single direct tap it always was, since there'd be nothing else
        // to choose from there.
        onPressed: () async {
          if (_isAndroidPlatform) {
            await _showAddChoice(context, selectedAccountId, apiSession: apiSession);
          } else {
            await openTransactionEditor(context,
                defaultAccountId: selectedAccountId, apiSession: apiSession);
          }
          apiRefresh?.call();
        },
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
                        negativeDate: negativeDates[selectedAccountId],
                      ),
                    ),
                    const SizedBox(height: AppTheme.gridGap),
                    _DashboardChartSection(
                      repository: repo,
                      scopedBalance: scopedBalance,
                      forecastDay: dbProvider.forecastDay,
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
                                            negativeDate:
                                                negativeDates[account.id],
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
                                      negativeDate: negativeDates[account.id],
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
                                onToggleReconciled: (value) async {
                                  if (apiSession != null &&
                                      apiSession.useApiForTransactions &&
                                      apiSession.isConnected) {
                                    await apiSession.setReconciled(tx.id, value);
                                    apiRefresh?.call();
                                  } else {
                                    repo.setReconciled(tx.id, value);
                                    dbProvider.touch();
                                  }
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
Future<void> _showAddChoice(BuildContext context, int? accountId,
    {ApiSessionProvider? apiSession}) async {
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
    await startVoiceEntry(context, accountId, apiSession: apiSession);
  } else {
    await openTransactionEditor(context, defaultAccountId: accountId, apiSession: apiSession);
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
  final int forecastDay;

  const _DashboardChartSection({
    required this.repository,
    required this.scopedBalance,
    required this.currency,
    required this.selectedAccountId,
    required this.forecastDay,
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
                    forecastDay: widget.forecastDay,
                  )
                : ForecastChart(
                    repository: widget.repository,
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

  /// See [AccountBalanceCard.negativeDate].
  final DateTime? negativeDate;

  const _TotalBalanceCard({
    required this.total,
    required this.label,
    this.currency,
    this.forecastBalance,
    this.forecastLabel,
    this.negativeDate,
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
          if (negativeDate != null) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.warning_amber_rounded,
                    size: 14, color: Colors.white),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    'Risque de solde négatif dès le '
                    '${DateFormat('d MMM', 'fr_FR').format(negativeDate!)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
