import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/mmex_repository.dart';
import '../models/category.dart';
import '../models/currency.dart';
import '../theme/app_theme.dart';
import 'bento_card.dart';
import 'envelope_gauge.dart' show forecastColor;

/// Adds [months] calendar months to [date], clamping the day of month to
/// the destination month's actual last day when it doesn't have one - same
/// helper as ForecastChart's (kept separate rather than shared/exported,
/// per this file's own self-contained date window rather than reusing
/// ForecastChart's forward-looking one).
DateTime _addMonths(DateTime date, int months) {
  final total = date.year * 12 + (date.month - 1) + months;
  final year = total ~/ 12;
  final month = total % 12 + 1;
  final lastDayOfMonth = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, date.day > lastDayOfMonth ? lastDayOfMonth : date.day);
}

DateTime _addDays(DateTime date, int days) => DateTime(date.year, date.month, date.day + days);

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

  _BarItem({required this.name, required this.spent, required this.planned});

  double get tallest => spent > planned ? spent : planned;
}

/// Bento card showing, per expense category, real spending against planned
/// spending (derived from recurring transactions, same basis as
/// [MmexRepository.categoryMonthlyRecurringTotals] - the budget screen's
/// "auto" envelope target) - dépensé vs prévu, side by side, sorted from
/// the biggest category down. Categories with neither any real spend nor
/// any recurring bill in the window are left out entirely rather than
/// padding the chart with empty bars.
///
/// Navigation mirrors [ForecastChart]'s duration dropdown + left/right
/// paging, but this chart never projects into the future the way that one
/// does: the window always ends on "today" (or on a past window once
/// scrolled back via the left arrow) and only ever shows real, already-
/// recorded spend - "prévu" here means the recurring schedule's monthly
/// rate scaled to the window's length, not a day-by-day projection.
class CategorySpendBarChart extends StatefulWidget {
  final MmexRepository repository;
  final CurrencyFormat? currency;
  final int? accountId;

  const CategorySpendBarChart({
    super.key,
    required this.repository,
    this.currency,
    this.accountId,
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
    final windowEnd = _addMonths(today, _offsetSteps * _duration.months);
    final windowStart = _addMonths(windowEnd, -_duration.months);

    final categories = repo.getCategories(onlyActive: false);
    final rawSpend = repo.categorySpendForPeriod(
      windowStart,
      _addDays(windowEnd, 1),
      accountId: widget.accountId,
    );
    final recurringMonthly = repo.categoryMonthlyRecurringTotals(accountId: widget.accountId);

    final items = <_BarItem>[];
    for (final c in categories.where((c) => c.parentId == null)) {
      final spent = rolledUpSpend(c.id, rawSpend, categories);
      final planned = rolledUpSpend(c.id, recurringMonthly, categories) * _duration.months;
      if (spent == 0 && planned == 0) continue;
      items.add(_BarItem(name: c.name, spent: spent, planned: planned));
    }
    items.sort((a, b) => b.tallest.compareTo(a.tallest));

    return BentoCard(
      title: 'Dépenses par catégorie',
      trailing: _RangeLabel(start: windowStart, end: windowEnd),
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
                : _buildChart(items, widget.currency),
          ),
        ],
      ),
    );
  }

  Widget _buildChart(List<_BarItem> items, CurrencyFormat? currency) {
    final maxVal = items.fold(0.0, (m, it) => it.tallest > m ? it.tallest : m);
    final maxY = maxVal <= 0 ? 10.0 : maxVal * 1.2;

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
        ),
        barGroups: [
          for (var i = 0; i < items.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: items[i].spent,
                  color: AppTheme.negative,
                  width: 10,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                ),
                if (items[i].planned > 0)
                  BarChartRodData(
                    toY: items[i].planned,
                    color: forecastColor,
                    width: 10,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                  ),
              ],
            ),
        ],
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
