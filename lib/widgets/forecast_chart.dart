import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/mmex_repository.dart';
import '../models/currency.dart';
import '../theme/app_theme.dart';
import 'bento_card.dart';

/// Adds [days] *calendar* days to [date] - never `date.add(Duration(days:
/// n))` for this. `Duration` addition is elapsed-time arithmetic in local
/// time, so it drifts by an hour across a DST transition, silently
/// breaking any bucket-map lookup keyed on exact midnight (see the same
/// helper in mmex_repository.dart for the full explanation).
DateTime _addDays(DateTime date, int days) => DateTime(date.year, date.month, date.day + days);

/// Whole calendar days from [a] to [b] (both taken as local dates,
/// ignoring time-of-day). Computed via UTC dates - which have no DST - so
/// a `.difference().inDays` spanning a spring-forward/fall-back transition
/// can't come out one day short or long the way local-time difference can.
int _daysBetween(DateTime a, DateTime b) {
  final utcA = DateTime.utc(a.year, a.month, a.day);
  final utcB = DateTime.utc(b.year, b.month, b.day);
  return utcB.difference(utcA).inDays;
}

/// Adds [months] calendar months to [date], clamping the day of month to
/// the destination month's actual last day when it doesn't have one (e.g.
/// 31 January + 1 month -> 28/29 February).
DateTime _addMonths(DateTime date, int months) {
  final total = date.year * 12 + (date.month - 1) + months;
  final year = total ~/ 12;
  final month = total % 12 + 1;
  final lastDayOfMonth = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, date.day > lastDayOfMonth ? lastDayOfMonth : date.day);
}

/// How far ahead the forecast looks, always starting from today - see
/// [ForecastChart].
enum ForecastDuration { oneMonth, twoMonths, threeMonths, sixMonths, oneYear }

extension on ForecastDuration {
  int get months => switch (this) {
        ForecastDuration.oneMonth => 1,
        ForecastDuration.twoMonths => 2,
        ForecastDuration.threeMonths => 3,
        ForecastDuration.sixMonths => 6,
        ForecastDuration.oneYear => 12,
      };

  String get label => switch (this) {
        ForecastDuration.oneMonth => '1 mois',
        ForecastDuration.twoMonths => '2 mois',
        ForecastDuration.threeMonths => '3 mois',
        ForecastDuration.sixMonths => '6 mois',
        ForecastDuration.oneYear => '1 an',
      };
}

/// One point of the forecast timeline (one calendar day): the real balance
/// for today, or a projection (known recurring transactions only) for every
/// day after.
class _Point {
  final DateTime day;
  final double net;
  final double cumulative;
  final bool projected;

  _Point(this.day, this.net, this.cumulative, this.projected);
}

/// Bento card showing the balance forecast from today forward, over a
/// selectable duration (1/2/3/6/12 months), with an optional "what-if"
/// simulated purchase (one-off or spread over up to 12 monthly
/// installments) overlaid as a second line - never written to the
/// database, purely a client-side projection.
class ForecastChart extends StatefulWidget {
  final MmexRepository repository;
  final CurrencyFormat? currency;
  final double startingBalance;
  final int? accountId;

  const ForecastChart({
    super.key,
    required this.repository,
    required this.startingBalance,
    this.currency,
    this.accountId,
  });

  @override
  State<ForecastChart> createState() => _ForecastChartState();
}

class _ForecastChartState extends State<ForecastChart> {
  ForecastDuration _duration = ForecastDuration.oneMonth;

  /// Chart vs. tabular ("Vue tableau", see ROADMAP.md) view of the same
  /// data - the duration/simulation controls stay the same either way.
  bool _showAsTable = false;

  /// Simulated "what-if" purchase: null means no simulation active.
  double? _simAmount;
  int _simInstallments = 1;

  // `accountBalance(asOf:)` scans the account's whole transaction history -
  // too expensive to redo on every rebuild. It only actually changes once
  // per calendar day, or when the account's data changes - and
  // `widget.startingBalance` (the parent's all-time balance for this
  // account) already changes exactly when the latter happens, so it doubles
  // as a cheap invalidation signal without any extra plumbing.
  int? _cachedBalanceAccountId;
  DateTime? _cachedBalanceDay;
  double? _cachedBalanceInput;
  double _cachedBalance = 0;

