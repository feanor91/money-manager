import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/budget.dart';
import '../models/category.dart';
import '../state/database_provider.dart';
import '../theme/app_theme.dart';
import '../utils/list_utils.dart';
import '../widgets/responsive_body.dart';
import '../widgets/searchable_select_field.dart';

class BudgetScreen extends StatefulWidget {
  const BudgetScreen({super.key});

  @override
  State<BudgetScreen> createState() => _BudgetScreenState();
}

class _BudgetScreenState extends State<BudgetScreen> {
  @override
  Widget build(BuildContext context) {
    final repo = context.watch<DatabaseProvider>().repository!;
    final currency = repo.getBaseCurrency();
    final years = repo.getBudgetYears();
    final categories = {for (final c in repo.getCategories()) c.id: c};

    if (years.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Budget')),
        body: const Center(
            child: Text('Aucun exercice budgetaire trouve dans la base.')),
      );
    }

    final year = years.first;
    final entries = repo.getBudgetEntries(year.id);
    final now = DateTime.now();
    final actualSpend = repo.categorySpendForMonth(now);

    return Scaffold(
      appBar: AppBar(title: Text('Budget - ${year.name}')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () =>
            _openEditor(context, year.id, categories.values.toList()),
        icon: const Icon(Icons.add),
        label: const Text('Ligne de budget'),
      ),
      body: ResponsiveBody(
        child: ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: entries.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, i) {
            final entry = entries[i];
            final category = categories[entry.categoryId];
            final spent = actualSpend[entry.categoryId] ?? 0;
            final ratio =
                entry.monthlyAmount > 0 ? (spent / entry.monthlyAmount) : 0.0;
            final over = ratio > 1;
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            category?.name ?? 'Categorie #${entry.categoryId}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        Text(
                          '${currency?.format(spent) ?? spent.toStringAsFixed(2)} / '
                          '${currency?.format(entry.monthlyAmount) ?? entry.monthlyAmount.toStringAsFixed(2)}',
                          style: TextStyle(
                              color:
                                  over ? AppTheme.negative : Colors.grey[700]),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: ratio.clamp(0, 1).toDouble(),
                        minHeight: 10,
                        backgroundColor: const Color(0xFFEDEEF3),
                        color: over ? AppTheme.negative : AppTheme.accent,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _openEditor(
      BuildContext context, int budgetYearId, List<Category> categories) async {
    final dbProvider = context.read<DatabaseProvider>();
    final repo = dbProvider.repository!;
    int? categoryId = categories.isNotEmpty ? categories.first.id : null;
    BudgetPeriod period = BudgetPeriod.monthly;
    final amountController = TextEditingController();

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Ligne de budget'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SearchableSelectField<Category>(
                label: 'Categorie',
                options: categories,
                labelOf: (c) => c.name,
                initialValue: findById(categories, categoryId, (c) => c.id),
                onSelected: (c) => setDialogState(() => categoryId = c?.id),
                onCreate: (text) async {
                  final id = repo.insertCategory(name: text);
                  return Category(id: id, name: text, active: true);
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<BudgetPeriod>(
                initialValue: period,
                decoration: const InputDecoration(labelText: 'Periode'),
                items: const [
                  DropdownMenuItem(
                      value: BudgetPeriod.weekly, child: Text('Hebdomadaire')),
                  DropdownMenuItem(
                      value: BudgetPeriod.monthly, child: Text('Mensuel')),
                  DropdownMenuItem(
                      value: BudgetPeriod.quarterly,
                      child: Text('Trimestriel')),
                  DropdownMenuItem(
                      value: BudgetPeriod.yearly, child: Text('Annuel')),
                ],
                onChanged: (v) => setDialogState(() => period = v ?? period),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: amountController,
                decoration: const InputDecoration(labelText: 'Montant'),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Annuler')),
            FilledButton(
              onPressed: () {
                if (categoryId == null) return;
                repo.upsertBudgetEntry(
                  budgetYearId: budgetYearId,
                  categoryId: categoryId!,
                  period: period,
                  amount: double.tryParse(amountController.text) ?? 0,
                );
                Navigator.of(context).pop();
                dbProvider.touch();
              },
              child: const Text('Enregistrer'),
            ),
          ],
        ),
      ),
    );
  }
}
