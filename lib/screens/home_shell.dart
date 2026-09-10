import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import 'package:money_manager_core/data/mmex_repository.dart';
import 'package:money_manager_core/models/account.dart';
import 'package:money_manager_core/models/bill_deposit.dart';
import 'package:money_manager_core/models/currency.dart';
import 'package:money_manager_core/models/payee.dart';
import 'package:money_manager_core/models/recurrence.dart';
import 'package:money_manager_core/models/transaction.dart';
import '../state/api_session_provider.dart';
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

  // Tant que la connexion API automatique n'a pas fini de s'installer
  // (réussie, échouée ou expirée), les écrans (DashboardScreen en tête,
  // premier de l'IndexedStack) ne sont pas encore montés - voir
  // [_autoConnectApi]. Sans cette barrière, chaque écran ferait sa toute
  // première lecture en local (les bascules useApiForX ne passent à
  // `true` qu'une fois la connexion établie) et plantait immédiatement
  // si le fichier local est un simple fichier factice sans schéma MMEX
  // (trouvé 2026-09-10 : "fake.mmb" vide -> SqliteException "no such
  // table: ACCOUNTLIST_V1" dès l'ouverture).
  bool _autoConnectSettled = false;

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
    // La connexion API doit être tentée AVANT que les écrans (et le
    // rattrapage des opérations récurrentes) ne se montent - voir
    // [_autoConnectSettled].
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _autoConnectApi();
      if (mounted) setState(() => _autoConnectSettled = true);
      await _runRecurringCatchUp();
    });
    // Update check moved to app.dart's _PinGateState (2026-08-07, user
    // request) - starts as soon as the database-picker/PIN screen shows
    // instead of waiting all the way until here (post-unlock).
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _version = info.version);
    });
  }

  /// Connexion automatique au serveur API au démarrage (chantier écriture,
  /// demande explicite de l'utilisateur le 2026-09-10 - voir
  /// PLAN_ARCHITECTURE_CLIENT_SERVEUR.md) - évite d'avoir à se reconnecter
  /// manuellement à chaque lancement pendant que ce chantier est testé.
  /// Adresse locale d'Excelsior par défaut (même valeur que le champ
  /// pré-rempli de l'écran de connexion, voir api_debug_screen.dart) -
  /// échoue silencieusement (pas de dialogue d'erreur) si le serveur n'est
  /// pas joignable, l'appli reste utilisable en local comme avant.
  Future<void> _autoConnectApi() async {
    final apiSession = context.read<ApiSessionProvider>();
    if (apiSession.isConnected) return;
    // Délai court délibéré (le reste de l'appli, via ApiSessionProvider.
    // login appelé manuellement depuis l'écran de connexion, n'a lui aucun
    // délai imposé) - les écrans restent maintenant bloqués derrière
    // [_autoConnectSettled] tant que cet appel n'a pas fini, donc un
    // serveur injoignable (hors du réseau local, éteint...) ne doit pas
    // faire attendre l'utilisateur plus de quelques secondes à chaque
    // lancement avant de retomber en mode local.
    try {
      await apiSession.login('http://192.168.1.44:8899', '3364').timeout(const Duration(seconds: 4));
    } on TimeoutException {
      return;
    }
    if (!apiSession.isConnected) return;
    // Toutes les bascules activées d'office - le but de ce test est
    // justement de vérifier que chaque écran fonctionne intégralement via
    // le serveur, pas de les activer une par une à la main.
    apiSession.useApiForAccounts = true;
    apiSession.useApiForPayees = true;
    apiSession.useApiForCategories = true;
    apiSession.useApiForSpendingExplorer = true;
    apiSession.useApiForRecurring = true;
    apiSession.useApiForTransactions = true;
    apiSession.useApiForBudget = true;
    apiSession.useApiForDashboard = true;
  }

  Future<void> _runRecurringCatchUp() async {
    final dbProvider = context.read<DatabaseProvider>();
    final repo = dbProvider.repository;
    if (repo == null) return;
    final apiSession = context.read<ApiSessionProvider>();
    final useApi = apiSession.useApiForRecurring && apiSession.isConnected;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final allBills = useApi ? await apiSession.getBillDeposits() : repo.getBillDeposits();
    if (!mounted) return;
    final due = allBills.where((b) => !b.paused && !b.nextOccurrence.isAfter(today)).toList();
    if (due.isEmpty) return;

    final silent = due.where((b) => b.autoExecute == RecurrenceAutoExecute.silent).toList();
    final notify = due.where((b) => b.autoExecute == RecurrenceAutoExecute.notify).toList();

    var addedCount = 0;
    for (final bill in silent) {
      if (useApi) {
        addedCount += (await apiSession.catchUpBillDeposit(bill, today)).length;
      } else {
        addedCount += repo.catchUpBillDeposit(bill, today).length;
      }
    }

    if (!mounted) return;
    if (addedCount > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$addedCount opération(s) récurrente(s) enregistrée(s) automatiquement')),
      );
      if (!useApi) dbProvider.touch();
    }

    if (notify.isNotEmpty) {
      await showDialog(
        context: context,
        builder: (_) => _RecurringCatchUpDialog(
          bills: notify,
          asOf: today,
          repo: repo,
          apiSession: useApi ? apiSession : null,
        ),
      );
      if (mounted && !useApi) dbProvider.touch();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_autoConnectSettled) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
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
  final ApiSessionProvider? apiSession;

  const _RecurringCatchUpDialog(
      {required this.bills, required this.asOf, required this.repo, this.apiSession});

  @override
  State<_RecurringCatchUpDialog> createState() => _RecurringCatchUpDialogState();
}

class _RecurringCatchUpDialogState extends State<_RecurringCatchUpDialog> {
  late final Set<int> _selected;
  CurrencyFormat? _currency;
  Map<int, Payee>? _payees;
  Map<int, Account>? _accounts;

  @override
  void initState() {
    super.initState();
    _selected = widget.bills.map((b) => b.id).toSet();
    if (widget.apiSession != null) {
      _loadViaApi();
    } else {
      _currency = widget.repo.getBaseCurrency();
      _payees = {for (final p in widget.repo.getPayees(onlyActive: false)) p.id: p};
      _accounts = {for (final a in widget.repo.getAccounts()) a.id: a};
    }
  }

  Future<void> _loadViaApi() async {
    final session = widget.apiSession!;
    final currency = await session.getBaseCurrency();
    final payees = await session.getPayees(onlyActive: false);
    final accounts = await session.getAccounts();
    if (!mounted) return;
    setState(() {
      _currency = currency;
      _payees = {for (final p in payees) p.id: p};
      _accounts = {for (final a in accounts) a.id: a};
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_payees == null || _accounts == null) {
      return const AlertDialog(
        content: SizedBox(height: 80, child: Center(child: CircularProgressIndicator())),
      );
    }
    final currency = _currency;
    final payees = _payees!;
    final accounts = _accounts!;

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
          onPressed: () async {
            for (final bill in widget.bills) {
              if (_selected.contains(bill.id)) {
                if (widget.apiSession != null) {
                  await widget.apiSession!.catchUpBillDeposit(bill, widget.asOf);
                } else {
                  widget.repo.catchUpBillDeposit(bill, widget.asOf);
                }
              }
            }
            if (context.mounted) Navigator.of(context).pop();
          },
          child: const Text('Enregistrer la sélection'),
        ),
      ],
    );
  }
}
