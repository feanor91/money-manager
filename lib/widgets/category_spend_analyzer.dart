import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/mmex_repository.dart';
import '../models/category.dart';
import '../models/currency.dart';
import '../models/payee.dart';
import '../models/transaction.dart';
import '../theme/app_theme.dart';
import '../utils/date_picker.dart';
import '../utils/list_utils.dart';
import 'hover_tooltip.dart';

/// Opens [CategorySpendAnalyzer] as a dialog - a read-only research tool to
/// look up real historical spend (one or several categories combined, over
/// a chosen time frame) before typing a number into a budget envelope.
/// Purely informational: it doesn't write anything back, the user reads
/// the figure and enters it into the suggestion/envelope field themselves.
Future<void> openCategorySpendAnalyzer({
  required BuildContext context,
  required MmexRepository repo,
  required int accountId,
  required List<Category> categories,
  required CurrencyFormat? currency,
}) {
  final screen = MediaQuery.sizeOf(context);
  final width = screen.width < 760 ? screen.width * 0.95 : 900.0;
  final height = screen.height * 0.88;
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: width,
        height: height,
        child: CategorySpendAnalyzer(
          repo: repo,
          accountId: accountId,
          categories: categories,
          currency: currency,
        ),
      ),
    ),
  );
}

enum _AnalyzerMode { sameMonthAcrossYears, yearAllMonths, customRange }

class CategorySpendAnalyzer extends StatefulWidget {
  final MmexRepository repo;
  final int accountId;
  final List<Category> categories;
  final CurrencyFormat? currency;

  const CategorySpendAnalyzer({
    super.key,
    required this.repo,
    required this.accountId,
    required this.categories,
    required this.currency,
  });

  @override
  State<CategorySpendAnalyzer> createState() => _CategorySpendAnalyzerState();
}

class _CategorySpendAnalyzerState extends State<CategorySpendAnalyzer> {
  static const _yearsBack = 5;

  final _selected = <int>{};
  final _expandedParents = <int>{};
  final _searchController = TextEditingController();
  String _search = '';
  _AnalyzerMode _mode = _AnalyzerMode.sameMonthAcrossYears;
  int _month = DateTime.now().month;
  int _year = DateTime.now().year;
  late DateTime _rangeStart;
  late DateTime _rangeEnd;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _rangeEnd = DateTime(now.year, now.month, now.day);
    _rangeStart = DateTime(now.year, now.month - 2, 1);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Selected ids with any id whose parent is *also* selected removed -
  /// selecting a parent already rolls up its children's spend (see
  /// [rolledUpSpend]), so keeping both would double-count that child. In
  /// practice [_toggleParent]/[_toggleChild] keep a parent and any of its
  /// children from ever being selected at the same time in the first
  /// place, so this is now mostly a safety net.
  Set<int> _effectiveIds(Map<int, Category> categoriesById) {
    return _selected.where((id) {
      final parentId = categoriesById[id]?.parentId;
      return parentId == null || !_selected.contains(parentId);
    }).toSet();
  }

  /// Checking a parent category means "the whole family" - any of its
  /// children checked individually would be redundant (already included)
  /// and, worse, looked like a bug: the total stayed the parent's full
  /// figure no matter which child got toggled next, since a selected
  /// parent always overrides its own children in [_effectiveIds]. So
  /// selecting the parent now clears any of its own children out of
  /// [_selected] instead of just leaving them there unused.
  void _toggleParent(Category parent, List<Category> children, bool value) {
    setState(() {
      if (value) {
        _selected.add(parent.id);
        _selected.removeAll(children.map((c) => c.id));
      } else {
        _selected.remove(parent.id);
      }
    });
  }

  /// Symmetric with [_toggleParent]: checking a specific subcategory means
  /// "just this one", not "the whole family plus this one" - so it also
  /// clears the parent out of [_selected] if it was checked, rather than
  /// silently being ignored by [_effectiveIds] while the parent's full
  /// total kept showing regardless of which child was toggled.
  void _toggleChild(Category child, int parentId, bool value) {
    setState(() {
      if (value) {
        _selected.add(child.id);
        _selected.remove(parentId);
      } else {
        _selected.remove(child.id);
      }
    });
  }