  double _balanceAsOfNow(DateTime now) {
    if (widget.accountId == null) return widget.startingBalance;
    final today = DateTime(now.year, now.month, now.day);
    if (_cachedBalanceAccountId == widget.accountId &&
        _cachedBalanceDay == today &&
        _cachedBalanceInput == widget.startingBalance) {
      return _cachedBalance;
    }
    _cachedBalance = widget.repository.accountBalance(widget.accountId!, asOf: now);
    _cachedBalanceAccountId = widget.accountId;
    _cachedBalanceDay = today;
    _cachedBalanceInput = widget.startingBalance;
    return _cachedBalance;
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final points = _buildPoints(now);
    final simulatedPoints = _buildSimulatedPoints(points);
    final currency = widget.currency;

    return BentoCard(
      title: 'Prevision de solde',
      trailing: _RangeLabel(points: points),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<ForecastDuration>(
                  initialValue: _duration,
                  isDense: true,
                  decoration: const InputDecoration(
                    labelText: 'Duree affichee',
                    isDense: true,
                  ),
                  items: [
                    for (final d in ForecastDuration.values)
                      DropdownMenuItem(value: d, child: Text(d.label)),
                  ],
                  onChanged: (d) {
                    if (d == null) return;
                    setState(() => _duration = d);
                  },
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: _showAsTable ? 'Afficher le graphique' : 'Afficher la liste',
                onPressed: () => setState(() => _showAsTable = !_showAsTable),
                icon: Icon(_showAsTable ? Icons.show_chart : Icons.table_rows_outlined),
              ),
              IconButton(
                tooltip: 'Simuler un achat',
                onPressed: () => _openSimulationDialog(context),
                icon: Icon(
                  Icons.add_shopping_cart,
                  color: _simAmount != null ? AppTheme.accent : null,
                ),
              ),
            ],
          ),
          if (_simAmount != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.circle, size: 10, color: Colors.orange.shade700),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _simInstallments > 1
                        ? 'Simulation : ${currency?.format(_simAmount!) ?? _simAmount!.toStringAsFixed(2)} '
                            'en $_simInstallments fois'
                        : 'Simulation : ${currency?.format(_simAmount!) ?? _simAmount!.toStringAsFixed(2)} comptant',
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Effacer la simulation',
                  icon: const Icon(Icons.close, size: 16),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() {
                    _simAmount = null;
                    _simInstallments = 1;
                  }),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Expanded(
            child: _showAsTable
                ? _buildOperationsList(points, currency)
                : _buildChart(points, simulatedPoints, currency),
          ),
        ],
      ),
    );
  }

  /// Every recurring-transaction occurrence within the currently displayed
  /// window, grouped by day (several bills can fall on the same date).
  Map<DateTime, List<RecurringOccurrence>> _groupedOccurrences(List<_Point> points) {
    if (points.isEmpty) return {};
    final occurrences = widget.repository.recurringOccurrencesInRange(
      start: points.first.day,
      end: points.last.day,
      accountId: widget.accountId,
    );
    final grouped = <DateTime, List<RecurringOccurrence>>{};
    for (final occurrence in occurrences) {
      grouped.putIfAbsent(occurrence.date, () => []).add(occurrence);
    }
    return grouped;
  }

  /// Tabular alternative to the chart ("Vue tableau", see ROADMAP.md):
  /// every recurring occurrence in the selected window (plus the simulated
  /// purchase's installments, if any), one row each, styled like
  /// [TransactionTile] - each row also shows that day's running projected
  /// balance (shared across every operation on the same day, since the
  /// underlying data is bucketed by day, not by individual transaction).
  Widget _buildOperationsList(List<_Point> points, CurrencyFormat? currency) {
    if (points.isEmpty) return const SizedBox.shrink();

    final grouped = _groupedOccurrences(points);
    final dayIndex = {for (var i = 0; i < points.length; i++) points[i].day: i};

    final rows = <_ForecastRow>[
      for (final occurrences in grouped.values)
        for (final o in occurrences)
          _ForecastRow(date: o.date, label: o.label, amount: o.signedAmount, simulated: false),
    ];
    if (_simAmount != null) {
      final perInstallment = _simAmount! / _simInstallments;
      for (var i = 0; i < _simInstallments; i++) {
        rows.add(_ForecastRow(
          date: _addMonths(points.first.day, i),
          label: 'Achat simule',
          amount: -perInstallment,
          simulated: true,
        ));
      }
    }
    rows.sort((a, b) => a.date.compareTo(b.date));

    if (rows.isEmpty) {
      return const Center(child: Text('Aucune operation prevue sur cette periode.'));
    }

    final dateFormat = DateFormat('EEEE d MMMM yyyy', 'fr_FR');
    return ListView.separated(
      itemCount: rows.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final row = rows[i];
        final positive = row.amount >= 0;
        final dayBalance = dayIndex[row.date] != null ? points[dayIndex[row.date]!].cumulative : null;
        return ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: CircleAvatar(
            backgroundColor: (positive ? AppTheme.positive : AppTheme.negative).withValues(alpha: 0.12),
            child: Icon(
              row.simulated
                  ? Icons.shopping_cart_outlined
                  : (positive ? Icons.south_west : Icons.north_east),
              color: positive ? AppTheme.positive : AppTheme.negative,
              size: 16,
            ),
          ),
          title: Text(
            row.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontStyle: row.simulated ? FontStyle.italic : FontStyle.normal),
          ),
          subtitle: Text(
            '${dateFormat.format(row.date)}${row.simulated ? ' - simulation' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                currency?.format(row.amount) ?? row.amount.toStringAsFixed(2),
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: positive ? AppTheme.positive : AppTheme.negative,
                ),
              ),
              if (dayBalance != null)
                Text(
                  'Solde : ${currency?.format(dayBalance) ?? dayBalance.toStringAsFixed(2)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openSimulationDialog(BuildContext context) async {
    final amountController = TextEditingController(
      text: _simAmount != null ? _simAmount!.toStringAsFixed(2) : '',
    );
    var installments = _simInstallments;
    var multiple = _simInstallments > 1;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Simuler un achat'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: amountController,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Montant'),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Paiement en plusieurs fois'),
                value: multiple,
                onChanged: (v) => setDialogState(() => multiple = v),
              ),
              if (multiple)
                DropdownButtonFormField<int>(
                  initialValue: installments > 1 ? installments : 2,
                  decoration: const InputDecoration(labelText: 'Nombre de mensualites'),
                  items: [
                    for (var n = 2; n <= 12; n++)
                      DropdownMenuItem(value: n, child: Text('$n fois')),
                  ],
                  onChanged: (n) {
                    if (n != null) setDialogState(() => installments = n);
                  },
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () {
                final amount = double.tryParse(amountController.text.replaceAll(',', '.'));
                if (amount == null || amount == 0) {
                  Navigator.of(context).pop(false);
                  return;
                }
                setState(() {
                  _simAmount = amount;
                  _simInstallments = multiple ? installments : 1;
                });
                Navigator.of(context).pop(true);
              },
              child: const Text('Appliquer'),
            ),
          ],
        ),
      ),
    );
    if (result != true) return;
  }

  /// Every day from today (inclusive) forward through the selected
  /// duration: today uses the real balance-as-of-now (so any transaction
  /// already recorded for today is reflected), every later day layers on
  /// the mechanical recurring-transaction projection only.
  List<_Point> _buildPoints(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final endDate = _addMonths(today, _duration.months);
    final totalDays = _daysBetween(today, endDate);

    final recurring = widget.repository.recurringDailyNet(
      anchor: endDate,
      days: totalDays + 1,
      accountId: widget.accountId,
    );

    final balanceNow = _balanceAsOfNow(now);
    final points = <_Point>[_Point(today, 0, balanceNow, false)];
    var cumulative = balanceNow;
    var cursor = _addDays(today, 1);
    while (!cursor.isAfter(endDate)) {
      final net = recurring[cursor] ?? 0.0;
      cumulative += net;
      points.add(_Point(cursor, net, cumulative, true));
      cursor = _addDays(cursor, 1);
    }
    return points;
  }

  /// Overlays a simulated purchase on top of [basePoints]: a one-off hits
  /// today in full, an installment plan spreads it evenly across up to 12
  /// consecutive monthly instalments starting today. Purely a display
  /// overlay - never persisted.
  List<_Point>? _buildSimulatedPoints(List<_Point> basePoints) {
    final amount = _simAmount;
    if (amount == null || basePoints.isEmpty) return null;

    final perInstallment = amount / _simInstallments;
    final impactDays = <DateTime>{
      for (var i = 0; i < _simInstallments; i++) _addMonths(basePoints.first.day, i),
    };

    var extra = 0.0;
    return [
      for (final p in basePoints) ...[
        () {
          if (impactDays.contains(p.day)) extra -= perInstallment;
          return _Point(p.day, p.net, p.cumulative + extra, p.projected);
        }(),
      ],
    ];
  }

  Widget _buildChart(List<_Point> points, List<_Point>? simulatedPoints, CurrencyFormat? currency) {
    if (points.isEmpty) return const SizedBox.shrink();

    final segments = _buildSegments(points);

    // Always keep the zero line in view (whether the whole window is
    // positive, negative, or straddles both), so the balance's sign is
    // never ambiguous. The simulated line (if any) is folded into the
    // min/max so it never gets clipped off the chart.
    final allCumulative = [
      ...points.map((p) => p.cumulative),
      if (simulatedPoints != null) ...simulatedPoints.map((p) => p.cumulative),
    ];
    final dataMin = allCumulative.reduce((a, b) => a < b ? a : b);
    final dataMax = allCumulative.reduce((a, b) => a > b ? a : b);
    final rangeMin = dataMin < 0 ? dataMin : 0.0;
    final rangeMax = dataMax > 0 ? dataMax : 0.0;
    final pad = ((rangeMax - rangeMin).abs() * 0.15).clamp(10, double.infinity).toDouble();
    final minY = rangeMin - pad;
    final maxY = rangeMax + pad;

    final axisFormat = DateFormat(points.length > 120 ? 'MMM yyyy' : 'd MMM', 'fr_FR');
    final tooltipFormat = DateFormat('EEEE d MMMM yyyy', 'fr_FR');
    final labelInterval = (points.length / 6).clamp(1, 60).roundToDouble();
    final grouped = _groupedOccurrences(points);
    final occurrenceLines = _buildOccurrenceLines(points, grouped);
    // Always the last series in lineBarsData - see its definition below.
    final markerBarIndex = segments.length + (simulatedPoints != null ? 1 : 0);

    return LineChart(
      LineChartData(
        minY: minY,
        maxY: maxY,
        extraLinesData: ExtraLinesData(
          horizontalLines: [
            HorizontalLine(
              y: 0,
              color: Colors.grey.withValues(alpha: 0.6),
              strokeWidth: 1.2,
              dashArray: [4, 4],
            ),
          ],
          verticalLines: occurrenceLines,
        ),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingVerticalLine: (_) => FlLine(color: Colors.grey.withValues(alpha: 0.25), strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 52,
              interval: labelInterval,
              getTitlesWidget: (value, meta) {
                final i = value.round();
                if (i < 0 || i >= points.length) return const SizedBox.shrink();
                final label = axisFormat.format(points[i].day);
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Transform.rotate(
                    angle: -0.6,
                    alignment: Alignment.topCenter,
                    child: Text(label, style: const TextStyle(fontSize: 9)),
                  ),
                );
              },
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            fitInsideHorizontally: true,
            fitInsideVertically: true,
            getTooltipItems: (spots) {
              final seen = <String>{};
              final items = <LineTooltipItem?>[];
              for (final s in spots) {
                final i = s.x.round();

                if (s.barIndex == markerBarIndex) {
                  if (!seen.add('marker:$i')) {
                    items.add(null);
                    continue;
                  }
                  final dayOccurrences = grouped[points[i].day];
                  if (dayOccurrences == null || dayOccurrences.isEmpty) {
                    items.add(null);
                    continue;
                  }
                  final lines = dayOccurrences.map((o) {
                    final amount = currency?.format(o.signedAmount) ?? o.signedAmount.toStringAsFixed(2);
                    return '${o.label} : $amount';
                  }).join('\n');
                  var text = lines;
                  if (dayOccurrences.length > 1) {
                    final total = dayOccurrences.fold(0.0, (sum, o) => sum + o.signedAmount);
                    final totalStr = currency?.format(total) ?? total.toStringAsFixed(2);
                    text = '$lines\nTotal : $totalStr';
                  }
                  items.add(LineTooltipItem(
                    text,
                    const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  ));
                  continue;
                }

                final isSimulated = simulatedPoints != null && s.barIndex == segments.length;
                final key = isSimulated ? 'sim:$i' : 'base:$i';
                if (!seen.add(key)) {
                  items.add(null);
                  continue;
                }
                final p = isSimulated ? simulatedPoints[i] : points[i];
                final value = currency?.format(p.cumulative) ?? p.cumulative.toStringAsFixed(2);
                final label = tooltipFormat.format(p.day);
                final suffix = isSimulated
                    ? ' (avec achat simule)'
                    : (p.projected ? ' (prevision)' : '');
                items.add(LineTooltipItem(
                  '$label\n$value$suffix',
                  const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ));
              }
              return items;
            },
          ),
        ),
        lineBarsData: [
          for (final segment in segments)
            LineChartBarData(
              spots: segment.spots,
              // Straight segments, not curved: with curve smoothing, each
              // colored segment is interpolated independently and can bulge
              // past its own endpoint's value, visually crossing the zero
              // line a point or two before the data actually does. Straight
              // lines guarantee the colour change lands exactly on the
              // real crossing point.
              isCurved: false,
              color: segment.positive ? AppTheme.accent : AppTheme.negative,
              barWidth: 3,
              dashArray: segment.projected ? [6, 5] : null,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: (segment.positive ? AppTheme.accent : AppTheme.negative).withValues(alpha: 0.12),
              ),
            ),
          if (simulatedPoints != null)
            LineChartBarData(
              spots: [
                for (var i = 0; i < simulatedPoints.length; i++)
                  FlSpot(i.toDouble(), simulatedPoints[i].cumulative),
              ],
              isCurved: false,
              color: Colors.orange.shade700,
              barWidth: 2.5,
              dashArray: [2, 3],
              dotData: const FlDotData(show: false),
            ),
          // Invisible series, one spot per day: exists purely so hovering
          // over a day with recurring occurrences (see [_groupedOccurrences])
          // registers a touch and can show their tooltip, without drawing
          // anything itself.
          LineChartBarData(
            spots: [for (var i = 0; i < points.length; i++) FlSpot(i.toDouble(), points[i].cumulative)],
            color: Colors.transparent,
            barWidth: 0,
            dotData: const FlDotData(show: false),
          ),
        ],
      ),
    );
  }

  /// One dashed red vertical line per day that has at least one recurring
  /// occurrence in [points]' range - no permanent text (that would clutter
  /// the chart when there are many), just the marker. Details show up in a
  /// tooltip on hover instead, via the invisible per-day touch series in
  /// [_buildChart].
  List<VerticalLine> _buildOccurrenceLines(
    List<_Point> points,
    Map<DateTime, List<RecurringOccurrence>> grouped,
  ) {
    if (grouped.isEmpty) return [];
    final dayIndex = {for (var i = 0; i < points.length; i++) points[i].day: i};

    return [
      for (final day in grouped.keys)
        if (dayIndex[day] != null)
          VerticalLine(
            x: dayIndex[day]!.toDouble(),
            color: Colors.red.withValues(alpha: 0.55),
            strokeWidth: 1.3,
            dashArray: [4, 3],
          ),
    ];
  }

  /// Splits the timeline into runs that share the same sign (for colour:
  /// blue above zero, red below) and the same actual/projected status (for
  /// dashing). A sign change between two adjacent points is cut exactly at
  /// its interpolated zero-crossing (not at the surrounding data points),
  /// otherwise the whole segment inherits its start point's colour and the
  /// new-sign side is left with a single, unrenderable point.
  List<_Segment> _buildSegments(List<_Point> points) {
    final segments = <_Segment>[];
    var spots = <FlSpot>[];
    bool? currentPositive;
    bool? currentProjected;

    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      final positive = p.cumulative >= 0;
      final spot = FlSpot(i.toDouble(), p.cumulative);

      if (currentPositive == null) {
        currentPositive = positive;
        currentProjected = p.projected;
        spots.add(spot);
        continue;
      }

      if (positive != currentPositive) {
        final prev = points[i - 1];
        // Interpolate x where the straight line between prev and p crosses
        // y=0: x = xPrev + (0 - yPrev) / (yP - yPrev).
        final denom = p.cumulative - prev.cumulative;
        final t = denom == 0 ? 0.0 : (0 - prev.cumulative) / denom;
        final crossingX = (i - 1) + t;
        spots.add(FlSpot(crossingX, 0));
        segments.add(_Segment(spots, currentPositive, currentProjected!));
        spots = [FlSpot(crossingX, 0)];
        currentPositive = positive;
        currentProjected = p.projected;
        spots.add(spot);
        continue;
      }

      if (p.projected != currentProjected) {
        spots.add(spot);
        segments.add(_Segment(spots, currentPositive, currentProjected!));
        spots = [spot];
        currentProjected = p.projected;
        continue;
      }

      spots.add(spot);
    }
    if (spots.isNotEmpty) {
      segments.add(_Segment(spots, currentPositive!, currentProjected!));
    }
    return segments;
  }
}

class _Segment {
  final List<FlSpot> spots;
  final bool positive;
  final bool projected;

  _Segment(this.spots, this.positive, this.projected);
}

/// One row of the tabular forecast view - see
/// [_ForecastChartState._buildOperationsList].
class _ForecastRow {
  final DateTime date;
  final String label;
  final double amount;
  final bool simulated;

  _ForecastRow({required this.date, required this.label, required this.amount, required this.simulated});
}

class _RangeLabel extends StatelessWidget {
  final List<_Point> points;

  const _RangeLabel({required this.points});

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) return const SizedBox.shrink();
    final format = DateFormat('d MMMM yyyy', 'fr_FR');
    final first = format.format(points.first.day);
    final last = format.format(points.last.day);
    return Text(
      '$first - $last',
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
