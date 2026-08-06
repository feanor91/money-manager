import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/mmex_repository.dart';
import '../models/budget.dart';
import '../models/budget_period.dart';
import '../models/category.dart';
import '../models/currency.dart';
import '../models/transaction.dart';
import '../state/database_provider.dart';
import '../state/purchase_simulation_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/category_spend_analyzer.dart';
import '../widgets/envelope_gauge.dart';
import '../widgets/hover_tooltip.dart';
import '../widgets/responsive_body.dart';
import '../widgets/searchable_select_field.dart';

/// Adds [months] calendar months to [date], clamping to the destination
/// month's real last day - same small helper every screen that needs it
/// keeps its own private copy of (see forecast_chart.dart/dashboard_screen.dart).
DateTime _addMonths(DateTime date, int months) {
  final total = date.year * 12 + (date.month - 1) + months;
  final year = total ~/ 12;
  final month = total % 12 + 1;
  final lastDay = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, date.day > lastDay ? lastDay : date.day);
}

/// One underlying budget envelope row feeding into a [_EnvelopeItem] group
/// - either the top-level category's own envelope, or one of its
/// subcategories'. [spentOwn] is that category's own direct spend only
/// (not rolled up to children - the group-level rollup happens once, at
/// [_EnvelopeItem.spentActual], across every child whether or not it has
/// its own envelope).
class _MemberEnvelope {
  final int entryId;
  final Category category;
  final double target;
  final double spentOwn;
  final double spentSimulated;
  final double forecastExtra;
  final bool isAuto;

  /// This envelope's own custom label, if the user set one - see
  /// [BudgetEnvelope.name]. Prefer [displayName] for anything shown to the
  /// user; this raw field is for pre-filling the rename field itself.
  final String? name;

  const _MemberEnvelope({
    required this.entryId,
    required this.category,
    required this.target,
    required this.spentOwn,
    required this.spentSimulated,
    required this.forecastExtra,
    required this.isAuto,
    this.name,
  });

  String get displayName => name?.isNotEmpty == true ? name! : category.name;
}

/// One bar on the budget screen, always a top-level category - envelopes
/// on its subcategories are folded into it rather than shown as their own
/// separate bars (see [_MemberEnvelope]), so the chart stays scannable
/// even with many subcategories budgeted individually. [spentActual] is
/// real recorded spending rolled up across the whole group (the top
/// category plus every one of its children, whether or not that child has
/// its own envelope). [forecastExtra] is the summed remaining gap for
/// every "auto" member in the still-ongoing window - shown as a lighter,
/// distinct fill so a recurring bill not yet paid this month doesn't read
/// as "nothing planned" (see [_CategoryBarRow]).
class _EnvelopeItem {
  final Category topCategory;
  final List<_MemberEnvelope> members;
  final double spentActual;

  const _EnvelopeItem({
    required this.topCategory,
    required this.members,
    required this.spentActual,
  });

  double get target => members.fold(0.0, (s, m) => s + m.target);
  double get spentSimulated => members.fold(0.0, (s, m) => s + m.spentSimulated);
  double get forecastExtra => members.fold(0.0, (s, m) => s + m.forecastExtra);
  bool get isAuto => members.any((m) => m.isAuto);
  double get spentTotal => spentActual + spentSimulated;

  /// The group's own custom name, if the top category has its own envelope
  /// and it was renamed - falls back to the top category's name (also the
  /// case when only subcategories are budgeted, not the top category itself).
  String get displayName {
    for (final m in members) {
      if (m.category.id == topCategory.id) return m.displayName;
    }
    return topCategory.name;
  }
}

class BudgetScreen extends StatefulWidget {
  const BudgetScreen({super.key});

  @override
  State<BudgetScreen> createState() => _BudgetScreenState();
}

class _BudgetScreenState extends State<BudgetScreen> {
  DateTime _cursor = DateTime.now();
  int? _selectedCategoryId;

  /// Toggles the whole screen between the real, persistent envelope
  /// budget (the default) and the "what if" scenario simulator - see
  /// _buildSimulationBody. Never affects APP_BUDGET_ENVELOPES either way.
  bool _simulationMode = false;
  int? _selectedScenarioId;

  /// Which top-level categories are currently unfolded to show their own
  /// subcategories as individually-editable rows, in the simulator - a
  /// local view preference only (not saved anywhere), same spirit as
  /// [_selectedCategoryId].
  final Set<int> _expandedScenarioCategoryIds = {};

