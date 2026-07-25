import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/mmex_repository.dart';
import '../models/currency.dart';
import '../theme/app_theme.dart';
import 'bento_card.dart';

enum _Scale { day, week, month }

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

DateTime _weekStart(DateTime date) {
  final d = DateTime(date.year, date.month, date.day);
  // Dart's DateTime.weekday: Monday=1 ... Sunday=7. Weeks start on Sunday.
  final daysSinceSunday = d.weekday % 7;
  return _addDays(d, -daysSinceSunday);
}

DateTime _monthStart(DateTime date) => DateTime(date.year, date.month, 1);

/// Per-scale tuning: how many buckets are visible by default, how many
/// extra trailing buckets to pull for the discretionary-average
/// calculation, how far a "Passe"/"Futur" tap or a drag step moves, and how
/// dates are formatted for that resolution.
class _ScaleConfig {
  final int windowSize;
  final int historyPadding;
  final int step;
  final double pxPerUnit;
  final int clampMin;
  final int clampMax;
  final String label;
  final String Function(DateTime) axisFormat;
  final String Function(DateTime) tooltipFormat;
  final bool showAllLabels;
  final bool showVerticalGrid;

  const _ScaleConfig({
    required this.windowSize,
    required this.historyPadding,
    required this.step,
    required this.pxPerUnit,
    required this.clampMin,
    required this.clampMax,
    required this.label,
    required this.axisFormat,
    required this.tooltipFormat,
    this.showAllLabels = false,
    this.showVerticalGrid = false,
  });
}

final Map<_Scale, _ScaleConfig> _scaleConfigs = {
  _Scale.day: _ScaleConfig(
    windowSize: 30,
    historyPadding: 45,
    step: 7,
    pxPerUnit: 10,
    clampMin: -730,
    clampMax: 545,
    label: 'Jour',
    axisFormat: (d) => DateFormat('d MMMM yyyy', 'fr_FR').format(d),
    tooltipFormat: (d) => DateFormat('EEEE d MMMM yyyy', 'fr_FR').format(d),
    showAllLabels: true,
    showVerticalGrid: true,
  ),
  _Scale.week: _ScaleConfig(
    windowSize: 20,
    historyPadding: 12,
    step: 4,
    pxPerUnit: 18,
    clampMin: -104,
    clampMax: 78,
    label: 'Semaine',
    axisFormat: (d) => DateFormat('d MMMM yyyy', 'fr_FR').format(d),
    tooltipFormat: (d) => 'Semaine du ${DateFormat('d MMMM yyyy', 'fr_FR').format(d)}',
  ),
  _Scale.month: _ScaleConfig(
    windowSize: 12,
    historyPadding: 6,
    step: 3,
    pxPerUnit: 28,
    clampMin: -36,
    clampMax: 24,
    label: 'Mois',
    axisFormat: (d) => DateFormat('MMMM yyyy', 'fr_FR').format(d),
    tooltipFormat: (d) => DateFormat('MMMM yyyy', 'fr_FR').format(d),
  ),
};

/// One point of the forecast timeline (one day/week/month depending on the
/// selected scale): an actual bucket from the ledger, or a projection
/// (known recurring transactions only) when in the future.
class _Point {
  final DateTime bucketStart;
  final double net;
  final double cumulative;
  final bool projected;

  _Point(this.bucketStart, this.net, this.cumulative, this.projected);
}

