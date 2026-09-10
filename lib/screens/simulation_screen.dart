import 'dart:async';
import 'dart:math' show max;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'package:money_manager_core/data/mmex_repository.dart';
import 'package:money_manager_core/models/account.dart';
import 'package:money_manager_core/models/bill_deposit.dart';
import 'package:money_manager_core/models/category.dart';
import 'package:money_manager_core/models/currency.dart';
import 'package:money_manager_core/models/payee.dart';
import 'package:money_manager_core/models/recurrence.dart';
import 'package:money_manager_core/models/sim_scenario.dart';
import 'package:money_manager_core/models/transaction.dart';
import '../state/api_session_provider.dart';
import '../state/database_provider.dart';
import '../theme/app_theme.dart';
import '../utils/date_picker.dart';
import '../widgets/refreshing_overlay.dart';

/// How far the projection looks - see PLAN_SIMULATION_LONG_TERME.md's open
/// "horizon nécessaire" question: rather than pick one answer, every option
/// realistically useful for retirement planning is offered, and the choice
/// is remembered per session (not persisted - a cheap, purely client-side
/// setting, same tier as [ForecastDuration] in forecast_chart.dart).
/// [oneYear] added 2026-09-02 specifically to match the dashboard's own
/// forecast chart's horizon ([ForecastDuration.oneYear]) - lets the user
/// compare the two side by side over the exact same window.
enum _Horizon { oneYear, fiveYears, tenYears, twentyYears, thirtyYears, fortyYears }

extension on _Horizon {
  int get years => switch (this) {
        _Horizon.oneYear => 1,
        _Horizon.fiveYears => 5,
        _Horizon.tenYears => 10,
        _Horizon.twentyYears => 20,
        _Horizon.thirtyYears => 30,
        _Horizon.fortyYears => 40,
      };
  String get label => '$years an${years > 1 ? 's' : ''}';
}

/// The handful of recurrence periods that actually make sense to type in by
/// hand for a new virtual/planned operation ("pension retraite", "loyer
/// perçu", ...) - deliberately a small curated subset of
/// [RecurrencePeriod]'s full 17 values (which include MMEX-specific
/// oddities like "dans (n) jours" that have no place in a from-scratch
/// planning tool), per the user's explicit "le plus simple possible" request
/// (2026-09-02).
const _simplePeriods = [
  RecurrencePeriod.monthly,
  RecurrencePeriod.quarterly,
  RecurrencePeriod.halfYearly,
  RecurrencePeriod.yearly,
  RecurrencePeriod.weekly,
];

/// Long-term "what if" scenario simulator (PLAN_SIMULATION_LONG_TERME.md,
/// phase 2) - full-page, desktop/web only (see home_shell.dart, which never
/// adds this to Android's navigation at all - the user only intends to use
/// this on a larger screen, 2026-09-02). Every edit writes straight to the
/// database and immediately recomputes/redraws the chart - no "Appliquer"
/// step anywhere, per the user's explicit "minimum de clics"/"tout doit
/// être dynamique" request. All figures come from
/// [MmexRepository.simulatedMonthlyNet] - 100% deterministic Dart
/// arithmetic over already-tested projection code (see
/// test/sim_scenario_test.dart), never the AI.
/// Données brutes de l'écran (scénarios/comptes/devise) qu'elles viennent
/// du fichier local ou du serveur API - même principe que les autres écrans
/// déjà migrés (voir dashboard_screen.dart). Les ajustements eux-mêmes
/// (_AdjustmentsPanel) et la courbe (_SimulationChart) font leur propre
/// chargement API-aware séparément, une fois qu'un scénario est
/// sélectionné.
class _SimulationData {
  final List<SimScenario> scenarios;
  final List<Account> accounts;
  final CurrencyFormat? currency;

  const _SimulationData({required this.scenarios, required this.accounts, required this.currency});
}

class SimulationScreen extends StatefulWidget {
  const SimulationScreen({super.key});

  @override
  State<SimulationScreen> createState() => _SimulationScreenState();
}

class _SimulationScreenState extends State<SimulationScreen> {
  int? _scenarioId;
  _Horizon _horizon = _Horizon.tenYears;

  /// Bumped by the "Rafraîchir" button (2026-09-03 user request: "pouvoir
  /// rafraîchir les scénarios de simulation quand j'ajoute des opérations
  /// récurrentes") - folded into [_AdjustmentsPanel]'s key below to force
  /// Flutter to fully tear down and recreate it (and every per-bill row
  /// state nested inside, each seeded once in its own initState) rather
  /// than just re-running build() on the existing State object. Adding a
  /// recurring bill elsewhere already reaches this screen reactively
  /// (Provider's `touch()` → `notifyListeners()`, watched via
  /// `context.watch<DatabaseProvider>()` below), so this is a deliberate
  /// belt-and-suspenders "start completely fresh" control for peace of
  /// mind, not a fix for a reproduced staleness bug.
  int _refreshNonce = 0;

  /// Whole-panel collapse - lives here, not inside _AdjustmentsPanel's own
  /// State, so the surrounding layout (wide-mode width, narrow-mode height)
  /// can actually shrink to match instead of leaving the space reserved.
  /// Starts collapsed (2026-09 user request: "collapse tout" means the
  /// panel too, not just each account section within it) - the chart gets
  /// the full view by default, the panel is one tap away when needed.
  bool _panelCollapsed = true;

  Future<_SimulationData>? _apiFuture;
  _SimulationData? _lastData;
  int? _apiFutureKey;

  _SimulationData _localData(MmexRepository repo, DatabaseProvider dbProvider) {
    return _SimulationData(
      scenarios: repo.getSimScenarios(),
      accounts:
          repo.getAccounts().where((a) => !dbProvider.isAccountHidden(a.id)).toList(),
      currency: repo.getBaseCurrency(),
    );
  }

  Future<_SimulationData> _loadViaApi(
      ApiSessionProvider session, DatabaseProvider dbProvider) async {
    final results =
        await Future.wait([session.getSimScenarios(), session.getAccounts(), session.getBaseCurrency()]);
    final scenarios = results[0] as List<SimScenario>;
    final accounts = (results[1] as List<Account>)
        .where((a) => !dbProvider.isAccountHidden(a.id))
        .toList();
    final currency = results[2] as CurrencyFormat?;
    return _SimulationData(scenarios: scenarios, accounts: accounts, currency: currency);
  }

  void _refreshApi(ApiSessionProvider session, DatabaseProvider dbProvider) {
    session.bumpDataVersion();
    setState(() {
      _apiFutureKey = session.dataVersion;
      _apiFuture = _loadViaApi(session, dbProvider);
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _selectMostRecentScenario());
  }

  Future<void> _selectMostRecentScenario() async {
    final dbProvider = context.read<DatabaseProvider>();
    final apiSession = context.read<ApiSessionProvider>();
    final useApi = apiSession.useApiForSimulation && apiSession.isConnected;
    final repo = dbProvider.repository;
    if (!useApi && repo == null) return;
    final scenarios =
        useApi ? await apiSession.getSimScenarios() : repo!.getSimScenarios();
    if (!mounted) return;
    if (scenarios.isNotEmpty) setState(() => _scenarioId = scenarios.first.id);
  }

  void _touch(DatabaseProvider dbProvider) => dbProvider.touch();

  Future<void> _createScenario(MmexRepository repo, DatabaseProvider dbProvider,
      {ApiSessionProvider? apiSession}) async {
    final name =
        await _promptText(context, title: 'Nouveau scénario', label: 'Nom');
    if (name == null || name.trim().isEmpty) return;
    final useApi = apiSession != null && apiSession.useApiForSimulation && apiSession.isConnected;
    final int id;
    if (useApi) {
      id = await apiSession.createSimScenario(name.trim());
      _refreshApi(apiSession, dbProvider);
    } else {
      id = repo.createSimScenario(name.trim());
      _touch(dbProvider);
    }
    if (mounted) setState(() => _scenarioId = id);
  }

  Future<void> _renameScenario(MmexRepository repo, DatabaseProvider dbProvider, SimScenario scenario,
      {ApiSessionProvider? apiSession}) async {
    final name = await _promptText(context,
        title: 'Renommer le scénario',
        label: 'Nom',
        initialValue: scenario.name);
    if (name == null || name.trim().isEmpty) return;
    final useApi = apiSession != null && apiSession.useApiForSimulation && apiSession.isConnected;
    if (useApi) {
      await apiSession.renameSimScenario(scenario.id, name.trim());
      _refreshApi(apiSession, dbProvider);
    } else {
      repo.renameSimScenario(scenario.id, name.trim());
      _touch(dbProvider);
    }
    if (mounted) setState(() {});
  }

  /// "Dupliquer ce scénario" (2026-09-03 user request) - suggests
  /// "{nom} (copie)" as a starting name, editable before confirming, same
  /// as [_renameScenario]'s prompt. Selects the new scenario afterward so
  /// the user lands straight on the copy to start tweaking it.
  Future<void> _duplicateScenario(
      MmexRepository repo, DatabaseProvider dbProvider, SimScenario scenario,
      {ApiSessionProvider? apiSession}) async {
    final name = await _promptText(context,
        title: 'Dupliquer le scénario',
        label: 'Nom du nouveau scénario',
        initialValue: '${scenario.name} (copie)');
    if (name == null || name.trim().isEmpty) return;
    final useApi = apiSession != null && apiSession.useApiForSimulation && apiSession.isConnected;
    final int newId;
    if (useApi) {
      newId = await apiSession.duplicateSimScenario(scenario.id, name.trim());
      _refreshApi(apiSession, dbProvider);
    } else {
      newId = repo.duplicateSimScenario(scenario.id, name.trim());
      _touch(dbProvider);
    }
    if (mounted) setState(() => _scenarioId = newId);
  }

  Future<void> _deleteScenario(MmexRepository repo, DatabaseProvider dbProvider, SimScenario scenario,
      {ApiSessionProvider? apiSession}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer ce scénario ?'),
        content: Text(
            '"${scenario.name}" et tous ses ajustements seront supprimés.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Annuler')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.negative),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final useApi = apiSession != null && apiSession.useApiForSimulation && apiSession.isConnected;
    if (useApi) {
      await apiSession.deleteSimScenario(scenario.id);
      _refreshApi(apiSession, dbProvider);
    } else {
      repo.deleteSimScenario(scenario.id);
      _touch(dbProvider);
    }
    if (!mounted) return;
    setState(() => _scenarioId = null);
    await _selectMostRecentScenario();
  }

  /// "3 comptes" / a single account's own name / "Tous les comptes" when
  /// every visible account is checked - keeps the toolbar button readable
  /// without listing every name.
  String _accountsSummaryLabel(List<Account> accounts, List<Account> selected) {
    if (selected.isEmpty) return 'Aucun compte';
    if (selected.length == accounts.length) return 'Tous les comptes';
    if (selected.length == 1) return selected.first.name;
    return '${selected.length} comptes';
  }

  Future<void> _selectAccounts(DatabaseProvider dbProvider,
      List<Account> accounts, List<Account> currentlySelected) async {
    final result = await showDialog<Set<int>>(
      context: context,
      builder: (context) => _AccountMultiSelectDialog(
        accounts: accounts,
        initiallySelected: currentlySelected.map((a) => a.id).toSet(),
      ),
    );
    if (result == null) return;
    await dbProvider.setSimulationSelectedAccountIds(result);
  }