  /// Opens a category's full detail (breakdown, sub-categories, recent
  /// transactions, and the inline name/amount editor) as a bottom sheet -
  /// a fixed spot near the bottom of the screen every time, unlike an
  /// earlier attempt that inserted it inline right under the tapped bar:
  /// that made the sheet's on-screen position (and how far you'd have to
  /// scroll to reach it) depend on which row was tapped, which is exactly
  /// what was rejected in favour of this.
  Future<void> _openEnvelopeDetail({
    required BuildContext context,
    required MmexRepository repo,
    required BudgetWindow window,
    required List<Category> categories,
    required Map<int, double> rawSpend,
    required Set<int> usedCategoryIds,
    required int accountId,
    required CurrencyFormat? currency,
    required Map<int, Category> categoriesById,
    required Map<int, double> recurringTotals,
    required DatabaseProvider dbProvider,
    required _EnvelopeItem item,
  }) async {
    setState(() => _selectedCategoryId = item.topCategory.id);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(sheetContext).size.height * 0.85),
          child: SingleChildScrollView(
            child: _EnvelopeDetail(
              item: item,
              repo: repo,
              window: window,
              categories: categories,
              rawSpend: rawSpend,
              usedCategoryIds: usedCategoryIds,
              accountId: accountId,
              currency: currency,
              onAddMember: () {
                final coveredIds = item.members.map((m) => m.category.id).toSet();
                final candidates = [
                  item.topCategory,
                  ...categories.where(
                      (c) => c.parentId == item.topCategory.id && usedCategoryIds.contains(c.id)),
                ].where((c) => c.active && !coveredIds.contains(c.id)).toList();
                _addEnvelope(
                  context: sheetContext,
                  repo: repo,
                  accountId: accountId,
                  candidateCategories: candidates,
                  categoriesById: categoriesById,
                  recurringTotals: recurringTotals,
                  onDone: () => dbProvider.touch(),
                );
              },
              onDone: () {
                dbProvider.touch();
                Navigator.of(sheetContext).pop();
              },
            ),
          ),
        ),
      ),
    );
    if (mounted) setState(() => _selectedCategoryId = null);
  }

  @override
  Widget build(BuildContext context) {
    final dbProvider = context.watch<DatabaseProvider>();
    final repo = dbProvider.repository!;
    final sim = context.watch<PurchaseSimulationProvider>();
    final currency = repo.getBaseCurrency();
    final startDay = dbProvider.forecastDay;

    final accounts = repo.getAccounts();
    final accountsById = {for (final a in accounts) a.id: a};
    final visibleAccounts =
        accounts.where((a) => !dbProvider.isAccountHidden(a.id)).toList();
    // Same "always the same account as elsewhere in the app" rule as the
    // Transactions screen - falls back to the first visible account if
    // nothing (valid) is selected yet.
    final accountId = visibleAccounts.any((a) => a.id == dbProvider.selectedAccountId)
        ? dbProvider.selectedAccountId
        : (visibleAccounts.isEmpty ? null : visibleAccounts.first.id);

    final window = budgetWindowContaining(_cursor, startDay);
    final today = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
    // Only let the user browse forward through windows that have already
    // closed - there's nothing real to show yet for one still in progress
    // or in the future.
    final canGoForward = window.end.isBefore(today) || window.end.isAtSameMomentAs(today);
    final isOngoingWindow = !canGoForward;

    final categories = repo.getCategories(onlyActive: false);
    final categoriesById = {for (final c in categories) c.id: c};
    final activeCategories = categories.where((c) => c.active).toList();

    final envelopes = accountId == null ? const <BudgetEnvelope>[] : repo.getBudgetEnvelopes(accountId);
    final recurringTotals = repo.categoryMonthlyRecurringTotals(accountId: accountId);
    final rawSpend = repo.categorySpendForPeriod(window.start, window.end, accountId: accountId);
    // Every category id genuinely relevant to this account (ever used on
    // a real transaction here, or with an active recurring bill) - keeps
    // the "budget a subcategory" picker from listing subcategories that
    // only ever appear on a different account.
    final usedCategoryIds = accountId == null
        ? const <int>{}
        : {...repo.categoriesUsedByAccount(accountId), ...recurringTotals.keys};

    double simulatedExtraFor(int categoryId) {
      if (sim.amount == null || sim.categoryId != categoryId) return 0;
      final perInstallment = sim.amount! / sim.installments;
      var extra = 0.0;
      for (var i = 0; i < sim.installments; i++) {
        if (window.contains(_addMonths(today, i))) extra += perInstallment;
      }
      return extra;
    }

    // Gauges only ever show a top-level category - group every envelope
    // (its own, or one of its subcategories') under that parent, folding
    // subcategory budgets into a single bar instead of one bar each.
    final envelopesByTop = <int, List<BudgetEnvelope>>{};
    for (final e in envelopes) {
      final category = categoriesById[e.categoryId];
      if (category == null) continue; // envelope's category was hard-deleted elsewhere
      final topId = category.parentId ?? category.id;
      envelopesByTop.putIfAbsent(topId, () => []).add(e);
    }

    final items = <_EnvelopeItem>[];
    for (final topEntry in envelopesByTop.entries) {
      final topCategory = categoriesById[topEntry.key];
      if (topCategory == null) continue;

      final members = <_MemberEnvelope>[];
      for (final e in topEntry.value) {
        final category = categoriesById[e.categoryId]!;
        final autoTotal = recurringTotals[e.categoryId] ?? 0;
        final auto = autoTotal > 0;
        final target = auto ? autoTotal : e.amount;
        final spentOwn = rawSpend[e.categoryId] ?? 0;
        final spentSimulated = simulatedExtraFor(e.categoryId);
        // Only for an "auto" envelope, in the window still in progress:
        // the recurring bill(s) haven't necessarily fired yet, but the
        // target already accounts for them - fill that known-but-not-yet-
        // recorded gap with a distinct colour instead of leaving it
        // looking empty.
        final forecastExtra = (auto && isOngoingWindow)
            ? (target - spentOwn - spentSimulated).clamp(0, target).toDouble()
            : 0.0;
        members.add(_MemberEnvelope(
          entryId: e.id,
          category: category,
          target: target,
          spentOwn: spentOwn,
          spentSimulated: spentSimulated,
          forecastExtra: forecastExtra,
          isAuto: auto,
          name: e.name,
        ));
      }
      members.sort((a, b) => b.target.compareTo(a.target));

      items.add(_EnvelopeItem(
        topCategory: topCategory,
        members: members,
        // Real spend rolled up across the *whole* group, not just members
        // that happen to have their own envelope - a subcategory with
        // real spend but no budget of its own still counts against its
        // parent's bar.
        spentActual: rolledUpSpend(topCategory.id, rawSpend, categories),
      ));
    }
    items.sort((a, b) => b.target.compareTo(a.target));

    // Ranked by actual spend (not target) for the bar chart below - "where
    // does my money actually go" is the point of that view, distinct from
    // [items]' own target-based order (used elsewhere, e.g. detail lookup).
    // Every bar's length is plotted on this same shared scale so categories
    // are directly comparable, instead of each bar being self-scaled to its
    // own target as the old vertical gauges were.
    final barItems = [...items]..sort((a, b) => b.spentTotal.compareTo(a.spentTotal));
    final maxScaleRaw = items.fold(
        0.0, (m, i) => [m, i.spentTotal, i.target].reduce((a, b) => a > b ? a : b));
    final maxScale = maxScaleRaw <= 0 ? 1.0 : maxScaleRaw;

    // Real income this window, and the expected/forecast income from
    // still-active recurring deposits (salary, etc.) - always shown as
    // the very first gauge, not tied to any envelope, so the budget
    // screen doesn't read as purely about spending.
    final income = accountId == null ? 0.0 : repo.incomeForPeriod(window.start, window.end, accountId: accountId);
    final expectedIncome = accountId == null ? 0.0 : repo.monthlyRecurringIncome(accountId: accountId);

    // "Reste a vivre" is the real forecasted account balance at the date
    // this budget window resets - not a budget-only calculation (target
    // minus spent). That's what actually answers "how much do I really
    // have", the same number the dashboard's own balance forecast would
    // give for that date (real balance if the window's already closed,
    // real balance + every recurring transaction still due before the
    // reset date otherwise).
    final remaining = accountId == null ? 0.0 : repo.forecastAccountBalance(accountId, window.end);

    void Function()? openAddDialog = accountId == null
        ? null
        : () => _addEnvelope(
              context: context,
              repo: repo,
              accountId: accountId,
              candidateCategories:
                  activeCategories.where((c) => !envelopes.any((e) => e.categoryId == c.id)).toList(),
              categoriesById: categoriesById,
              recurringTotals: recurringTotals,
              onDone: () => dbProvider.touch(),
            );

    void Function()? openSuggestions = accountId == null
        ? null
        : () => _openSuggestions(
              context: context,
              repo: repo,
              accountId: accountId,
              startDay: startDay,
              existingEnvelopes: envelopes,
              categoriesById: categoriesById,
              recurringTotals: recurringTotals,
              currency: currency,
              onDone: () => dbProvider.touch(),
            );

    return Scaffold(
      appBar: AppBar(
        title: Text(accountId == null ? 'Budget' : 'Budget - ${accountsById[accountId]!.name}'),
        actions: [
          IconButton(
            tooltip: _simulationMode ? 'Retour au budget' : 'Simulation de budget',
            icon: Icon(_simulationMode ? Icons.pie_chart_outline : Icons.calculate_outlined),
            onPressed: () => setState(() {
              _simulationMode = !_simulationMode;
              _selectedScenarioId = null;
            }),
          ),
          if (!_simulationMode) ...[
            IconButton(
              tooltip: 'Suggérer des enveloppes automatiquement',
              icon: const Icon(Icons.auto_awesome_outlined),
              onPressed: openSuggestions,
            ),
          ],
          PopupMenuButton<int>(
            icon: const Icon(Icons.filter_list),
            onSelected: (id) => dbProvider.selectAccount(id),
            itemBuilder: (context) => [
              for (final a in visibleAccounts)
                PopupMenuItem(value: a.id, child: Text(a.name)),
            ],
          ),
          if (!_simulationMode) ...[
            PopupMenuButton<String>(
              tooltip: 'Réinitialiser',
              icon: const Icon(Icons.restart_alt),
              onSelected: (action) {
                if (action == 'reset' && accountId != null) {
                  _resetBudget(
                    context: context,
                    repo: repo,
                    accountId: accountId,
                    accountName: accountsById[accountId]!.name,
                    onDone: () {
                      setState(() => _selectedCategoryId = null);
                      dbProvider.touch();
                    },
                  );
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'reset',
                  enabled: accountId != null && envelopes.isNotEmpty,
                  child: Text(
                    'Réinitialiser le budget de ce compte',
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              ],
            ),
          ],
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Paramètres',
            onPressed: () => Navigator.of(context).pushNamed('/settings'),
          ),
        ],
      ),
      floatingActionButton: _simulationMode
          ? null
          : FloatingActionButton.extended(
              onPressed: openAddDialog,
              icon: const Icon(Icons.add),
              label: const Text('Enveloppe'),
            ),
      body: ResponsiveBody(
        maxWidth: 800,
        child: _simulationMode
            ? _buildSimulationBody(
                context: context,
                repo: repo,
                dbProvider: dbProvider,
                accountId: accountId,
                categories: categories,
                categoriesById: categoriesById,
                currency: currency,
              )
            : ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            _PeriodNav(
              window: window,
              canGoForward: canGoForward,
              onPrev: () => setState(() => _cursor = previousBudgetWindow(window, startDay).start),
              onNext: canGoForward
                  ? () => setState(() => _cursor = nextBudgetWindow(window, startDay).start)
                  : null,
            ),
            const SizedBox(height: 12),
            _RemainingCard(remaining: remaining, resetDate: window.end, currency: currency),
            const SizedBox(height: 20),
            if (accountId != null) ...[
              _CategoryBarRow(
                label: 'Revenus',
                spent: income,
                target: expectedIncome,
                moreIsBetter: true,
                currency: currency,
              ),
              for (final item in barItems) ...[
                const SizedBox(height: 18),
                _CategoryBarRow(
                  icon: item.isAuto ? Icons.autorenew : null,
                  label: item.displayName,
                  spent: item.spentTotal,
                  target: item.target,
                  forecastExtra: item.forecastExtra,
                  maxScale: maxScale,
                  currency: currency,
                  selected: item.topCategory.id == _selectedCategoryId,
                  onTap: () => _openEnvelopeDetail(
                    context: context,
                    repo: repo,
                    window: window,
                    categories: categories,
                    rawSpend: rawSpend,
                    usedCategoryIds: usedCategoryIds,
                    accountId: accountId,
                    currency: currency,
                    categoriesById: categoriesById,
                    recurringTotals: recurringTotals,
                    dbProvider: dbProvider,
                    item: item,
                  ),
                ),
              ],
            ],
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: Column(
                    children: [
                      const Text('Aucune enveloppe pour l\'instant.'),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: openSuggestions,
                        icon: const Icon(Icons.auto_awesome_outlined),
                        label: const Text('Générer automatiquement'),
                      ),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: openAddDialog,
                        icon: const Icon(Icons.add),
                        label: const Text('Ou ajouter une enveloppe manuellement'),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// "What if" budget simulator - a named, saveable scenario per account
  /// (APP_BUDGET_SCENARIOS/APP_BUDGET_SCENARIO_AMOUNTS), never touching the
  /// real envelope budget above. Every relevant category (income and
  /// expense alike, unlike the envelope view's expense-only bars) gets its
  /// own bar: the real historical average next to a simulated amount the
  /// user can edit freely - a category with no saved override yet just
  /// tracks the real average as its starting point.
  Widget _buildSimulationBody({
    required BuildContext context,
    required MmexRepository repo,
    required DatabaseProvider dbProvider,
    required int? accountId,
    required List<Category> categories,
    required Map<int, Category> categoriesById,
    required CurrencyFormat? currency,
  }) {
    if (accountId == null) {
      return const Center(child: Text('Choisissez un compte.'));
    }

    final scenarios = repo.getBudgetScenarios(accountId);
    if (_selectedScenarioId == null || !scenarios.any((s) => s.id == _selectedScenarioId)) {
      _selectedScenarioId = scenarios.isEmpty ? null : scenarios.first.id;
    }
    BudgetScenario? scenario;
    for (final s in scenarios) {
      if (s.id == _selectedScenarioId) scenario = s;
    }

    Future<void> create() async {
      final controller = TextEditingController();
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Nouveau scénario'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Nom du scénario'),
            onSubmitted: (_) => Navigator.of(context).pop(true),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Créer')),
          ],
        ),
      );
      final name = controller.text.trim();
      if (confirmed != true || name.isEmpty || !context.mounted) return;
      final id = repo.createBudgetScenario(accountId: accountId, name: name);
      dbProvider.touch();
      setState(() => _selectedScenarioId = id);
    }

    Future<void> rename(BudgetScenario current) async {
      final controller = TextEditingController(text: current.name);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Renommer le scénario'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Nom du scénario'),
            onSubmitted: (_) => Navigator.of(context).pop(true),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Renommer')),
          ],
        ),
      );
      final name = controller.text.trim();
      if (confirmed != true || name.isEmpty || !context.mounted) return;
      repo.renameBudgetScenario(current.id, name);
      dbProvider.touch();
      setState(() {});
    }

    Future<void> remove(BudgetScenario current) async {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Supprimer ce scénario'),
          content: Text('Supprimer "${current.name}" et tous ses montants simulés ? '
              'Le vrai budget de ce compte n\'est pas concerné.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Annuler')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Supprimer'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      repo.deleteBudgetScenario(current.id);
      dbProvider.touch();
      setState(() => _selectedScenarioId = null);
    }

    final pickerRow = Row(
      children: [
        Expanded(
          child: scenarios.isEmpty
              ? const Text('Aucun scénario pour l\'instant.')
              : DropdownButton<int>(
                  isExpanded: true,
                  value: scenario?.id,
                  items: [
                    for (final s in scenarios) DropdownMenuItem(value: s.id, child: Text(s.name)),
                  ],
                  onChanged: (id) => setState(() => _selectedScenarioId = id),
                ),
        ),
        IconButton(icon: const Icon(Icons.add), tooltip: 'Nouveau scénario', onPressed: create),
        if (scenario != null) ...[
          IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Renommer',
              onPressed: () => rename(scenario!)),
          IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Supprimer',
              onPressed: () => remove(scenario!)),
        ],
      ],
    );

    if (scenario == null) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          pickerRow,
          const SizedBox(height: 32),
          const Center(child: Text('Créez un scénario pour commencer une simulation.')),
        ],
      );
    }
    final activeScenario = scenario;

    void setPeriod(int months) {
      repo.setBudgetScenarioPeriodMonths(activeScenario.id, months);
      dbProvider.touch();
      setState(() {});
    }

    // Closed months only, never the one still in progress - it's
    // incomplete (e.g. rent due the 25th looks "free" if you're simulating
    // on the 5th), which would understate or misleadingly zero out a
    // category that's actually perfectly normal. Deliberately plain
    // calendar months (not the forecast-day-anchored BudgetWindow the
    // envelope suggestions use below) - the simulator already worked in
    // calendar months before this change, this only resolves *which*
    // month counts as "still in progress".
    final now = DateTime.now();
    final closedMonthsEnd = DateTime(now.year, now.month, 1);
    final start = _addMonths(closedMonthsEnd, -activeScenario.periodMonths);
    final rawNet = repo.categoryNetTotalsForPeriod(start, closedMonthsEnd, accountId: accountId);
    final savedAmounts = repo.getBudgetScenarioAmounts(activeScenario.id);

    // A recurring bill/deposit is a near-certain monthly figure - it takes
    // priority over the historical average for a category that has one,
    // same rule already used for envelope suggestions (see _openSuggestions
    // below): not additive, the recurring figure simply replaces the
    // average when both exist.
    final recurringExpense = repo.categoryMonthlyRecurringTotals(accountId: accountId);
    final recurringIncome = repo.categoryMonthlyRecurringIncomeTotals(accountId: accountId);

    final usedCategoryIds = repo.categoriesUsedByAccount(accountId);
    // Per-scenario add/remove override on top of the automatic "has real
    // history on this account" default - see APP_BUDGET_SCENARIO_CATEGORIES
    // and the "Ajouter une catégorie"/per-row remove button below.
    final categoryVisibility = repo.getBudgetScenarioCategoryOverrides(activeScenario.id);
    // Budget-only categories with no real CATEGORY_V1 row at all - see
    // APP_BUDGET_SCENARIO_VIRTUAL_CATEGORIES. Synthesized as ordinary
    // Category objects (negative id, no parent) so they flow through
    // exactly the same rows/rollup/tooltip machinery as a real one - a
    // tooltip naturally comes up empty for one since no real transaction
    // can ever carry a negative CATEGID.
    // Every virtual category (top-level or an artificial subdivision of a
    // real one - see VirtualBudgetCategory) folds into the same byParent
    // map as the real categories, keyed the same way (null = top-level,
    // otherwise its real or virtual parent's id) - from here on nothing
    // downstream needs to know or care which categories are real.
    final virtualCategories = repo.getVirtualBudgetCategories(activeScenario.id);
    final byParent = <int?, List<Category>>{};
    for (final c in categories) {
      byParent.putIfAbsent(c.parentId, () => []).add(c);
    }
    for (final v in virtualCategories) {
      byParent
          .putIfAbsent(v.parentCategId, () => [])
          .add(Category(id: v.id, name: v.name, active: true, parentId: v.parentCategId));
    }
    bool usedHere(Category c) {
      final children = byParent[c.id] ?? const <Category>[];
      return usedCategoryIds.contains(c.id) || children.any((child) => usedCategoryIds.contains(child.id));
    }
    bool isVirtualCategory(Category c) => c.id < 0;
    // A virtual category has no organic "used" signal (never a real
    // transaction) - it only ever shows once explicitly added, unlike a
    // real one which defaults to visible as soon as it has history.
    bool defaultVisible(Category c) => isVirtualCategory(c) ? false : usedHere(c);

    final allTopCategories = byParent[null] ?? const <Category>[];
    final topCategories =
        allTopCategories.where((c) => categoryVisibility[c.id] ?? defaultVisible(c)).toList();
    final hiddenTopCategories =
        allTopCategories.where((c) => !(categoryVisibility[c.id] ?? defaultVisible(c))).toList()
          ..sort((a, b) => a.name.compareTo(b.name));

    final relevantIds = <int>{};
    for (final top in topCategories) {
      relevantIds.add(top.id);
      for (final c in byParent[top.id] ?? const <Category>[]) {
        relevantIds.add(c.id);
      }
    }
    // Pure historical average - the "Réel" column always reflects actual
    // transactions only, whatever the suggested/simulated side is doing.
    final realMap = {
      for (final id in relevantIds) id: (rawNet[id] ?? 0) / activeScenario.periodMonths,
    };
    // Recurring-priority-else-average - only used as the fallback for a
    // category with no saved amount yet (see simulatedMap below), never
    // shown directly.
    final suggestedMap = {
      for (final id in relevantIds)
        id: recurringExpense.containsKey(id)
            ? -recurringExpense[id]!
            : (recurringIncome[id] ?? realMap[id]!),
    };
    // Fixed: every visible category is guaranteed a saved row by
    // fixBudgetScenario, so the ?? 0 fallback is mostly theoretical (only
    // reachable mid-edit for a category added after fixing, which is
    // always prompted for a manual amount immediately - see addCategory).
    // Draft: an unset category keeps tracking the live suggestion.
    final simulatedMap = {
      for (final id in relevantIds)
        id: activeScenario.isFixed ? (savedAmounts[id] ?? 0) : (savedAmounts[id] ?? suggestedMap[id]!),
    };

    final rows = [
      for (final top in topCategories)
        _ScenarioRow(
          topCategory: top,
          real: rolledUpSpend(top.id, realMap, categories),
          simulated: rolledUpSpend(top.id, simulatedMap, categories),
        ),
    ];
    bool isIncomeRow(_ScenarioRow r) => r.real != 0 ? r.real > 0 : r.simulated >= 0;
    final incomeRows = rows.where(isIncomeRow).toList()
      ..sort((a, b) => b.simulated.compareTo(a.simulated));
    final expenseRows = rows.where((r) => !isIncomeRow(r)).toList()
      ..sort((a, b) => a.simulated.compareTo(b.simulated));
    final incomeMaxScale =
        incomeRows.fold(0.0, (m, r) => [m, r.real, r.simulated].reduce((a, b) => a > b ? a : b));
    final expenseMaxScale = expenseRows.fold(
        0.0, (m, r) => [m, -r.real, -r.simulated].reduce((a, b) => a > b ? a : b));

    final totalSimulatedIncome = incomeRows.fold(0.0, (s, r) => s + r.simulated);
    final totalSimulatedExpense = expenseRows.fold(0.0, (s, r) => s - r.simulated);
    final totalRealIncome = incomeRows.fold(0.0, (s, r) => s + r.real);
    final totalRealExpense = expenseRows.fold(0.0, (s, r) => s - r.real);
    String fmt(double v) => currency?.format(v) ?? v.toStringAsFixed(0);

    // Same hover-tooltip principle as the envelope view's own detail sheet
    // and budget_preview_card.dart: list the real transactions (not the
    // simulated figure, which is just a typed-in number) that make up a
    // bar's real average, grouped the same way the average itself is
    // rolled up (top category plus its direct children).
    final payees = {for (final p in repo.getPayees(onlyActive: false)) p.id: p};
    final periodTransactions = repo
        .getTransactions(
          accountId: accountId,
          from: start,
          to: closedMonthsEnd.subtract(const Duration(days: 1)),
          limit: 3000,
        )
        .where((t) => t.categoryId != null && !t.isVoid)
        .toList();
    final transactionsByCategory = <int, List<MoneyTransaction>>{};
    for (final t in periodTransactions) {
      transactionsByCategory.putIfAbsent(t.categoryId!, () => []).add(t);
    }
    final dateFormat = DateFormat('d MMM', 'fr_FR');
    String? tooltipFor(Category top) {
      final relevantCategoryIds = {
        top.id,
        for (final c in byParent[top.id] ?? const <Category>[]) c.id,
      };
      final txns = [
        for (final id in relevantCategoryIds) ...?transactionsByCategory[id],
      ]..sort((a, b) => b.date.compareTo(a.date));
      if (txns.isEmpty) return null;
      return txns.map((t) {
        final line = '${dateFormat.format(t.date)} - '
            '${payees[t.payeeId]?.name ?? 'Tiers inconnu'} : ${fmt(t.signedAmountFor(accountId))}';
        return (t.notes?.isNotEmpty ?? false) ? '$line — ${t.notes}' : line;
      }).join('\n');
    }

    // 12/6/3/1-month real averages for [top], each ending at the same
    // closed-months boundary as everything else here - shown as reference
    // context whenever the user is asked to type a monthly amount (never
    // for a virtual category: it has no real transaction to average).
    Map<int, double> referenceAverages(Category top) {
      return {
        for (final months in [12, 6, 3, 1])
          months: rolledUpSpend(
                top.id,
                repo.categoryNetTotalsForPeriod(
                  _addMonths(closedMonthsEnd, -months),
                  closedMonthsEnd,
                  accountId: accountId,
                ),
                categories,
              ) /
              months,
      };
    }

    // Shared by editAmount and addCategory - always asks for a positive
    // magnitude (the row/category's own income-or-expense classification
    // decides the sign, see isIncomeRow), with the 4 reference averages
    // shown alongside for a real category. Returns null on cancel.
    Future<double?> promptAmount({
      required String title,
      required double prefill,
      Map<int, double>? refs,
    }) async {
      final controller = TextEditingController(text: prefill.abs().toStringAsFixed(2));
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (refs != null) ...[
                Text(
                  'Moyennes réelles - 12 mois : ${fmt(refs[12]!.abs())}  ·  '
                  '6 mois : ${fmt(refs[6]!.abs())}  ·  3 mois : ${fmt(refs[3]!.abs())}  ·  '
                  'dernier mois : ${fmt(refs[1]!.abs())}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Montant mensuel simulé'),
                onSubmitted: (_) => Navigator.of(context).pop(true),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Enregistrer')),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return null;
      return double.tryParse(controller.text.replaceAll(',', '.')) ?? 0;
    }

    Future<void> editAmount(_ScenarioRow row) async {
      final isVirtual = row.topCategory.id < 0;
      final magnitude = await promptAmount(
        title: row.topCategory.name,
        prefill: row.simulated,
        refs: isVirtual ? null : referenceAverages(row.topCategory),
      );
      if (magnitude == null) return;
      final signed = isIncomeRow(row) ? magnitude : -magnitude;
      repo.upsertBudgetScenarioAmount(
          scenarioId: activeScenario.id, categoryId: row.topCategory.id, amount: signed);
      dbProvider.touch();
      setState(() {});
    }

    // Hides a row for this scenario only - its saved simulated amount (if
    // any) stays in APP_BUDGET_SCENARIO_AMOUNTS untouched, so re-adding the
    // category later brings back its old value intact. No confirmation:
    // this is just a view toggle, not a delete.
    void removeCategory(Category top) {
      repo.setBudgetScenarioCategoryVisible(activeScenario.id, top.id, false);
      dbProvider.touch();
      setState(() {});
    }

    // Picks among top-level categories not currently shown (never used on
    // this account, previously removed, or brand new - "onCreate" makes a
    // virtual budget-only category on the fly), then always requires a
    // typed monthly amount before the category actually appears - no more
    // silent default. Cancelling either step adds nothing at all.
    Future<void> addCategory() async {
      Category? picked;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Ajouter une catégorie'),
          content: SizedBox(
            width: 360,
            child: SearchableSelectField<Category>(
              label: 'Catégorie',
              options: hiddenTopCategories,
              labelOf: (c) => c.name,
              onSelected: (c) {
                picked = c;
                Navigator.of(context).pop();
              },
              onCreate: (text) async {
                final id = repo.createVirtualBudgetCategory(activeScenario.id, text);
                dbProvider.touch();
                return Category(id: id, name: text, active: true, parentId: null);
              },
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
          ],
        ),
      );
      if (picked == null || !context.mounted) return;
      final category = picked!;
      final isVirtual = category.id < 0;
      final refs = isVirtual ? null : referenceAverages(category);
      // A category with some non-zero real history uses its sign (income
      // vs expense) as a sensible default; virtual or genuinely never-used
      // real categories have nothing to infer from, so default to expense -
      // a newly imagined budget line is far more often a cost than income.
      final defaultsToIncome = refs != null && refs[12]! > 0;
      final magnitude = await promptAmount(
        title: category.name,
        prefill: refs?[12] ?? 0,
        refs: refs,
      );
      if (magnitude == null || !context.mounted) return;
      repo.setBudgetScenarioCategoryVisible(activeScenario.id, category.id, true);
      repo.upsertBudgetScenarioAmount(
        scenarioId: activeScenario.id,
        categoryId: category.id,
        amount: defaultsToIncome ? magnitude : -magnitude,
      );
      dbProvider.touch();
      setState(() {});
    }

    // "Fixer" snapshots every currently-visible category's simulated value
    // (whichever ones are still on auto-pilot get a MANUAL=0 row; already-
    // manual ones are untouched) and stamps FIXED_AT - see
    // MmexRepository.fixBudgetScenario. Confirmed explicitly since it
    // changes how every row behaves from here on, not just one value.
    Future<void> fixScenario() async {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Fixer ce budget'),
          content: const Text(
            'Les montants simulés affichés seront gravés tels quels : ils ne suivront plus '
            'automatiquement vos moyennes réelles ou récurrentes, seule une modification '
            'manuelle les changera ensuite. La colonne "Réel" continue elle de suivre vos '
            'vraies transactions, pour comparer prévu et réel. Vous pourrez revenir en '
            'arrière à tout moment avec "Défixer".',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Fixer')),
          ],
        ),
      );
      if (confirmed != true) return;
      repo.fixBudgetScenario(activeScenario.id, {for (final row in rows) row.topCategory.id: row.simulated});
      dbProvider.touch();
      setState(() {});
    }

    void unfixScenario() {
      repo.unfixBudgetScenario(activeScenario.id);
      dbProvider.touch();
      setState(() {});
    }

    // A subcategory's own edit dialog - separate from editAmount rather
    // than reusing it via a synthetic _ScenarioRow, because isIncomeRow's
    // sign inference (real/simulated's own sign) is unreliable for a
    // subcategory that happens to be exactly 0 (never used yet): it must
    // follow its parent's income/expense classification instead, passed in
    // explicitly as [parentIsIncome] - same one used for the parent's own
    // section/colour (moreIsBetter in buildScenarioRow below).
    Future<void> editChildAmount(Category child, {required bool parentIsIncome}) async {
      final isVirtual = child.id < 0;
      final childSimulated = rolledUpSpend(child.id, simulatedMap, categories);
      final magnitude = await promptAmount(
        title: child.name,
        prefill: childSimulated,
        refs: isVirtual ? null : referenceAverages(child),
      );
      if (magnitude == null) return;
      repo.upsertBudgetScenarioAmount(
        scenarioId: activeScenario.id,
        categoryId: child.id,
        amount: parentIsIncome ? magnitude : -magnitude,
      );
      dbProvider.touch();
      setState(() {});
    }

    // One category row, plus - if it has real subcategories and is
    // currently unfolded - one extra row per subcategory right underneath,
    // indented, each individually tappable to edit its own amount (same
    // dialog/reference-averages as a top-level category). Shares maxScale
    // and moreIsBetter with its parent, so a subcategory always reads as
    // the same kind (income/expense) and stays on the same visual scale as
    // the row it belongs to, rather than introducing a second scale to
    // learn.
    // "Subdivide" a category with no subcategory of its own to split up
    // (e.g. one MMEX category lumping together two people's salaries,
    // distinguishable only by payee in the tooltip, never by category) -
    // name first, then the usual amount prompt (no reference averages: a
    // brand new virtual line has no real history of its own to show).
    Future<void> addVirtualSubcategory(Category parent, {required bool parentIsIncome}) async {
      final controller = TextEditingController();
      final confirmedName = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Nouvelle sous-catégorie'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Nom'),
            onSubmitted: (_) => Navigator.of(context).pop(true),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Suivant')),
          ],
        ),
      );
      final name = controller.text.trim();
      if (confirmedName != true || name.isEmpty || !context.mounted) return;
      final magnitude = await promptAmount(title: name, prefill: 0, refs: null);
      if (magnitude == null || !context.mounted) return;
      final id = repo.createVirtualBudgetCategory(activeScenario.id, name, parentCategId: parent.id);
      repo.upsertBudgetScenarioAmount(
        scenarioId: activeScenario.id,
        categoryId: id,
        amount: parentIsIncome ? magnitude : -magnitude,
      );
      dbProvider.touch();
      setState(() => _expandedScenarioCategoryIds.add(parent.id));
    }

    Widget buildScenarioRow(_ScenarioRow row, {required double maxScale, required bool moreIsBetter}) {
      final children = (byParent[row.topCategory.id] ?? const <Category>[])
          .where((c) => categoryVisibility[c.id] ?? true)
          .toList();
      final expanded = _expandedScenarioCategoryIds.contains(row.topCategory.id);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                icon: Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 20),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                tooltip: expanded ? 'Replier les sous-catégories' : 'Déplier les sous-catégories',
                onPressed: () => setState(() {
                  if (expanded) {
                    _expandedScenarioCategoryIds.remove(row.topCategory.id);
                  } else {
                    _expandedScenarioCategoryIds.add(row.topCategory.id);
                  }
                }),
              ),
              Expanded(
                child: _tooltipped(
                  tooltipFor(row.topCategory),
                  _CategoryBarRow(
                    label: row.topCategory.name,
                    spent: row.real.abs(),
                    target: row.simulated.abs(),
                    maxScale: maxScale,
                    moreIsBetter: moreIsBetter,
                    currency: currency,
                    onTap: () => editAmount(row),
                    onRemove: () => removeCategory(row.topCategory),
                  ),
                ),
              ),
            ],
          ),
          if (expanded) ...[
            for (final child in children)
              Padding(
                padding: const EdgeInsets.only(left: 40, top: 6),
                child: _tooltipped(
                  tooltipFor(child),
                  _CategoryBarRow(
                    label: child.name,
                    spent: rolledUpSpend(child.id, realMap, categories).abs(),
                    target: rolledUpSpend(child.id, simulatedMap, categories).abs(),
                    maxScale: maxScale,
                    moreIsBetter: moreIsBetter,
                    currency: currency,
                    onTap: () => editChildAmount(child, parentIsIncome: moreIsBetter),
                    onRemove: () => removeCategory(child),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 4),
              child: TextButton.icon(
                onPressed: () => addVirtualSubcategory(row.topCategory, parentIsIncome: moreIsBetter),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Ajouter une sous-catégorie'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          ],
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        pickerRow,
        const SizedBox(height: 8),
        if (activeScenario.isFixed)
          Row(
            children: [
              Icon(Icons.lock_outline, size: 16, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Fixé le ${DateFormat('d MMM y', 'fr_FR').format(activeScenario.fixedAt!)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              TextButton(onPressed: unfixScenario, child: const Text('Défixer')),
            ],
          )
        else
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonalIcon(
              onPressed: fixScenario,
              icon: const Icon(Icons.lock_outline, size: 18),
              label: const Text('Fixer le budget'),
            ),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            // Once fixed, this no longer feeds the simulated amounts (those
            // are frozen) - it now only controls the "Réel" comparison
            // column/total below, which stays live either way.
            Text(activeScenario.isFixed ? 'Comparer sur : ' : 'Moyenne sur : '),
            const SizedBox(width: 8),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('1 mois')),
                ButtonSegment(value: 3, label: Text('3 mois')),
                ButtonSegment(value: 6, label: Text('6 mois')),
                ButtonSegment(value: 12, label: Text('12 mois')),
              ],
              selected: {activeScenario.periodMonths},
              onSelectionChanged: (s) => setPeriod(s.first),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            // Always enabled, even with nothing hidden to re-add - the
            // dialog's "create" option (SearchableSelectField.onCreate)
            // still lets you start a brand new virtual category from here.
            onPressed: addCategory,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Ajouter une catégorie'),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Revenus simulés'),
                    Text(fmt(totalSimulatedIncome), style: const TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Dépenses simulées'),
                    Text(fmt(totalSimulatedExpense), style: const TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
                const Divider(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Reste simulé', style: TextStyle(fontWeight: FontWeight.w800)),
                    Builder(builder: (context) {
                      final reste = totalSimulatedIncome - totalSimulatedExpense;
                      return Text(
                        fmt(reste),
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                          color: reste < 0 ? AppTheme.negative : AppTheme.positive,
                        ),
                      );
                    }),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Réel sur la période : ${fmt(totalRealIncome)} - ${fmt(totalRealExpense)} '
                  '= ${fmt(totalRealIncome - totalRealExpense)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        if (incomeRows.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text('Revenus', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final row in incomeRows) ...[
            buildScenarioRow(row, maxScale: incomeMaxScale, moreIsBetter: true),
            const SizedBox(height: 10),
          ],
        ],
        if (expenseRows.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('Dépenses', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final row in expenseRows) ...[
            buildScenarioRow(row, maxScale: expenseMaxScale, moreIsBetter: false),
            const SizedBox(height: 10),
          ],
        ],
        if (rows.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: Text('Aucune catégorie avec un historique sur ce compte.')),
          ),
      ],
    );
  }
}