/// Bento card showing a scrollable/draggable balance forecast, at a
/// selectable resolution (day/week/month): drag left to look further into
/// the future (projected, dashed), drag right to look further into the
/// past (actual history).
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
  _Scale _scale = _Scale.day;
  int _offsetUnits = 0;
  double _dragAccumulator = 0;

  // `accountBalance(asOf:)` scans the account's whole transaction history -
  // too expensive to redo on every rebuild, which fires on every few pixels
  // of drag (see onHorizontalDragUpdate below) and was pegging the CPU hard
  // enough to freeze the tab. It only actually changes once per calendar
  // day, or when the account's data changes - and `widget.startingBalance`
  // (the parent's all-time balance for this account) already changes
  // exactly when the latter happens, so it doubles as a cheap invalidation
  // signal without any extra plumbing.
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

  _ScaleConfig get _config => _scaleConfigs[_scale]!;

  void _setScale(_Scale scale) {
    if (scale == _scale) return;
    setState(() {
      _scale = scale;
      _offsetUnits = 0;
      _dragAccumulator = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final points = _buildPoints(now);
    final currency = widget.currency;
    final config = _config;

    return BentoCard(
      title: 'Prevision de solde',
      trailing: _RangeLabel(points: points, format: config.axisFormat),
      child: GestureDetector(
        onHorizontalDragUpdate: (details) {
          _dragAccumulator += details.delta.dx;
          final pxPerUnit = config.pxPerUnit;
          if (_dragAccumulator.abs() >= pxPerUnit) {
            final steps = (_dragAccumulator / pxPerUnit).truncate();
            setState(() {
              _offsetUnits = (_offsetUnits - steps).clamp(config.clampMin, config.clampMax).toInt();
              _dragAccumulator -= steps * pxPerUnit;
            });
          }
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<_Scale>(
              segments: [
                for (final s in _Scale.values) ButtonSegment(value: s, label: Text(_scaleConfigs[s]!.label)),
              ],
              selected: {_scale},
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              onSelectionChanged: (s) => _setScale(s.first),
            ),
            const SizedBox(height: 8),
            Expanded(child: _buildChart(points, currency, config)),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton.icon(
                  onPressed: () => setState(
                      () => _offsetUnits = (_offsetUnits - config.step).clamp(config.clampMin, config.clampMax).toInt()),
                  icon: const Icon(Icons.chevron_left, size: 18),
                  label: const Text('Passe'),
                ),
                if (_offsetUnits != 0)
                  TextButton(
                    onPressed: () => setState(() => _offsetUnits = 0),
                    child: const Text("Aujourd'hui"),
                  ),
                TextButton.icon(
                  onPressed: () => setState(
                      () => _offsetUnits = (_offsetUnits + config.step).clamp(config.clampMin, config.clampMax).toInt()),
                  icon: const Text('Futur'),
                  label: const Icon(Icons.chevron_right, size: 18),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<_Point> _buildPoints(DateTime now) {
    switch (_scale) {
      case _Scale.day:
        return _buildGenericPoints(
          now: DateTime(now.year, now.month, now.day),
          // n may be negative (backward) or positive (forward).
          shift: (d, n) => _addDays(d, n),
          spanUnits: (a, b) => _daysBetween(a, b),
          fetchHistory: (anchor, span) =>
              widget.repository.dailyNetTotals(anchor: anchor, days: span, accountId: widget.accountId),
          fetchRecurring: (anchor, span) =>
              widget.repository.recurringDailyNet(anchor: anchor, days: span, accountId: widget.accountId),
        );
      case _Scale.week:
        return _buildGenericPoints(
          now: _weekStart(now),
          shift: (d, n) => _addDays(d, 7 * n),
          spanUnits: (a, b) => _daysBetween(a, b) ~/ 7,
          fetchHistory: (anchor, span) =>
              widget.repository.weeklyNetTotals(anchor: anchor, weeks: span, accountId: widget.accountId),
          fetchRecurring: (anchor, span) =>
              widget.repository.recurringWeeklyNet(anchor: anchor, weeks: span, accountId: widget.accountId),
        );
      case _Scale.month:
        return _buildGenericPoints(
          now: _monthStart(now),
          shift: (d, n) => DateTime(d.year, d.month + n, 1),
          spanUnits: (a, b) => (b.year - a.year) * 12 + (b.month - a.month),
          fetchHistory: (anchor, span) =>
              widget.repository.monthlyNetTotals(anchor: anchor, months: span, accountId: widget.accountId),
          fetchRecurring: (anchor, span) =>
              widget.repository.recurringMonthlyNet(anchor: anchor, months: span, accountId: widget.accountId),
        );
    }
  }

  /// Shared point-building logic parameterized over the bucket unit
  /// (day/week/month): walk from an "anchor" backward through history plus
  /// forward into the visible+projected window, mixing real ledger values
  /// (past/current buckets) with a projection (future buckets = known
  /// recurring transactions for that bucket only - budget is not factored
  /// in yet). [shift] moves a bucket start forward by n units (n negative
  /// moves backward).
  List<_Point> _buildGenericPoints({
    required DateTime now,
    required DateTime Function(DateTime d, int n) shift,
    required int Function(DateTime, DateTime) spanUnits,
    required Map<DateTime, double> Function(DateTime anchor, int span) fetchHistory,
    required Map<DateTime, double> Function(DateTime anchor, int span) fetchRecurring,
  }) {
    final config = _config;
    final endBucket = shift(now, _offsetUnits);
    final start = shift(endBucket, -(config.windowSize - 1));

    final latestBucket = endBucket.isAfter(now) ? endBucket : now;
    final earliestBucket = shift(start, -config.historyPadding);
    final spanCount = spanUnits(earliestBucket, latestBucket) + 1;

    final history = fetchHistory(latestBucket, spanCount);
    final recurring = fetchRecurring(latestBucket, spanCount);

    // `widget.startingBalance` sums every transaction on the account
    // regardless of date (matching MMEX's own total), which can include
    // postdated real entries the user already recorded for a known future
    // expense - beyond `now`, so entirely outside what `history` covers.
    // Anchoring the walk on that figure would bake those future amounts
    // into every reconstructed *past* point too. Use the balance capped at
    // `now` instead, then seed by subtracting the actual net change since
    // `earliestBucket` (so the walk reconstructs `now`'s balance exactly,
    // not overshooting it).
    final balanceAsOfNow = _balanceAsOfNow(now);
    final actualSinceEarliest = history.entries
        .where((e) => !e.key.isBefore(earliestBucket) && !e.key.isAfter(now))
        .fold(0.0, (sum, e) => sum + e.value);

    final points = <_Point>[];
    var cumulative = balanceAsOfNow - actualSinceEarliest;

    var cursor = earliestBucket;
    while (!cursor.isAfter(endBucket)) {
      final isFuture = cursor.isAfter(now);
      final net = isFuture ? (recurring[cursor] ?? 0) : (history[cursor] ?? 0.0);
      cumulative += net;
      if (!cursor.isBefore(start)) {
        points.add(_Point(cursor, net, cumulative, isFuture));
      }
      cursor = shift(cursor, 1);
    }
    return points;
  }

  Widget _buildChart(List<_Point> points, CurrencyFormat? currency, _ScaleConfig config) {
    if (points.isEmpty) return const SizedBox.shrink();

    final segments = _buildSegments(points);

    // Always keep the zero line in view (whether the whole window is
    // positive, negative, or straddles both), so the balance's sign is
    // never ambiguous.
    final dataMin = points.map((p) => p.cumulative).reduce((a, b) => a < b ? a : b);
    final dataMax = points.map((p) => p.cumulative).reduce((a, b) => a > b ? a : b);
    final rangeMin = dataMin < 0 ? dataMin : 0.0;
    final rangeMax = dataMax > 0 ? dataMax : 0.0;
    final pad = ((rangeMax - rangeMin).abs() * 0.15).clamp(10, double.infinity).toDouble();
    final minY = rangeMin - pad;
    final maxY = rangeMax + pad;

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
        ),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: config.showVerticalGrid,
          verticalInterval: 1,
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
              reservedSize: config.showAllLabels ? 76 : 52,
              interval: config.showAllLabels ? 1 : (points.length / 6).clamp(1, 30).roundToDouble(),
              getTitlesWidget: (value, meta) {
                final i = value.round();
                if (i < 0 || i >= points.length) return const SizedBox.shrink();
                final label = config.axisFormat(points[i].bucketStart);
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Transform.rotate(
                    angle: config.showAllLabels ? -1.3 : -0.6,
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
            getTooltipItems: (spots) {
              // The bridge point at the actual/projected transition exists
              // in both bar series at the same x, which would otherwise
              // render the same bucket/value twice in the tooltip.
              final seenIndices = <int>{};
              final items = <LineTooltipItem?>[];
              for (final s in spots) {
                final i = s.x.round();
                if (!seenIndices.add(i)) {
                  items.add(null);
                  continue;
                }
                final p = points[i];
                final value = currency?.format(p.cumulative) ?? p.cumulative.toStringAsFixed(2);
                final label = config.tooltipFormat(p.bucketStart);
                items.add(LineTooltipItem(
                  '$label\n$value${p.projected ? ' (prevision)' : ''}',
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
        ],
      ),
    );
  }

  /// Splits the timeline into runs that share the same sign (for colour:
  /// blue above zero, red below) and the same actual/projected status (for
  /// dashing). A sign change between two adjacent points is cut exactly at
  /// its interpolated zero-crossing (not at the surrounding data points),
  /// otherwise the whole day-to-day segment inherits its start point's
  /// colour and the new-sign side is left with a single, unrenderable
  /// point - which is why a rising line used to stay red long after the
  /// real balance had turned positive.
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

class _RangeLabel extends StatelessWidget {
  final List<_Point> points;
  final String Function(DateTime) format;

  const _RangeLabel({required this.points, required this.format});

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) return const SizedBox.shrink();
    final first = format(points.first.bucketStart);
    final last = format(points.last.bucketStart);
    return Text(
      '$first - $last',
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