  @override
  Widget build(BuildContext context) {
    final dbProvider = context.watch<DatabaseProvider>();
    final apiSession = context.watch<ApiSessionProvider>();
    final repo = dbProvider.repository;
    if (repo == null) return const SizedBox.shrink();

    if (apiSession.useApiForSimulation) {
      if (_apiFuture == null || _apiFutureKey != apiSession.dataVersion) {
        _apiFutureKey = apiSession.dataVersion;
        _apiFuture = _loadViaApi(apiSession, dbProvider);
      }
      return FutureBuilder<_SimulationData>(
        future: _apiFuture,
        builder: (context, snapshot) {
          // Garde les dernières données affichées pendant un
          // rafraîchissement plutôt que de faire disparaître toute la page
          // pour un simple spinner - même convention que les autres écrans
          // déjà migrés (2026-09-10).
          if (snapshot.hasData) _lastData = snapshot.data;
          if (_lastData == null) {
            if (snapshot.hasError) {
              return Scaffold(body: Center(child: Text('Erreur : ${snapshot.error}')));
            }
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          return RefreshingOverlay(
            refreshing: snapshot.connectionState != ConnectionState.done,
            child: _buildContent(context, dbProvider, repo, _lastData!,
                apiSession: apiSession,
                apiRefresh: () => _refreshApi(apiSession, dbProvider)),
          );
        },
      );
    }

    _apiFuture = null;
    return _buildContent(context, dbProvider, repo, _localData(repo, dbProvider));
  }

  Widget _buildContent(
    BuildContext context,
    DatabaseProvider dbProvider,
    MmexRepository repo,
    _SimulationData data, {
    ApiSessionProvider? apiSession,
    VoidCallback? apiRefresh,
  }) {
    final scenarios = data.scenarios;
    if (_scenarioId != null && !scenarios.any((s) => s.id == _scenarioId)) {
      _scenarioId = scenarios.isEmpty ? null : scenarios.first.id;
    }
    final scenario = scenarios.where((s) => s.id == _scenarioId).firstOrNull;
    final accounts = data.accounts;
    final currency = data.currency;
    // Checkbox-based multi-account selection (2026-09 user request: show
    // one baseline+scenario curve per checked account, side by side,
    // instead of a single account or a merged "tous les comptes" total).
    // Persisted via DatabaseProvider.simulationSelectedAccountIds, filtered
    // to accounts that still actually exist/aren't hidden. Falls back to
    // the dashboard's own "in focus" account (same idea the old
    // single-account selector used) only the very first time this screen
    // is opened, when nothing has been saved here yet - never once the
    // user has actually picked something, even an empty selection.
    final savedIds = dbProvider.simulationSelectedAccountIds
        .where((id) => accounts.any((a) => a.id == id))
        .toSet();
    final selectedAccounts = dbProvider.simulationSelectedAccountIds.isNotEmpty
        ? accounts.where((a) => savedIds.contains(a.id)).toList()
        : accounts.where((a) => a.id == dbProvider.selectedAccountId).toList();
    // "Jour de prévision du solde" (Paramètres) - the day of the month
    // "Retour à l'équilibre" recurs on, every month (2026-09-02 user
    // request for the mechanism it replaces, "solde final supposé";
    // redesigned 2026-09-04 - see
    // MmexRepository.simulatedDailyNetWithMeanReversion). Same date the
    // dashboard's own near-term forecast already anchors to
    // (dashboard_screen.dart) - computed inside _AdjustmentsPanel itself
    // (its flag button lives there, one per account).

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Simulation'),
            if (scenarios.isNotEmpty) ...[
              const SizedBox(width: 16),
              DropdownButton<int>(
                value: _scenarioId,
                underline: const SizedBox.shrink(),
                items: [
                  for (final s in scenarios)
                    DropdownMenuItem(value: s.id, child: Text(s.name)),
                ],
                onChanged: (id) => setState(() => _scenarioId = id),
              ),
            ],
          ],
        ),
        actions: [
          if (scenario != null) ...[
            IconButton(
              tooltip: 'Renommer',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _renameScenario(repo, dbProvider, scenario, apiSession: apiSession),
            ),
            IconButton(
              tooltip: 'Supprimer ce scénario',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _deleteScenario(repo, dbProvider, scenario, apiSession: apiSession),
            ),
            IconButton(
              tooltip: 'Dupliquer ce scénario',
              icon: const Icon(Icons.copy_outlined),
              onPressed: () =>
                  _duplicateScenario(repo, dbProvider, scenario, apiSession: apiSession),
            ),
          ],
          IconButton(
            tooltip: 'Nouveau scénario',
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () => _createScenario(repo, dbProvider, apiSession: apiSession),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Rafraîchir (après avoir ajouté des opérations '
                'récurrentes, par exemple)',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              if (apiRefresh != null) {
                apiRefresh();
              } else {
                setState(() => _refreshNonce++);
              }
            },
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: accounts.isEmpty
                ? null
                : () => _selectAccounts(dbProvider, accounts, selectedAccounts),
            icon: const Icon(Icons.checklist),
            label: Text(_accountsSummaryLabel(accounts, selectedAccounts)),
          ),
          const SizedBox(width: 8),
          DropdownButton<_Horizon>(
            value: _horizon,
            underline: const SizedBox.shrink(),
            items: [
              for (final h in _Horizon.values)
                DropdownMenuItem(value: h, child: Text(h.label)),
            ],
            onChanged: (h) => setState(() => _horizon = h!),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: scenario == null
          ? _buildEmptyState(context, repo, dbProvider, apiSession: apiSession)
          : LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 900;
                final selectedAccountIds =
                    selectedAccounts.map((a) => a.id).toList();
                final panel = _AdjustmentsPanel(
                  key: ValueKey(
                      '${scenario.id}_${_refreshNonce}_${apiSession?.dataVersion}'),
                  repo: repo,
                  scenario: scenario,
                  accountIds: selectedAccountIds,
                  accounts: accounts,
                  currency: currency,
                  startDay: dbProvider.forecastDay,
                  collapsed: _panelCollapsed,
                  apiSession: apiSession,
                  onToggleCollapsed: () =>
                      setState(() => _panelCollapsed = !_panelCollapsed),
                  onChanged: () {
                    if (apiRefresh != null) {
                      apiRefresh();
                    } else {
                      _touch(dbProvider);
                    }
                    setState(() {});
                  },
                );
                final chart = _SimulationChart(
                  key: ValueKey('${scenario.id}_${apiSession?.dataVersion}'),
                  repo: repo,
                  scenarioId: scenario.id,
                  accountIds: selectedAccountIds,
                  accounts: accounts,
                  horizonMonths: _horizon.years * 12,
                  currency: currency,
                  startDay: dbProvider.forecastDay,
                  apiSession: apiSession,
                );
                if (wide) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: _panelCollapsed ? 56 : 420, child: panel),
                      const VerticalDivider(width: 1),
                      Expanded(
                          child: Padding(
                              padding: const EdgeInsets.all(16), child: chart)),
                    ],
                  );
                }
                return Column(
                  children: [
                    _panelCollapsed
                        ? Expanded(child: chart)
                        : SizedBox(height: 320, child: chart),
                    const Divider(height: 1),
                    _panelCollapsed
                        ? SizedBox(height: 56, child: panel)
                        : Expanded(child: panel),
                  ],
                );
              },
            ),
    );
  }

  Widget _buildEmptyState(BuildContext context, MmexRepository repo, DatabaseProvider dbProvider,
      {ApiSessionProvider? apiSession}) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insights_outlined,
              size: 64, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 16),
          Text('Aucun scénario pour l\'instant',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            'Un scénario te permet de simuler l\'impact d\'un changement\n'
            '(perte de revenu, nouvelle pension, arrêt d\'une charge...)\n'
            'sur plusieurs années, sans jamais toucher tes vraies données.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () => _createScenario(repo, dbProvider, apiSession: apiSession),
            icon: const Icon(Icons.add),
            label: const Text('Créer un scénario'),
          ),
        ],
      ),
    );
  }
}

/// Checkbox picker for which accounts show their own baseline+scenario
/// curve on the simulation chart (2026-09 user request) - same
/// `AlertDialog(content: SizedBox(...ListView...))` shape budget_screen.dart's
/// own multi-select dialogs already use. At least one account must stay
/// checked to save: an empty selection would leave the chart with nothing
/// to draw, and would also be indistinguishable from "never configured yet"
/// (see DatabaseProvider.simulationSelectedAccountIds's own doc comment),
/// which falls back to the dashboard's selected account instead of staying
/// empty.
class _AccountMultiSelectDialog extends StatefulWidget {
  final List<Account> accounts;
  final Set<int> initiallySelected;

  const _AccountMultiSelectDialog({
    required this.accounts,
    required this.initiallySelected,
  });

  @override
  State<_AccountMultiSelectDialog> createState() =>
      _AccountMultiSelectDialogState();
}

