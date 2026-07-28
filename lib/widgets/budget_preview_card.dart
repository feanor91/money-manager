import 'package:flutter/material.dart';

import '../data/mmex_repository.dart';
import '../models/budget.dart';
import '../models/budget_period.dart';
import '../models/category.dart';
import '../models/currency.dart';
import '../theme/app_theme.dart';
import 'bento_card.dart';

/// Read-only preview of the budget on the dashboard: the biggest envelopes
/// this period, each with a small progress bar - no add/edit/delete here,
/// that all lives on the full Budget screen. Has its own month navigation
/// (mirroring the Budget screen's, on the same forecast-day-anchored
/// window) since a fixed "current month only" preview would go stale the
/// moment you looked back at last month elsewhere in the app.
class BudgetPreviewCard extends StatefulWidget {
  final MmexRepository repository;
  final CurrencyFormat? currency;
  final int? accountId;
  final int forecastDay;
  final int itemCount;

  const BudgetPreviewCard({
    super.key,
    required this.repository,
    required this.forecastDay,
    this.currency,
    this.accountId,
    this.itemCount = 5,
  });

  @override
  State<BudgetPreviewCard> createState() => _BudgetPreviewCardState();
}

class _BudgetPreviewCardState extends State<BudgetPreviewCard> {
  DateTime _cursor = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final repo = widget.repository;
    final window = budgetWindowContaining(_cursor, widget.forecastDay);
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    final canGoForward = !window.end.isAfter(todayDate);

    final categories = repo.getCategories(onlyActive: false);
    final categoriesById = {for (final c in categories) c.id: c};
    final envelopes = widget.accountId == null
        ? const <BudgetEnvelope>[]
        : repo.getBudgetEnvelopes(widget.accountId!);
    final recurringTotals = repo.categoryMonthlyRecurringTotals(accountId: widget.accountId);
    final rawSpend =
        repo.categorySpendForPeriod(window.start, window.end, accountId: widget.accountId);

    final items = <_PreviewItem>[];
    for (final e in envelopes) {
      final category = categoriesById[e.categoryId];
      if (category == null) continue;
      final autoTotal = recurringTotals[e.categoryId] ?? 0;
      final target = autoTotal > 0 ? autoTotal : e.amount;
      final spent = rolledUpSpend(e.categoryId, rawSpend, categories);
      items.add(_PreviewItem(category: category, target: target, spent: spent));
    }
    items.sort((a, b) => b.spent.compareTo(a.spent));
    final top = items.take(widget.itemCount).toList();

    return BentoCard(
      title: 'Apercu du budget',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.chevron_left, size: 18),
            onPressed: () => setState(
                () => _cursor = previousBudgetWindow(window, widget.forecastDay).start),
          ),
          SizedBox(
            width: 84,
            child: Text(
              window.label,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.chevron_right,
                size: 18, color: canGoForward ? null : Theme.of(context).disabledColor),
            onPressed: canGoForward
                ? () => setState(
                    () => _cursor = nextBudgetWindow(window, widget.forecastDay).start)
                : null,
          ),
        ],
      ),
      child: top.isEmpty
          ? const Center(child: Text('Aucune enveloppe de budget definie'))
          : ListView.separated(
              physics: const NeverScrollableScrollPhysics(),
              itemCount: top.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final item = top[index];
                final ratio = item.target > 0 ? (item.spent / item.target).clamp(0, 1.5) : null;
                final over = ratio != null && ratio > 1;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.category.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        Text(
                          widget.currency?.format(item.spent) ?? item.spent.toStringAsFixed(2),
                          style: TextStyle(
                            color: over ? AppTheme.negative : null,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    if (ratio != null) ...[
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(
                          value: ratio.clamp(0, 1).toDouble(),
                          minHeight: 8,
                          backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                          color: over ? AppTheme.negative : AppTheme.accent,
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
    );
  }
}

class _PreviewItem {
  final Category category;
  final double target;
  final double spent;

  const _PreviewItem({required this.category, required this.target, required this.spent});
}