  /// Real (non-void) transactions on this account for [start, end) - the
  /// shared source of truth for [_categoryTotalsForPeriod],
  /// [_expenseIncomeTotals] and [_transactionsTooltip], so a figure and
  /// its hover breakdown can never disagree about which transactions
  /// count. Deliberately NOT restricted to withdrawals only (unlike
  /// [MmexRepository.categorySpendForPeriod], which is - correctly - a
  /// spending-only figure for the budget feature): a category here can
  /// just as well be an income one ("Salaire", "Pension"), and it should
  /// show its real deposit totals instead of a hardcoded 0. Categorized
  /// transfers are included too (e.g. a recurring "Virement:Épargne" from
  /// one of the user's own accounts to another) - only genuinely
  /// uncategorized ones are excluded, since those aren't tagged as
  /// meaning anything in particular.
  List<MoneyTransaction> _transactionsForPeriod(DateTime start, DateTime end) {
    return widget.repo
        .getTransactions(
            accountId: widget.accountId, from: start, to: end, limit: 2000)
        .where((t) => t.categoryId != null && !t.isVoid)
        .toList();
  }

  /// Per-leaf-category totals for [start, end), built from
  /// [_transactionsForPeriod] - the analyzer's own equivalent of
  /// [MmexRepository.categorySpendForMonth]/[categorySpendForPeriod], but
  /// covering income and categorized-transfer categories too (see
  /// [_transactionsForPeriod]). Signed from this account's own point of
  /// view ([MoneyTransaction.signedAmountFor]) so a transfer *into* this
  /// account reads as positive and one going *out* as negative, exactly
  /// like a deposit/withdrawal would.
  Map<int, double> _categoryTotalsForPeriod(DateTime start, DateTime end) {
    final totals = <int, double>{};
    for (final t in _transactionsForPeriod(start, end)) {
      totals[t.categoryId!] =
          (totals[t.categoryId!] ?? 0) + t.signedAmountFor(widget.accountId);
    }
    return totals;
  }

  /// [effectiveIds] widened to include a selected parent's direct
  /// children (matching how its total is already rolled up - see
  /// [rolledUpSpend]) - shared by [_expenseIncomeTotals] and
  /// [_transactionsTooltip] so neither can silently disagree with the
  /// other about which categories count.
  Set<int> _relevantIds(Set<int> effectiveIds) {
    final relevantIds = <int>{};
    for (final id in effectiveIds) {
      relevantIds.add(id);
      for (final c in widget.categories) {
        if (c.parentId == id) relevantIds.add(c.id);
      }
    }
    return relevantIds;
  }

  /// Expense and income are fundamentally different things - blindly
  /// summing "Salaire" (income) together with "Nourriture" (expense) into
  /// one figure produces a number that means nothing (e.g. "135 661 €"
  /// when what actually happened was 73 379 € spent and 62 282 € earned,
  /// a deficit of ~11 000 €, not a "total" of 135 661 €). This keeps the
  /// two apart so the UI can show both, plus their real difference.
  ({double expenses, double income}) _expenseIncomeTotals(
    DateTime start,
    DateTime end,
    Set<int> effectiveIds,
  ) {
    final relevantIds = _relevantIds(effectiveIds);
    var expenses = 0.0;
    var income = 0.0;
    for (final t in _transactionsForPeriod(start, end)) {
      if (!relevantIds.contains(t.categoryId)) continue;
      final signed = t.signedAmountFor(widget.accountId);
      if (signed < 0) {
        expenses += -signed;
      } else {
        income += signed;
      }
    }
    return (expenses: expenses, income: income);
  }

