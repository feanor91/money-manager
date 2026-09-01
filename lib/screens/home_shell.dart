import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../data/mmex_repository.dart';
import '../models/bill_deposit.dart';
import '../models/recurrence.dart';
import '../models/transaction.dart';
import '../state/database_provider.dart';
import '../widgets/webdav_conflict_dialog.dart';
import 'accounts_screen.dart';
import 'budget_screen.dart';
import 'dashboard_screen.dart';
import 'recurring_screen.dart';
import 'simulation_screen.dart';
import 'spending_explorer_screen.dart';
import 'transactions_screen.dart';

/// Same one-line platform-check convention as transactions_screen.dart/
/// dashboard_screen.dart - gates [SimulationScreen] off Android entirely
/// (2026-09-02 user request: "je ne vais utiliser cette fonctionnalité que
/// sur la version web et desktop") - never added to [_HomeShellState._screens]
/// or its nav destinations there at all, not just hidden.
bool get _isAndroidPlatform =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

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

  List<Widget> get _screens => [
        const DashboardScreen(),
        const TransactionsScreen(),
        const BudgetScreen(),
        const RecurringScreen(),
        const AccountsScreen(),
        const SpendingExplorerScreen(),
        if (!_isAndroidPlatform) const SimulationScreen(),
      ];

  /// Same breakpoint already used elsewhere in the app (the ledger
  /// table/cards split, the category spend analyzer's stacked panels) for
  /// "narrow enough that a phone-oriented layout is needed instead of the
  /// tablet/desktop/web one".
  static const _narrowNavBreakpoint = 640.0;

  /// The four most-used sections, kept directly on the bottom bar even on a
  /// narrow phone - see [_narrowNavBreakpoint].
  static const _primaryNavItems = [
    _NavItem(screenIndex: 0, icon: Icons.dashboard_outlined, selectedIcon: Icons.dashboard, label: 'Accueil'),
    _NavItem(screenIndex: 1, icon: Icons.receipt_long_outlined, selectedIcon: Icons.receipt_long, label: 'Transactions'),
    _NavItem(screenIndex: 2, icon: Icons.pie_chart_outline, selectedIcon: Icons.pie_chart, label: 'Budget'),
    _NavItem(screenIndex: 3, icon: Icons.autorenew, selectedIcon: Icons.autorenew, label: 'Récurrentes'),
  ];

  /// Tucked behind the "Plus" overflow item on a narrow phone - reference/
  /// analysis screens visited less often day-to-day than the four above.
  /// [SimulationScreen]'s own entry only exists here at all off Android
  /// (see [_isAndroidPlatform]) - its `screenIndex` (6) is only ever valid
  /// when [_screens] actually included it, which is exactly the same
  /// condition.
  List<_NavItem> get _overflowNavItems => [
        const _NavItem(screenIndex: 4, icon: Icons.account_balance_outlined, selectedIcon: Icons.account_balance, label: 'Comptes'),
        const _NavItem(screenIndex: 5, icon: Icons.query_stats_outlined, selectedIcon: Icons.query_stats, label: 'Explorateur'),
        if (!_isAndroidPlatform)
          const _NavItem(screenIndex: 6, icon: Icons.insights_outlined, selectedIcon: Icons.insights, label: 'Simulation'),
      ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _runRecurringCatchUp());
    // Update check moved to app.dart's _PinGateState (2026-08-07, user
    // request) - starts as soon as the database-picker/PIN screen shows
    // instead of waiting all the way until here (post-unlock).
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
          // Six labeled destinations comfortably fit a tablet/desktop/web
          // window, but crowd a real phone width badly enough that words
          // wrap mid-label (2026-09-01 user report, after adding
          // "Explorateur" as the 6th) - below _narrowNavBreakpoint, only
          // the four most-used sections stay directly on the bar; the rest
          // move behind a "Plus" overflow sheet (see _showOverflowMenu).
          // Same LayoutBuilder-on-width convention already used elsewhere
          // in the app for a narrow-screen layout (transactions_screen.dart's
          // ledger table/cards split, category_spend_analyzer.dart).
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= _narrowNavBreakpoint) {
                return NavigationBar(
                  selectedIndex: _index,
                  onDestinationSelected: (i) => setState(() => _index = i),
                  destinations: [
                    for (final item in [..._primaryNavItems, ..._overflowNavItems])
                      NavigationDestination(
                        icon: Icon(item.icon),
                        selectedIcon: Icon(item.selectedIcon),
                        label: item.label,
                      ),
                  ],
                );
              }
              final onOverflowScreen =
                  _overflowNavItems.any((item) => item.screenIndex == _index);
              final selectedSlot = onOverflowScreen
                  ? _primaryNavItems.length
                  : _primaryNavItems.indexWhere((item) => item.screenIndex == _index);
              return NavigationBar(
                selectedIndex: selectedSlot,
                onDestinationSelected: (slot) {
                  if (slot == _primaryNavItems.length) {
                    _showOverflowMenu(context);
                  } else {
                    setState(() => _index = _primaryNavItems[slot].screenIndex);
                  }
                },
                destinations: [
                  for (final item in _primaryNavItems)
                    NavigationDestination(
                      icon: Icon(item.icon),
                      selectedIcon: Icon(item.selectedIcon),
                      label: item.label,
                    ),
                  // Highlighted (via selectedSlot above) whenever the
                  // current screen is actually one of the overflowing
                  // ones, so "Plus" still reflects where the user is
                  // rather than always looking unselected.
                  const NavigationDestination(
                    icon: Icon(Icons.more_horiz),
                    selectedIcon: Icon(Icons.more_horiz),
                    label: 'Plus',
                  ),
                ],
              );
            },
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

  /// The "Plus" destination's target on a narrow screen - a plain modal
  /// bottom sheet (same dismiss-on-outside-tap default used everywhere else
  /// in the app for this kind of choice) listing whatever didn't fit
  /// directly on the bar. Highlights whichever one is the current screen,
  /// if any, so reopening this after already having navigated into
  /// "Comptes"/"Explorateur" doesn't look like nothing is selected anywhere.
  Future<void> _showOverflowMenu(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in _overflowNavItems)
              ListTile(
                leading: Icon(_index == item.screenIndex ? item.selectedIcon : item.icon),
                title: Text(item.label),
                selected: _index == item.screenIndex,
                onTap: () {
                  setState(() => _index = item.screenIndex);
                  Navigator.of(sheetContext).pop();
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// One bottom-nav destination, shared between the always-visible
/// [_HomeShellState._primaryNavItems] and the overflowing
/// [_HomeShellState._overflowNavItems] - [screenIndex] is the position in
/// [_HomeShellState._screens] this destination switches to, independent of
/// its own position on the bar (or in the overflow sheet).
class _NavItem {
  final int screenIndex;
  final IconData icon;
  final IconData selectedIcon;
  final String label;

  const _NavItem({
    required this.screenIndex,
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });
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
                : (payees[bill.payeeId]?.name ?? 'Tiers inconnu');
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
