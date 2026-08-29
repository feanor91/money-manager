import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/mmex_repository.dart';
import '../models/account.dart';
import '../models/category.dart';
import '../models/currency.dart';
import '../models/payee.dart';
import '../models/transaction.dart';
import '../state/database_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/transaction_tile.dart';

/// Cross-account spending explorer: four cascading multi-select filters
/// (Année → Catégorie → Sous-catégorie → Tiers, each descending level
/// filtered by the level above it), then a single "Appliquer" action that
/// produces both a table of the matching operations and a stacked monthly
/// bar chart of the same data - see [_applyFilters].
class SpendingExplorerScreen extends StatefulWidget {
  const SpendingExplorerScreen({super.key});

  @override
  State<SpendingExplorerScreen> createState() => _SpendingExplorerScreenState();
}

class _SpendingExplorerScreenState extends State<SpendingExplorerScreen> {
  final Set<int> _selectedAccountIds = {};
  final Set<int> _selectedYears = {};
  final Set<int> _selectedCategoryIds = {};
  final Set<int> _selectedSubCategoryIds = {};
  final Set<int> _selectedPayeeIds = {};

  List<MoneyTransaction>? _results;

  List<Category> _subCategoryOptions(List<Category> allCategories) {
    final options = allCategories
        .where((c) =>
            c.parentId != null &&
            (_selectedCategoryIds.isEmpty ||
                _selectedCategoryIds.contains(c.parentId)))
        .toList();
    options.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return options;
  }

  List<Payee> _payeeOptions(List<Payee> allPayees) {
    final options = allPayees
        .where((p) =>
            _selectedSubCategoryIds.isEmpty ||
            _selectedSubCategoryIds.contains(p.categoryId))
        .toList();
    options.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return options;
  }

  void _toggleAccount(int id, bool value) {
    setState(() {
      if (value) {
        _selectedAccountIds.add(id);
      } else {
        _selectedAccountIds.remove(id);
      }
    });
  }

  void _toggleYear(int year, bool value) {
    setState(() {
      if (value) {
        _selectedYears.add(year);
      } else {
        _selectedYears.remove(year);
      }
    });
  }

  void _toggleCategory(
      int id, bool value, List<Category> allCategories, List<Payee> allPayees) {
    setState(() {
      if (value) {
        _selectedCategoryIds.add(id);
      } else {
        _selectedCategoryIds.remove(id);
      }
      final validSubIds = _subCategoryOptions(allCategories).map((c) => c.id).toSet();
      _selectedSubCategoryIds.removeWhere((sid) => !validSubIds.contains(sid));
      final validPayeeIds = _payeeOptions(allPayees).map((p) => p.id).toSet();
      _selectedPayeeIds.removeWhere((pid) => !validPayeeIds.contains(pid));
    });
  }

  void _toggleSubCategory(int id, bool value, List<Payee> allPayees) {
    setState(() {
      if (value) {
        _selectedSubCategoryIds.add(id);
      } else {
        _selectedSubCategoryIds.remove(id);
      }
      final validPayeeIds = _payeeOptions(allPayees).map((p) => p.id).toSet();
      _selectedPayeeIds.removeWhere((pid) => !validPayeeIds.contains(pid));
    });
  }

  void _togglePayee(int id, bool value) {
    setState(() {
      if (value) {
        _selectedPayeeIds.add(id);
      } else {
        _selectedPayeeIds.remove(id);
      }
    });
  }

  /// Backs every filter section's "Tout" / "Aucun" pair - [target] is
  /// whichever selection set the section owns, [options] the ids currently
  /// offered by that section (so "Tout" only ever selects what's actually
  /// visible, not stale ids hidden by a narrower upstream filter).
  void _selectAll(Set<int> target, Iterable<int> options) {
    setState(() => target.addAll(options));
  }

  void _selectNone(Set<int> target) {
    setState(() => target.clear());
  }

  void _resetFilters() {
    setState(() {
      _selectedAccountIds.clear();
      _selectedYears.clear();
      _selectedCategoryIds.clear();
      _selectedSubCategoryIds.clear();
      _selectedPayeeIds.clear();
      _results = null;
    });
  }

