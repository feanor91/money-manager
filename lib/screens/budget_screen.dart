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
import '../utils/list_utils.dart';
import '../widgets/envelope_gauge.dart';
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

  const _MemberEnvelope({
    required this.entryId,
    required this.category,
    required this.target,
    required this.spentOwn,
    required this.spentSimulated,
    required this.forecastExtra,
    required this.isAuto,
  });
}

/// One gauge on the budget screen, always a top-level category - envelopes
/// on its subcategories are folded into it rather than shown as their own
/// separate bars (see [_MemberEnvelope]), so the gauge row stays scannable
/// even with many subcategories budgeted individually. [spentActual] is
/// real recorded spending rolled up across the whole group (the top
/// category plus every one of its children, whether or not that child has
/// its own envelope). [forecastExtra] is the summed remaining gap for
/// every "auto" member in the still-ongoing window - shown as a lighter,
/// distinct fill so a recurring bill not yet paid this month doesn't read
/// as "nothing planned" (see EnvelopeGauge).
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
}

class BudgetScreen extends StatefulWidget {
  const BudgetScreen({super.key});

  @override
  State<BudgetScreen> createState() => _BudgetScreenState();
}

class _BudgetScreenState extends State<BudgetScreen> {
  DateTime _cursor = DateTime.now();
  int? _selectedCategoryId;
  final _gaugeScrollController = ScrollController();

  @override
  void dispose() {
    _gaugeScrollController.dispose();
    super.dispose();
  }

  void _scrollGauges(double delta) {
    if (!_gaugeScrollController.hasClients) return;
    final position = _gaugeScrollController.position;
    final target = (position.pixels + delta).clamp(position.minScrollExtent, position.maxScrollExtent);
    _gaugeScrollController.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
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

    final selectedItem = findById(items, _selectedCategoryId, (i) => i.topCategory.id);

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
              onDone: () => dbProvider.touch(),
            );