/// Wraps [child] in a [HoverTooltip] when there's actually a [message] to
/// show - same "null means nothing to hover" convention as
/// budget_preview_card.dart's own tooltipFor.
Widget _tooltipped(String? message, Widget child) =>
    message == null ? child : HoverTooltip(message: message, child: child);

/// One top-level category's real historical average next to its simulated
/// (saved or defaulted) amount, both signed (positive income, negative
/// expense) and rolled up across its subcategories - see
/// _BudgetScreenState._buildSimulationBody.
class _ScenarioRow {
  final Category topCategory;
  final double real;
  final double simulated;

  const _ScenarioRow({required this.topCategory, required this.real, required this.simulated});
}

Future<void> _resetBudget({
  required BuildContext context,
  required MmexRepository repo,
  required int accountId,
  required String accountName,
  required VoidCallback onDone,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Réinitialiser le budget'),
      content: Text(
        'Supprimer toutes les enveloppes de budget de "$accountName" ? '
        'Les opérations et échéances elles-mêmes ne sont pas touchées, '
        'seul le budget de ce compte est effacé.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Annuler')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Tout supprimer'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  repo.resetBudgetEnvelopes(accountId);
  onDone();
}

Future<void> _addEnvelope({
  required BuildContext context,
  required MmexRepository repo,
  required int accountId,
  required List<Category> candidateCategories,
  required Map<int, Category> categoriesById,
  required Map<int, double> recurringTotals,
  required VoidCallback onDone,
}) async {
  Category? category;
  final amountController = TextEditingController();

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) {
        final autoTotal = category == null ? null : recurringTotals[category!.id];
        return AlertDialog(
          title: const Text('Nouvelle enveloppe'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SearchableSelectField<Category>(
                  label: 'Catégorie',
                  options: candidateCategories,
                  labelOf: (c) => categoryFullPath(c.id, categoriesById),
                  onSelected: (c) => setDialogState(() {
                    category = c;
                    if (c != null && (recurringTotals[c.id] ?? 0) > 0) {
                      amountController.text = recurringTotals[c.id]!.toStringAsFixed(2);
                    }
                  }),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amountController,
                  decoration: const InputDecoration(labelText: 'Montant mensuel'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                ),
                if (autoTotal != null && autoTotal > 0) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Cette catégorie a déjà des opérations récurrentes actives : '
                    'le montant sera calculé automatiquement (${autoTotal.toStringAsFixed(2)}/mois) '
                    'tant qu\'elles existent - la valeur ci-dessus ne sert que de repli si elles '
                    'sont un jour supprimées.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Annuler')),
            FilledButton(
              onPressed: category == null ? null : () => Navigator.of(context).pop(true),
              child: const Text('Ajouter'),
            ),
          ],
        );
      },
    ),
  );

  if (confirmed != true || category == null || !context.mounted) return;
  repo.upsertBudgetEnvelope(
    accountId: accountId,
    categoryId: category!.id,
    amount: double.tryParse(amountController.text.replaceAll(',', '.')) ?? 0,
  );
  onDone();
}