  /// A checked category with no specific sub-category checked underneath it
  /// rolls up to that category plus all its direct children - covers the
  /// common case ("I want everything under Boucherie") without another
  /// click per sub-category. But if the user *has* narrowed down to
  /// specific sub-categories of that same parent, only those specific ones
  /// count - the other, unchecked siblings are deliberately left out
  /// (confirmed 2026-08-28: a flat union of category+sub-category ids with
  /// no per-parent rollup meant checking a category alone, with nothing
  /// checked below it, matched only transactions tagged directly to the
  /// parent itself - normally close to none, since real spending almost
  /// always lands on a leaf sub-category - which read as "the filter does
  /// nothing"; a straight per-parent auto-rollup regardless of sub-category
  /// picks was rejected earlier the same day for silently including
  /// siblings the user hadn't chosen).
  void _applyFilters(MmexRepository repo, List<Category> allCategories) {
    final effectiveCategoryIds = <int>{};
    for (final catId in _selectedCategoryIds) {
      final childIds = allCategories
          .where((c) => c.parentId == catId)
          .map((c) => c.id)
          .toSet();
      final selectedChildren = _selectedSubCategoryIds.intersection(childIds);
      if (selectedChildren.isEmpty) {
        effectiveCategoryIds.add(catId);
        effectiveCategoryIds.addAll(childIds);
      } else {
        effectiveCategoryIds.addAll(selectedChildren);
      }
    }
    // Safety net for a sub-category checked whose own parent isn't checked
    // (possible: with no category checked, every sub-category is offered).
    effectiveCategoryIds.addAll(_selectedSubCategoryIds);

    setState(() {
      _results = repo.getTransactionsFiltered(
        years: _selectedYears.isEmpty ? null : _selectedYears.toList(),
        categoryIds:
            effectiveCategoryIds.isEmpty ? null : effectiveCategoryIds.toList(),
        payeeIds: _selectedPayeeIds.isEmpty ? null : _selectedPayeeIds.toList(),
        accountIds:
            _selectedAccountIds.isEmpty ? null : _selectedAccountIds.toList(),
      );
    });
  }

