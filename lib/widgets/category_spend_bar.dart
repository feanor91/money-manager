import 'package:flutter/material.dart';

import '../models/category.dart';
import '../models/currency.dart';
import '../theme/app_theme.dart';
import 'bento_card.dart';

class CategorySpend {
  final Category category;
  final double spent;
  final double? budget;

  const CategorySpend({required this.category, required this.spent, this.budget});
}

/// Bento card listing top spending categories this month, each with a
/// progress bar against its budget (if one exists).
class CategorySpendCard extends StatelessWidget {
  final List<CategorySpend> items;
  final CurrencyFormat? currency;

  const CategorySpendCard({super.key, required this.items, this.currency});

  @override
  Widget build(BuildContext context) {
    final sorted = [...items]..sort((a, b) => b.spent.compareTo(a.spent));
    final top = sorted.take(6).toList();

    return BentoCard(
      title: 'Depenses par categorie (ce mois)',
      child: top.isEmpty
          ? const Center(child: Text('Aucune depense ce mois-ci'))
          : ListView.separated(
              physics: const NeverScrollableScrollPhysics(),
              itemCount: top.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final item = top[index];
                final ratio = (item.budget != null && item.budget! > 0)
                    ? (item.spent / item.budget!).clamp(0, 1.5)
                    : null;
                final over = ratio != null && ratio > 1;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.category.name,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        Text(
                          currency?.format(item.spent) ?? item.spent.toStringAsFixed(2),
                          style: TextStyle(
                            color: over ? AppTheme.negative : null,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    // Without a budget there's nothing to measure progress
                    // against - a bar with `value: null` renders as an
                    // indeterminate, endlessly sliding animation instead of
                    // just... not showing a bar.
                    if (ratio != null) ...[
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(
                          value: ratio.clamp(0, 1).toDouble(),
                          minHeight: 8,
                          backgroundColor: const Color(0xFFEDEEF3),
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