class _Suggestion {
  final Category category;
  double amount;
  final bool fromRecurring;
  final bool stale;
  bool selected = true;

  _Suggestion({
    required this.category,
    required this.amount,
    required this.fromRecurring,
    this.stale = false,
  });
}

const _suggestionHistoryMonths = 12;

/// Builds envelope suggestions for [accountId] from data that's already
/// in the file - a recurring bill is a near-certain monthly cost, and
/// categories with a real spending history (even without a recurring
/// bill) are a reasonable starting target - then lets the user pick which
/// ones to actually create instead of typing every envelope in by hand.
Future<void> _openSuggestions({
  required BuildContext context,
  required MmexRepository repo,
  required int accountId,
  required int startDay,
  required List<BudgetEnvelope> existingEnvelopes,
  required Map<int, Category> categoriesById,
  required Map<int, double> recurringTotals,
  required CurrencyFormat? currency,
  required VoidCallback onDone,
}) async {
  final existingCategoryIds = existingEnvelopes.map((e) => e.categoryId).toSet();
  final suggestions = <_Suggestion>[];

  for (final entry in recurringTotals.entries) {
    if (entry.value <= 0 || existingCategoryIds.contains(entry.key)) continue;
    final category = categoriesById[entry.key];
    if (category == null || !category.active) continue;
    suggestions.add(_Suggestion(category: category, amount: entry.value, fromRecurring: true));
  }

  // Average real spend over the last few *closed* budget windows (not the
  // one still in progress, which is incomplete) - for categories with no
  // recurring bill of their own, this is the only other signal already
  // sitting in the file worth suggesting from.
  var window = previousBudgetWindow(budgetWindowContaining(DateTime.now(), startDay), startDay);
  final historyTotals = <int, double>{};
  DateTime? earliestStart;
  for (var i = 0; i < _suggestionHistoryMonths; i++) {
    final spend = repo.categorySpendForPeriod(window.start, window.end, accountId: accountId);
    spend.forEach((categoryId, amount) {
      historyTotals[categoryId] = (historyTotals[categoryId] ?? 0) + amount;
    });
    earliestStart = window.start;
    window = previousBudgetWindow(window, startDay);
  }
  // Flags a history-based suggestion whose category hasn't actually had a
  // transaction in the last ~3 months - the 1-year average can still be
  // non-zero from something that happened 8 months ago and never again,
  // which isn't a great basis for an ongoing monthly budget.
  final lastSpendDates = earliestStart == null
      ? <int, DateTime>{}
      : repo.lastSpendDatePerCategory(earliestStart, DateTime.now(), accountId: accountId);
  final staleThreshold = DateTime.now().subtract(const Duration(days: 90));
  for (final entry in historyTotals.entries) {
    if (existingCategoryIds.contains(entry.key)) continue;
    if ((recurringTotals[entry.key] ?? 0) > 0) continue; // already suggested above
    final category = categoriesById[entry.key];
    if (category == null || !category.active) continue;
    final average = entry.value / _suggestionHistoryMonths;
    if (average < 1) continue; // not worth a suggestion
    final lastSpend = lastSpendDates[entry.key];
    suggestions.add(_Suggestion(
      category: category,
      amount: average,
      fromRecurring: false,
      stale: lastSpend == null || lastSpend.isBefore(staleThreshold),
    ));
  }

  if (suggestions.isEmpty) {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rien à suggérer'),
        content: const Text(
          'Aucune opération récurrente ni historique de dépenses exploitable '
          'trouvé pour ce compte.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Fermer')),
        ],
      ),
    );
    return;
  }

  // Grouped by parent category so subcategories with the same leaf name
  // under different parents (e.g. "Divers") don't look identical, and so
  // a whole group can be picked or dropped with one tap - but only ONE
  // envelope per group actually gets written on confirm, summing whatever
  // subcategories stayed checked (see the "Ajouter" handler below): the
  // gauges themselves only ever show a top-level bar, so a subcategory
  // that's unchecked here should simply not contribute to that bar's
  // total rather than getting its own separate envelope row.
  final groups = <int, List<_Suggestion>>{};
  for (final s in suggestions) {
    final groupId = s.category.parentId ?? s.category.id;
    groups.putIfAbsent(groupId, () => []).add(s);
  }
  for (final list in groups.values) {
    list.sort((a, b) => b.amount.compareTo(a.amount));
  }
  final groupOrder = groups.keys.toList()
    ..sort((a, b) {
      final totalA = groups[a]!.fold(0.0, (sum, s) => sum + s.amount);
      final totalB = groups[b]!.fold(0.0, (sum, s) => sum + s.amount);
      return totalB.compareTo(totalA);
    });

  final controllers = {
    for (final s in suggestions) s.category.id: TextEditingController(text: s.amount.toStringAsFixed(2)),
  };
  // A group header's own amount field normally just mirrors the sum of its
  // selected children (updated live as they're checked/unchecked) - typing
  // a different value there overrides that sum outright for that group
  // (children stay tickable, for reference, but no longer feed the total
  // once overridden).
  final groupControllers = {
    for (final groupId in groupOrder)
      groupId: TextEditingController(
        text: groups[groupId]!.where((s) => s.selected).fold(0.0, (sum, s) => sum + s.amount).toStringAsFixed(2),
      ),
  };
  final overriddenGroups = <int>{};
  // Collapsed by default - with many suggestions, an all-expanded list is
  // a lot to scroll past just to reach the next parent's total. Only
  // groups that actually get a header (i.e. not a single self-suggested
  // top-level category, which never shows one - see isSingleSelfGroup
  // below) need to start in collapsedGroups at all.
  final collapsedGroups = groupOrder
      .where((g) => !(groups[g]!.length == 1 && groups[g]!.first.category.id == g))
      .toSet();

  bool? confirmed;
  try {
    confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final selectedGroups = groupOrder.where((g) => groups[g]!.any((s) => s.selected)).length;
          void updateGroupSum(int groupId) {
            if (overriddenGroups.contains(groupId)) return;
            groupControllers[groupId]!.text = groups[groupId]!
                .where((s) => s.selected)
                .fold(0.0, (sum, s) => sum + s.amount)
                .toStringAsFixed(2);
          }

          return AlertDialog(
            title: Row(
              children: [
                const Expanded(child: Text('Enveloppes suggérées')),
                IconButton(
                  tooltip: 'Analyser les dépenses par catégorie',
                  icon: const Icon(Icons.query_stats),
                  onPressed: () => openCategorySpendAnalyzer(
                    context: context,
                    repo: repo,
                    accountId: accountId,
                    categories: categoriesById.values.toList(),
                    currency: currency,
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 440,
              height: 420,
              child: ListView.builder(
                itemCount: groupOrder.length,
                itemBuilder: (context, i) {
                  final groupId = groupOrder[i];
                  final list = groups[groupId]!;
                  final isSingleSelfGroup = list.length == 1 && list.first.category.id == groupId;

                  // Built from the exact same Row shape as the group header
                  // below (Checkbox, then content, then a fixed-width amount
                  // field, then a same-width trailing spacer standing in for
                  // the header's chevron button) - CheckboxListTile's own
                  // built-in content padding doesn't line up with a plain
                  // Checkbox+Row, which was making every child row's
                  // checkbox and amount field sit at different x positions
                  // than its header's.
                  Widget buildChildRow(_Suggestion s, {required bool indent}) {
                    return Padding(
                      padding: EdgeInsets.fromLTRB(indent ? 32 : 4, 4, 16, 4),
                      child: Row(
                        children: [
                          Checkbox(
                            value: s.selected,
                            onChanged: (v) => setDialogState(() {
                              s.selected = v ?? false;
                              updateGroupSum(groupId);
                            }),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(s.category.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                Row(
                                  children: [
                                    Icon(s.fromRecurring ? Icons.autorenew : Icons.history, size: 13),
                                    const SizedBox(width: 4),
                                    Text(
                                      s.fromRecurring ? 'Opération récurrente' : 'Moyenne sur 1 an',
                                      style: Theme.of(context).textTheme.bodySmall,
                                    ),
                                    if (s.stale) ...[
                                      const SizedBox(width: 6),
                                      const Icon(Icons.warning_amber_rounded,
                                          size: 13, color: AppTheme.warning),
                                      const SizedBox(width: 2),
                                      Text(
                                        'plus de 3 mois',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(color: AppTheme.warning),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                          SizedBox(
                            width: 76,
                            child: TextField(
                              controller: controllers[s.category.id],
                              enabled: s.selected,
                              textAlign: TextAlign.right,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              decoration: const InputDecoration(isDense: true),
                              onChanged: (v) => setDialogState(() {
                                s.amount = double.tryParse(v.replaceAll(',', '.')) ?? s.amount;
                                updateGroupSum(groupId);
                              }),
                            ),
                          ),
                          const SizedBox(width: 40),
                        ],
                      ),
                    );
                  }

                  // A standalone top-level suggestion (no subcategories of
                  // its own in this batch) renders as a bare row, no box -
                  // reserving the boxed/header treatment below for actual
                  // parent+children groups keeps the two visually
                  // unmistakable. The same vertical margin as a boxed group
                  // (below) still applies here, otherwise this row sits
                  // flush against whatever box happens to be above it and
                  // reads as if it belongs inside it.
                  if (isSingleSelfGroup) {
                    return Container(
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      child: buildChildRow(list.first, indent: false),
                    );
                  }

                  final selectedInGroup = list.where((s) => s.selected).length;
                  final groupValue =
                      selectedInGroup == list.length ? true : (selectedInGroup == 0 ? false : null);
                  final overridden = overriddenGroups.contains(groupId);
                  final collapsed = collapsedGroups.contains(groupId);
                  void toggleAll() => setDialogState(() {
                        final newValue = groupValue != true;
                        for (final s in list) {
                          s.selected = newValue;
                        }
                        updateGroupSum(groupId);
                      });

                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    clipBehavior: Clip.antiAlias,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 4, 16, 4),
                          child: Row(
                            children: [
                              // Toggle fully-on <-> fully-off ourselves
                              // rather than trusting the value Checkbox
                              // hands back - with tristate:true its own tap
                              // cycle is false -> true -> null -> false, so
                              // tapping a fully-checked box would land on
                              // null (still selected under `v ?? true`)
                              // instead of flipping off.
                              Checkbox(
                                tristate: true,
                                value: groupValue,
                                onChanged: (_) => toggleAll(),
                              ),
                              Expanded(
                                child: InkWell(
                                  onTap: toggleAll,
                                  child: Text(
                                    (categoriesById[groupId] ?? list.first.category).name,
                                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 76,
                                child: TextField(
                                  controller: groupControllers[groupId],
                                  textAlign: TextAlign.right,
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  style: overridden ? const TextStyle(fontWeight: FontWeight.w700) : null,
                                  decoration: const InputDecoration(isDense: true),
                                  onChanged: (_) => overriddenGroups.add(groupId),
                                ),
                              ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                icon: Icon(collapsed ? Icons.expand_more : Icons.expand_less, size: 20),
                                onPressed: () => setDialogState(() {
                                  if (collapsed) {
                                    collapsedGroups.remove(groupId);
                                  } else {
                                    collapsedGroups.add(groupId);
                                  }
                                }),
                              ),
                            ],
                          ),
                        ),
                        if (!collapsed) for (final s in list) buildChildRow(s, indent: true),
                      ],
                    ),
                  );
                },
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Annuler')),
              FilledButton(
                onPressed: selectedGroups == 0 ? null : () => Navigator.of(context).pop(true),
                child: Text('Ajouter ($selectedGroups)'),
              ),
            ],
          );
        },
      ),
    );
  } finally {
    // Deferred a frame past the dialog's own pop/teardown, rather than
    // disposed immediately here - disposing controllers still attached to
    // TextFields mid-teardown of the dialog route was the likely cause of
    // a framework assertion crash when adding a large selection.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final c in controllers.values) {
        c.dispose();
      }
      for (final c in groupControllers.values) {
        c.dispose();
      }
    });
  }

  if (confirmed != true || !context.mounted) return;
  for (final groupId in groupOrder) {
    final total = overriddenGroups.contains(groupId)
        ? double.tryParse(groupControllers[groupId]!.text.replaceAll(',', '.')) ?? 0
        : groups[groupId]!.where((s) => s.selected).fold(0.0, (sum, s) => sum + s.amount);
    if (total <= 0) continue;
    final topCategory = categoriesById[groupId];
    if (topCategory == null) continue;
    repo.upsertBudgetEnvelope(accountId: accountId, categoryId: topCategory.id, amount: total);
  }
  onDone();
}