class _AccountMultiSelectDialogState extends State<_AccountMultiSelectDialog> {
  late Set<int> _selected = {...widget.initiallySelected};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Comptes affichés sur la simulation'),
      content: SizedBox(
        width: 360,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                TextButton(
                  onPressed: () => setState(
                      () => _selected = widget.accounts.map((a) => a.id).toSet()),
                  child: const Text('Tout cocher'),
                ),
                TextButton(
                  onPressed: () => setState(() => _selected = {}),
                  child: const Text('Tout décocher'),
                ),
              ],
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                children: [
                  for (final a in widget.accounts)
                    CheckboxListTile(
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _selected.contains(a.id),
                      onChanged: (v) => setState(() {
                        if (v ?? false) {
                          _selected.add(a.id);
                        } else {
                          _selected.remove(a.id);
                        }
                      }),
                      title: Text(a.name),
                    ),
                ],
              ),
            ),
            if (_selected.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Coche au moins un compte.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler')),
        FilledButton(
          onPressed:
              _selected.isEmpty ? null : () => Navigator.of(context).pop(_selected),
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}

Future<String?> _promptText(
  BuildContext context, {
  required String title,
  required String label,
  String? initialValue,
  // Longer explanation shown as its own wrapped line above the field,
  // separate from [label] - found 2026-09 that a long sentence passed as
  // the field's own `labelText` (the assumed-final-balance prompt's, at
  // the time) gets silently truncated with "…" instead of wrapping, since
  // a TextField's floating label is always a single line by Material
  // design. Short labels ("Nom", "Montant"...) still just use [label]
  // directly and never need this.
  String? helperText,
}) {
  final controller = TextEditingController(text: initialValue);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (helperText != null) ...[
              Text(helperText,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(labelText: label),
              onSubmitted: (v) => Navigator.of(context).pop(v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: const Text('Valider'),
        ),
      ],
    ),
  );
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

/// The left/top panel listing every adjustment this scenario makes - real
/// bills (with inline "arrêt le"/"nouveau montant" fields), virtual bills,
/// and one-off events, grouped into one collapsible section per selected
/// account (2026-09 user feedback: showing every account's items in one
/// merged list made it impossible to tell which account a given adjustment
/// actually belonged to). The whole panel can also collapse down to a
/// single button, to give the chart more room. Every control commits
/// immediately (no "Enregistrer" button anywhere in this panel) via
/// [_AdjustmentsPanel.onChanged], which the parent uses to persist
/// ([DatabaseProvider.touch]) and recompute the chart.
class _AdjustmentsPanel extends StatefulWidget {
  final MmexRepository repo;
  final SimScenario scenario;
  final List<int> accountIds;
  final List<Account> accounts;
  final CurrencyFormat? currency;
  final VoidCallback onChanged;
  final int startDay;

  /// Whole-panel collapse state - owned by the parent (not this widget's
  /// own State) so the *layout* around it (the wide-mode SizedBox width,
  /// the narrow-mode row height) can actually shrink to match, instead of
  /// reserving the same space regardless (2026-09 user report: collapsing
  /// used to leave the chart stuck at its original width, the panel just
  /// showing a mostly-empty strip inside the space it still reserved).
  final bool collapsed;
  final VoidCallback onToggleCollapsed;

  /// Non-null ET connecté : les lectures/écritures passent par le serveur
  /// au lieu du fichier local (voir simulation_screen.dart's own doc
  /// comment at the top of the file).
  final ApiSessionProvider? apiSession;

  const _AdjustmentsPanel({
    super.key,
    required this.repo,
    required this.scenario,
    required this.accountIds,
    required this.accounts,
    required this.currency,
    required this.onChanged,
    required this.startDay,
    required this.collapsed,
    required this.onToggleCollapsed,
    this.apiSession,
  });

  @override
  State<_AdjustmentsPanel> createState() => _AdjustmentsPanelState();
}

/// Tout ce dont [_AdjustmentsPanelState._buildContent] a besoin, préchargé
/// en un seul lot au montage en mode API (voir [_AdjustmentsPanelState._loadPanelDataViaApi])
/// plutôt que lu en synchrone à chaque build comme en local -
/// [naturalEndDateByBillId] ne couvre que les factures à durée limitée (voir
/// [_AdjustmentsPanelState._naturalEndDate]), les autres n'y figurent pas.
class _PanelApiData {
  final Map<int, Payee> payeesById;
  final Map<int, Category> categoriesById;
  final Map<int, SimBillOverride> overridesByBillId;
  final List<BillDeposit> allRealBills;
  final List<SimVirtualBill> allVirtualBills;
  final List<SimOneOffEvent> allEvents;
  final Map<int, DateTime?> naturalEndDateByBillId;
  final Map<int, ({bool enabled, double? equilibrium, double strength, double noisePercent})>
      meanReversionByAccountId;

  const _PanelApiData({
    required this.payeesById,
    required this.categoriesById,
    required this.overridesByBillId,
    required this.allRealBills,
    required this.allVirtualBills,
    required this.allEvents,
    required this.naturalEndDateByBillId,
    required this.meanReversionByAccountId,
  });
}

class _AdjustmentsPanelState extends State<_AdjustmentsPanel> {
  /// Per-account expand state for each account's own section below - unlike
  /// [_AdjustmentsPanel.collapsed] (the whole panel), this never affects the
  /// surrounding layout, so it's fine to keep purely local. Empty = every
  /// account section starts collapsed (2026-09 user request) - opt-in to
  /// expand, not opt-in to collapse, so a newly-selected account also
  /// starts collapsed without needing to track it explicitly.
  final Set<int> _expandedAccountIds = {};

  MmexRepository get repo => widget.repo;
  SimScenario get scenario => widget.scenario;
  List<int> get accountIds => widget.accountIds;
  List<Account> get accounts => widget.accounts;
  CurrencyFormat? get currency => widget.currency;
  VoidCallback get onChanged => widget.onChanged;
  int get startDay => widget.startDay;

  bool get _useApi =>
      widget.apiSession != null && widget.apiSession!.useApiForSimulation && widget.apiSession!.isConnected;

  _PanelApiData? _apiData;

  @override
  void initState() {
    super.initState();
    if (_useApi) _loadPanelDataViaApi();
  }

  /// Un seul lot de requêtes en parallèle (Future.wait) pour tout ce dont
  /// [_buildContent] a besoin - voir [_PanelApiData]. Ce panneau est
  /// entièrement démonté/remonté (nouvelle clé, voir simulation_screen.dart)
  /// après chaque écriture, donc pas besoin d'invalider ce cache soi-même :
  /// un nouveau montage relance simplement ce chargement.
  Future<void> _loadPanelDataViaApi() async {
    final session = widget.apiSession!;
    final results = await Future.wait([
      session.getPayees(onlyActive: false),
      session.getCategories(onlyActive: false),
      session.getSimBillOverrides(scenario.id),
      session.getBillDeposits(),
      session.getSimVirtualBills(scenario.id),
      session.getSimOneOffEvents(scenario.id),
    ]);
    final payees = results[0] as List<Payee>;
    final categories = results[1] as List<Category>;
    final overrides = results[2] as List<SimBillOverride>;
    final allRealBills = (results[3] as List<BillDeposit>).where((b) => !b.paused).toList();
    final allVirtualBills = results[4] as List<SimVirtualBill>;
    final allEvents = results[5] as List<SimOneOffEvent>;

    final limitedBills = allRealBills
        .where((b) => !periodUsesXParam(b.period) && b.numOccurrences > 0)
        .toList();
    final farFuture = DateTime(DateTime.now().year + 60);
    final occurrenceLists = await Future.wait([
      for (final bill in limitedBills)
        session.occurrencesForBill(bill, bill.nextOccurrence, farFuture),
    ]);
    final naturalEndDateByBillId = <int, DateTime?>{};
    for (var i = 0; i < limitedBills.length; i++) {
      final occurrences = occurrenceLists[i];
      naturalEndDateByBillId[limitedBills[i].id] =
          occurrences.length < limitedBills[i].numOccurrences
              ? null
              : occurrences[limitedBills[i].numOccurrences - 1];
    }

    final reversionResults = await Future.wait(
        [for (final a in accounts) session.getSimMeanReversion(scenario.id, a.id)]);
    final meanReversionByAccountId = <int,
        ({bool enabled, double? equilibrium, double strength, double noisePercent})>{};
    for (var i = 0; i < accounts.length; i++) {
      final reversion = reversionResults[i];
      if (reversion != null) meanReversionByAccountId[accounts[i].id] = reversion;
    }

    if (!mounted) return;
    setState(() {
      _apiData = _PanelApiData(
        payeesById: {for (final p in payees) p.id: p},
        categoriesById: {for (final c in categories) c.id: c},
        overridesByBillId: {for (final o in overrides) o.billId: o},
        allRealBills: allRealBills,
        allVirtualBills: allVirtualBills,
        allEvents: allEvents,
        naturalEndDateByBillId: naturalEndDateByBillId,
        meanReversionByAccountId: meanReversionByAccountId,
      );
    });
  }

  /// The date a limited-duration bill (a fixed remaining occurrence count,
  /// e.g. the last N payments left on a loan - see
  /// [BillDeposit.numOccurrences]'s own doc comment) will fire for the last
  /// time - reuses the exact same occurrence-walking engine the real
  /// projection is built on ([MmexRepository.occurrencesForBill]), just
  /// asked for a long enough window to contain every remaining occurrence.
  /// Null for a bill that repeats forever, or one of the 4 "dans/tous les X
  /// ..." periods where [BillDeposit.numOccurrences] means something else
  /// entirely (an interval, not a count - see [periodUsesXParam]). En mode
  /// API, lit [_PanelApiData.naturalEndDateByBillId] (précalculé) plutôt
  /// que de recalculer en direct.
  DateTime? _naturalEndDate(BillDeposit bill) {
    if (periodUsesXParam(bill.period) || bill.numOccurrences <= 0) return null;
    if (_useApi) return _apiData?.naturalEndDateByBillId[bill.id];
    final farFuture = DateTime(DateTime.now().year + 60);
    final occurrences =
        repo.occurrencesForBill(bill, bill.nextOccurrence, farFuture);
    if (occurrences.length < bill.numOccurrences) return null;
    return occurrences[bill.numOccurrences - 1];
  }

  String _billTooltip(
    BillDeposit bill,
    String label,
    Map<int, Category> categoriesById,
    Map<int, Account> accountsById,
  ) {
    final buffer = StringBuffer(label);
    buffer.write(
        bill.transCode == TransCode.deposit ? ' (revenu)' : ' (dépense)');
    final categoryPath = categoryFullPath(bill.categoryId, categoriesById);
    if (categoryPath.isNotEmpty) buffer.write('\nCatégorie : $categoryPath');
    buffer.write('\nCompte : ${accountsById[bill.accountId]?.name ?? "?"}');
    buffer.write('\nPériodicité : ${recurrencePeriodLabel(bill.period)}');
    buffer.write(
        '\nProchaine échéance : ${DateFormat('d MMM yyyy', 'fr_FR').format(bill.nextOccurrence)}');
    if ((bill.notes ?? '').trim().isNotEmpty) {
      buffer.write('\nNotes : ${bill.notes!.trim()}');
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    // Found 2026-09: collapsing/expanding the *whole* panel (as opposed to
    // one account's own section, which has its own RepaintBoundary fix
    // right below) could leave the exact same kind of blank/grey
    // rectangle behind, reproduced live - toggling this swaps the returned
    // widget between a tiny Align and the full scrolling Column below,
    // while this State object (and its BuildContext/Element) stays the
    // same. A keyed RepaintBoundary that changes key on every toggle
    // forces Flutter to genuinely discard and remount the old compositing
    // layer instead of trying to reuse/diff it - the same fix as the
    // per-account one, one level up.
    return RepaintBoundary(
      key: ValueKey('sim-panel-repaint-${widget.collapsed}'),
      child: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (widget.collapsed) {
      return Align(
        alignment: Alignment.topCenter,
        child: IconButton(
          tooltip: 'Afficher les ajustements',
          icon: const Icon(Icons.chevron_right),
          onPressed: widget.onToggleCollapsed,
        ),
      );
    }

    if (_useApi && _apiData == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final accountsById = {for (final a in accounts) a.id: a};
    final Map<int, Payee> payeesById;
    final Map<int, Category> categoriesById;
    final Map<int, SimBillOverride> overridesByBillId;
    final List<BillDeposit> allRealBills;
    final List<SimVirtualBill> allVirtualBills;
    final List<SimOneOffEvent> allEvents;
    if (_useApi) {
      final data = _apiData!;
      payeesById = data.payeesById;
      categoriesById = data.categoriesById;
      overridesByBillId = data.overridesByBillId;
      allRealBills = data.allRealBills;
      allVirtualBills = data.allVirtualBills;
      allEvents = data.allEvents;
    } else {
      payeesById = {for (final p in repo.getPayees(onlyActive: false)) p.id: p};
      categoriesById = {for (final c in repo.getCategories(onlyActive: false)) c.id: c};
      overridesByBillId = {for (final o in repo.getSimBillOverrides(scenario.id)) o.billId: o};
      // Every real/virtual/one-off item, unfiltered - each account's own
      // section below picks out just its own from these.
      allRealBills = repo.getBillDeposits().where((b) => !b.paused).toList();
      allVirtualBills = repo.getSimVirtualBills(scenario.id);
      allEvents = repo.getSimOneOffEvents(scenario.id);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
          child: Row(
            children: [
              Expanded(
                  child: Text('Ajustements',
                      style: Theme.of(context).textTheme.titleMedium)),
              IconButton(
                tooltip: 'Replier',
                icon: const Icon(Icons.chevron_left),
                onPressed: widget.onToggleCollapsed,
              ),
            ],
          ),
        ),
        Expanded(
          child: accountIds.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                      'Sélectionne au moins un compte pour voir/modifier ses ajustements.'),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
                  children: [
                    for (final id in accountIds)
                      if (accountsById[id] != null)
                        _buildAccountSection(
                          context,
                          accountsById[id]!,
                          payeesById,
                          accountsById,
                          categoriesById,
                          overridesByBillId,
                          allRealBills,
                          allVirtualBills,
                          allEvents,
                        ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildAccountSection(
    BuildContext context,
    Account account,
    Map<int, Payee> payeesById,
    Map<int, Account> accountsById,
    Map<int, Category> categoriesById,
    Map<int, SimBillOverride> overridesByBillId,
    List<BillDeposit> allRealBills,
    List<SimVirtualBill> allVirtualBills,
    List<SimOneOffEvent> allEvents,
  ) {
    final realBills = allRealBills
        .where((b) => b.accountId == account.id || b.toAccountId == account.id)
        .toList()
      // Biggest recurring items first (2026-09-02 user request) - by
      // magnitude regardless of income/expense direction, same convention
      // as this app's other rankings (top expenses, category spend).
      ..sort((a, b) => b.amount.abs().compareTo(a.amount.abs()));
    final virtualBills = allVirtualBills.where((v) => v.accountId == account.id).toList()
      ..sort((a, b) => b.amount.abs().compareTo(a.amount.abs()));
    final events = allEvents.where((e) => e.accountId == account.id).toList()
      ..sort((a, b) => b.amount.abs().compareTo(a.amount.abs()));

    final expanded = _expandedAccountIds.contains(account.id);
    // Found 2026-09: re-expanding an ExpansionTile inside this scrolling
    // panel left a blank/grey rectangle where its content should be, with
    // a sliver of the chart's own pixels bleeding through at the edge -
    // adding `maintainState: true` (the standard fix for ExpansionTile
    // losing its child subtree on collapse) did not fix it, pointing at a
    // paint/compositing glitch from its SizeTransition rather than a lost
    // subtree. Replaced with a plain conditional (no animation at all, so
    // nothing to glitch) wrapped in its own RepaintBoundary, trading the
    // expand animation away for a symptom that structurally can't recur.
    return RepaintBoundary(
      child: Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: () => setState(() {
                if (expanded) {
                  _expandedAccountIds.remove(account.id);
                } else {
                  _expandedAccountIds.add(account.id);
                }
              }),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(account.name,
                          style: Theme.of(context).textTheme.titleSmall),
                    ),
                    Icon(expanded ? Icons.expand_less : Icons.expand_more),
                  ],
                ),
              ),
            ),
            if (expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
          Row(
            children: [
              Expanded(
                  child: Text('Opérations virtuelles',
                      style: Theme.of(context).textTheme.labelLarge)),
              () {
                final reversion = _useApi
                    ? _apiData!.meanReversionByAccountId[account.id]
                    : repo.getSimMeanReversion(scenario.id, account.id);
                return IconButton(
                  tooltip: reversion == null
                      ? 'Configurer le retour à l\'équilibre pour ce compte'
                      : reversion.enabled
                          ? 'Retour à l\'équilibre activé pour ce compte'
                          : 'Retour à l\'équilibre désactivé pour ce compte '
                              '(réglages conservés)',
                  icon: Icon(
                    Icons.balance,
                    color: reversion != null && reversion.enabled
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  onPressed: () =>
                      _openMeanReversionDialog(context, account.id),
                );
              }(),
              IconButton(
                tooltip: 'Ajustement réaliste (dépenses imprévues, calculé '
                    'depuis l\'historique)',
                icon: const Icon(Icons.auto_graph),
                onPressed: () =>
                    _openDiscretionaryAdjustmentDialog(context, account.id),
              ),
              IconButton(
                tooltip: 'Ajouter une opération virtuelle',
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () => _openVirtualBillDialog(context, account.id),
              ),
            ],
          ),
          if (virtualBills.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Aucune - ex. "pension de retraite +1200€/mois".'),
            ),
          for (final v in virtualBills)
            Tooltip(
              message:
                  '${v.label} (${v.transCode == TransCode.deposit ? "revenu" : "dépense"})\n'
                  'Compte : ${accountsById[v.accountId]?.name ?? "?"}\n'
                  'Périodicité : ${recurrencePeriodLabel(v.period)}\n'
                  'À partir du : ${DateFormat('d MMM yyyy', 'fr_FR').format(v.startDate)}'
                  '${v.variancePercent > 0 ? '\nVariation aléatoire : ±${v.variancePercent.round()} %' : ''}',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  v.transCode == TransCode.deposit
                      ? Icons.south_west
                      : Icons.north_east,
                  color: v.transCode == TransCode.deposit
                      ? AppTheme.positive
                      : AppTheme.negative,
                ),
                title: Text(v.label),
                subtitle: Text(
                  '${currency?.format(v.amount) ?? v.amount.toStringAsFixed(2)} - '
                  '${recurrencePeriodLabel(v.period)} - à partir du '
                  '${DateFormat('d MMM yyyy', 'fr_FR').format(v.startDate)}',
                ),
                onTap: () => _openVirtualBillDialog(context, account.id, existing: v),
                trailing: IconButton(
                  tooltip: 'Supprimer',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () async {
                    if (_useApi) {
                      await widget.apiSession!.deleteSimVirtualBill(v.id);
                    } else {
                      repo.deleteSimVirtualBill(v.id);
                    }
                    onChanged();
                  },
                ),
              ),
            ),
          const Divider(height: 24),
          Text('Opérations récurrentes réelles',
              style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          const Text(
            'Laisse vide pour ne rien changer. "Arrêt le" exclut cette opération '
            'à partir de cette date ; "Nouveau montant" remplace son montant '
            'réel dans ce scénario uniquement.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          if (realBills.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Aucune opération récurrente sur ce compte.'),
            ),
          for (final bill in realBills)
            _RealBillRow(
              key: ValueKey('bill-${bill.id}'),
              bill: bill,
              label: _billLabel(bill, payeesById, accountsById),
              tooltip: _billTooltip(
                  bill,
                  _billLabel(bill, payeesById, accountsById),
                  categoriesById,
                  accountsById),
              naturalEndDate: _naturalEndDate(bill),
              currency: currency,
              savedOverride: overridesByBillId[bill.id],
              onChanged: (disabledFrom, amountOverride) async {
                final hasNoOverride =
                    disabledFrom == null && amountOverride == null;
                if (_useApi) {
                  if (hasNoOverride) {
                    await widget.apiSession!.deleteSimBillOverride(scenario.id, bill.id);
                  } else {
                    await widget.apiSession!.upsertSimBillOverride(scenario.id, bill.id,
                        disabledFrom: disabledFrom, amountOverride: amountOverride);
                  }
                } else {
                  if (hasNoOverride) {
                    repo.deleteSimBillOverride(scenario.id, bill.id);
                  } else {
                    repo.upsertSimBillOverride(scenario.id, bill.id,
                        disabledFrom: disabledFrom, amountOverride: amountOverride);
                  }
                }
                onChanged();
              },
            ),
          const Divider(height: 24),
          Row(
            children: [
              Expanded(
                  child: Text('Événements ponctuels',
                      style: Theme.of(context).textTheme.labelLarge)),
              IconButton(
                tooltip: 'Ajouter un événement ponctuel',
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () => _openOneOffEventDialog(context, account.id),
              ),
            ],
          ),
          if (events.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Aucun - ex. "capital de départ +50000€".'),
            ),
          for (final e in events)
            Tooltip(
              message:
                  '${e.label} (${e.transCode == TransCode.deposit ? "revenu" : "dépense"})\n'
                  'Compte : ${accountsById[e.accountId]?.name ?? "?"}\n'
                  'Date : ${DateFormat('d MMM yyyy', 'fr_FR').format(e.date)}',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  e.transCode == TransCode.deposit
                      ? Icons.south_west
                      : Icons.north_east,
                  color: e.transCode == TransCode.deposit
                      ? AppTheme.positive
                      : AppTheme.negative,
                ),
                title: Text(e.label),
                subtitle: Text(
                  '${currency?.format(e.amount) ?? e.amount.toStringAsFixed(2)} le '
                  '${DateFormat('d MMM yyyy', 'fr_FR').format(e.date)}',
                ),
                trailing: IconButton(
                  tooltip: 'Supprimer',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () async {
                    if (_useApi) {
                      await widget.apiSession!.deleteSimOneOffEvent(e.id);
                    } else {
                      repo.deleteSimOneOffEvent(e.id);
                    }
                    onChanged();
                  },
                ),
              ),
            ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _billLabel(BillDeposit bill, Map<int, Payee> payeesById,
      Map<int, Account> accountsById) {
    if (bill.transCode == TransCode.transfer) {
      return '${accountsById[bill.accountId]?.name ?? "?"} → '
          '${accountsById[bill.toAccountId]?.name ?? "?"}';
    }
    return payeesById[bill.payeeId]?.name ?? 'Tiers inconnu';
  }

  /// "Retour à l'équilibre" (2026-09-04, replacing "solde final supposé" -
  /// see [MmexRepository.simulatedDailyNetWithMeanReversion]'s own doc
  /// comment for why). Same "reopen for an account that already has a
  /// setting starts from its saved values" convention as
  /// [_openDiscretionaryAdjustmentDialog].
  Future<void> _openMeanReversionDialog(
      BuildContext context, int forAccountId) async {
    final existingByAccountId = _useApi
        ? _apiData!.meanReversionByAccountId
        : {
            for (final a in accounts)
              if (repo.getSimMeanReversion(scenario.id, a.id) != null)
                a.id: repo.getSimMeanReversion(scenario.id, a.id)!,
          };
    final result = await showDialog<_MeanReversionResult>(
      context: context,
      builder: (context) => _MeanReversionDialog(
        repo: repo,
        accounts: accounts,
        currency: currency,
        startDay: startDay,
        initialAccountId: forAccountId,
        existingByAccountId: existingByAccountId,
        apiSession: widget.apiSession,
      ),
    );
    if (result == null) return;
    if (_useApi) {
      if (result.delete) {
        await widget.apiSession!.deleteSimMeanReversion(scenario.id, result.accountId);
      } else {
        await widget.apiSession!.setSimMeanReversion(
          scenario.id,
          result.accountId,
          enabled: result.enabled,
          equilibrium: result.equilibrium,
          strength: result.strength,
          noisePercent: result.noisePercent,
        );
      }
    } else {
      if (result.delete) {
        repo.deleteSimMeanReversion(scenario.id, result.accountId);
      } else {
        repo.setSimMeanReversion(
          scenario.id,
          result.accountId,
          enabled: result.enabled,
          equilibrium: result.equilibrium,
          strength: result.strength,
          noisePercent: result.noisePercent,
        );
      }
    }
    onChanged();
  }

  Future<void> _openVirtualBillDialog(BuildContext context, int forAccountId,
      {SimVirtualBill? existing}) async {
    final result = await showDialog<_VirtualBillFormResult>(
      context: context,
      builder: (context) => _VirtualBillDialog(
          accounts: accounts,
          existing: existing,
          initialAccountId: forAccountId),
    );
    if (result == null) return;
    if (_useApi) {
      final session = widget.apiSession!;
      if (existing != null) await session.deleteSimVirtualBill(existing.id);
      await session.addSimVirtualBill(
        scenarioId: scenario.id,
        accountId: result.accountId,
        label: result.label,
        transCode: result.transCode,
        amount: result.amount,
        startDate: result.startDate,
        period: result.period,
        variancePercent: result.variancePercent,
      );
    } else {
      if (existing != null) repo.deleteSimVirtualBill(existing.id);
      repo.addSimVirtualBill(
        scenarioId: scenario.id,
        accountId: result.accountId,
        label: result.label,
        transCode: result.transCode,
        amount: result.amount,
        startDate: result.startDate,
        period: result.period,
        variancePercent: result.variancePercent,
      );
    }
    onChanged();
  }

  /// Same recognizable label every time, so re-opening this guided dialog
  /// for the same account replaces its previous adjustment (delete then
  /// recreate, same convention [_openVirtualBillDialog]'s own edit path
  /// already uses) instead of accumulating duplicates.
  static const _discretionaryAdjustmentLabel =
      'Dépenses imprévues (historique)';

  Future<void> _openDiscretionaryAdjustmentDialog(
      BuildContext context, int forAccountId) async {
    final allVirtualBills =
        _useApi ? _apiData!.allVirtualBills : repo.getSimVirtualBills(scenario.id);
    final result = await showDialog<_DiscretionaryAdjustmentResult>(
      context: context,
      builder: (context) => _DiscretionaryAdjustmentDialog(
        repo: repo,
        accounts: accounts,
        currency: currency,
        initialAccountId: forAccountId,
        startDay: startDay,
        existingByAccountId: {
          for (final v in allVirtualBills)
            if (v.label == _discretionaryAdjustmentLabel) v.accountId: v,
        },
        apiSession: widget.apiSession,
      ),
    );
    if (result == null) return;
    if (_useApi) {
      final session = widget.apiSession!;
      final currentVirtualBills = await session.getSimVirtualBills(scenario.id);
      final existing = currentVirtualBills
          .where((v) =>
              v.accountId == result.accountId && v.label == _discretionaryAdjustmentLabel)
          .firstOrNull;
      if (existing != null) await session.deleteSimVirtualBill(existing.id);
      await session.addSimVirtualBill(
        scenarioId: scenario.id,
        accountId: result.accountId,
        label: _discretionaryAdjustmentLabel,
        transCode: result.amount >= 0 ? TransCode.deposit : TransCode.withdrawal,
        amount: result.amount.abs(),
        startDate: DateTime.now(),
        period: RecurrencePeriod.monthly,
        variancePercent: result.variancePercent,
      );
    } else {
      final existing = repo
          .getSimVirtualBills(scenario.id)
          .where((v) =>
              v.accountId == result.accountId &&
              v.label == _discretionaryAdjustmentLabel)
          .firstOrNull;
      if (existing != null) repo.deleteSimVirtualBill(existing.id);
      repo.addSimVirtualBill(
        scenarioId: scenario.id,
        accountId: result.accountId,
        label: _discretionaryAdjustmentLabel,
        transCode: result.amount >= 0 ? TransCode.deposit : TransCode.withdrawal,
        amount: result.amount.abs(),
        startDate: DateTime.now(),
        period: RecurrencePeriod.monthly,
        variancePercent: result.variancePercent,
      );
    }
    onChanged();
  }

  Future<void> _openOneOffEventDialog(
      BuildContext context, int forAccountId) async {
    final result = await showDialog<_OneOffEventFormResult>(
      context: context,
      builder: (context) => _OneOffEventDialog(
          accounts: accounts, initialAccountId: forAccountId),
    );
    if (result == null) return;
    if (_useApi) {
      await widget.apiSession!.addSimOneOffEvent(
        scenarioId: scenario.id,
        accountId: result.accountId,
        label: result.label,
        transCode: result.transCode,
        amount: result.amount,
        date: result.date,
      );
    } else {
      repo.addSimOneOffEvent(
        scenarioId: scenario.id,
        accountId: result.accountId,
        label: result.label,
        transCode: result.transCode,
        amount: result.amount,
        date: result.date,
      );
    }
    onChanged();
  }
}

/// Sentinel [SimBillOverride.disabledFrom] value meaning "excluded for the
/// entire scenario, not just from some future date" - see the "Exclure"
/// checkbox in [_RealBillRowState]. Any real date this far in the past
/// necessarily precedes every occurrence a live bill could still have (see
/// [MmexRepository.occurrencesForBill]'s own floor at
/// [BillDeposit.nextOccurrence]), so it excludes every occurrence in any
/// projection window without needing a second, separate "fully excluded"
/// column in APP_SIM_BILL_OVERRIDES.
final _fullyExcludedSentinel = DateTime(1900, 1, 1);

/// One real bill's row - two optional, independently-debounced fields
/// ("arrêt le"/"nouveau montant") mapping onto [SimBillOverride], plus a
/// quick "Exclure" checkbox (2026-09-02 user request) that's really just a
/// shortcut for setting "arrêt le" to [_fullyExcludedSentinel] - no third
/// state to keep in sync with the other two.
class _RealBillRow extends StatefulWidget {
  final BillDeposit bill;
  final String label;
  final String tooltip;

  /// When this bill already has a fixed remaining occurrence count (see
  /// [BillDeposit.numOccurrences]'s own doc comment), the date it naturally
  /// fires for the last time - null for a bill that repeats forever. Only
  /// used to *pre-fill* "arrêt le" the first time this row is shown for a
  /// bill with no saved override yet (see [_RealBillRowState.initState]) -
  /// 2026-09-02 user request: without this, a limited-duration bill was
  /// projected as if it repeated forever, both here and in the real
  /// forecast chart, since occurrence-walking is driven by the period
  /// alone and was never capped by the remaining count outside of actually
  /// firing a bill (see MmexRepository.occurrencesForBill's own doc
  /// comment on this gap).
  final DateTime? naturalEndDate;

  final CurrencyFormat? currency;
  final SimBillOverride? savedOverride;
  final void Function(DateTime? disabledFrom, double? amountOverride) onChanged;

  const _RealBillRow({
    super.key,
    required this.bill,
    required this.label,
    required this.tooltip,
    required this.naturalEndDate,
    required this.currency,
    required this.savedOverride,
    required this.onChanged,
  });

  @override
  State<_RealBillRow> createState() => _RealBillRowState();
}

class _RealBillRowState extends State<_RealBillRow> {
  late DateTime? _disabledFrom =
      widget.savedOverride?.disabledFrom ?? widget.naturalEndDate;
  late final _amountController = TextEditingController(
      text: widget.savedOverride?.amountOverride?.toStringAsFixed(2) ?? '');
  Timer? _debounce;

  bool get _fullyExcluded =>
      _disabledFrom != null && !_disabledFrom!.isAfter(_fullyExcludedSentinel);

  @override
  void initState() {
    super.initState();
    // Auto-fills (and immediately persists) a limited-duration bill's
    // natural end date the first time this row is shown, so the scenario
    // reflects it accurately without the user having to know/compute that
    // date themselves - see [_RealBillRow.naturalEndDate]'s own doc
    // comment. Deferred a frame (never call widget.onChanged, which
    // ultimately calls setState on an ancestor, synchronously from
    // initState/build) and only when there's genuinely nothing saved yet,
    // so this never overwrites a real (possibly deliberately cleared)
    // choice the user already made.
    if (widget.savedOverride == null && widget.naturalEndDate != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.onChanged(widget.naturalEndDate, null);
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _amountController.dispose();
    super.dispose();
  }

  void _commitAmount(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      final parsed = double.tryParse(text.replaceAll(',', '.'));
      widget.onChanged(_disabledFrom, text.trim().isEmpty ? null : parsed);
    });
  }

  Future<void> _pickStopDate() async {
    final picked = await pickDate(
      context: context,
      initialDate: (_disabledFrom == null || _fullyExcluded)
          ? DateTime.now()
          : _disabledFrom!,
      firstDate: DateTime.now(),
      lastDate: DateTime(DateTime.now().year + 60),
      helpText: 'Arrêt de "${widget.label}"',
    );
    if (picked == null) return;
    setState(() => _disabledFrom = picked);
    final amount = double.tryParse(_amountController.text.replaceAll(',', '.'));
    widget.onChanged(picked, amount);
  }

  void _clearStopDate() {
    setState(() => _disabledFrom = null);
    final amount = double.tryParse(_amountController.text.replaceAll(',', '.'));
    widget.onChanged(null, amount);
  }

  void _setFullyExcluded(bool excluded) {
    setState(() => _disabledFrom = excluded ? _fullyExcludedSentinel : null);
    final amount = double.tryParse(_amountController.text.replaceAll(',', '.'));
    widget.onChanged(excluded ? _fullyExcludedSentinel : null, amount);
  }

  @override
  Widget build(BuildContext context) {
    final bill = widget.bill;
    final realAmountLabel =
        widget.currency?.format(bill.amount) ?? bill.amount.toStringAsFixed(2);
    return Tooltip(
      message: widget.tooltip,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  bill.transCode == TransCode.deposit
                      ? Icons.south_west
                      : Icons.north_east,
                  size: 16,
                  color: bill.transCode == TransCode.deposit
                      ? AppTheme.positive
                      : AppTheme.negative,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                Text(
                  '$realAmountLabel - ${recurrencePeriodLabel(bill.period)}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Checkbox(
                  value: _fullyExcluded,
                  onChanged: (v) => _setFullyExcluded(v ?? false),
                ),
                const Text('Exclure', style: TextStyle(fontSize: 12)),
                const SizedBox(width: 8),
                Expanded(
                  child: IgnorePointer(
                    ignoring: _fullyExcluded,
                    child: Opacity(
                      opacity: _fullyExcluded ? 0.4 : 1,
                      child: InkWell(
                        onTap: _pickStopDate,
                        child: InputDecorator(
                          decoration: InputDecoration(
                            isDense: true,
                            labelText: 'Arrêt le',
                            suffixIcon: _disabledFrom == null
                                ? const Icon(Icons.event_outlined, size: 18)
                                : IconButton(
                                    icon: const Icon(Icons.clear, size: 16),
                                    onPressed: _clearStopDate,
                                  ),
                          ),
                          child: Text(
                            _disabledFrom == null
                                ? ''
                                : DateFormat('d MMM yyyy', 'fr_FR')
                                    .format(_disabledFrom!),
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            TextField(
              controller: _amountController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  isDense: true, labelText: 'Nouveau montant'),
              onChanged: _commitAmount,
            ),
          ],
        ),
      ),
    );
  }
}

class _VirtualBillFormResult {
  final int accountId;
  final String label;
  final TransCode transCode;
  final double amount;
  final DateTime startDate;
  final RecurrencePeriod period;
  final double variancePercent;

  const _VirtualBillFormResult({
    required this.accountId,
    required this.label,
    required this.transCode,
    required this.amount,
    required this.startDate,
    required this.period,
    this.variancePercent = 0,
  });
}

class _VirtualBillDialog extends StatefulWidget {
  final List<Account> accounts;
  final SimVirtualBill? existing;
  final int? initialAccountId;

  const _VirtualBillDialog(
      {required this.accounts, this.existing, this.initialAccountId});

  @override
  State<_VirtualBillDialog> createState() => _VirtualBillDialogState();
}

class _VirtualBillDialogState extends State<_VirtualBillDialog> {
  late final _labelController =
      TextEditingController(text: widget.existing?.label ?? '');
  late final _amountController = TextEditingController(
      text: widget.existing?.amount.toStringAsFixed(2) ?? '');
  late int _accountId = widget.existing?.accountId ??
      widget.initialAccountId ??
      widget.accounts.first.id;
  late TransCode _transCode = widget.existing?.transCode ?? TransCode.deposit;
  late DateTime _startDate = widget.existing?.startDate ?? DateTime.now();
  late RecurrencePeriod _period =
      widget.existing?.period ?? RecurrencePeriod.monthly;
  late double _variancePercent = widget.existing?.variancePercent ?? 0;

  @override
  void dispose() {
    _labelController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  void _submit() {
    final amount = double.tryParse(_amountController.text.replaceAll(',', '.'));
    if (_labelController.text.trim().isEmpty || amount == null || amount <= 0) {
      return;
    }
    Navigator.of(context).pop(_VirtualBillFormResult(
      accountId: _accountId,
      label: _labelController.text.trim(),
      transCode: _transCode,
      amount: amount,
      startDate: _startDate,
      period: _period,
      variancePercent: _variancePercent,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null
          ? 'Nouvelle opération virtuelle'
          : 'Modifier l\'opération virtuelle'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _labelController,
                autofocus: true,
                decoration: const InputDecoration(
                    labelText: 'Libellé (ex. Pension de retraite)'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: SegmentedButton<TransCode>(
                      segments: const [
                        ButtonSegment(
                            value: TransCode.deposit, label: Text('Revenu')),
                        ButtonSegment(
                            value: TransCode.withdrawal,
                            label: Text('Dépense')),
                      ],
                      selected: {_transCode},
                      onSelectionChanged: (s) =>
                          setState(() => _transCode = s.first),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _amountController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Montant'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: _accountId,
                decoration: const InputDecoration(labelText: 'Compte'),
                items: [
                  for (final a in widget.accounts)
                    DropdownMenuItem(value: a.id, child: Text(a.name)),
                ],
                onChanged: (id) => setState(() => _accountId = id!),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<RecurrencePeriod>(
                initialValue: _period,
                decoration: const InputDecoration(labelText: 'Périodicité'),
                items: [
                  for (final p in _simplePeriods)
                    DropdownMenuItem(
                        value: p, child: Text(recurrencePeriodLabel(p))),
                ],
                onChanged: (p) => setState(() => _period = p!),
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: () async {
                  final picked = await pickDate(
                    context: context,
                    initialDate: _startDate,
                    firstDate: DateTime.now().subtract(const Duration(days: 1)),
                    lastDate: DateTime(DateTime.now().year + 60),
                    helpText: 'Date de départ',
                  );
                  if (picked != null) setState(() => _startDate = picked);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'À partir du'),
                  child: Text(
                      DateFormat('d MMM yyyy', 'fr_FR').format(_startDate)),
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _variancePercent == 0
                      ? 'Montant identique à chaque échéance'
                      : 'Variation aléatoire d\'une échéance à l\'autre : '
                          '±${_variancePercent.round()} %',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              Slider(
                value: _variancePercent,
                min: 0,
                max: 50,
                divisions: 50,
                label: '±${_variancePercent.round()} %',
                onChanged: (v) => setState(() => _variancePercent = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler')),
        FilledButton(onPressed: _submit, child: const Text('Valider')),
      ],
    );
  }
}

class _DiscretionaryAdjustmentResult {
  final int accountId;
  final double amount;
  final double variancePercent;

  const _DiscretionaryAdjustmentResult({
    required this.accountId,
    required this.amount,
    required this.variancePercent,
  });
}

/// Guided flow for a scenario's "dépenses imprévues" adjustment
/// (2026-09-02 user request) - unlike [_VirtualBillDialog], this doesn't
/// ask the user to invent a number from scratch: it computes a real,
/// data-derived starting point ([MmexRepository.historicalDiscretionaryMonthlyAverage])
/// from this account's own transaction history, then lets a
/// [Slider] adjust it and another control the month-to-month random
/// variation, before saving it as an ordinary [SimVirtualBill] (see
/// _AdjustmentsPanel._openDiscretionaryAdjustmentDialog) - the underlying
/// mechanism is exactly the same one "pension de retraite" or any other
/// virtual bill uses, just reached through a different door.
class _DiscretionaryAdjustmentDialog extends StatefulWidget {
  final MmexRepository repo;
  final List<Account> accounts;
  final CurrencyFormat? currency;
  final int? initialAccountId;
  final int startDay;

  /// This scenario's existing discretionary-adjustment bill per account (if
  /// any) - re-opening this dialog for an account that already has one
  /// starts the sliders from its saved values instead of silently
  /// discarding a previous manual tweak in favor of the freshly-computed
  /// suggestion.
  final Map<int, SimVirtualBill> existingByAccountId;

  /// Non-null ET connecté : la moyenne suggérée passe par le serveur
  /// (un aller-retour, voir [_loadSuggested]) au lieu du calcul local
  /// synchrone.
  final ApiSessionProvider? apiSession;

  const _DiscretionaryAdjustmentDialog({
    required this.repo,
    required this.accounts,
    required this.currency,
    required this.existingByAccountId,
    required this.startDay,
    this.initialAccountId,
    this.apiSession,
  });

  @override
  State<_DiscretionaryAdjustmentDialog> createState() =>
      _DiscretionaryAdjustmentDialogState();
}

class _DiscretionaryAdjustmentDialogState
    extends State<_DiscretionaryAdjustmentDialog> {
  late int _accountId = widget.initialAccountId ?? widget.accounts.first.id;
  int _historyMonths = 12;
  double _suggested = 0;
  late double _amount = _initialAmount(_accountId);
  late double _variancePercent =
      widget.existingByAccountId[_accountId]?.variancePercent ?? 10;
  bool _loadingSuggested = true;

  bool get _useApi => widget.apiSession != null && widget.apiSession!.isConnected;

  double _initialAmount(int accountId) {
    final existing = widget.existingByAccountId[accountId];
    if (existing == null) return 0; // remplacé dès que _loadSuggested résout
    return existing.transCode == TransCode.deposit
        ? existing.amount
        : -existing.amount;
  }

  @override
  void initState() {
    super.initState();
    _loadSuggested(syncAmount: !widget.existingByAccountId.containsKey(_accountId));
  }

  /// Un aller-retour serveur en mode API plutôt qu'un calcul local
  /// synchrone - garde `_suggested`/`_amount` affichés tels quels pendant
  /// le chargement (voir [_loadingSuggested]) plutôt que de faire
  /// disparaître le contenu, comme pour le reste de l'écran (2026-09-10).
  Future<void> _loadSuggested({required bool syncAmount}) async {
    setState(() => _loadingSuggested = true);
    final accountId = _accountId;
    final months = _historyMonths;
    final value = _useApi
        ? await widget.apiSession!.historicalDiscretionaryMonthlyAverage(
            accountId: accountId, anchor: DateTime.now(), startDay: widget.startDay, months: months)
        : widget.repo.historicalDiscretionaryMonthlyAverage(
            accountId: accountId, anchor: DateTime.now(), startDay: widget.startDay, months: months);
    if (!mounted || accountId != _accountId || months != _historyMonths) return;
    setState(() {
      _suggested = value;
      _loadingSuggested = false;
      if (syncAmount) _amount = value;
    });
  }

  void _selectAccount(int accountId) {
    final wasAtSuggested = _amount == _suggested;
    setState(() {
      _accountId = accountId;
      _amount = _initialAmount(accountId);
      _variancePercent =
          widget.existingByAccountId[accountId]?.variancePercent ?? 10;
    });
    _loadSuggested(
        syncAmount: !widget.existingByAccountId.containsKey(accountId) || wasAtSuggested);
  }

  void _selectHistoryMonths(int months) {
    // Only follow the recomputed suggestion if the slider hadn't been
    // manually moved away from it yet - once the user has tweaked the
    // amount by hand, changing the history window shouldn't silently
    // discard that tweak.
    final wasAtSuggested = _amount == _suggested;
    setState(() => _historyMonths = months);
    _loadSuggested(syncAmount: wasAtSuggested);
  }

  String _formatAmount(double amount) =>
      widget.currency?.format(amount) ?? amount.toStringAsFixed(2);

  /// Red for a net expense (the common "dépenses imprévues" case), green for
  /// a net credit, unstyled at exactly 0 - same convention as the rest of
  /// the app's amount coloring.
  Color? _amountColor(double amount) {
    if (amount < 0) return Colors.red.shade700;
    if (amount > 0) return Colors.green.shade700;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // At least ±500 of headroom even when the computed suggestion is 0 (a
    // brand-new account with no history yet) - otherwise the slider would
    // have nowhere to move at all.
    final range = max(500.0, _suggested.abs() * 2);
    final clampedAmount = _amount.clamp(-range, range);
    return AlertDialog(
      title: const Text('Ajustement réaliste (dépenses imprévues)'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'La simulation ne connaît que les opérations récurrentes réelles - '
                'jamais les dépenses variables (nourriture, imprévus...). Cet '
                'ajustement ajoute chaque mois la différence moyenne, calculée sur '
                'ton historique réel, entre ce que le solde a vraiment fait et ce '
                'que les opérations récurrentes seules auraient prédit.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: _accountId,
                decoration: const InputDecoration(labelText: 'Compte'),
                items: [
                  for (final a in widget.accounts)
                    DropdownMenuItem(value: a.id, child: Text(a.name)),
                ],
                onChanged: (id) => _selectAccount(id!),
              ),
              const SizedBox(height: 12),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 12, label: Text('12 mois')),
                  ButtonSegment(value: 24, label: Text('24 mois')),
                  ButtonSegment(value: 36, label: Text('36 mois')),
                ],
                selected: {_historyMonths},
                onSelectionChanged: (s) => _selectHistoryMonths(s.first),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        style: const TextStyle(fontSize: 12),
                        children: [
                          TextSpan(
                              text: 'Sur les $_historyMonths derniers mois : '),
                          TextSpan(
                            text: _formatAmount(_suggested),
                            style: TextStyle(
                              color: _amountColor(_suggested),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const TextSpan(
                              text: ' / mois en moyenne, non expliqué par les '
                                  'opérations récurrentes.'),
                        ],
                      ),
                    ),
                  ),
                  if (_loadingSuggested) ...[
                    const SizedBox(width: 8),
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(text: 'Montant mensuel appliqué : '),
                    TextSpan(
                      text: _formatAmount(_amount),
                      style: TextStyle(
                        color: _amountColor(_amount),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              Slider(
                value: clampedAmount,
                min: -range,
                max: range,
                divisions: 200,
                label: _formatAmount(_amount),
                onChanged: (v) => setState(() => _amount = v),
              ),
              const SizedBox(height: 8),
              Text(
                _variancePercent == 0
                    ? 'Montant identique chaque mois'
                    : 'Variation aléatoire d\'un mois à l\'autre : '
                        '±${_variancePercent.round()} %',
              ),
              Slider(
                value: _variancePercent,
                min: 0,
                max: 50,
                divisions: 50,
                label: '±${_variancePercent.round()} %',
                onChanged: (v) => setState(() => _variancePercent = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler')),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(_DiscretionaryAdjustmentResult(
            accountId: _accountId,
            amount: _amount,
            variancePercent: _variancePercent,
          )),
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}

class _MeanReversionResult {
  /// True when "Supprimer ce réglage" was tapped - the caller should
  /// remove the whole configuration rather than save the fields below
  /// (which are then meaningless/stale, left at whatever the dialog's
  /// controls happened to show at the time).
  final bool delete;
  final int accountId;
  final bool enabled;
  final double equilibrium;
  final double strength;
  final double noisePercent;

  const _MeanReversionResult({
    this.delete = false,
    required this.accountId,
    required this.enabled,
    required this.equilibrium,
    required this.strength,
    required this.noisePercent,
  });
}

/// "Retour à l'équilibre" (2026-09-04, replacing "solde final supposé" -
/// see [MmexRepository.simulatedDailyNetWithMeanReversion]'s own doc
/// comment for the full story). Same guided-flow shape as
/// [_DiscretionaryAdjustmentDialog] - a real, data-derived starting point
/// ([MmexRepository.historicalEquilibriumBalance]) rather than a number
/// invented from scratch, adjustable before saving.
class _MeanReversionDialog extends StatefulWidget {
  final MmexRepository repo;
  final List<Account> accounts;
  final CurrencyFormat? currency;
  final int startDay;
  final int? initialAccountId;

  /// This scenario's existing setting per account (if any) - re-opening
  /// this dialog for an account that already has one starts every control
  /// from its saved values instead of silently discarding a previous tweak
  /// in favor of the freshly-computed suggestion.
  final Map<int, ({bool enabled, double? equilibrium, double strength, double noisePercent})>
      existingByAccountId;

  /// Non-null ET connecté : équilibre/écart-type suggérés passent par le
  /// serveur (un aller-retour groupé, voir [_loadSuggestions]) au lieu du
  /// calcul local synchrone.
  final ApiSessionProvider? apiSession;

  const _MeanReversionDialog({
    required this.repo,
    required this.accounts,
    required this.currency,
    required this.startDay,
    required this.existingByAccountId,
    this.initialAccountId,
    this.apiSession,
  });

  @override
  State<_MeanReversionDialog> createState() => _MeanReversionDialogState();
}

class _MeanReversionDialogState extends State<_MeanReversionDialog> {
  late int _accountId = widget.initialAccountId ?? widget.accounts.first.id;
  int _historyMonths = 12;
  double _suggestedEquilibrium = 0;
  double _stdev = 0;
  late double _equilibrium = _initialEquilibrium(_accountId);
  late double _strength =
      widget.existingByAccountId[_accountId]?.strength ?? 0.5;
  late double _noisePercent =
      widget.existingByAccountId[_accountId]?.noisePercent ?? 100;
  late bool _enabled = widget.existingByAccountId[_accountId]?.enabled ?? true;
  bool _loadingSuggestions = true;

  bool get _useApi => widget.apiSession != null && widget.apiSession!.isConnected;

  double _initialEquilibrium(int accountId) =>
      widget.existingByAccountId[accountId]?.equilibrium ?? 0;

  @override
  void initState() {
    super.initState();
    _loadSuggestions(syncEquilibrium: !widget.existingByAccountId.containsKey(_accountId));
  }

  /// Un aller-retour groupé (équilibre + écart-type) en mode API plutôt que
  /// deux calculs locaux synchrones - garde les valeurs affichées telles
  /// quelles pendant le chargement (voir [_loadingSuggestions]), même
  /// convention que [_DiscretionaryAdjustmentDialogState._loadSuggested].
  Future<void> _loadSuggestions({required bool syncEquilibrium}) async {
    setState(() => _loadingSuggestions = true);
    final accountId = _accountId;
    final months = _historyMonths;
    final double equilibrium;
    final double stdev;
    if (_useApi) {
      final results = await Future.wait([
        widget.apiSession!.historicalEquilibriumBalance(
            accountId: accountId, anchor: DateTime.now(), startDay: widget.startDay, months: months),
        widget.apiSession!.historicalDiscretionaryMonthlyStdev(
            accountId: accountId, anchor: DateTime.now(), startDay: widget.startDay, months: months),
      ]);
      equilibrium = results[0];
      stdev = results[1];
    } else {
      equilibrium = widget.repo.historicalEquilibriumBalance(
          accountId: accountId, anchor: DateTime.now(), startDay: widget.startDay, months: months);
      stdev = widget.repo.historicalDiscretionaryMonthlyStdev(
          accountId: accountId, anchor: DateTime.now(), startDay: widget.startDay, months: months);
    }
    if (!mounted || accountId != _accountId || months != _historyMonths) return;
    setState(() {
      _suggestedEquilibrium = equilibrium;
      _stdev = stdev;
      _loadingSuggestions = false;
      if (syncEquilibrium) _equilibrium = equilibrium;
    });
  }

  void _selectAccount(int accountId) {
    final wasAtSuggested = _equilibrium == _suggestedEquilibrium;
    setState(() {
      _accountId = accountId;
      _equilibrium = _initialEquilibrium(accountId);
      _strength = widget.existingByAccountId[accountId]?.strength ?? 0.5;
      _noisePercent =
          widget.existingByAccountId[accountId]?.noisePercent ?? 100;
      _enabled = widget.existingByAccountId[accountId]?.enabled ?? true;
    });
    _loadSuggestions(
        syncEquilibrium: !widget.existingByAccountId.containsKey(accountId) || wasAtSuggested);
  }

  void _selectHistoryMonths(int months) {
    final wasAtSuggested = _equilibrium == _suggestedEquilibrium;
    setState(() => _historyMonths = months);
    _loadSuggestions(syncEquilibrium: wasAtSuggested);
  }

  String _formatAmount(double amount) =>
      widget.currency?.format(amount) ?? amount.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final range = max(500.0, _suggestedEquilibrium.abs() * 2);
    final clampedEquilibrium = _equilibrium.clamp(-range, range);
    final stdev = _stdev;
    final noiseAmount = stdev * _noisePercent / 100;
    final hasExisting = widget.existingByAccountId.containsKey(_accountId);
    return AlertDialog(
      title: const Text('Retour à l\'équilibre'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Ton solde réel ne dérive pas indéfiniment : quand il y a de '
                'la marge, elle finit dépensée : quand il en manque, les '
                'dépenses se resserrent. Ce réglage tire chaque mois le '
                'solde projeté vers une valeur d\'équilibre calculée sur ton '
                'historique réel, au lieu de le laisser dériver sans fin.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Activé'),
                subtitle: Text(_enabled
                    ? 'Appliqué à chaque échéance mensuelle'
                    : 'Réglages conservés, mais pas appliqués'),
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<int>(
                initialValue: _accountId,
                decoration: const InputDecoration(labelText: 'Compte'),
                items: [
                  for (final a in widget.accounts)
                    DropdownMenuItem(value: a.id, child: Text(a.name)),
                ],
                onChanged: (id) => _selectAccount(id!),
              ),
              const SizedBox(height: 12),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 12, label: Text('12 mois')),
                  ButtonSegment(value: 24, label: Text('24 mois')),
                  ButtonSegment(value: 36, label: Text('36 mois')),
                ],
                selected: {_historyMonths},
                onSelectionChanged: (s) => _selectHistoryMonths(s.first),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        style: const TextStyle(fontSize: 12),
                        children: [
                          TextSpan(
                              text: 'Sur les $_historyMonths derniers mois, solde '
                                  'moyen constaté au jour de prévision : '),
                          TextSpan(
                            text: _formatAmount(_suggestedEquilibrium),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          TextSpan(
                              text: ' (variation réelle typique : ±'
                                  '${_formatAmount(stdev)}/mois).'),
                        ],
                      ),
                    ),
                  ),
                  if (_loadingSuggestions) ...[
                    const SizedBox(width: 8),
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(text: 'Équilibre cible : '),
                    TextSpan(
                      text: _formatAmount(_equilibrium),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
              Slider(
                value: clampedEquilibrium,
                min: -range,
                max: range,
                divisions: 200,
                label: _formatAmount(_equilibrium),
                onChanged: (v) => setState(() => _equilibrium = v),
              ),
              const SizedBox(height: 8),
              Text('Force de rappel : ${(_strength * 100).round()} % '
                  '(0 % = aucun effet, 100 % = revient pile à l\'équilibre '
                  'chaque mois)'),
              Slider(
                value: _strength,
                min: 0,
                max: 1,
                divisions: 20,
                label: '${(_strength * 100).round()} %',
                onChanged: (v) => setState(() => _strength = v),
              ),
              const SizedBox(height: 8),
              Text(_noisePercent == 0
                  ? 'Aucune variation aléatoire'
                  : 'Variation aléatoire : ±${_formatAmount(noiseAmount)}/mois '
                      '(${_noisePercent.round()} % de la variation typique)'),
              Slider(
                value: _noisePercent,
                min: 0,
                max: 200,
                divisions: 40,
                label: '${_noisePercent.round()} %',
                onChanged: (v) => setState(() => _noisePercent = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (hasExisting)
          TextButton(
            onPressed: () => Navigator.of(context).pop(_MeanReversionResult(
              delete: true,
              accountId: _accountId,
              enabled: _enabled,
              equilibrium: _equilibrium,
              strength: _strength,
              noisePercent: _noisePercent,
            )),
            child: const Text('Supprimer ce réglage'),
          ),
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_MeanReversionResult(
            accountId: _accountId,
            enabled: _enabled,
            equilibrium: _equilibrium,
            strength: _strength,
            noisePercent: _noisePercent,
          )),
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}

class _OneOffEventFormResult {
  final int accountId;
  final String label;
  final TransCode transCode;
  final double amount;
  final DateTime date;

  const _OneOffEventFormResult({
    required this.accountId,
    required this.label,
    required this.transCode,
    required this.amount,
    required this.date,
  });
}

class _OneOffEventDialog extends StatefulWidget {
  final List<Account> accounts;
  final int? initialAccountId;

  const _OneOffEventDialog({required this.accounts, this.initialAccountId});

  @override
  State<_OneOffEventDialog> createState() => _OneOffEventDialogState();
}

class _OneOffEventDialogState extends State<_OneOffEventDialog> {
  final _labelController = TextEditingController();
  final _amountController = TextEditingController();
  late int _accountId = widget.initialAccountId ?? widget.accounts.first.id;
  TransCode _transCode = TransCode.deposit;
  DateTime _date = DateTime.now();

  @override
  void dispose() {
    _labelController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  void _submit() {
    final amount = double.tryParse(_amountController.text.replaceAll(',', '.'));
    if (_labelController.text.trim().isEmpty || amount == null || amount <= 0) {
      return;
    }
    Navigator.of(context).pop(_OneOffEventFormResult(
      accountId: _accountId,
      label: _labelController.text.trim(),
      transCode: _transCode,
      amount: amount,
      date: _date,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nouvel événement ponctuel'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _labelController,
              autofocus: true,
              decoration: const InputDecoration(
                  labelText: 'Libellé (ex. Capital de départ)'),
            ),
            const SizedBox(height: 12),
            SegmentedButton<TransCode>(
              segments: const [
                ButtonSegment(value: TransCode.deposit, label: Text('Revenu')),
                ButtonSegment(
                    value: TransCode.withdrawal, label: Text('Dépense')),
              ],
              selected: {_transCode},
              onSelectionChanged: (s) => setState(() => _transCode = s.first),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _amountController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Montant'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _accountId,
              decoration: const InputDecoration(labelText: 'Compte'),
              items: [
                for (final a in widget.accounts)
                  DropdownMenuItem(value: a.id, child: Text(a.name)),
              ],
              onChanged: (id) => setState(() => _accountId = id!),
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: () async {
                final picked = await pickDate(
                  context: context,
                  initialDate: _date,
                  firstDate: DateTime.now().subtract(const Duration(days: 1)),
                  lastDate: DateTime(DateTime.now().year + 60),
                  helpText: 'Date de l\'événement',
                );
                if (picked != null) setState(() => _date = picked);
              },
              child: InputDecorator(
                decoration: const InputDecoration(labelText: 'Date'),
                child: Text(DateFormat('d MMM yyyy', 'fr_FR').format(_date)),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler')),
        FilledButton(onPressed: _submit, child: const Text('Valider')),
      ],
    );
  }
}

/// One rotating colour per selected account (2026-09 user request: as many
/// simulated curves as selected accounts, distinguished by colour, with
/// solid-vs-dashed still meaning baseline-vs-scenario within each colour).
/// Cycles via modulo if more accounts are selected than colours - unlikely
/// in practice, and not worse than reusing a colour would be anyway.
const _accountColors = [
  Color(0xFF3F51B5), // indigo
  Color(0xFFE65100), // deep orange
  Color(0xFF2E7D32), // green
  Color(0xFF6A1B9A), // purple
  Color(0xFF00838F), // teal
  Color(0xFFAD1457), // pink
  Color(0xFF5D4037), // brown
  Color(0xFF37474F), // blue grey
];

/// One selected account's full computed series - see
/// [_SimulationChart._buildSeries].
class _AccountSeries {
  final Account account;
  final Color color;
  final List<double> baseline;
  final List<double> scenario;
  final String? assumedBalanceNote;

  const _AccountSeries({
    required this.account,
    required this.color,
    required this.baseline,
    required this.scenario,
    required this.assumedBalanceNote,
  });
}

/// The baseline-vs-scenario projection chart - solid line for "si rien ne
/// change" ([MmexRepository.recurringDailyNet], the real schedule,
/// untouched), dashed line for the scenario itself
/// ([MmexRepository.simulatedDailyNet]) - dashed is the same "simulated"
/// visual convention forecast_chart.dart already uses for its own
/// simulated-purchase overlay, reused here on purpose for a consistent
/// meaning across the app. Both start from today's real per-account balance
/// ([MmexRepository.accountBalance]), so they only ever diverge from what
/// the scenario actually changes.
///
/// One such pair per entry in [accountIds] (2026-09 user request: checked
/// accounts each get their own curves, colour-coded, rather than a single
/// account or a merged "tous les comptes" total) - see [_buildSeries] and
/// [_AccountSeries].
///
/// Bucketed day by day, same granularity as the dashboard's own
/// [ForecastChart] (2026-09-02 user request: match it exactly, rather than
/// the monthly pay-cycle bucketing this chart used until then - see git
/// history for that earlier attempt and why it was replaced). Recurring-bill
/// detail shows up in the tooltip on hover, same as the dashboard, but
/// deliberately without its red dashed per-day vertical lines - those would
/// be an unreadable wall of red across a multi-year horizon, let alone
/// across several accounts' worth of them.
///
/// [startDay] itself (Settings' "Jour de prévision du solde") no longer
/// changes how this chart buckets - only the exact calendar day matters now
/// - but is still threaded through, since the "Ajustement réaliste" and
/// "Retour à l'équilibre" dialogs reached from this same screen still need
/// it for [MmexRepository.historicalDiscretionaryMonthlyAverage]/
/// [MmexRepository.historicalEquilibriumBalance], and since 2026-09-02
/// also anchors the "retour à l'équilibre" monthly checkpoints themselves
/// (see [MmexRepository.simulatedDailyNetWithMeanReversion]).
class _SimulationChart extends StatefulWidget {
  final MmexRepository repo;
  final int scenarioId;
  final List<int> accountIds;
  final List<Account> accounts;
  final int horizonMonths;
  final CurrencyFormat? currency;
  final int startDay;

  /// Non-null ET connecté : le calcul de la courbe passe par le serveur en
  /// un seul aller-retour (voir [ApiSessionProvider.computeSimulationChart])
  /// au lieu des ~6 appels locaux séquentiels.
  final ApiSessionProvider? apiSession;

  const _SimulationChart({
    super.key,
    required this.repo,
    required this.scenarioId,
    required this.accountIds,
    required this.accounts,
    required this.horizonMonths,
    required this.currency,
    required this.startDay,
    this.apiSession,
  });

  @override
  State<_SimulationChart> createState() => _SimulationChartState();
}

class _SimulationChartState extends State<_SimulationChart> {
  /// 2026-09 user request: with several accounts selected, the chart shows
  /// a solid ("sans changement") and dashed ("avec ce scénario") line per
  /// account at once - a lot of visual clutter once you only care about the
  /// scenario's actual effect. This hides every solid line at once (never
  /// per-account: a single switch is simpler to reason about than tracking
  /// which accounts a scenario actually touches, and the dashed line alone
  /// already shows "unchanged" by tracing the same path as the baseline
  /// would have). Purely a display toggle, never persisted - resets to
  /// showing both on next visit, same as the other view-only chart state in
  /// this file (no equivalent to _panelCollapsed's persistence expected
  /// here).
  bool _hideUnchanged = false;

  MmexRepository get repo => widget.repo;
  int get scenarioId => widget.scenarioId;
  List<int> get accountIds => widget.accountIds;
  List<Account> get accounts => widget.accounts;
  int get horizonMonths => widget.horizonMonths;
  CurrencyFormat? get currency => widget.currency;
  int get startDay => widget.startDay;

  List<double> _cumulative(
      Map<DateTime, double> dailyNet, double startingBalance) {
    final keys = dailyNet.keys.toList()..sort();
    var running = startingBalance;
    return [for (final k in keys) running += dailyNet[k]!];
  }

  /// One [_AccountSeries] per entry in [accountIds], in the same order -
  /// every figure (starting balance, baseline, scenario, "solde final
  /// supposé" note) computed independently per account, never summed/merged
  /// across them.
  List<_AccountSeries> _buildSeries(DateTime anchor, int days) {
    final accountsById = {for (final a in accounts) a.id: a};
    final series = <_AccountSeries>[];
    for (var i = 0; i < accountIds.length; i++) {
      final id = accountIds[i];
      final account = accountsById[id];
      if (account == null) continue; // hidden/deleted since selection - skip
      final color = _accountColors[i % _accountColors.length];
      final startingBalance = repo.accountBalance(id, asOf: DateTime.now());
      final baselineNet =
          repo.recurringDailyNet(anchor: anchor, days: days, accountId: id);
      final reversion = repo.getSimMeanReversion(scenarioId, id);
      final equilibrium = reversion?.equilibrium ??
          repo.historicalEquilibriumBalance(
              accountId: id, anchor: DateTime.now(), startDay: startDay);
      final stdev = repo.historicalDiscretionaryMonthlyStdev(
          accountId: id, anchor: DateTime.now(), startDay: startDay);
      final scenarioResult = repo.simulatedDailyNetWithMeanReversion(
        scenarioId: scenarioId,
        accountId: id,
        enabled: reversion?.enabled ?? false,
        equilibrium: equilibrium,
        strength: reversion?.strength ?? 0.5,
        noiseAmount: stdev * (reversion?.noisePercent ?? 100) / 100,
        anchor: anchor,
        days: days,
        forecastDay: startDay,
      );

      String? assumedBalanceNote;
      if (reversion != null && !reversion.enabled) {
        assumedBalanceNote =
            '${account.name} : retour à l\'équilibre désactivé (réglages conservés)';
      } else if (scenarioResult.appliedDates.isNotEmpty) {
        final equilibriumLabel =
            currency?.format(equilibrium) ?? equilibrium.toStringAsFixed(2);
        assumedBalanceNote = '${account.name} : retour à l\'équilibre '
            '($equilibriumLabel) appliqué ${scenarioResult.appliedDates.length} '
            'fois sur l\'horizon affiché';
      }

      series.add(_AccountSeries(
        account: account,
        color: color,
        baseline: _cumulative(baselineNet, startingBalance),
        scenario: _cumulative(scenarioResult.net, startingBalance),
        assumedBalanceNote: assumedBalanceNote,
      ));
    }
    return series;
  }

  bool get _useApi =>
      widget.apiSession != null && widget.apiSession!.useApiForSimulation && widget.apiSession!.isConnected;

  /// Un seul aller-retour par compte sélectionné (en parallèle via
  /// Future.wait), au lieu des ~6 appels locaux séquentiels de
  /// [_buildSeries] - voir [ApiSessionProvider.computeSimulationChart] et
  /// sa route serveur, qui font exactement le même enchaînement.
  Future<List<_AccountSeries>> _loadSeriesViaApi(DateTime anchor, int days) async {
    final accountsById = {for (final a in accounts) a.id: a};
    final results = await Future.wait([
      for (final id in accountIds)
        widget.apiSession!.computeSimulationChart(
          scenarioId: scenarioId,
          accountId: id,
          anchor: anchor,
          days: days,
          startDay: startDay,
        ),
    ]);
    final series = <_AccountSeries>[];
    for (var i = 0; i < accountIds.length; i++) {
      final id = accountIds[i];
      final account = accountsById[id];
      if (account == null) continue;
      final color = _accountColors[i % _accountColors.length];
      final result = results[i];
      String? assumedBalanceNote;
      final reversion = result.meanReversion;
      if (reversion != null && !reversion.enabled) {
        assumedBalanceNote =
            '${account.name} : retour à l\'équilibre désactivé (réglages conservés)';
      } else if (result.appliedDates.isNotEmpty) {
        final equilibriumLabel =
            currency?.format(result.equilibrium) ?? result.equilibrium.toStringAsFixed(2);
        assumedBalanceNote = '${account.name} : retour à l\'équilibre '
            '($equilibriumLabel) appliqué ${result.appliedDates.length} '
            'fois sur l\'horizon affiché';
      }
      series.add(_AccountSeries(
        account: account,
        color: color,
        baseline: _cumulative(result.baselineNet, result.startingBalance),
        scenario: _cumulative(result.scenarioNet, result.startingBalance),
        assumedBalanceNote: assumedBalanceNote,
      ));
    }
    return series;
  }

  Future<List<_AccountSeries>>? _apiSeriesFuture;
  List<_AccountSeries>? _lastSeries;
  ({List<int> accountIds, int horizonMonths})? _apiSeriesKey;

  @override
  Widget build(BuildContext context) {
    if (accountIds.isEmpty) {
      return Center(
        child: Text(
          'Sélectionne au moins un compte pour voir la simulation.',
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
      );
    }

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final anchor = DateTime(now.year, now.month + horizonMonths, now.day)
        .subtract(const Duration(days: 1));
    final days = anchor.difference(today).inDays + 1;
    // Independent of account - every account's own recurringDailyNet/
    // simulatedDailyNet is bucketed [today, anchor] the exact same way.
    final points = [
      for (var i = 0; i < days; i++)
        DateTime(today.year, today.month, today.day + i),
    ];

    if (_useApi) {
      final key = (accountIds: accountIds, horizonMonths: horizonMonths);
      if (_apiSeriesFuture == null || _apiSeriesKey != key) {
        _apiSeriesKey = key;
        _apiSeriesFuture = _loadSeriesViaApi(anchor, days);
      }
      return FutureBuilder<List<_AccountSeries>>(
        future: _apiSeriesFuture,
        builder: (context, snapshot) {
          if (snapshot.hasData) _lastSeries = snapshot.data;
          if (_lastSeries == null) {
            if (snapshot.hasError) {
              return Center(child: Text('Erreur : ${snapshot.error}'));
            }
            return const Center(child: CircularProgressIndicator());
          }
          if (_lastSeries!.isEmpty) {
            return Center(
              child: Text(
                'Sélectionne au moins un compte pour voir la simulation.',
                style: TextStyle(color: Theme.of(context).colorScheme.outline),
              ),
            );
          }
          return RefreshingOverlay(
            refreshing: snapshot.connectionState != ConnectionState.done,
            child: _buildChartUi(context, points, _lastSeries!),
          );
        },
      );
    }

    final series = _buildSeries(anchor, days);
    if (series.isEmpty) {
      return Center(
        child: Text(
          'Sélectionne au moins un compte pour voir la simulation.',
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
      );
    }
    return _buildChartUi(context, points, series);
  }

  Widget _buildChartUi(BuildContext context, List<DateTime> points, List<_AccountSeries> series) {
    final allValues = [
      if (!_hideUnchanged) for (final s in series) ...s.baseline,
      for (final s in series) ...s.scenario,
    ];
    final minY = allValues.reduce((a, b) => a < b ? a : b);
    final maxY = allValues.reduce((a, b) => a > b ? a : b);
    final pad = (maxY - minY).abs() * 0.1 + 1;

    final labelInterval = (points.length / 8).clamp(1, double.infinity).roundToDouble();
    final axisFormat =
        DateFormat(horizonMonths > 24 ? 'yyyy' : 'd MMM yy', 'fr_FR');
    final outline = Theme.of(context).colorScheme.outline;

    return Column(
      children: [
        Wrap(
          spacing: 16,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final s in series) _Legend(color: s.color, label: s.account.name),
            if (!_hideUnchanged) _Legend(color: outline, label: 'Sans changement'),
            _Legend(color: outline, label: 'Avec ce scénario', dashed: true),
            InkWell(
              onTap: () => setState(() => _hideUnchanged = !_hideUnchanged),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _hideUnchanged ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                    size: 16,
                    color: outline,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _hideUnchanged
                        ? 'Projections sans changement masquées'
                        : 'Masquer les projections sans changement',
                    style: TextStyle(fontSize: 12, color: outline),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (points.isNotEmpty) ...[
          const SizedBox(height: 4),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              for (final s in series)
                Text(
                  '${s.account.name} - écart le '
                  '${DateFormat('d MMM yyyy', 'fr_FR').format(points.last)} : '
                  '${currency?.format(s.scenario.last - s.baseline.last) ?? (s.scenario.last - s.baseline.last).toStringAsFixed(2)}',
                  style: TextStyle(fontWeight: FontWeight.w600, color: s.color),
                ),
            ],
          ),
        ],
        // Always says whether the assumption was actually used, and why
        // not when it wasn't (2026-09-02) - the whole point of the
        // "uniquement si positif" rule is that a negative calculated
        // outcome is never quietly hidden, so silence here would defeat it.
        for (final s in series)
          if (s.assumedBalanceNote != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.flag_outlined, size: 14, color: outline),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    s.assumedBalanceNote!,
                    style: TextStyle(fontSize: 12, color: outline),
                  ),
                ),
              ],
            ),
          ],
        const SizedBox(height: 12),
        Expanded(
          child: LineChart(
            LineChartData(
              minY: minY - pad,
              maxY: maxY + pad,
              gridData: const FlGridData(drawVerticalLine: false),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                leftTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 32,
                    interval: labelInterval,
                    getTitlesWidget: (value, meta) {
                      final i = value.round();
                      if (i < 0 || i >= points.length) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(axisFormat.format(points[i]),
                            style: const TextStyle(fontSize: 10)),
                      );
                    },
                  ),
                ),
              ),
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  fitInsideHorizontally: true,
                  fitInsideVertically: true,
                  // Just each account's balance (2026-09 user feedback: the
                  // per-day recurring-operations breakdown made this
                  // "trop chargé" with several accounts selected - 2N
                  // multi-line items at once). One compact line per bar,
                  // the date shown only once at the very top.
                  getTooltipItems: (spots) => [
                    for (var i = 0; i < spots.length; i++)
                      () {
                        final s = spots[i];
                        // 2 bars per account normally (baseline then
                        // scenario, see lineBarsData below) - only 1 (the
                        // scenario alone) when the solid baseline is hidden.
                        final barsPerAccount = _hideUnchanged ? 1 : 2;
                        final seriesIndex = s.barIndex ~/ barsPerAccount;
                        final isScenario =
                            _hideUnchanged || s.barIndex.isOdd;
                        final acc = series[seriesIndex];
                        final day = points[s.x.round()];
                        final valueLabel =
                            currency?.format(s.y) ?? s.y.toStringAsFixed(2);
                        final dateLine = i == 0
                            ? '${DateFormat('EEEE d MMMM yyyy', 'fr_FR').format(day)}\n'
                            : '';
                        return LineTooltipItem(
                          '$dateLine${acc.account.name}'
                          '${isScenario ? ' (scénario)' : ''} : $valueLabel',
                          const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.w600),
                        );
                      }(),
                  ],
                ),
              ),
              lineBarsData: [
                for (final s in series) ...[
                  if (!_hideUnchanged)
                    LineChartBarData(
                      spots: [
                        for (var i = 0; i < s.baseline.length; i++)
                          FlSpot(i.toDouble(), s.baseline[i])
                      ],
                      isCurved: false,
                      color: s.color,
                      barWidth: 2.5,
                      dotData: const FlDotData(show: false),
                    ),
                  LineChartBarData(
                    spots: [
                      for (var i = 0; i < s.scenario.length; i++)
                        FlSpot(i.toDouble(), s.scenario[i])
                    ],
                    isCurved: false,
                    color: s.color,
                    barWidth: 2.5,
                    dashArray: const [6, 5],
                    dotData: const FlDotData(show: false),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  final Color color;
  final String label;
  final bool dashed;

  const _Legend(
      {required this.color, required this.label, this.dashed = false});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 20,
          height: 2,
          child: dashed
              ? Row(
                  children: List.generate(
                    4,
                    (i) => Expanded(
                      child: Container(
                          margin: EdgeInsets.only(right: i < 3 ? 2 : 0),
                          color: i.isEven ? color : null),
                    ),
                  ),
                )
              : Container(color: color),
        ),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
