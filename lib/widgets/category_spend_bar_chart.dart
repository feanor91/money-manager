import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/mmex_repository.dart';
import '../models/budget_period.dart';
import '../models/category.dart';
import '../models/currency.dart';
import '../models/recurrence.dart';
import '../models/transaction.dart';
import '../theme/app_theme.dart';
import 'bento_card.dart';
import 'envelope_gauge.dart' show forecastColor;
import 'transaction_tile.dart';

DateTime _addDays(DateTime date, int days) => DateTime(date.year, date.month, date.day + days);

/// [count] budget windows before [window] (see budget_period.dart) -
/// chained one month at a time so each step gets the same day-of-month
/// clamping as a single [previousBudgetWindow] call.
BudgetWindow _stepBackBudgetWindows(BudgetWindow window, int count, int anchorDay) {
  var w = window;
  for (var i = 0; i < count; i++) {
    w = previousBudgetWindow(w, anchorDay);
  }
  return w;
}

/// Width of the trailing window shown, always ending on "today" (or on a
/// past window when scrolled back - see [_CategorySpendBarChartState]).
enum _WindowDuration { oneMonth, twoMonths, threeMonths, sixMonths, oneYear }

extension on _WindowDuration {
  int get months => switch (this) {
        _WindowDuration.oneMonth => 1,
        _WindowDuration.twoMonths => 2,
        _WindowDuration.threeMonths => 3,
        _WindowDuration.sixMonths => 6,
        _WindowDuration.oneYear => 12,
      };

  String get label => switch (this) {
        _WindowDuration.oneMonth => '1 mois',
        _WindowDuration.twoMonths => '2 mois',
        _WindowDuration.threeMonths => '3 mois',
        _WindowDuration.sixMonths => '6 mois',
        _WindowDuration.oneYear => '1 an',
      };
}

class _BarItem {
  final String name;
  final double spent;
  final double planned;

  /// The category itself plus its direct children - same set [rolledUpSpend]
  /// summed over to produce [spent]/[planned], reused to fetch the actual
  /// operations behind a tapped bar (see [_CategorySpendBarChartState._showBarDetail]).
  final List<int> categoryIds;

  _BarItem({
    required this.name,
    required this.spent,
    required this.planned,
    required this.categoryIds,
  });

  double get tallest => spent > planned ? spent : planned;
}

/// Bento card showing, per expense category, real spending against planned
/// spending (derived from recurring transactions, same basis as
/// [MmexRepository.categoryMonthlyRecurringTotals] - the budget screen's
/// "auto" envelope target) - dépensé vs prévu, side by side, sorted from
/// the biggest category down. Categories with neither any real spend nor
/// any recurring bill in the window are left out entirely rather than
/// padding the chart with empty bars. Tapping a bar lists the operations
/// (real transactions, or recurring bill templates for "prévu") that make
/// up its total - see [_showBarDetail].
///
/// Navigation mirrors [ForecastChart]'s duration dropdown + left/right
/// paging, but this chart never projects into the future the way that one
/// does: the window always ends on the current "Jour de prévision du
/// solde" (Settings) - not literally today - or on a past window once
/// scrolled back via the left arrow, and only ever shows real, already-
/// recorded spend - "prévu" here means the recurring schedule's monthly
/// rate scaled to the window's length, not a day-by-day projection. See
/// [_stepBackBudgetWindows] for why windows are anchored on that day
/// instead of calendar months.
class CategorySpendBarChart extends StatefulWidget {
  final MmexRepository repository;
  final CurrencyFormat? currency;
  final int? accountId;
  final int forecastDay;

  const CategorySpendBarChart({
    super.key,
    required this.repository,
    this.currency,
    this.accountId,
    required this.forecastDay,
  });

  @override
  State<CategorySpendBarChart> createState() => _CategorySpendBarChartState();
}

class _CategorySpendBarChartState extends State<CategorySpendBarChart> {
  _WindowDuration _duration = _WindowDuration.oneMonth;

  /// How many [_duration]-wide windows back from today the visible window
  /// is shifted - always <= 0 (today is the window's own end at 0, and the
  /// right arrow can only step back *toward* today, never past it: there's
  /// no "planned" concept for a future window here, unlike ForecastChart).
  int _offsetSteps = 0;

