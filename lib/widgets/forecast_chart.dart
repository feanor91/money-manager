import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/mmex_repository.dart';
import '../models/category.dart';
import '../models/currency.dart';
import '../models/transaction.dart';
import '../state/purchase_simulation_provider.dart';
import '../theme/app_theme.dart';
import 'bento_card.dart';
import 'searchable_select_field.dart';

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

/// Bento card showing the balance forecast, scrollable in either direction
/// by [_ForecastChartState._offsetSteps] windows of the selected duration
/// (1/2/3/6/12 months, the "Durée affichée" dropdown) - the visible window
/// is always real (not projected) balance for any day up to and including
/// today, then the usual mechanical recurring-transaction projection after
/// it. Restored 2026-08-06 after being reported as a regression (the
/// original version of this chart could pan into the past; the
/// "future-only" redesign that added the purchase simulation below dropped
/// that entirely and never brought it back) - first as a fixed
/// today-centered window, then reworked the same day into real left/right
/// paging with an "Aujourd'hui" reset after that first attempt was judged
/// not intuitive enough. History renders as a solid line, projection as
/// dashed (see [_Point.projected] / [_buildSegments]) so the two are never
/// visually ambiguous. Optional "what-if" simulated purchase (one-off or
/// spread over up to 12 monthly installments starting today, regardless of
/// which window is currently in view) overlaid as a second line - never
/// written to the database, purely a client-side projection.
class ForecastChart extends StatefulWidget {
  final MmexRepository repository;
  final CurrencyFormat? currency;
  final int? accountId;