class _PeriodNav extends StatelessWidget {
  final BudgetWindow window;
  final bool canGoForward;
  final VoidCallback onPrev;
  final VoidCallback? onNext;

  const _PeriodNav({
    required this.window,
    required this.canGoForward,
    required this.onPrev,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(onPressed: onPrev, icon: const Icon(Icons.chevron_left)),
        SizedBox(
          width: 160,
          child: Text(
            window.label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
          ),
        ),
        IconButton(
          onPressed: onNext,
          icon: Icon(Icons.chevron_right, color: canGoForward ? null : Theme.of(context).disabledColor),
        ),
      ],
    );
  }
}

class _RemainingCard extends StatelessWidget {
  final double remaining;
  final DateTime resetDate;
  final CurrencyFormat? currency;

  const _RemainingCard({required this.remaining, required this.resetDate, this.currency});

  @override
  Widget build(BuildContext context) {
    final negative = remaining < 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Reste à vivre ce mois-ci', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(
              currency?.format(remaining) ?? remaining.toStringAsFixed(2),
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w700,
                color: negative ? AppTheme.negative : AppTheme.positive,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Solde prévu au ${DateFormat('d MMM', 'fr_FR').format(resetDate)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// One ranked horizontal bar in the budget screen's spend-by-category
/// chart. Bar length is the category's actual spend plotted on a scale
/// shared across every row (via [maxScale]) so categories are directly
/// comparable at a glance - unlike the old vertical gauges, which were
/// each self-scaled to their own target. A tick mark on the track still
/// shows where that target sits, and going over it triggers the same red
/// pulsing halo + overage badge used to mean "needs attention" elsewhere
/// (see [PulsingHalo]).
///
/// Also doubles as the always-first income row ([moreIsBetter]: true,
/// [maxScale] left null so the bar is self-scaled against its own target
/// instead, like a plain progress bar - income figures aren't on the same
/// scale as category spend, so plotting it against [maxScale] would be
/// meaningless). Exceeding income is good news, not an alarm: no glow,
/// and the badge/tick colour flips to positive.
class _CategoryBarRow extends StatelessWidget {
  final IconData? icon;
  final String label;
  final double spent;
  final double target;
  final double forecastExtra;
  final double? maxScale;
  final bool moreIsBetter;
  final bool selected;
  final CurrencyFormat? currency;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  const _CategoryBarRow({
    required this.label,
    required this.spent,
    required this.target,
    this.icon,
    this.forecastExtra = 0,
    this.maxScale,
    this.moreIsBetter = false,
    this.selected = false,
    this.currency,
    this.onTap,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ratio = target > 0 ? spent / target : (spent > 0 ? 2.0 : 0.0);
    final overTarget = target > 0 && spent > target;
    // "Alarm" (red, glowing) only for a genuine overspend - exceeding an
    // income target is the opposite of a problem.
    final alarm = overTarget && !moreIsBetter;
    final barColor = alarm
        ? AppTheme.negative
        : (!moreIsBetter && ratio >= 0.8 ? AppTheme.warning : AppTheme.positive);
    String fmt(double v) => currency?.format(v) ?? v.toStringAsFixed(0);

    final fillRatio = maxScale != null
        ? (maxScale! > 0 ? (spent / maxScale!).clamp(0, 1).toDouble() : 0.0)
        : ratio.clamp(0, 1).toDouble();
    final forecastRatio = (!alarm && target > 0 && forecastExtra > 0)
        ? (maxScale != null
            ? (maxScale! > 0 ? ((spent + forecastExtra) / maxScale!).clamp(0, 1).toDouble() : 0.0)
            : ((spent + forecastExtra) / target).clamp(0, 1).toDouble())
        : fillRatio;
    final targetRatio = (maxScale != null && target > 0 && maxScale! > 0)
        ? (target / maxScale!).clamp(0, 1).toDouble()
        : null;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
              width: 116,
              child: Row(
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 14, color: scheme.primary),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final trackWidth = constraints.maxWidth;
                  Widget fill = FractionallySizedBox(
                    widthFactor: fillRatio,
                    alignment: Alignment.centerLeft,
                    child: Container(
                      decoration: BoxDecoration(color: barColor, borderRadius: BorderRadius.circular(6)),
                    ),
                  );
                  if (alarm) fill = PulsingHalo(borderRadius: 6, child: fill);
                  return SizedBox(
                    height: 22,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                        if (forecastRatio > fillRatio)
                          FractionallySizedBox(
                            widthFactor: forecastRatio,
                            alignment: Alignment.centerLeft,
                            child: Container(
                              decoration: BoxDecoration(
                                color: forecastColor.withValues(alpha: 0.45),
                                borderRadius: BorderRadius.circular(6),
                              ),
                            ),
                          ),
                        Align(alignment: Alignment.centerLeft, child: fill),
                        if (targetRatio != null)
                          Positioned(
                            left: (trackWidth * targetRatio).clamp(0, trackWidth) - 1,
                            top: -3,
                            bottom: -3,
                            child: Container(width: 2, color: scheme.onSurface.withValues(alpha: 0.55)),
                          ),
                        if (overTarget)
                          Positioned(
                            left: (trackWidth * fillRatio).clamp(0, trackWidth) - 14,
                            top: -20,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: (alarm ? AppTheme.negative : AppTheme.positive).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '+${(spent - target).toStringAsFixed(0)}',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: alarm ? AppTheme.negative : AppTheme.positive,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 92,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    fmt(spent),
                    style: TextStyle(fontWeight: FontWeight.w700, color: alarm ? AppTheme.negative : null),
                  ),
                  if (target > 0)
                    Text(
                      '/ ${fmt(target)}',
                      style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),
            if (onRemove != null) ...[
              const SizedBox(width: 4),
              IconButton(
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                tooltip: 'Retirer du scénario',
                icon: const Icon(Icons.close),
                onPressed: onRemove,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Prominent spent/target readout for the detail card - the small text
/// under each gauge (see _GaugeColumn) is easy to miss, this is the same
/// numbers made hard to overlook once an envelope is selected.
class _AmountSummary extends StatelessWidget {
  final _EnvelopeItem item;
  final CurrencyFormat? currency;

  const _AmountSummary({required this.item, this.currency});

  @override
  Widget build(BuildContext context) {
    String fmt(double v) => currency?.format(v) ?? v.toStringAsFixed(2);
    final over = item.target > 0 && item.spentTotal > item.target;
    final color = over ? AppTheme.negative : AppTheme.positive;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              fmt(item.spentTotal),
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: color),
            ),
            const SizedBox(width: 4),
            Text(
              '/ ${fmt(item.target)}',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        if (item.forecastExtra > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                const Icon(Icons.schedule, size: 14, color: forecastColor),
                const SizedBox(width: 4),
                Text(
                  '+ ${fmt(item.forecastExtra)} prévu(s), pas encore passé',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: forecastColor),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _EnvelopeDetail extends StatefulWidget {
  final _EnvelopeItem item;
  final MmexRepository repo;
  final BudgetWindow window;
  final List<Category> categories;
  final Map<int, double> rawSpend;
  final Set<int> usedCategoryIds;
  final int? accountId;
  final CurrencyFormat? currency;
  final VoidCallback onAddMember;

  /// Called after the top envelope (name/amount) is saved or deleted from
  /// this card, so the caller can persist the change (dbProvider.touch()).
  final VoidCallback onDone;

  const _EnvelopeDetail({
    required this.item,
    required this.repo,
    required this.window,
    required this.categories,
    required this.rawSpend,
    required this.usedCategoryIds,
    required this.onAddMember,
    required this.onDone,
    this.accountId,
    this.currency,
  });

  @override
  State<_EnvelopeDetail> createState() => _EnvelopeDetailState();
}

class _EnvelopeDetailState extends State<_EnvelopeDetail> {
  late final TextEditingController _nameController;
  late final TextEditingController _amountController;

  /// The envelope entry for the top category itself, if one exists yet -
  /// distinct from its subcategories' own entries, which are display-only
  /// here (the user explicitly asked to only edit the title/amount of the
  /// top envelope from this card, not its subcategories).
  _MemberEnvelope? get _topMember {
    for (final m in widget.item.members) {
      if (m.category.id == widget.item.topCategory.id) return m;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.item.displayName);
    _amountController = TextEditingController(text: (_topMember?.target ?? 0).toStringAsFixed(2));
  }

  @override
  void dispose() {
    _nameController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  void _save() {
    final top = _topMember;
    // An empty field, or one left equal to the category's own name, means
    // "no custom label" - store null so it keeps following the category's
    // name automatically (e.g. if that's later renamed via Categories).
    final typedName = _nameController.text.trim();
    final customName =
        (typedName.isEmpty || typedName == widget.item.topCategory.name) ? null : typedName;
    widget.repo.upsertBudgetEnvelope(
      id: top?.entryId,
      accountId: widget.accountId!,
      categoryId: widget.item.topCategory.id,
      amount: double.tryParse(_amountController.text.replaceAll(',', '.')) ?? 0,
      name: customName,
    );
    widget.onDone();
  }

  void _delete() {
    final top = _topMember;
    if (top == null) return;
    widget.repo.deleteBudgetEnvelope(top.entryId);
    // The card stays open (e.g. subcategories may still be budgeted under
    // this same top category) - reset the fields to a blank "not budgeted
    // yet" state rather than leaving the just-deleted values on screen.
    setState(() {
      _nameController.text = widget.item.topCategory.name;
      _amountController.text = '0.00';
    });
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final repo = widget.repo;
    final window = widget.window;
    final categories = widget.categories;
    final rawSpend = widget.rawSpend;
    final usedCategoryIds = widget.usedCategoryIds;
    final accountId = widget.accountId;
    final currency = widget.currency;

    final children = categories.where((c) => c.parentId == item.topCategory.id).toList()
      ..sort((a, b) => (rawSpend[b.id] ?? 0).compareTo(rawSpend[a.id] ?? 0));
    final childIds = children.map((c) => c.id).toSet();
    final relevantIds = {item.topCategory.id, ...childIds};
    // Only subcategories actually relevant to this account (used here at
    // least once, or already budgeted here) - a child only ever used on a
    // different account is just noise in this breakdown.
    final memberChildIds = item.members.map((m) => m.category.id).toSet();
    final relevantChildren = children
        .where((c) => usedCategoryIds.contains(c.id) || memberChildIds.contains(c.id))
        .toList();
    final payees = {for (final p in repo.getPayees(onlyActive: false)) p.id: p};
    final transactions = repo
        .getTransactions(accountId: accountId, from: window.start, to: window.end, limit: 500)
        .where((t) =>
            t.categoryId != null &&
            relevantIds.contains(t.categoryId) &&
            t.transCode == TransCode.withdrawal &&
            !t.isVoid)
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));

    final dateFormat = DateFormat('d MMM', 'fr_FR');
    String fmt(double v) => currency?.format(v) ?? v.toStringAsFixed(2);
    final scheme = Theme.of(context).colorScheme;
    final hasChildEnvelopes = item.members.length > 1 ||
        (item.members.length == 1 && item.members.first.category.id != item.topCategory.id);

    final topMember = _topMember;

    // Same [transactions] list already fetched above, just grouped by
    // category - lets each subcategory row show exactly which operations
    // make up its total on hover, instead of only the combined list at
    // the bottom of the card.
    final transactionsByCategory = <int, List<MoneyTransaction>>{};
    for (final t in transactions) {
      transactionsByCategory.putIfAbsent(t.categoryId!, () => []).add(t);
    }

    Widget buildChildRow(Category c) {
      final row = Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(child: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
            Text(fmt(rawSpend[c.id] ?? 0)),
          ],
        ),
      );
      final txns = transactionsByCategory[c.id];
      if (txns == null || txns.isEmpty) return row;
      final message = txns.map((t) {
        final line =
            '${dateFormat.format(t.date)} - ${payees[t.payeeId]?.name ?? 'Tiers inconnu'} : ${fmt(t.amount)}';
        return (t.notes?.isNotEmpty ?? false) ? '$line — ${t.notes}' : line;
      }).join('\n');
      return HoverTooltip(message: message, child: row);
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (item.isAuto) ...[
                  Icon(Icons.autorenew, size: 16, color: scheme.primary),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(item.displayName,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                ),
                IconButton(
                  tooltip: 'Ajouter une sous-catégorie',
                  icon: const Icon(Icons.add, size: 18),
                  onPressed: widget.onAddMember,
                ),
              ],
            ),
            const SizedBox(height: 8),
            _AmountSummary(item: item, currency: currency),
            if (item.spentSimulated > 0)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  'Dont ${fmt(item.spentSimulated)} simulé(s)',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
                ),
              ),
            const SizedBox(height: 16),
            // Editing lives directly in this card - no separate popup - per
            // explicit user feedback: only the top envelope's title/amount
            // are editable here, subcategories below stay display-only.
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Nom de l\'enveloppe'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _amountController,
              decoration: const InputDecoration(labelText: 'Montant mensuel'),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
            if (topMember?.isAuto ?? false) ...[
              const SizedBox(height: 8),
              Text(
                'Cette enveloppe est actuellement calculée automatiquement depuis des '
                'opérations récurrentes actives - ce montant ne sera utilisé que si elles '
                'sont un jour supprimées.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                TextButton(
                  onPressed: topMember == null ? null : _delete,
                  child: const Text('Supprimer'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _save,
                  child: const Text('Enregistrer'),
                ),
              ],
            ),
            const Divider(height: 20),
            Text('Répartition du budget', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            for (final m in item.members)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    if (m.isAuto)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Icon(Icons.autorenew, size: 13, color: scheme.primary),
                      ),
                    Expanded(
                      child: Text(
                        m.category.id == item.topCategory.id ? 'Cette catégorie (sans les sous-cat.)' : m.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(fmt(m.target), style: const TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            if (!hasChildEnvelopes)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: TextButton.icon(
                  onPressed: widget.onAddMember,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Budgeter une sous-catégorie séparément'),
                ),
              ),
            if (relevantChildren.isNotEmpty) ...[
              const Divider(height: 20),
              Text('Sous-catégories (dépenses réelles)', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 4),
              for (final c in relevantChildren) buildChildRow(c),
            ],
            const Divider(height: 20),
            Text('Opérations de la période', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            if (transactions.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Aucune opération sur cette période.'),
              )
            else
              for (final t in transactions)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 40,
                        child: Text(dateFormat.format(t.date), style: Theme.of(context).textTheme.bodySmall),
                      ),
                      Expanded(
                        child: Text(
                          payees[t.payeeId]?.name ?? 'Tiers inconnu',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        currency?.format(t.amount) ?? t.amount.toStringAsFixed(2),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