  @override
  Widget build(BuildContext context) {
    final repo = widget.repository;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // Windows are "full months" anchored on the day *after* the "Jour de
    // prévision du solde" (Settings) through that same day next month -
    // e.g. forecastDay=24 gives 25 June to 24 July - rather than calendar
    // months, so they line up with the user's own pay cycle the same way
    // BudgetWindow (budget_period.dart) does. Built by shifting a chain of
    // BudgetWindows forward by one day: BudgetWindow itself is defined as
    // [forecastDay, nextForecastDay) (start inclusive on the day itself,
    // end exclusive) - shifting both ends by +1 day turns that into
    // (forecastDay, nextForecastDay] as a half-open [start, end) pair,
    // i.e. exactly "day-after through day-inclusive", while preserving the
    // half-open tiling (window N's end is window N+1's start) that avoids
    // double-counting a transaction dated exactly on the boundary.
    final currentBudgetWindow = budgetWindowContaining(today, widget.forecastDay);
    final endBudgetWindow =
        _stepBackBudgetWindows(currentBudgetWindow, -_offsetSteps * _duration.months, widget.forecastDay);
    final startBudgetWindow = _stepBackBudgetWindows(endBudgetWindow, _duration.months - 1, widget.forecastDay);
    final windowStart = _addDays(startBudgetWindow.start, 1);
    final windowEndExclusive = _addDays(endBudgetWindow.end, 1);
    final windowEndInclusive = _addDays(windowEndExclusive, -1);

    final categories = repo.getCategories(onlyActive: false);
    final rawSpend = repo.categorySpendForPeriod(
      windowStart,
      windowEndExclusive,
      accountId: widget.accountId,
    );
    final recurringMonthly = repo.categoryMonthlyRecurringTotals(accountId: widget.accountId);

    final items = <_BarItem>[];
    for (final c in categories.where((c) => c.parentId == null)) {
      final spent = rolledUpSpend(c.id, rawSpend, categories);
      final planned = rolledUpSpend(c.id, recurringMonthly, categories) * _duration.months;
      if (spent == 0 && planned == 0) continue;
      final childIds = categories.where((x) => x.parentId == c.id).map((x) => x.id);
      items.add(_BarItem(
        name: c.name,
        spent: spent,
        planned: planned,
        categoryIds: [c.id, ...childIds],
      ));
    }
    items.sort((a, b) => b.tallest.compareTo(a.tallest));

    return BentoCard(
      title: 'Dépenses par catégorie',
      trailing: _RangeLabel(start: windowStart, end: windowEndInclusive),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<_WindowDuration>(
                  initialValue: _duration,
                  isDense: true,
                  decoration: const InputDecoration(
                    labelText: 'Période affichée',
                    isDense: true,
                  ),
                  items: [
                    for (final d in _WindowDuration.values)
                      DropdownMenuItem(value: d, child: Text(d.label)),
                  ],
                  onChanged: (d) {
                    if (d == null) return;
                    setState(() {
                      _duration = d;
                      _offsetSteps = 0;
                    });
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: 'Période précédente',
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _offsetSteps -= 1),
                icon: const Icon(Icons.chevron_left),
              ),
              TextButton.icon(
                onPressed: _offsetSteps == 0 ? null : () => setState(() => _offsetSteps = 0),
                icon: const Icon(Icons.today, size: 16),
                label: const Text('Aujourd\'hui'),
              ),
              IconButton(
                tooltip: 'Période suivante',
                visualDensity: VisualDensity.compact,
                onPressed: _offsetSteps == 0 ? null : () => setState(() => _offsetSteps += 1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _LegendDot(color: AppTheme.negative, label: 'Dépensé'),
              SizedBox(width: 16),
              _LegendDot(color: forecastColor, label: 'Prévu'),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: items.isEmpty
                ? const Center(child: Text('Aucune dépense sur cette période.'))
                : LayoutBuilder(
                    builder: (context, constraints) => _buildChart(
                      items,
                      widget.currency,
                      constraints.maxWidth,
                      windowStart,
                      windowEndExclusive,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildChart(
    List<_BarItem> items,
    CurrencyFormat? currency,
    double availableWidth,
    DateTime windowStart,
    DateTime windowEndExclusive,
  ) {
    final maxVal = items.fold(0.0, (m, it) => it.tallest > m ? it.tallest : m);
    final maxY = maxVal <= 0 ? 10.0 : maxVal * 1.2;

    // Scale bar width with however much horizontal room each category
    // actually has, instead of a fixed width that looks fine with a dozen
    // categories but leaves a wide desktop card mostly empty when there are
    // only two or three.
    final perGroup = availableWidth / items.length;
    final barWidth = (perGroup * 0.28).clamp(14.0, 46.0);

    return BarChart(
      BarChartData(
        maxY: maxY,
        alignment: BarChartAlignment.spaceAround,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) => FlLine(color: Colors.grey.withValues(alpha: 0.25), strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 64,
              interval: 1,
              getTitlesWidget: (value, meta) {
                final i = value.round();
                if (i < 0 || i >= items.length) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Transform.rotate(
                    angle: -0.6,
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                      width: 72,
                      child: Text(
                        items[i].name,
                        style: const TextStyle(fontSize: 9),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
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
              final item = items[group.x.toInt()];
              final isSpent = rodIndex == 0;
              final value = isSpent ? item.spent : item.planned;
              final label = isSpent ? 'Dépensé' : 'Prévu';
              final formatted = currency?.format(value) ?? value.toStringAsFixed(2);
              return BarTooltipItem(
                '${item.name}\n$label : $formatted',
                const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              );
            },
          ),
          touchCallback: (event, response) {
            if (event is! FlTapUpEvent) return;
            final spot = response?.spot;
            if (spot == null) return;
            final item = items[spot.touchedBarGroupIndex];
            final isSpent = spot.touchedRodDataIndex == 0;
            _showBarDetail(item, isSpent, windowStart, windowEndExclusive);
          },
        ),
        barGroups: [
          for (var i = 0; i < items.length; i++)
            BarChartGroupData(
              x: i,
              barsSpace: 3,
              barRods: [
                BarChartRodData(
                  toY: items[i].spent,
                  color: AppTheme.negative,
                  width: barWidth,
                  borderRadius: BorderRadius.zero,
                ),
                if (items[i].planned > 0)
                  BarChartRodData(
                    toY: items[i].planned,
                    color: forecastColor,
                    width: barWidth,
                    borderRadius: BorderRadius.zero,
                  ),
              ],
            ),
        ],
      ),
    );
  }

  /// Lists the real operations (or, for "prévu", the recurring bill
  /// templates) that add up to a tapped bar - the same rolled-up category
  /// set (see [_BarItem.categoryIds]) and window the bar's own total was
  /// computed from, so the numbers always match what's on screen.
  void _showBarDetail(
    _BarItem item,
    bool isSpent,
    DateTime windowStart,
    DateTime windowEndExclusive,
  ) {
    final repo = widget.repository;
    final payees = {for (final p in repo.getPayees(onlyActive: false)) p.id: p};

    if (isSpent) {
      final accounts = {for (final a in repo.getAccounts()) a.id: a};
      final categoriesById = {for (final c in repo.getCategories(onlyActive: false)) c.id: c};
      final txns = repo
          .getTransactions(
            accountId: widget.accountId,
            from: windowStart,
            to: windowEndExclusive,
            limit: 1000,
          )
          .where((t) =>
              t.transCode == TransCode.withdrawal &&
              !t.isVoid &&
              t.categoryId != null &&
              item.categoryIds.contains(t.categoryId))
          .toList();

      _openDetailSheet(
        title: item.name,
        subtitle: 'Dépensé',
        itemCount: txns.length,
        itemBuilder: (context, i) {
          final t = txns[i];
          return TransactionTile(
            transaction: t,
            payee: payees[t.payeeId],
            category: categoriesById[t.categoryId],
            fromAccount: accounts[t.accountId],
            toAccount: t.toAccountId != null ? accounts[t.toAccountId] : null,
            viewpointAccountId: widget.accountId,
            currency: widget.currency,
          );
        },
      );
    } else {
      final bills = repo.getBillDeposits().where((b) =>
          !b.paused &&
          b.transCode == TransCode.withdrawal &&
          b.categoryId != null &&
          item.categoryIds.contains(b.categoryId) &&
          (widget.accountId == null || b.accountId == widget.accountId)).toList();

      _openDetailSheet(
        title: item.name,
        subtitle: 'Prévu (opérations récurrentes)',
        itemCount: bills.length,
        itemBuilder: (context, i) {
          final b = bills[i];
          return ListTile(
            title: Text(payees[b.payeeId]?.name ?? 'Tiers inconnu'),
            subtitle: Text(recurrencePeriodLabel(b.period)),
            trailing: Text(
              widget.currency?.format(b.amount) ?? b.amount.toStringAsFixed(2),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          );
        },
      );
    }
  }

  void _openDetailSheet({
    required String title,
    required String subtitle,
    required int itemCount,
    required Widget Function(BuildContext, int) itemBuilder,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (context, scrollController) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey)),
              const SizedBox(height: 8),
              Expanded(
                child: itemCount == 0
                    ? const Center(child: Text('Aucune opération sur cette période.'))
                    : ListView.separated(
                        controller: scrollController,
                        itemCount: itemCount,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: itemBuilder,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
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

class _RangeLabel extends StatelessWidget {
  final DateTime start;
  final DateTime end;

  const _RangeLabel({required this.start, required this.end});

  @override
  Widget build(BuildContext context) {
    final format = DateFormat('d MMMM yyyy', 'fr_FR');
    return Text(
      '${format.format(start)} - ${format.format(end)}',
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
