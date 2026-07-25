import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/mmex_repository.dart';
import '../models/bill_deposit.dart';
import '../models/recurrence.dart';
import '../models/transaction.dart';
import '../state/database_provider.dart';
import 'accounts_screen.dart';
import 'budget_screen.dart';
import 'dashboard_screen.dart';
import 'recurring_screen.dart';
import 'transactions_screen.dart';

/// Bottom navigation shell holding the main sections of the app.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _screens = [
    DashboardScreen(),
    TransactionsScreen(),
    RecurringScreen(),
    AccountsScreen(),
    BudgetScreen(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _runRecurringCatchUp());
  }

  Future<void> _runRecurringCatchUp() async {
    final dbProvider = context.read<DatabaseProvider>();
    final repo = dbProvider.repository;
    if (repo == null) return;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final due = repo.getDueBillDeposits(today);
    if (due.isEmpty) return;

    final silent = due.where((b) => b.autoExecute == RecurrenceAutoExecute.silent).toList();
    final notify = due.where((b) => b.autoExecute == RecurrenceAutoExecute.notify).toList();

    var addedCount = 0;
    for (final bill in silent) {
      addedCount += repo.catchUpBillDeposit(bill, today).length;
    }

    if (!mounted) return;
    if (addedCount > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$addedCount operation(s) recurrente(s) enregistree(s) automatiquement')),
      );
      dbProvider.touch();
    }

    if (notify.isNotEmpty) {
      await showDialog(
        context: context,
        builder: (_) => _RecurringCatchUpDialog(bills: notify, asOf: today, repo: repo),
      );
      if (mounted) dbProvider.touch();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Accueil'),
          NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'Transactions'),
          NavigationDestination(icon: Icon(Icons.autorenew), selectedIcon: Icon(Icons.autorenew), label: 'Recurrentes'),
          NavigationDestination(icon: Icon(Icons.account_balance_outlined), selectedIcon: Icon(Icons.account_balance), label: 'Comptes'),
          NavigationDestination(icon: Icon(Icons.pie_chart_outline), selectedIcon: Icon(Icons.pie_chart), label: 'Budget'),
        ],
      ),
    );
  }
}

/// Shown at startup when "notify"-mode recurring transactions are overdue:
/// lets the user pick which ones to record now before they're inserted.
class _RecurringCatchUpDialog extends StatefulWidget {
  final List<BillDeposit> bills;
  final DateTime asOf;
  final MmexRepository repo;

  const _RecurringCatchUpDialog({required this.bills, required this.asOf, required this.repo});

  @override
  State<_RecurringCatchUpDialog> createState() => _RecurringCatchUpDialogState();
}

class _RecurringCatchUpDialogState extends State<_RecurringCatchUpDialog> {
  late final Set<int> _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.bills.map((b) => b.id).toSet();
  }

  @override
  Widget build(BuildContext context) {
    final currency = widget.repo.getBaseCurrency();
    final payees = {for (final p in widget.repo.getPayees(onlyActive: false)) p.id: p};
    final accounts = {for (final a in widget.repo.getAccounts()) a.id: a};

    return AlertDialog(
      title: const Text('Operations recurrentes a confirmer'),
      content: SizedBox(
        width: 400,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: widget.bills.length,
          itemBuilder: (context, i) {
            final bill = widget.bills[i];
            final isTransfer = bill.transCode == TransCode.transfer;
            final signed = bill.transCode == TransCode.deposit ? bill.amount : -bill.amount;
            final title = isTransfer
                ? '${accounts[bill.accountId]?.name ?? '?'} → ${accounts[bill.toAccountId]?.name ?? '?'}'
                : (payees[bill.payeeId]?.name ?? 'Payé inconnu');
            return CheckboxListTile(
              value: _selected.contains(bill.id),
              onChanged: (v) => setState(() {
                if (v == true) {
                  _selected.add(bill.id);
                } else {
                  _selected.remove(bill.id);
                }
              }),
              title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${DateFormat.yMMMd('fr_FR').format(bill.nextOccurrence)} - '
                '${currency?.format(signed) ?? signed.toStringAsFixed(2)}',
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Ignorer pour l\'instant'),
        ),
        FilledButton(
          onPressed: () {
            for (final bill in widget.bills) {
              if (_selected.contains(bill.id)) {
                widget.repo.catchUpBillDeposit(bill, widget.asOf);
              }
            }
            Navigator.of(context).pop();
          },
          child: const Text('Enregistrer la selection'),
        ),
      ],
    );
  }
}