    return Scaffold(
      appBar: AppBar(
        title: Text(accountId == null ? 'Budget' : 'Budget - ${accountsById[accountId]!.name}'),
        actions: [
          IconButton(
            tooltip: 'Suggérer des enveloppes automatiquement',
            icon: const Icon(Icons.auto_awesome_outlined),
            onPressed: openSuggestions,
          ),
          PopupMenuButton<int>(
            icon: const Icon(Icons.filter_list),
            onSelected: (id) => dbProvider.selectAccount(id),
            itemBuilder: (context) => [
              for (final a in visibleAccounts)
                PopupMenuItem(value: a.id, child: Text(a.name)),
            ],
          ),
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
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: openAddDialog,
        icon: const Icon(Icons.add),
        label: const Text('Enveloppe'),
      ),
      body: ResponsiveBody(
        maxWidth: 800,
        child: ListView(
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
              SizedBox(
                height: EnvelopeGauge.height + 60,
                child: ListView.separated(
                  controller: _gaugeScrollController,
                  scrollDirection: Axis.horizontal,
                  itemCount: items.length + 1,
                  separatorBuilder: (_, __) => const SizedBox(width: 14),
                  itemBuilder: (context, i) {
                    if (i == 0) {
                      return _IncomeGaugeColumn(
                        income: income,
                        expected: expectedIncome,
                        currency: currency,
                      );
                    }
                    final item = items[i - 1];
                    return _GaugeColumn(
                      item: item,
                      currency: currency,
                      selected: item.topCategory.id == _selectedCategoryId,
                      onTap: () => setState(() {
                        _selectedCategoryId =
                            _selectedCategoryId == item.topCategory.id ? null : item.topCategory.id;
                      }),
                    );
                  },
                ),
              ),
              // Explicit arrows rather than relying on mouse-wheel/trackpad
              // gestures over the row - wheel scrolling here isn't
              // intuitive (it's already the page's own vertical scroll) -
              // but only shown when the row actually overflows, otherwise
              // they'd sit there doing nothing.
              LayoutBuilder(builder: (context, constraints) {
                const columnWidth = 60.0;
                const separatorWidth = 14.0;
                final gaugeCount = items.length + 1;
                final contentWidth = gaugeCount * columnWidth + (gaugeCount - 1) * separatorWidth;
                if (contentWidth <= constraints.maxWidth) return const SizedBox.shrink();
                return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.chevron_left),
                      onPressed: () => _scrollGauges(-160),
                    ),
                    IconButton(
                      icon: const Icon(Icons.chevron_right),
                      onPressed: () => _scrollGauges(160),
                    ),
                  ],
                );
              }),
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
            if (selectedItem != null) ...[
              const SizedBox(height: 20),
              _EnvelopeDetail(
                key: ValueKey(selectedItem.topCategory.id),
                item: selectedItem,
                repo: repo,
                window: window,
                categories: categories,
                rawSpend: rawSpend,
                usedCategoryIds: usedCategoryIds,
                accountId: accountId,
                currency: currency,
                onAddMember: () {
                  final coveredIds = selectedItem.members.map((m) => m.category.id).toSet();
                  final candidates = [
                    selectedItem.topCategory,
                    ...categories.where((c) =>
                        c.parentId == selectedItem.topCategory.id && usedCategoryIds.contains(c.id)),
                  ].where((c) => c.active && !coveredIds.contains(c.id)).toList();
                  _addEnvelope(
                    context: context,
                    repo: repo,
                    accountId: accountId!,
                    candidateCategories: candidates,
                    categoriesById: categoriesById,
                    recurringTotals: recurringTotals,
                    onDone: () => dbProvider.touch(),
                  );
                },
                onEditMember: (member) => _editEnvelope(
                  context: context,
                  repo: repo,
                  accountId: accountId!,
                  member: member,
                  onDone: () => dbProvider.touch(),
                ),
                onDeleteMember: (member) async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Supprimer l\'enveloppe'),
                      content: Text('Supprimer l\'enveloppe "${member.category.name}" ?'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.of(context).pop(false),
                            child: const Text('Annuler')),
                        FilledButton(
                            onPressed: () => Navigator.of(context).pop(true),
                            child: const Text('Supprimer')),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    repo.deleteBudgetEnvelope(member.entryId);
                    dbProvider.touch();
                  }
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
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
            title: const Text('Enveloppes suggérées'),
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

Future<void> _editEnvelope({
  required BuildContext context,
  required MmexRepository repo,
  required int accountId,
  required _MemberEnvelope member,
  required VoidCallback onDone,
}) async {
  final amountController = TextEditingController(text: member.target.toStringAsFixed(2));
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Modifier "${member.category.name}"'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: amountController,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Montant mensuel'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          if (member.isAuto) ...[
            const SizedBox(height: 8),
            Text(
              'Cette enveloppe est actuellement calculée automatiquement depuis des '
              'opérations récurrentes actives - ce montant ne sera utilisé que si elles '
              'sont un jour supprimées.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Annuler')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Enregistrer'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  repo.upsertBudgetEnvelope(
    id: member.entryId,
    accountId: accountId,
    categoryId: member.category.id,
    amount: double.tryParse(amountController.text.replaceAll(',', '.')) ?? 0,
  );
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

/// The always-first gauge on the budget screen: real income received this
/// window against expected income (still-active recurring deposits, e.g.
/// salary) - same size/shape as an [EnvelopeGauge] for visual consistency,
/// but its own colour logic since "more than expected" is good here, the
/// opposite of an over-budget envelope.
class _IncomeGaugeColumn extends StatelessWidget {
  final double income;
  final double expected;
  final CurrencyFormat? currency;

  const _IncomeGaugeColumn({required this.income, required this.expected, this.currency});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ratio = expected > 0 ? income / expected : (income > 0 ? 1.0 : 0.0);
    final fillRatio = ratio.clamp(0, 1).toDouble();
    final exceeded = expected > 0 && income > expected;
    String fmt(double v) => currency?.format(v) ?? v.toStringAsFixed(0);

    return SizedBox(
      width: 60,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 18),
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.topCenter,
              children: [
                Container(
                  width: EnvelopeGauge.width,
                  height: EnvelopeGauge.height,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppTheme.positive, width: 1.5),
                  ),
                  child: Stack(
                    children: [
                      if (fillRatio < 1)
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: Container(color: forecastColor.withValues(alpha: 0.22)),
                        ),
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: FractionallySizedBox(
                          heightFactor: fillRatio,
                          widthFactor: 1,
                          child: Container(color: AppTheme.positive),
                        ),
                      ),
                    ],
                  ),
                ),
                if (exceeded)
                  Positioned(
                    top: -18,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: AppTheme.positive.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '+${(income - expected).toStringAsFixed(0)}',
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.positive),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Revenus',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.positive),
          ),
          Text(
            '${fmt(income)}/${fmt(expected)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _GaugeColumn extends StatelessWidget {
  final _EnvelopeItem item;
  final CurrencyFormat? currency;
  final bool selected;
  final VoidCallback onTap;

  const _GaugeColumn({
    required this.item,
    required this.selected,
    required this.onTap,
    this.currency,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 60,
      child: Column(
        children: [
          EnvelopeGauge(
            spent: item.spentTotal,
            target: item.target,
            forecastExtra: item.forecastExtra,
            selected: selected,
            onTap: onTap,
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (item.isAuto)
                Padding(
                  padding: const EdgeInsets.only(right: 3),
                  child: Icon(Icons.autorenew, size: 11, color: scheme.primary),
                ),
              Flexible(
                child: Text(
                  item.topCategory.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: item.isAuto ? scheme.primary : null,
                  ),
                ),
              ),
            ],
          ),
          Text(
            '${(currency?.format(item.spentTotal) ?? item.spentTotal.toStringAsFixed(0))}/'
            '${currency?.format(item.target) ?? item.target.toStringAsFixed(0)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
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

class _EnvelopeDetail extends StatelessWidget {
  final _EnvelopeItem item;
  final MmexRepository repo;
  final BudgetWindow window;
  final List<Category> categories;
  final Map<int, double> rawSpend;
  final Set<int> usedCategoryIds;
  final int? accountId;
  final CurrencyFormat? currency;
  final VoidCallback onAddMember;
  final ValueChanged<_MemberEnvelope> onEditMember;
  final ValueChanged<_MemberEnvelope> onDeleteMember;

  const _EnvelopeDetail({
    super.key,
    required this.item,
    required this.repo,
    required this.window,
    required this.categories,
    required this.rawSpend,
    required this.usedCategoryIds,
    required this.onAddMember,
    required this.onEditMember,
    required this.onDeleteMember,
    this.accountId,
    this.currency,
  });

  @override
  Widget build(BuildContext context) {
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

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      if (item.isAuto) ...[
                        Icon(Icons.autorenew, size: 16, color: scheme.primary),
                        const SizedBox(width: 6),
                      ],
                      Flexible(
                        child: Text(item.topCategory.name,
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Ajouter une sous-catégorie',
                  icon: const Icon(Icons.add, size: 18),
                  onPressed: onAddMember,
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
            const Divider(height: 20),
            Text('Répartition du budget', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            for (final m in item.members)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    if (m.isAuto)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Icon(Icons.autorenew, size: 13, color: scheme.primary),
                      ),
                    Expanded(
                      child: Text(
                        m.category.id == item.topCategory.id ? 'Cette catégorie (sans les sous-cat.)' : m.category.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(fmt(m.target), style: const TextStyle(fontWeight: FontWeight.w600)),
                    IconButton(
                      tooltip: 'Modifier',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      onPressed: () => onEditMember(m),
                    ),
                    IconButton(
                      tooltip: 'Supprimer',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.delete_outline, size: 16, color: AppTheme.negative),
                      onPressed: () => onDeleteMember(m),
                    ),
                  ],
                ),
              ),
            if (!hasChildEnvelopes)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: TextButton.icon(
                  onPressed: onAddMember,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Budgeter une sous-catégorie séparément'),
                ),
              ),
            if (relevantChildren.isNotEmpty) ...[
              const Divider(height: 20),
              Text('Sous-catégories (dépenses réelles)', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 4),
              for (final c in relevantChildren)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                      Text(fmt(rawSpend[c.id] ?? 0)),
                    ],
                  ),
                ),
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
                          payees[t.payeeId]?.name ?? 'Payé inconnu',
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