  const ForecastChart({
    super.key,
    required this.repository,
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

  /// How many [_duration]-wide windows the visible range is shifted from
  /// today - 0 means "today at the start of the graph" (see [_ForwardNavRow]),
  /// negative scrolls into real history, positive scrolls further into the
  /// projection. A step count, not a date, so changing [_duration] mid-scroll
  /// can't silently jump to a nonsensical date - see the dropdown's
  /// onChanged below, which resets this back to 0 whenever that happens.
  int _offsetSteps = 0;

  @override
  Widget build(BuildContext context) {
    final sim = context.watch<PurchaseSimulationProvider>();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final windowStart = _addMonths(today, _offsetSteps * _duration.months);
    final points = _buildPoints(today, windowStart);
    final simulatedPoints = _buildSimulatedPoints(points, today, sim.amount, sim.installments);
    final currency = widget.currency;

    String? simCategoryLabel;
    if (sim.categoryId != null) {
      final categoriesById = {
        for (final c in widget.repository.getCategories(onlyActive: false)) c.id: c
      };
      final path = categoryFullPath(sim.categoryId, categoriesById);
      if (path.isNotEmpty) simCategoryLabel = path;
    }

    return BentoCard(
      title: 'Prévision de solde',
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
                    labelText: 'Durée affichée',
                    isDense: true,
                  ),
                  items: [
                    for (final d in ForecastDuration.values)
                      DropdownMenuItem(value: d, child: Text(d.label)),
                  ],
                  onChanged: (d) {
                    if (d == null) return;
                    // Reset the scroll position too - "+2 windows of 3 mois"
                    // would silently become "+2 windows of 1 an" otherwise,
                    // jumping to a date that has nothing to do with what was
                    // on screen a moment ago.
                    setState(() {
                      _duration = d;
                      _offsetSteps = 0;
                    });
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
                  color: sim.isActive ? AppTheme.accent : null,
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
                onPressed:
                    _offsetSteps == 0 ? null : () => setState(() => _offsetSteps = 0),
                icon: const Icon(Icons.today, size: 16),
                label: const Text('Aujourd\'hui'),
              ),
              IconButton(
                tooltip: 'Période suivante',
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _offsetSteps += 1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          if (sim.isActive) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.circle, size: 10, color: Colors.orange.shade700),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    [
                      sim.installments > 1
                          ? 'Simulation : ${currency?.format(sim.amount!) ?? sim.amount!.toStringAsFixed(2)} en ${sim.installments} fois'
                          : 'Simulation : ${currency?.format(sim.amount!) ?? sim.amount!.toStringAsFixed(2)} comptant',
                      if (simCategoryLabel != null) '($simCategoryLabel)',
                    ].join(' '),
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Effacer la simulation',
                  icon: const Icon(Icons.close, size: 16),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => context.read<PurchaseSimulationProvider>().clear(),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Expanded(
            child: _showAsTable
                ? _buildOperationsList(points, today, currency, sim.amount, sim.installments)
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

  /// Real transactions actually recorded in [start]..[end] (inclusive) -
  /// the past-days counterpart of [_groupedOccurrences], which only ever
  /// covers *scheduled* (future) recurring occurrences. Without this,
  /// scrolling "Vue tableau" into a past window (see the nav row in
  /// [build]) showed nothing there even though the chart itself already
  /// plots real balance for those same days (see [_buildPoints]).
  /// Labelled exactly like [TransactionTile].
  List<_ForecastRow> _realOperationRows(DateTime start, DateTime end) {
    final id = widget.accountId;
    // The "all accounts" case never actually happens at this widget's one
    // real call site (dashboard_screen.dart always passes a concrete
    // account) - left as a graceful no-op rather than building untested
    // multi-account transfer-dedup logic for a path nothing exercises.
    if (id == null) return const [];

    final payeesById = {for (final p in widget.repository.getPayees(onlyActive: false)) p.id: p};
    final accountsById = {for (final a in widget.repository.getAccounts()) a.id: a};

    return [
      for (final t
          in widget.repository.getTransactionsWithRunningBalance(id, from: start, to: end))
        _ForecastRow(
          date: DateTime(
              t.transaction.date.year, t.transaction.date.month, t.transaction.date.day),
          label: t.transaction.transCode == TransCode.transfer
              ? '${accountsById[t.transaction.accountId]?.name ?? '?'} → '
                  '${accountsById[t.transaction.toAccountId]?.name ?? '?'}'
              : (payeesById[t.transaction.payeeId]?.name ?? 'Tiers inconnu'),
          amount: t.transaction.signedAmountFor(id),
          simulated: false,
        ),
    ];
  }

  /// Tabular alternative to the chart ("Vue tableau", see ROADMAP.md): real
  /// transactions for the window's real (past-through-today) days plus
  /// every recurring occurrence for its projected (future) days - plus the
  /// simulated purchase's installments, if any - one row each, styled like
  /// [TransactionTile]. Each row also shows that day's running balance
  /// (shared across every operation on the same day, since the underlying
  /// data is bucketed by day, not by individual transaction).
  Widget _buildOperationsList(
    List<_Point> points,
    DateTime today,
    CurrencyFormat? currency,
    double? simAmount,
    int simInstallments,
  ) {
    if (points.isEmpty) return const SizedBox.shrink();

    final grouped = _groupedOccurrences(points);
    final dayIndex = {for (var i = 0; i < points.length; i++) points[i].day: i};

    final rows = <_ForecastRow>[
      if (!points.first.day.isAfter(today))
        ..._realOperationRows(
          points.first.day,
          points.last.day.isBefore(today) ? points.last.day : today,
        ),
      for (final occurrences in grouped.values)
        for (final o in occurrences)
          _ForecastRow(date: o.date, label: o.label, amount: o.signedAmount, simulated: false),
    ];
    if (simAmount != null) {
      final perInstallment = simAmount / simInstallments;
      for (var i = 0; i < simInstallments; i++) {
        rows.add(_ForecastRow(
          // Always anchored on today, never points.first.day - the latter
          // is now the *history* window's start once that's non-empty (see
          // _buildPoints), which would silently backdate every simulated
          // installment into the past.
          date: _addMonths(today, i),
          label: 'Achat simulé',
          amount: -perInstallment,
          simulated: true,
        ));
      }
    }
    rows.sort((a, b) => a.date.compareTo(b.date));

    if (rows.isEmpty) {
      return const Center(child: Text('Aucune opération sur cette période.'));
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
    final sim = context.read<PurchaseSimulationProvider>();
    final amountController = TextEditingController(
      text: sim.amount != null ? sim.amount!.toStringAsFixed(2) : '',
    );
    var installments = sim.installments;
    var multiple = sim.installments > 1;
    var categoryId = sim.categoryId;

    final categories = widget.repository.getCategories();
    final categoriesById = {for (final c in categories) c.id: c};
    final sortedCategories = [...categories]..sort((a, b) =>
        categoryFullPath(a.id, categoriesById)
            .toLowerCase()
            .compareTo(categoryFullPath(b.id, categoriesById).toLowerCase()));

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
              SearchableSelectField<Category>(
                label: 'Catégorie budgétaire (optionnel)',
                options: sortedCategories,
                labelOf: (c) => categoryFullPath(c.id, categoriesById),
                initialValue: categoryId == null
                    ? null
                    : categoriesById[categoryId],
                onSelected: (c) => setDialogState(() => categoryId = c?.id),
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
                  decoration: const InputDecoration(labelText: 'Nombre de mensualités'),
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
                sim.set(
                  amount: amount,
                  installments: multiple ? installments : 1,
                  categoryId: categoryId,
                );
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

  /// Builds the [_duration]-wide window starting at [windowStart] (may be
  /// entirely in the past, straddle [today], or be entirely in the future -
  /// see the scroll navigation row in [build]): real (never projected)
  /// balance for every day up to and including today when the window
  /// reaches that far back, then the mechanical recurring-transaction
  /// projection for every day after it.
  ///
  /// Today itself always starts from the real balance *as of today*
  /// ([_realBalanceAsOf], excluding anything dated after today) rather than
  /// the day-bucketed queries used for its neighbours - but only actually
  /// appears as a point when it's inside [windowStart]..windowEnd; it's
  /// always still used to seed the projection math below even when
  /// scrolled out of view, so a window entirely in the future doesn't
  /// silently start from zero.
  ///
  /// Deliberately *not* [MmexRepository.accountBalance] with no `asOf`
  /// (which includes postdated entries regardless of date, e.g. a bill
  /// recorded a couple of weeks ahead of its due date): folding those
  /// straight into "today" made an account with any such entry look
  /// already overdrawn *today*, before the postdated transaction's own
  /// date, even though the real balance as of today was fine (found
  /// 2026-08-18). Those entries aren't dropped, only moved to where they
  /// belong - see the projection loop below, which adds
  /// [MmexRepository.futureDailyNet] (real, already-recorded future
  /// transactions) alongside the usual recurring-bill projection, so a
  /// postdated entry still shows up, on its own actual date, in full.
  /// Never double-counts a postdated entry against the recurring-bill
  /// side of that projection: recording a recurring bill's occurrence (on
  /// time, late, or ahead of schedule - see
  /// MmexRepository.recordBillOccurrence/catchUpBillDeposit) always
  /// advances that bill's own next-occurrence date past it, so the
  /// template can never also re-project something already recorded as a
  /// real transaction.
  List<_Point> _buildPoints(DateTime today, DateTime windowStart) {
    final windowEnd = _addMonths(windowStart, _duration.months);
    final points = <_Point>[];

    if (windowStart.isBefore(today)) {
      final realEnd = windowEnd.isBefore(today) ? windowEnd : _addDays(today, -1);
      final realDays = _daysBetween(windowStart, realEnd) + 1;
      // anchor=realEnd (not realEnd+1 or today): MmexRepository.dailyNetTotals
      // buckets exactly [anchor-(days-1), anchor], so anchor must be the
      // *last* day actually consumed below, not one past it - getting this
      // wrong silently drops the oldest day's real transactions from the
      // total instead of erroring (found + fixed 2026-08-06 rewriting this
      // for scrolling; the previous today-anchored version had exactly
      // this off-by-one).
      final netTotals = widget.repository.dailyNetTotals(
        anchor: realEnd,
        days: realDays,
        accountId: widget.accountId,
      );
      var cumulative = _realBalanceAsOf(_addDays(windowStart, -1));
      var cursor = windowStart;
      for (var i = 0; i < realDays; i++) {
        final net = netTotals[cursor] ?? 0.0;
        cumulative += net;
        points.add(_Point(cursor, net, cumulative, false));
        cursor = _addDays(cursor, 1);
      }
    }

    final todayBalance = _realBalanceAsOf(today);

    if (!today.isBefore(windowStart) && !today.isAfter(windowEnd)) {
      points.add(_Point(today, 0, todayBalance, false));
    }

    if (windowEnd.isAfter(today)) {
      final projStart = _addDays(today, 1);
      final projDays = _daysBetween(projStart, windowEnd) + 1;
      final recurring = widget.repository.recurringDailyNet(
        anchor: windowEnd,
        days: projDays,
        accountId: widget.accountId,
      );
      // Real transactions already recorded with a future date (e.g. a bill
      // paid ahead of its due date) - merged in alongside the recurring-bill
      // projection above so they land on their own actual date instead of
      // being pulled into "today" (see the doc comment above).
      final futureReal = widget.repository.futureDailyNet(
        after: today,
        end: windowEnd,
        accountId: widget.accountId,
      );
      var cumulative = todayBalance;
      var cursor = projStart;
      for (var i = 0; i < projDays; i++) {
        final net = (recurring[cursor] ?? 0.0) + (futureReal[cursor] ?? 0.0);
        cumulative += net;
        // Still walked even before windowStart (when the whole window is
        // scrolled into the future) to keep `cumulative` correct - only
        // actually emitted once the cursor reaches the visible window.
        if (!cursor.isBefore(windowStart)) {
          points.add(_Point(cursor, net, cumulative, true));
        }
        cursor = _addDays(cursor, 1);
      }
    }

    return points;
  }

  /// [MmexRepository.accountBalance]'s `asOf` only takes one concrete
  /// account - sums across every account when [ForecastChart.accountId] is
  /// null (the "all accounts" case [recurringDailyNet]/[dailyNetTotals]
  /// already handle internally via their own nullable `accountId`).
  double _realBalanceAsOf(DateTime day) {
    final id = widget.accountId;
    if (id != null) return widget.repository.accountBalance(id, asOf: day);
    return widget.repository
        .getAccounts()
        .fold(0.0, (sum, a) => sum + widget.repository.accountBalance(a.id, asOf: day));
  }

  /// Overlays a simulated purchase on top of [basePoints]: a one-off hits
  /// today in full, an installment plan spreads it evenly across up to 12
  /// consecutive monthly instalments starting today. Purely a display
  /// overlay - never persisted.
  List<_Point>? _buildSimulatedPoints(
      List<_Point> basePoints, DateTime today, double? amount, int installments) {
    if (amount == null || basePoints.isEmpty) return null;

    final perInstallment = amount / installments;
    // Anchored on today, never basePoints.first.day - the latter is now the
    // *history* window's start once that's non-empty (see _buildPoints),
    // which would silently backdate every installment into the past.
    final impactDays = <DateTime>{
      for (var i = 0; i < installments; i++) _addMonths(today, i),
    };

    // Seed with every installment that landed *before* the visible window
    // even starts - relevant now the window can scroll away from today
    // (see the nav row in build()): without this, simulating a purchase
    // while scrolled past its own installment dates would make its effect
    // silently vanish from view instead of still discounting the balance.
    var extra = -perInstallment *
        impactDays.where((d) => d.isBefore(basePoints.first.day)).length;
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
                    ? ' (avec achat simulé)'
                    : (p.projected ? ' (prévision)' : '');
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