  /// Exports exactly the filtered [rows] behind the chart/table - same
  /// cross-platform `FilePicker.saveFile` + UTF-8-BOM + RFC-4180-escaping
  /// pattern already used by the ledger's own CSV export
  /// (transactions_screen.dart's `_exportLedgerCsv`/`_csvField`) and the AI
  /// chat's (nl_query_dialog.dart) - duplicated rather than shared since
  /// each is small, private, and lives in an otherwise-unrelated file. No
  /// "Solde après" column here (unlike the ledger export): this list spans
  /// every account, so there's no single running balance to show.
  Future<void> _exportResultsCsv(
    BuildContext context, {
    required List<MoneyTransaction> rows,
    required Map<int, Account> accountsById,
    required Map<int, Category> categoriesById,
    required Map<int, Payee> payeesById,
  }) async {
    final buffer =
        StringBuffer('Date,Compte,Tiers,Catégorie,Débit,Crédit,Statut,Notes\n');
    for (final t in rows) {
      final isCredit = t.transCode == TransCode.deposit;
      final statut = t.isVoid
          ? 'Annulée'
          : t.isReconciled
              ? 'Pointée'
              : '';
      final fields = [
        DateFormat('dd/MM/yyyy').format(t.date),
        accountsById[t.accountId]?.name ?? '',
        payeesById[t.payeeId]?.name ?? '',
        categoriesById[t.categoryId]?.name ?? '',
        isCredit ? '' : t.amount.toStringAsFixed(2),
        isCredit ? t.amount.toStringAsFixed(2) : '',
        statut,
        t.notes ?? '',
      ];
      buffer.write('${fields.map(_csvField).join(',')}\n');
    }
    final timestamp = DateFormat('yyyy-MM-dd_HHmmss').format(DateTime.now());
    try {
      await FilePicker.saveFile(
        fileName: 'explorateur_depenses_$timestamp.csv',
        bytes: Uint8List.fromList(
            [0xEF, 0xBB, 0xBF, ...utf8.encode(buffer.toString())]),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Échec de l'export CSV : $e")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final dbProvider = context.watch<DatabaseProvider>();
    final repo = dbProvider.repository!;
    final currency = repo.getBaseCurrency();
    final allCategories = repo.getCategories(onlyActive: false);
    final allPayees = repo.getPayees(onlyActive: false);
    final accounts = repo.getAccounts()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final accountsById = {for (final a in accounts) a.id: a};
    final categoriesById = {for (final c in allCategories) c.id: c};
    final payeesById = {for (final p in allPayees) p.id: p};

    final yearRange = repo.transactionYearRangeAll();
    final years = yearRange == null
        ? <int>[]
        : [for (var y = yearRange.max; y >= yearRange.min; y--) y];

    final parentCategories = allCategories.where((c) => c.parentId == null).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final subCategoryOptions = _subCategoryOptions(allCategories);
    final payeeOptions = _payeeOptions(allPayees);

    final results = _results;

    return Scaffold(
      appBar: AppBar(title: const Text('Explorateur de dépenses')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
        children: [
          _filterSection(
            title: 'Compte',
            icon: Icons.account_balance_outlined,
            selectedCount: _selectedAccountIds.length,
            onSelectAll: () =>
                _selectAll(_selectedAccountIds, accounts.map((a) => a.id)),
            onSelectNone: () => _selectNone(_selectedAccountIds),
            items: [
              for (final a in accounts)
                CheckboxListTile(
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _selectedAccountIds.contains(a.id),
                  onChanged: (v) => _toggleAccount(a.id, v ?? false),
                  title: Text(a.name),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _filterSection(
            title: 'Année',
            icon: Icons.calendar_today_outlined,
            selectedCount: _selectedYears.length,
            onSelectAll: () => _selectAll(_selectedYears, years),
            onSelectNone: () => _selectNone(_selectedYears),
            items: [
              for (final y in years)
                CheckboxListTile(
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _selectedYears.contains(y),
                  onChanged: (v) => _toggleYear(y, v ?? false),
                  title: Text('$y'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _filterSection(
            title: 'Catégorie',
            icon: Icons.category_outlined,
            selectedCount: _selectedCategoryIds.length,
            onSelectAll: () => _selectAll(
                _selectedCategoryIds, parentCategories.map((c) => c.id)),
            onSelectNone: () => _selectNone(_selectedCategoryIds),
            items: [
              for (final c in parentCategories)
                CheckboxListTile(
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _selectedCategoryIds.contains(c.id),
                  onChanged: (v) =>
                      _toggleCategory(c.id, v ?? false, allCategories, allPayees),
                  title: Text(c.name),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _filterSection(
            title: 'Sous-catégorie',
            icon: Icons.subdirectory_arrow_right,
            selectedCount: _selectedSubCategoryIds.length,
            onSelectAll: () => _selectAll(
                _selectedSubCategoryIds, subCategoryOptions.map((c) => c.id)),
            onSelectNone: () => _selectNone(_selectedSubCategoryIds),
            items: [
              for (final c in subCategoryOptions)
                CheckboxListTile(
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _selectedSubCategoryIds.contains(c.id),
                  onChanged: (v) => _toggleSubCategory(c.id, v ?? false, allPayees),
                  title: Text(c.name),
                ),
            ],
            emptyLabel: subCategoryOptions.isEmpty
                ? 'Aucune sous-catégorie pour ce filtre.'
                : null,
          ),
          const SizedBox(height: 12),
          _filterSection(
            title: 'Tiers',
            icon: Icons.people_outline,
            selectedCount: _selectedPayeeIds.length,
            onSelectAll: () =>
                _selectAll(_selectedPayeeIds, payeeOptions.map((p) => p.id)),
            onSelectNone: () => _selectNone(_selectedPayeeIds),
            items: [
              for (final p in payeeOptions)
                CheckboxListTile(
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _selectedPayeeIds.contains(p.id),
                  onChanged: (v) => _togglePayee(p.id, v ?? false),
                  title: Text(p.name),
                ),
            ],
            emptyLabel: payeeOptions.isEmpty ? 'Aucun tiers pour ce filtre.' : null,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.filter_alt_outlined),
                  label: const Text('Appliquer les filtres'),
                  onPressed: () => _applyFilters(repo, allCategories),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: _resetFilters,
                child: const Text('Réinitialiser'),
              ),
            ],
          ),
          if (results != null) ...[
            const SizedBox(height: 20),
            if (results.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text('Aucune opération pour ces filtres.')),
              )
            else ...[
              Row(
                children: [
                  Expanded(
                    child: Text('${results.length} opération(s)',
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  IconButton(
                    icon: const Icon(Icons.download_outlined),
                    tooltip: 'Exporter en CSV',
                    onPressed: () => _exportResultsCsv(
                      context,
                      rows: results,
                      accountsById: accountsById,
                      categoriesById: categoriesById,
                      payeesById: payeesById,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
                  child: SizedBox(
                    height: 360,
                    child: _MonthlyStackedBarChart(
                      transactions: results,
                      categoriesById: categoriesById,
                      payeesById: payeesById,
                      currency: currency,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: results.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final t = results[results.length - 1 - i];
                    return TransactionTile(
                      transaction: t,
                      payee: payeesById[t.payeeId],
                      category: categoriesById[t.categoryId],
                      fromAccount: accountsById[t.accountId],
                      toAccount: t.toAccountId != null
                          ? accountsById[t.toAccountId]
                          : null,
                      currency: currency,
                    );
                  },
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _filterSection({
    required String title,
    required IconData icon,
    required int selectedCount,
    required List<Widget> items,
    required VoidCallback onSelectAll,
    required VoidCallback onSelectNone,
    String? emptyLabel,
  }) {
    return Card(
      child: ExpansionTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(
            selectedCount == 0 ? 'Tous' : '$selectedCount sélectionné(s)'),
        children: [
          if (emptyLabel != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(emptyLabel, style: TextStyle(color: Colors.grey[600])),
              ),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 16, 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: items.isEmpty ? null : onSelectAll,
                    child: const Text('Tout sélectionner'),
                  ),
                  TextButton(
                    onPressed: selectedCount == 0 ? null : onSelectNone,
                    child: const Text('Aucun'),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: (items.length * 48.0).clamp(48.0, 280.0),
              child: ListView(
                padding: EdgeInsets.zero,
                children: items,
              ),
            ),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// One stacked segment's identity within a month: the pairing of category
/// and payee, so a bar breaks down by both - e.g. two different tiers
/// ("Carrefour", "Hello Fresh") in the same category show as two separate
/// segments instead of merging into one indistinguishable block (confirmed
/// 2026-08-28 after a category-only version made a same-category, several-
/// tiers selection look like a single flat colour with no tier detail).
typedef _StackKey = ({int categoryId, int payeeId});

class _MonthBucket {
  final int year;
  final int month;
  final Map<_StackKey, double> byKey = {};

  _MonthBucket(this.year, this.month);

  String label(bool showYear) {
    final date = DateTime(year, month);
    return showYear
        ? DateFormat('MMM yy', 'fr_FR').format(date)
        : DateFormat('MMM', 'fr_FR').format(date);
  }
}

/// Distinct colours cycled across whichever categories actually appear in
/// the filtered results - not tied to [AppTheme], which only defines a
/// fixed positive/negative/warning triad, not a category palette.
const _stackPalette = <Color>[
  Color(0xFF5B6CFF),
  Color(0xFF10B981),
  Color(0xFFF79009),
  Color(0xFFF04438),
  Color(0xFF06B6D4),
  Color(0xFFA855F7),
  Color(0xFFEC4899),
  Color(0xFF84CC16),
  Color(0xFF64748B),
  Color(0xFFEAB308),
  Color(0xFF3B82F6),
  Color(0xFF14B8A6),
];

/// Vertical stacked bar chart: one bar per month touched by [transactions]
/// (year shown in the label only when the results span more than one
/// year), each bar stacking its (category, tiers) pairs' cumulated signed
/// amount - positive (income) segments stacked upward from zero, negative
/// (expense) segments stacked downward - with a hover tooltip naming the
/// specific category/tiers segment under the pointer.
///
/// fl_chart's [BarTouchTooltipData.getTooltipItem] callback isn't told
/// which stacked segment is being hovered (only the group/rod) - that
/// information ([BarTouchedSpot.touchedStackItemIndex]) only reaches
/// [BarTouchData.touchCallback]. So the hovered group/stack index is
/// captured there into local state, and [getTooltipItem] reads it back -
/// the two fire from the same pointer event, so they stay in sync.
class _MonthlyStackedBarChart extends StatefulWidget {
  final List<MoneyTransaction> transactions;
  final Map<int, Category> categoriesById;
  final Map<int, Payee> payeesById;
  final CurrencyFormat? currency;

  const _MonthlyStackedBarChart({
    required this.transactions,
    required this.categoriesById,
    required this.payeesById,
    required this.currency,
  });

  @override
  State<_MonthlyStackedBarChart> createState() => _MonthlyStackedBarChartState();
}

class _MonthlyStackedBarChartState extends State<_MonthlyStackedBarChart> {
  int? _hoverGroupIndex;
  int? _hoverStackIndex;

  @override
  Widget build(BuildContext context) {
    final bucketsByMonthKey = <String, _MonthBucket>{};
    for (final t in widget.transactions) {
      final monthKey = '${t.date.year}-${t.date.month}';
      final bucket = bucketsByMonthKey.putIfAbsent(
          monthKey, () => _MonthBucket(t.date.year, t.date.month));
      // Withdrawals (spending, the dominant case for this screen) stack
      // upward from a zero baseline at the bottom of the chart - deposits
      // stack downward below it - the opposite of signedAmountFor's usual
      // account-viewpoint convention (deposit positive), which instead put
      // 0 at the top with spend hanging below it. Confirmed 2026-08-28:
      // the account-viewpoint convention read as "upside down" here since
      // this screen is analysis-only, not a specific account's ledger.
      final signed = t.transCode == TransCode.withdrawal ? t.amount : -t.amount;
      final stackKey = (categoryId: t.categoryId ?? -1, payeeId: t.payeeId);
      bucket.byKey[stackKey] = (bucket.byKey[stackKey] ?? 0) + signed;
    }
    final buckets = bucketsByMonthKey.values.toList()
      ..sort((a, b) {
        final c = a.year.compareTo(b.year);
        return c != 0 ? c : a.month.compareTo(b.month);
      });

    if (buckets.isEmpty) {
      return const Center(child: Text('Aucune opération pour ces filtres.'));
    }

    final showYear = buckets.map((b) => b.year).toSet().length > 1;

    final keys = <_StackKey>{};
    for (final b in buckets) {
      keys.addAll(b.byKey.keys);
    }
    final sortedKeys = keys.toList()
      ..sort((a, b) {
        final c = a.categoryId.compareTo(b.categoryId);
        return c != 0 ? c : a.payeeId.compareTo(b.payeeId);
      });
    Color colorFor(_StackKey key) =>
        _stackPalette[sortedKeys.indexOf(key) % _stackPalette.length];
    String payeeNameFor(int payeeId) =>
        widget.payeesById[payeeId]?.name ?? 'Tiers inconnu';
    String categoryNameFor(int categoryId) => categoryId == -1
        ? 'Non catégorisé'
        : (widget.categoriesById[categoryId]?.name ?? 'Catégorie inconnue');
    String legendLabelFor(_StackKey key) =>
        '${payeeNameFor(key.payeeId)} (${categoryNameFor(key.categoryId)})';

    final stackKeysByGroup = <List<_StackKey>>[];

    return LayoutBuilder(builder: (context, constraints) {
      // Only fall back to a horizontal scroll (and a floor on per-group
      // width) when there are enough months that the natural width would
      // squeeze bars unreadably thin - otherwise stretch to fill the full
      // card width instead of an arbitrary 96px cap, which used to leave
      // most of a wide desktop card empty (confirmed 2026-08-28).
      final naturalPerGroup = constraints.maxWidth / buckets.length;
      final perGroup = naturalPerGroup < 56.0 ? 56.0 : naturalPerGroup;
      final chartWidth = perGroup * buckets.length;
      final barWidth = (perGroup * 0.45).clamp(14.0, 72.0);

      final barGroups = <BarChartGroupData>[];
      stackKeysByGroup.clear();
      var maxY = 0.0;
      var minY = 0.0;

      for (var i = 0; i < buckets.length; i++) {
        final bucket = buckets[i];
        final stackItems = <BarChartRodStackItem>[];
        final stackKeysForGroup = <_StackKey>[];
        double negCum = 0;
        double posCum = 0;
        for (final key in sortedKeys) {
          final v = bucket.byKey[key];
          if (v == null || v == 0) continue;
          final color = colorFor(key);
          if (v > 0) {
            final from = posCum;
            posCum += v;
            stackItems.add(BarChartRodStackItem(from, posCum, color));
          } else {
            final to = negCum;
            negCum += v;
            stackItems.add(BarChartRodStackItem(negCum, to, color));
          }
          stackKeysForGroup.add(key);
        }
        if (posCum > maxY) maxY = posCum;
        if (negCum < minY) minY = negCum;
        stackKeysByGroup.add(stackKeysForGroup);
        barGroups.add(BarChartGroupData(
          x: i,
          barRods: [
            BarChartRodData(
              fromY: negCum,
              toY: posCum,
              rodStackItems: stackItems,
              width: barWidth,
              borderRadius: BorderRadius.zero,
            ),
          ],
        ));
      }

      final maxYPadded = maxY <= 0 ? 10.0 : maxY * 1.15;
      final minYPadded = minY >= 0 ? 0.0 : minY * 1.15;

      final chart = BarChart(
        BarChartData(
          maxY: maxYPadded,
          minY: minYPadded,
          alignment: BarChartAlignment.spaceAround,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) =>
                FlLine(color: Colors.grey.withValues(alpha: 0.2), strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 60,
                getTitlesWidget: (value, meta) => Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Text(
                    widget.currency?.format(value) ?? value.toStringAsFixed(0),
                    style: const TextStyle(fontSize: 9),
                  ),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 32,
                interval: 1,
                getTitlesWidget: (value, meta) {
                  final i = value.round();
                  if (i < 0 || i >= buckets.length) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      buckets[i].label(showYear),
                      style: const TextStyle(fontSize: 10),
                    ),
                  );
                },
              ),
            ),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              maxContentWidth: 220,
              fitInsideHorizontally: true,
              fitInsideVertically: true,
              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                final stackIndex = _hoverStackIndex;
                if (stackIndex == null ||
                    stackIndex < 0 ||
                    groupIndex != _hoverGroupIndex) {
                  return null;
                }
                final keysForGroup = stackKeysByGroup[groupIndex];
                if (stackIndex >= keysForGroup.length) return null;
                final key = keysForGroup[stackIndex];
                final value = buckets[groupIndex].byKey[key] ?? 0;
                final formatted =
                    widget.currency?.format(value) ?? value.toStringAsFixed(2);
                return BarTooltipItem(
                  '${payeeNameFor(key.payeeId)}\n${categoryNameFor(key.categoryId)}\n'
                  '${buckets[groupIndex].label(true)} : $formatted',
                  const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                );
              },
            ),
            touchCallback: (event, response) {
              final spot = response?.spot;
              setState(() {
                _hoverGroupIndex = spot?.touchedBarGroupIndex;
                _hoverStackIndex = spot?.touchedStackItemIndex;
              });
            },
          ),
          barGroups: barGroups,
        ),
      );

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(width: chartWidth, child: chart),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            children: [
              for (final key in sortedKeys)
                _LegendDot(color: colorFor(key), label: legendLabelFor(key)),
            ],
          ),
        ],
      );
    });
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

/// Escapes one CSV field per RFC 4180 - see transactions_screen.dart's
/// identical helper (and its own doc comment) for why embedded newlines are
/// collapsed to a single space before the quoting check, rather than kept
/// as a legal-but-confusing multi-line quoted field.
String _csvField(Object? value) {
  if (value == null) return '';
  final text = value.toString().replaceAll(RegExp(r'[\n\r]+'), ' ').trim();
  if (text.contains(RegExp('[,"]'))) {
    return '"${text.replaceAll('"', '""')}"';
  }
  return text;
}