  /// Hover-tooltip text listing the actual transactions behind a figure
  /// (date, payee, amount, note) - same format as the budget screen's own
  /// tooltips (see [budget_screen.dart]'s envelope detail sheet and
  /// [budget_preview_card.dart]), so the two feel like the same feature.
  /// Unlike [rolledUpSpend]'s plain totals, this fetches real transaction
  /// rows for [start, end) and keeps only the ones under a *selected*
  /// category (rolled up to include a selected parent's direct children,
  /// matching how the displayed total itself is computed) - never just
  /// "the amount for the row" again.
  String _transactionsTooltip(
    DateTime start,
    DateTime end,
    Set<int> effectiveIds,
    Map<int, Payee> payeesById,
    String Function(double) fmt,
  ) {
    final relevantIds = _relevantIds(effectiveIds);
    final txns = _transactionsForPeriod(start, end)
        .where((t) => relevantIds.contains(t.categoryId))
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    if (txns.isEmpty) return 'Aucune opération sur cette période.';
    final dateFormat = DateFormat('d MMM', 'fr_FR');
    return txns.map((t) {
      // .abs(): a transfer's amount from this account's own side (see
      // signedAmountFor) may be the toAmount, not t.amount directly (cross-
      // currency transfers) - this is always the right magnitude to show.
      final amount = t.signedAmountFor(widget.accountId).abs();
      final line =
          '${dateFormat.format(t.date)} - ${payeesById[t.payeeId]?.name ?? 'Tiers inconnu'} : ${fmt(amount)}';
      return (t.notes?.isNotEmpty ?? false) ? '$line — ${t.notes}' : line;
    }).join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final categoriesById = {for (final c in widget.categories) c.id: c};
    final payeesById = {
      for (final p in widget.repo.getPayees(onlyActive: false)) p.id: p
    };
    final byParent = <int?, List<Category>>{};
    for (final c in widget.categories) {
      byParent.putIfAbsent(c.parentId, () => []).add(c);
    }
    // Only categories with a real transaction on this specific account -
    // no point listing "Crédit immobilier" or "Épargne" while analysing
    // an account that's never once used them (same filter BudgetScreen's
    // "Budgeter une sous-categorie" flow already applies for the same
    // reason). A parent still shows if any of ITS children are used, even
    // if the parent itself never got a direct transaction of its own.
    final usedCategoryIds =
        widget.repo.categoriesUsedByAccount(widget.accountId);
    bool isRelevant(Category c) =>
        usedCategoryIds.contains(c.id) ||
        (byParent[c.id] ?? const <Category>[])
            .any((child) => usedCategoryIds.contains(child.id));
    final allTopCategories = (byParent[null] ?? const <Category>[])
        .where(isRelevant)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final query = foldDiacritics(_search.trim());
    bool matches(Category c) => foldDiacritics(c.name).contains(query);
    final topCategories = query.isEmpty
        ? allTopCategories
        : allTopCategories.where((p) {
            final children = byParent[p.id] ?? const <Category>[];
            return matches(p) || children.any(matches);
          }).toList();
    final effectiveIds = _effectiveIds(categoriesById);
    final currency = widget.currency;
    String fmt(double v) => currency?.format(v) ?? v.toStringAsFixed(2);

    // A bare Dialog (unlike the AlertDialogs used elsewhere in this app)
    // doesn't reliably pick up the app's dark surface color on its own -
    // paint it explicitly so nothing shows the raw Material default grey.
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text('Analyser les dépenses',
                      style: Theme.of(context).textTheme.titleLarge),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            // A phone-width screen can't fit the desktop side-by-side layout
            // (260px category panel + a right panel with a 3-segment button
            // whose labels are full sentences) - below that it stacks
            // vertically and the mode picker switches to a dropdown instead
            // of forcing each SegmentedButton label to wrap character by
            // character. Same breakpoint convention as the ledger's
            // table-vs-cards split in transactions_screen.dart.
            child: LayoutBuilder(builder: (context, constraints) {
              final narrow = constraints.maxWidth < 640;
              final categoryPanel = _buildCategoryPanel(
                  topCategories, byParent, usedCategoryIds, query, matches);
              final resultsPanel = _buildResultsPanel(
                  context, effectiveIds, categoriesById, payeesById, fmt,
                  narrow: narrow);
              if (narrow) {
                return Column(
                  children: [
                    SizedBox(height: 220, child: categoryPanel),
                    const Divider(height: 1),
                    Expanded(child: resultsPanel),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 260, child: categoryPanel),
                  const VerticalDivider(width: 1),
                  Expanded(child: resultsPanel),
                ],
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryPanel(
    List<Category> topCategories,
    Map<int?, List<Category>> byParent,
    Set<int> usedCategoryIds,
    String query,
    bool Function(Category) matches,
  ) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: TextField(
            controller: _searchController,
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 20),
              hintText: 'Rechercher une catégorie',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _search = v),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(
                onPressed: () => setState(() {
                  // Selecting every visible top-level category already
                  // rolls up all its children (see _toggleParent) - no
                  // need to also select each leaf individually.
                  for (final p in topCategories) {
                    _selected.add(p.id);
                    final children = byParent[p.id] ?? const <Category>[];
                    _selected.removeAll(children.map((c) => c.id));
                  }
                }),
                child: const Text('Tout cocher'),
              ),
              TextButton(
                onPressed: () => setState(() => _selected.clear()),
                child: const Text('Tout décocher'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: topCategories.length,
            itemBuilder: (context, i) {
              final parent = topCategories[i];
              // .toList() before sorting is required: a parent with no
              // children hits the `?? const []` fallback, and sorting a
              // const list in place throws (caught per-widget by Flutter,
              // which silently renders a blank placeholder in release mode
              // instead of a visible error) - this was the real cause of a
              // very confusing "grey box" investigation.
              final children = (byParent[parent.id] ?? const [])
                  .where((c) => usedCategoryIds.contains(c.id))
                  .toList()
                ..sort((a, b) => a.name.compareTo(b.name));
              // While searching, force every matching parent open so a
              // matched child is actually visible without an extra click.
              final expanded = _expandedParents.contains(parent.id) ||
                  (query.isNotEmpty && children.any(matches));
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CheckboxListTile(
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding:
                        const EdgeInsets.only(left: 4, right: 4),
                    value: _selected.contains(parent.id),
                    onChanged: (v) =>
                        _toggleParent(parent, children, v ?? false),
                    title: Row(
                      children: [
                        Expanded(
                          child: Text(parent.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                        if (children.isNotEmpty)
                          IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            iconSize: 18,
                            icon: Icon(expanded
                                ? Icons.expand_less
                                : Icons.expand_more),
                            onPressed: () => setState(() {
                              expanded
                                  ? _expandedParents.remove(parent.id)
                                  : _expandedParents.add(parent.id);
                            }),
                          ),
                      ],
                    ),
                  ),
                  if (expanded)
                    for (final child in children)
                      Padding(
                        padding: const EdgeInsets.only(left: 20),
                        child: CheckboxListTile(
                          dense: true,
                          controlAffinity: ListTileControlAffinity.leading,
                          contentPadding: const EdgeInsets.only(right: 4),
                          value: _selected.contains(child.id),
                          onChanged: (v) =>
                              _toggleChild(child, parent.id, v ?? false),
                          title: Text(child.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  static const _modeLabels = {
    _AnalyzerMode.sameMonthAcrossYears: 'Même mois, plusieurs années',
    _AnalyzerMode.yearAllMonths: 'Une année, tous les mois',
    _AnalyzerMode.customRange: 'Période libre',
  };

  Widget _buildResultsPanel(
    BuildContext context,
    Set<int> effectiveIds,
    Map<int, Category> categoriesById,
    Map<int, Payee> payeesById,
    String Function(double) fmt, {
    required bool narrow,
  }) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: _selected.isEmpty
          ? const Center(child: Text('Choisissez au moins une catégorie.'))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final id in _selected)
                        Chip(
                          label: Text(categoriesById[id]?.name ?? '?'),
                          onDeleted: () =>
                              setState(() => _selected.remove(id)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // SegmentedButton forces its segments onto a single row
                  // and shrinks them to fit - with labels this long
                  // ("Même mois, plusieurs années", ...) a narrow phone
                  // width leaves each button only a handful of pixels,
                  // which wraps the text vertically one letter per line.
                  // A dropdown stays compact regardless of label length.
                  if (narrow)
                    DropdownButtonFormField<_AnalyzerMode>(
                      initialValue: _mode,
                      isExpanded: true,
                      decoration: const InputDecoration(isDense: true),
                      items: [
                        for (final mode in _AnalyzerMode.values)
                          DropdownMenuItem(
                            value: mode,
                            child: Text(_modeLabels[mode]!),
                          ),
                      ],
                      onChanged: (v) => setState(() => _mode = v!),
                    )
                  else
                    SegmentedButton<_AnalyzerMode>(
                      segments: [
                        for (final mode in _AnalyzerMode.values)
                          ButtonSegment(
                            value: mode,
                            label: Text(_modeLabels[mode]!),
                          ),
                      ],
                      selected: {_mode},
                      onSelectionChanged: (s) =>
                          setState(() => _mode = s.first),
                    ),
                  const SizedBox(height: 16),
                  if (_mode == _AnalyzerMode.sameMonthAcrossYears)
                    _buildSameMonthMode(
                        context, effectiveIds, payeesById, fmt)
                  else if (_mode == _AnalyzerMode.yearAllMonths)
                    _buildYearAllMonthsMode(
                        context, effectiveIds, payeesById, fmt)
                  else
                    _buildCustomRangeMode(
                        context, categoriesById, effectiveIds, fmt),
                ],
              ),
    );
  }

  /// Three-line "Dépenses / Revenus / Solde" summary, replacing a single
  /// blindly-summed figure that meant nothing once income categories were
  /// mixed in with expense ones (see [_expenseIncomeTotals]). Solde turns
  /// red when it's a deficit (revenus < dépenses), matching how negative
  /// figures read everywhere else in the app.
  Widget _expenseIncomeSummary(
      BuildContext context, double expenses, double income, String label,
      {required String Function(double) fmt}) {
    final solde = income - expenses;
    Widget row(String text, double value, {bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(text,
                  style: bold
                      ? Theme.of(context).textTheme.labelLarge
                      : Theme.of(context).textTheme.bodyMedium),
              Text(
                fmt(value),
                style: TextStyle(
                  fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
                  fontSize: bold ? 18 : 14,
                  color: bold
                      ? (value < 0 ? AppTheme.negative : AppTheme.accent)
                      : null,
                ),
              ),
            ],
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row('Dépenses ($label)', expenses),
        row('Revenus ($label)', income),
        const Divider(),
        row('Solde ($label)', solde, bold: true),
      ],
    );
  }

  Widget _buildSameMonthMode(
    BuildContext context,
    Set<int> effectiveIds,
    Map<int, Payee> payeesById,
    String Function(double) fmt,
  ) {
    final now = DateTime.now();
    final years = [
      for (var y = now.year - _yearsBack + 1; y <= now.year; y++) y
    ];
    final totalsByYear = <int, ({double expenses, double income})>{};
    for (final year in years) {
      totalsByYear[year] = _expenseIncomeTotals(
        DateTime(year, _month, 1),
        DateTime(year, _month + 1, 1),
        effectiveIds,
      );
    }
    final yearsWithData =
        totalsByYear.values.where((v) => v.expenses > 0 || v.income > 0);
    final avgExpenses = yearsWithData.isEmpty
        ? 0.0
        : yearsWithData.map((v) => v.expenses).reduce((a, b) => a + b) /
            yearsWithData.length;
    final avgIncome = yearsWithData.isEmpty
        ? 0.0
        : yearsWithData.map((v) => v.income).reduce((a, b) => a + b) /
            yearsWithData.length;

    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButton<int>(
            value: _month,
            items: [
              for (var m = 1; m <= 12; m++)
                DropdownMenuItem(
                    value: m,
                    child: Text(
                        DateFormat.MMMM('fr_FR').format(DateTime(2000, m)))),
            ],
            onChanged: (m) => setState(() => _month = m ?? _month),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              children: [
                for (final year in years.reversed)
                  HoverTooltip(
                    message: _transactionsTooltip(
                      DateTime(year, _month, 1),
                      DateTime(year, _month + 1, 1),
                      effectiveIds,
                      payeesById,
                      fmt,
                    ),
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('$year'),
                      trailing: Builder(builder: (context) {
                        final net = totalsByYear[year]!.income -
                            totalsByYear[year]!.expenses;
                        return Text(
                          fmt(net),
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: net < 0 ? AppTheme.negative : null,
                          ),
                        );
                      }),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(),
          _expenseIncomeSummary(context, avgExpenses, avgIncome, 'moyenne',
              fmt: fmt),
        ],
      ),
    );
  }

  Widget _buildYearAllMonthsMode(
    BuildContext context,
    Set<int> effectiveIds,
    Map<int, Payee> payeesById,
    String Function(double) fmt,
  ) {
    final now = DateTime.now();
    final years = [
      for (var y = now.year - _yearsBack + 1; y <= now.year; y++) y
    ];
    final totalsByMonth = <int, ({double expenses, double income})>{};
    for (var m = 1; m <= 12; m++) {
      totalsByMonth[m] = _expenseIncomeTotals(
        DateTime(_year, m, 1),
        DateTime(_year, m + 1, 1),
        effectiveIds,
      );
    }
    final yearExpenses =
        totalsByMonth.values.map((v) => v.expenses).fold(0.0, (a, b) => a + b);
    final yearIncome =
        totalsByMonth.values.map((v) => v.income).fold(0.0, (a, b) => a + b);

    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButton<int>(
            value: _year,
            items: [
              for (final y in years.reversed)
                DropdownMenuItem(value: y, child: Text('$y')),
            ],
            onChanged: (y) => setState(() => _year = y ?? _year),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              children: [
                for (var m = 1; m <= 12; m++)
                  HoverTooltip(
                    message: _transactionsTooltip(
                      DateTime(_year, m, 1),
                      DateTime(_year, m + 1, 1),
                      effectiveIds,
                      payeesById,
                      fmt,
                    ),
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                          DateFormat.MMMM('fr_FR').format(DateTime(2000, m))),
                      trailing: Builder(builder: (context) {
                        final net = totalsByMonth[m]!.income -
                            totalsByMonth[m]!.expenses;
                        return Text(
                          fmt(net),
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: net < 0 ? AppTheme.negative : null,
                          ),
                        );
                      }),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(),
          _expenseIncomeSummary(
              context, yearExpenses, yearIncome, "sur l'année",
              fmt: fmt),
        ],
      ),
    );
  }

  Widget _buildCustomRangeMode(
    BuildContext context,
    Map<int, Category> categoriesById,
    Set<int> effectiveIds,
    String Function(double) fmt,
  ) {
    final spend = _categoryTotalsForPeriod(
      _rangeStart,
      _rangeEnd.add(const Duration(days: 1)),
    );
    final totals = _expenseIncomeTotals(
      _rangeStart,
      _rangeEnd.add(const Duration(days: 1)),
      effectiveIds,
    );
    final dateFmt = DateFormat.yMMMd('fr_FR');

    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    final picked = await pickDate(
                      context: context,
                      initialDate: _rangeStart,
                      firstDate: DateTime(2000),
                      lastDate: _rangeEnd,
                      helpText: 'Début de la période',
                    );
                    if (picked != null) setState(() => _rangeStart = picked);
                  },
                  child: Text('Du ${dateFmt.format(_rangeStart)}'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    final picked = await pickDate(
                      context: context,
                      initialDate: _rangeEnd,
                      firstDate: _rangeStart,
                      lastDate: DateTime.now(),
                      helpText: 'Fin de la période',
                    );
                    if (picked != null) setState(() => _rangeEnd = picked);
                  },
                  child: Text('au ${dateFmt.format(_rangeEnd)}'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('Détail par catégorie',
              style: Theme.of(context).textTheme.labelLarge),
          Expanded(
            child: ListView(
              children: [
                for (final id in effectiveIds)
                  Builder(builder: (context) {
                    final value = rolledUpSpend(id, spend, widget.categories);
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(categoriesById[id]?.name ?? '?'),
                      trailing: Text(
                        fmt(value),
                        style: TextStyle(
                            color: value < 0 ? AppTheme.negative : null),
                      ),
                    );
                  }),
              ],
            ),
          ),
          const Divider(),
          _expenseIncomeSummary(
              context, totals.expenses, totals.income, 'sur la période',
              fmt: fmt),
        ],
      ),
    );
  }
}
