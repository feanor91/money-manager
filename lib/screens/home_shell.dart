import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../data/mmex_repository.dart';
import '../models/bill_deposit.dart';
import '../models/recurrence.dart';
import '../models/transaction.dart';
import '../state/database_provider.dart';
import '../widgets/update_prompt.dart';
import '../widgets/webdav_conflict_dialog.dart';
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

  // Read once at startup (see pubspec.yaml's version field, bumped
  // automatically by the release CI) - null until it resolves, so the
  // corner label just stays blank for the first frame rather than showing
  // a placeholder.
  String? _version;

  static const _screens = [
    DashboardScreen(),
    TransactionsScreen(),
    BudgetScreen(),
    RecurringScreen(),
    AccountsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _runRecurringCatchUp());
    WidgetsBinding.instance
        .addPostFrameCallback((_) => checkForUpdatesAndPrompt(context));
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _version = info.version);
    });
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
        SnackBar(content: Text('$addedCount opération(s) récurrente(s) enregistrée(s) automatiquement')),
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
    final dbProvider = context.watch<DatabaseProvider>();
    return Scaffold(
      // A Stack overlay, not a Column - the banner floating on top of the
      // current screen rather than pushing it down. It used to sit above
      // an Expanded(IndexedStack(...)) in a Column, so it appearing/
      // disappearing shifted every control on the current screen down or
      // up by its own height, right when a save just failed - the exact
      // moment a misplaced tap (now landing on whatever shifted into that
      // spot) is most costly.
      body: Stack(
        children: [
          Positioned.fill(child: IndexedStack(index: _index, children: _screens)),
          // Both banners can in principle be relevant at once (a failed
          // local save and a pending WebDAV conflict are independent
          // states) - a Column of whichever are currently active, not an
          // assumption that only one can ever show.
          if (dbProvider.saveError != null ||
              dbProvider.syncStatus == SyncStatus.conflictPending ||
              dbProvider.syncStatus == SyncStatus.remoteMissing ||
              dbProvider.syncMessage != null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (dbProvider.saveError != null)
                    _SaveErrorBanner(error: dbProvider.saveError!),
                  if (dbProvider.syncStatus == SyncStatus.conflictPending ||
                      dbProvider.syncStatus == SyncStatus.remoteMissing)
                    _SyncConflictBanner(status: dbProvider.syncStatus),
                  if (dbProvider.syncMessage != null)
                    _SyncMessageBanner(message: dbProvider.syncMessage!),
                ],
              ),
            ),
        ],
      ),
      bottomNavigationBar: Stack(
        alignment: Alignment.bottomRight,
        children: [
          NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Accueil'),
              NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'Transactions'),
              NavigationDestination(icon: Icon(Icons.pie_chart_outline), selectedIcon: Icon(Icons.pie_chart), label: 'Budget'),
              NavigationDestination(icon: Icon(Icons.autorenew), selectedIcon: Icon(Icons.autorenew), label: 'Récurrentes'),
              NavigationDestination(icon: Icon(Icons.account_balance_outlined), selectedIcon: Icon(Icons.account_balance), label: 'Comptes'),
            ],
          ),
          if (dbProvider.hasPendingWrite)
            const Positioned(
              left: 8,
              bottom: 4,
              child: IgnorePointer(child: _SavingIndicator()),
            ),
          if (_version != null)
            // Positioned explicitly, like _SavingIndicator above - found
            // 2026-08-04 that this used to be a plain Padding, relying on
            // the Stack's own alignment: bottomRight to place it. That's
            // measured against the Stack's bounding box, which NavigationBar
            // (the Stack's sizing child) grows to accommodate Android's own
            // system gesture/button navigation bar - not something desktop
            // or web ever has to account for, which is almost certainly why
            // this went unnoticed until now: the label was very plausibly
            // being laid out correctly but ending up under/behind that
            // system bar on a real Android device. Positioned coordinates
            // are anchored directly to the Stack's edges the same way
            // _SavingIndicator's already are, sidestepping the question
            // entirely rather than trying to out-guess NavigationBar's own
            // inset math.
            Positioned(
              right: 6,
              bottom: 2,
              child: IgnorePointer(
                child: Text(
                  'v$_version',
                  style: TextStyle(
                    fontSize: 9,
                    color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Shown in the bottom nav bar whenever a write-back to the real .mmb file
/// is scheduled or actively running (DatabaseProvider.hasPendingWrite). This
/// is deliberately a presence indicator ("not yet safely on disk" vs "done"),
/// not a percentage gauge - the File System Access API doesn't expose
/// byte-level progress for a whole-file replace, so there's nothing to
/// measure a percentage from.
class _SavingIndicator extends StatelessWidget {
  const _SavingIndicator();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 11,
          height: 11,
          child: CircularProgressIndicator(strokeWidth: 1.8, color: color),
        ),
        const SizedBox(width: 5),
        Text('Sauvegarde…', style: TextStyle(fontSize: 10, color: color)),
      ],
    );
  }
}

/// Shown app-wide whenever the last write-back to the real .mmb file on
/// disk failed - a failed save must never happen silently, since the whole
/// point of the direct file link is that the app doesn't need a separate
/// "save" step the user could forget.
class _SaveErrorBanner extends StatelessWidget {
  final String error;

  const _SaveErrorBanner({required this.error});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Icon(Icons.error_outline, color: theme.colorScheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Échec de l\'enregistrement sur le fichier .mmb - vos dernières '
                  'modifications ne sont peut-être pas sauvegardées : $error',
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
              TextButton(
                onPressed: () => context.read<DatabaseProvider>().retrySave(),
                child: const Text('Réessayer'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown whenever Android WebDAV sync needs a decision from the user - a
/// genuine conflict, or the remote file having gone missing. Tinted
/// tertiary rather than error: unlike a failed save, this is an expected,
/// resolvable state (see DatabaseProvider's WebDAV sync section), not a
/// failure - a transient network/server error alone doesn't get a
/// persistent banner here (only visible via the dashboard's sync icon and
/// the settings card), since it may well resolve itself on the next
/// automatic retry at the next launch.
class _SyncConflictBanner extends StatelessWidget {
  final SyncStatus status;

  const _SyncConflictBanner({required this.status});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = status == SyncStatus.conflictPending
        ? 'La base a été modifiée à la fois sur ce téléphone et sur le serveur - '
            'une décision est nécessaire.'
        : 'Le fichier n\'est plus trouvé sur le serveur WebDAV.';
    return Material(
      color: theme.colorScheme.tertiaryContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Icon(Icons.cloud_sync_outlined, color: theme.colorScheme.onTertiaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(message,
                    style: TextStyle(color: theme.colorScheme.onTertiaryContainer)),
              ),
              TextButton(
                onPressed: () => handleWebDavSyncTap(context),
                child: const Text('Résoudre'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown briefly (auto-clears itself, see DatabaseProvider.syncMessage) after
/// a launch/resume/manual sync silently pushed or pulled something -
/// otherwise a successful automatic sync had zero visible confirmation,
/// which read exactly like nothing had happened at all. Tinted primary, not
/// tertiary/error: purely informational, nothing to resolve, no action
/// button.
class _SyncMessageBanner extends StatelessWidget {
  final String message;

  const _SyncMessageBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.primaryContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              Icon(Icons.cloud_done_outlined, color: theme.colorScheme.onPrimaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(message,
                    style: TextStyle(color: theme.colorScheme.onPrimaryContainer)),
              ),
            ],
          ),
        ),
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
      title: const Text('Opérations récurrentes à confirmer'),
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
          child: const Text('Enregistrer la sélection'),
        ),
      ],
    );
  }
}
