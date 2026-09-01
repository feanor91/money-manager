import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/mmex_repository.dart';
import '../models/account.dart';
import '../models/bill_deposit.dart';
import '../models/category.dart';
import '../models/currency.dart';
import '../models/payee.dart';
import '../models/recurrence.dart';
import '../models/sim_scenario.dart';
import '../models/transaction.dart';
import '../state/database_provider.dart';
import '../theme/app_theme.dart';
import '../utils/date_picker.dart';

/// How far the projection looks - see PLAN_SIMULATION_LONG_TERME.md's open
/// "horizon nécessaire" question: rather than pick one answer, every option
/// realistically useful for retirement planning is offered, and the choice
/// is remembered per session (not persisted - a cheap, purely client-side
/// setting, same tier as [ForecastDuration] in forecast_chart.dart).
enum _Horizon { fiveYears, tenYears, twentyYears, thirtyYears, fortyYears }

extension on _Horizon {
  int get years => switch (this) {
        _Horizon.fiveYears => 5,
        _Horizon.tenYears => 10,
        _Horizon.twentyYears => 20,
        _Horizon.thirtyYears => 30,
        _Horizon.fortyYears => 40,
      };
  String get label => '$years ans';
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
class SimulationScreen extends StatefulWidget {
  const SimulationScreen({super.key});

  @override
  State<SimulationScreen> createState() => _SimulationScreenState();
}

class _SimulationScreenState extends State<SimulationScreen> {
  int? _scenarioId;
  _Horizon _horizon = _Horizon.tenYears;

  /// null = every account combined - see PLAN_SIMULATION_LONG_TERME.md's
  /// open "un compte ou tous les comptes" question: rather than pick one
  /// answer up front, both are offered and the choice is just a filter on
  /// already-scenario-agnostic computations
  /// ([MmexRepository.simulatedMonthlyNet]/[MmexRepository.accountBalance]
  /// already accept a nullable accountId).
  int? _accountId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _selectMostRecentScenario());
  }

  void _selectMostRecentScenario() {
    final repo = context.read<DatabaseProvider>().repository;
    if (repo == null || !mounted) return;
    final scenarios = repo.getSimScenarios();
    if (scenarios.isNotEmpty) setState(() => _scenarioId = scenarios.first.id);
  }

  void _touch() => context.read<DatabaseProvider>().touch();

  Future<void> _createScenario(MmexRepository repo) async {
    final name = await _promptText(context, title: 'Nouveau scénario', label: 'Nom');
    if (name == null || name.trim().isEmpty) return;
    final id = repo.createSimScenario(name.trim());
    _touch();
    setState(() => _scenarioId = id);
  }

  Future<void> _renameScenario(MmexRepository repo, SimScenario scenario) async {
    final name = await _promptText(context,
        title: 'Renommer le scénario', label: 'Nom', initialValue: scenario.name);
    if (name == null || name.trim().isEmpty) return;
    repo.renameSimScenario(scenario.id, name.trim());
    _touch();
    setState(() {});
  }

  Future<void> _deleteScenario(MmexRepository repo, SimScenario scenario) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer ce scénario ?'),
        content: Text('"${scenario.name}" et tous ses ajustements seront supprimés.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Annuler')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.negative),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    repo.deleteSimScenario(scenario.id);
    _touch();
    setState(() => _scenarioId = null);
    _selectMostRecentScenario();
  }

  @override
  Widget build(BuildContext context) {
    final dbProvider = context.watch<DatabaseProvider>();
    final repo = dbProvider.repository;
    if (repo == null) return const SizedBox.shrink();

    final scenarios = repo.getSimScenarios();
    if (_scenarioId != null && !scenarios.any((s) => s.id == _scenarioId)) {
      _scenarioId = scenarios.isEmpty ? null : scenarios.first.id;
    }
    final scenario = scenarios.where((s) => s.id == _scenarioId).firstOrNull;
    // Same convention as the voice-entry account matcher (see CLAUDE.md) -
    // an account the user hid elsewhere in the app (Comptes) has no place
    // in a *new* planning tool either (2026-09-02 user report: it was
    // showing up in every account dropdown here).
    final accounts =
        repo.getAccounts().where((a) => !dbProvider.isAccountHidden(a.id)).toList();
    final currency = repo.getBaseCurrency();

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
                  for (final s in scenarios) DropdownMenuItem(value: s.id, child: Text(s.name)),
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
              onPressed: () => _renameScenario(repo, scenario),
            ),
            IconButton(
              tooltip: 'Supprimer ce scénario',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _deleteScenario(repo, scenario),
            ),
            const SizedBox(width: 8),
          ],
          IconButton(
            tooltip: 'Nouveau scénario',
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () => _createScenario(repo),
          ),
          const SizedBox(width: 8),
          DropdownButton<int?>(
            value: _accountId,
            underline: const SizedBox.shrink(),
            items: [
              const DropdownMenuItem(value: null, child: Text('Tous les comptes')),
              for (final a in accounts) DropdownMenuItem(value: a.id, child: Text(a.name)),
            ],
            onChanged: (id) => setState(() => _accountId = id),
          ),
          const SizedBox(width: 8),
          DropdownButton<_Horizon>(
            value: _horizon,
            underline: const SizedBox.shrink(),
            items: [
              for (final h in _Horizon.values) DropdownMenuItem(value: h, child: Text(h.label)),
            ],
            onChanged: (h) => setState(() => _horizon = h!),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: scenario == null
          ? _buildEmptyState(context, repo)
          : LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 900;
                final panel = _AdjustmentsPanel(
                  key: ValueKey(scenario.id),
                  repo: repo,
                  scenario: scenario,
                  accountId: _accountId,
                  accounts: accounts,
                  currency: currency,
                  onChanged: () {
                    _touch();
                    setState(() {});
                  },
                );
                final chart = _SimulationChart(
                  repo: repo,
                  scenarioId: scenario.id,
                  accountId: _accountId,
                  accounts: accounts,
                  horizonMonths: _horizon.years * 12,
                  currency: currency,
                );
                if (wide) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 420, child: panel),
                      const VerticalDivider(width: 1),
                      Expanded(child: Padding(padding: const EdgeInsets.all(16), child: chart)),
                    ],
                  );
                }
                return Column(
                  children: [
                    SizedBox(height: 320, child: chart),
                    const Divider(height: 1),
                    Expanded(child: panel),
                  ],
                );
              },
            ),
    );
  }

  Widget _buildEmptyState(BuildContext context, MmexRepository repo) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insights_outlined, size: 64, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 16),
          Text('Aucun scénario pour l\'instant', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            'Un scénario te permet de simuler l\'impact d\'un changement\n'
            '(perte de revenu, nouvelle pension, arrêt d\'une charge...)\n'
            'sur plusieurs années, sans jamais toucher tes vraies données.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () => _createScenario(repo),
            icon: const Icon(Icons.add),
            label: const Text('Créer un scénario'),
          ),
        ],
      ),
    );
  }
}

Future<String?> _promptText(
  BuildContext context, {
  required String title,
  required String label,
  String? initialValue,
}) {
  final controller = TextEditingController(text: initialValue);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
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

/// The scrollable left/top panel listing every adjustment this scenario
/// makes - real bills (with inline "arrêt le"/"nouveau montant" fields),
/// virtual bills, and one-off events, each section with its own compact
/// "+" entry point. Every control commits immediately (no "Enregistrer"
/// button anywhere in this panel) via [onChanged], which the parent uses to
/// persist ([DatabaseProvider.touch]) and recompute the chart.
class _AdjustmentsPanel extends StatelessWidget {
  final MmexRepository repo;
  final SimScenario scenario;
  final int? accountId;
  final List<Account> accounts;
  final CurrencyFormat? currency;
  final VoidCallback onChanged;

  const _AdjustmentsPanel({
    super.key,
    required this.repo,
    required this.scenario,
    required this.accountId,
    required this.accounts,
    required this.currency,
    required this.onChanged,
  });

  /// The date a limited-duration bill (a fixed remaining occurrence count,
  /// e.g. the last N payments left on a loan - see
  /// [BillDeposit.numOccurrences]'s own doc comment) will fire for the last
  /// time - reuses the exact same occurrence-walking engine the real
  /// projection is built on ([MmexRepository.occurrencesForBill]), just
  /// asked for a long enough window to contain every remaining occurrence.
  /// Null for a bill that repeats forever, or one of the 4 "dans/tous les X
  /// ..." periods where [BillDeposit.numOccurrences] means something else
  /// entirely (an interval, not a count - see [periodUsesXParam]).
  DateTime? _naturalEndDate(BillDeposit bill) {
    if (periodUsesXParam(bill.period) || bill.numOccurrences <= 0) return null;
    final farFuture = DateTime(DateTime.now().year + 60);
    final occurrences = repo.occurrencesForBill(bill, bill.nextOccurrence, farFuture);
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
    buffer.write(bill.transCode == TransCode.deposit ? ' (revenu)' : ' (dépense)');
    final categoryPath = categoryFullPath(bill.categoryId, categoriesById);
    if (categoryPath.isNotEmpty) buffer.write('\nCatégorie : $categoryPath');
    buffer.write('\nCompte : ${accountsById[bill.accountId]?.name ?? "?"}');
    buffer.write('\nPériodicité : ${recurrencePeriodLabel(bill.period)}');
    buffer.write('\nProchaine échéance : ${DateFormat('d MMM yyyy', 'fr_FR').format(bill.nextOccurrence)}');
    if ((bill.notes ?? '').trim().isNotEmpty) buffer.write('\nNotes : ${bill.notes!.trim()}');
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    final payeesById = {for (final p in repo.getPayees(onlyActive: false)) p.id: p};
    final accountsById = {for (final a in accounts) a.id: a};
    final categoriesById = {for (final c in repo.getCategories(onlyActive: false)) c.id: c};
    final overridesByBillId = {for (final o in repo.getSimBillOverrides(scenario.id)) o.billId: o};
    final realBills = repo.getBillDeposits().where((b) {
      if (b.paused) return false;
      if (accountId == null) return b.transCode != TransCode.transfer;
      return b.accountId == accountId || b.toAccountId == accountId;
    }).toList()
      // Biggest recurring items first (2026-09-02 user request) - by
      // magnitude regardless of income/expense direction, same convention
      // as this app's other rankings (top expenses, category spend).
      ..sort((a, b) => b.amount.abs().compareTo(a.amount.abs()));
    final virtualBills = repo.getSimVirtualBills(scenario.id)
      ..sort((a, b) => b.amount.abs().compareTo(a.amount.abs()));
    final events = repo.getSimOneOffEvents(scenario.id)
      ..sort((a, b) => b.amount.abs().compareTo(a.amount.abs()));

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
                child:
                    Text('Opérations virtuelles', style: Theme.of(context).textTheme.titleSmall)),
            IconButton(
              tooltip: accounts.isEmpty
                  ? 'Crée d\'abord un compte'
                  : 'Ajouter une opération virtuelle',
              icon: const Icon(Icons.add_circle_outline),
              onPressed: accounts.isEmpty ? null : () => _openVirtualBillDialog(context),
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
            message: '${v.label} (${v.transCode == TransCode.deposit ? "revenu" : "dépense"})\n'
                'Compte : ${accountsById[v.accountId]?.name ?? "?"}\n'
                'Périodicité : ${recurrencePeriodLabel(v.period)}\n'
                'À partir du : ${DateFormat('d MMM yyyy', 'fr_FR').format(v.startDate)}',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                v.transCode == TransCode.deposit ? Icons.south_west : Icons.north_east,
                color: v.transCode == TransCode.deposit ? AppTheme.positive : AppTheme.negative,
              ),
              title: Text(v.label),
              subtitle: Text(
                '${currency?.format(v.amount) ?? v.amount.toStringAsFixed(2)} - '
                '${recurrencePeriodLabel(v.period)} - à partir du '
                '${DateFormat('d MMM yyyy', 'fr_FR').format(v.startDate)}',
              ),
              onTap: () => _openVirtualBillDialog(context, existing: v),
              trailing: IconButton(
                tooltip: 'Supprimer',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  repo.deleteSimVirtualBill(v.id);
                  onChanged();
                },
              ),
            ),
          ),
        const Divider(height: 32),
        Text('Opérations récurrentes réelles', style: Theme.of(context).textTheme.titleSmall),
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
            child: Text('Aucune opération récurrente sur ce périmètre.'),
          ),
        for (final bill in realBills)
          _RealBillRow(
            key: ValueKey('bill-${bill.id}'),
            bill: bill,
            label: _billLabel(bill, payeesById, accountsById),
            tooltip: _billTooltip(
                bill, _billLabel(bill, payeesById, accountsById), categoriesById, accountsById),
            naturalEndDate: _naturalEndDate(bill),
            currency: currency,
            savedOverride: overridesByBillId[bill.id],
            onChanged: (disabledFrom, amountOverride) {
              final hasNoOverride = disabledFrom == null && amountOverride == null;
              if (hasNoOverride) {
                repo.deleteSimBillOverride(scenario.id, bill.id);
              } else {
                repo.upsertSimBillOverride(scenario.id, bill.id,
                    disabledFrom: disabledFrom, amountOverride: amountOverride);
              }
              onChanged();
            },
          ),
        const Divider(height: 32),
        Row(
          children: [
            Expanded(
                child: Text('Événements ponctuels', style: Theme.of(context).textTheme.titleSmall)),
            IconButton(
              tooltip: accounts.isEmpty
                  ? 'Crée d\'abord un compte'
                  : 'Ajouter un événement ponctuel',
              icon: const Icon(Icons.add_circle_outline),
              onPressed: accounts.isEmpty ? null : () => _openOneOffEventDialog(context),
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
            message: '${e.label} (${e.transCode == TransCode.deposit ? "revenu" : "dépense"})\n'
                'Compte : ${accountsById[e.accountId]?.name ?? "?"}\n'
                'Date : ${DateFormat('d MMM yyyy', 'fr_FR').format(e.date)}',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                e.transCode == TransCode.deposit ? Icons.south_west : Icons.north_east,
                color: e.transCode == TransCode.deposit ? AppTheme.positive : AppTheme.negative,
              ),
              title: Text(e.label),
              subtitle: Text(
                '${currency?.format(e.amount) ?? e.amount.toStringAsFixed(2)} le '
                '${DateFormat('d MMM yyyy', 'fr_FR').format(e.date)}',
              ),
              trailing: IconButton(
                tooltip: 'Supprimer',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  repo.deleteSimOneOffEvent(e.id);
                  onChanged();
                },
              ),
            ),
          ),
      ],
    );
  }

  String _billLabel(BillDeposit bill, Map<int, Payee> payeesById, Map<int, Account> accountsById) {
    if (bill.transCode == TransCode.transfer) {
      return '${accountsById[bill.accountId]?.name ?? "?"} → '
          '${accountsById[bill.toAccountId]?.name ?? "?"}';
    }
    return payeesById[bill.payeeId]?.name ?? 'Tiers inconnu';
  }

  Future<void> _openVirtualBillDialog(BuildContext context, {SimVirtualBill? existing}) async {
    final result = await showDialog<_VirtualBillFormResult>(
      context: context,
      builder: (context) => _VirtualBillDialog(accounts: accounts, existing: existing),
    );
    if (result == null) return;
    if (existing != null) repo.deleteSimVirtualBill(existing.id);
    repo.addSimVirtualBill(
      scenarioId: scenario.id,
      accountId: result.accountId,
      label: result.label,
      transCode: result.transCode,
      amount: result.amount,
      startDate: result.startDate,
      period: result.period,
    );
    onChanged();
  }

  Future<void> _openOneOffEventDialog(BuildContext context) async {
    final result = await showDialog<_OneOffEventFormResult>(
      context: context,
      builder: (context) => _OneOffEventDialog(accounts: accounts),
    );
    if (result == null) return;
    repo.addSimOneOffEvent(
      scenarioId: scenario.id,
      accountId: result.accountId,
      label: result.label,
      transCode: result.transCode,
      amount: result.amount,
      date: result.date,
    );
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
  late DateTime? _disabledFrom = widget.savedOverride?.disabledFrom ?? widget.naturalEndDate;
  late final _amountController =
      TextEditingController(text: widget.savedOverride?.amountOverride?.toStringAsFixed(2) ?? '');
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
      initialDate: (_disabledFrom == null || _fullyExcluded) ? DateTime.now() : _disabledFrom!,
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
    final realAmountLabel = widget.currency?.format(bill.amount) ?? bill.amount.toStringAsFixed(2);
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
                  bill.transCode == TransCode.deposit ? Icons.south_west : Icons.north_east,
                  size: 16,
                  color: bill.transCode == TransCode.deposit ? AppTheme.positive : AppTheme.negative,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(widget.label,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
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
                                : DateFormat('d MMM yyyy', 'fr_FR').format(_disabledFrom!),
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
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(isDense: true, labelText: 'Nouveau montant'),
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

  const _VirtualBillFormResult({
    required this.accountId,
    required this.label,
    required this.transCode,
    required this.amount,
    required this.startDate,
    required this.period,
  });
}

class _VirtualBillDialog extends StatefulWidget {
  final List<Account> accounts;
  final SimVirtualBill? existing;

  const _VirtualBillDialog({required this.accounts, this.existing});

  @override
  State<_VirtualBillDialog> createState() => _VirtualBillDialogState();
}

class _VirtualBillDialogState extends State<_VirtualBillDialog> {
  late final _labelController = TextEditingController(text: widget.existing?.label ?? '');
  late final _amountController =
      TextEditingController(text: widget.existing?.amount.toStringAsFixed(2) ?? '');
  late int _accountId = widget.existing?.accountId ?? widget.accounts.first.id;
  late TransCode _transCode = widget.existing?.transCode ?? TransCode.deposit;
  late DateTime _startDate = widget.existing?.startDate ?? DateTime.now();
  late RecurrencePeriod _period = widget.existing?.period ?? RecurrencePeriod.monthly;

  @override
  void dispose() {
    _labelController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  void _submit() {
    final amount = double.tryParse(_amountController.text.replaceAll(',', '.'));
    if (_labelController.text.trim().isEmpty || amount == null || amount <= 0) return;
    Navigator.of(context).pop(_VirtualBillFormResult(
      accountId: _accountId,
      label: _labelController.text.trim(),
      transCode: _transCode,
      amount: amount,
      startDate: _startDate,
      period: _period,
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _labelController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Libellé (ex. Pension de retraite)'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: SegmentedButton<TransCode>(
                    segments: const [
                      ButtonSegment(value: TransCode.deposit, label: Text('Revenu')),
                      ButtonSegment(value: TransCode.withdrawal, label: Text('Dépense')),
                    ],
                    selected: {_transCode},
                    onSelectionChanged: (s) => setState(() => _transCode = s.first),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _amountController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Montant'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _accountId,
              decoration: const InputDecoration(labelText: 'Compte'),
              items: [
                for (final a in widget.accounts) DropdownMenuItem(value: a.id, child: Text(a.name)),
              ],
              onChanged: (id) => setState(() => _accountId = id!),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<RecurrencePeriod>(
              initialValue: _period,
              decoration: const InputDecoration(labelText: 'Périodicité'),
              items: [
                for (final p in _simplePeriods)
                  DropdownMenuItem(value: p, child: Text(recurrencePeriodLabel(p))),
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
                child: Text(DateFormat('d MMM yyyy', 'fr_FR').format(_startDate)),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
        FilledButton(onPressed: _submit, child: const Text('Valider')),
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

  const _OneOffEventDialog({required this.accounts});

  @override
  State<_OneOffEventDialog> createState() => _OneOffEventDialogState();
}

class _OneOffEventDialogState extends State<_OneOffEventDialog> {
  final _labelController = TextEditingController();
  final _amountController = TextEditingController();
  late int _accountId = widget.accounts.first.id;
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
    if (_labelController.text.trim().isEmpty || amount == null || amount <= 0) return;
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
              decoration: const InputDecoration(labelText: 'Libellé (ex. Capital de départ)'),
            ),
            const SizedBox(height: 12),
            SegmentedButton<TransCode>(
              segments: const [
                ButtonSegment(value: TransCode.deposit, label: Text('Revenu')),
                ButtonSegment(value: TransCode.withdrawal, label: Text('Dépense')),
              ],
              selected: {_transCode},
              onSelectionChanged: (s) => setState(() => _transCode = s.first),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _amountController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Montant'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _accountId,
              decoration: const InputDecoration(labelText: 'Compte'),
              items: [
                for (final a in widget.accounts) DropdownMenuItem(value: a.id, child: Text(a.name)),
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
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
        FilledButton(onPressed: _submit, child: const Text('Valider')),
      ],
    );
  }
}

/// The baseline-vs-scenario projection chart - solid accent line for "si
/// rien ne change" ([MmexRepository.recurringMonthlyNet], the real
/// schedule, untouched), dashed orange line for the scenario itself
/// ([MmexRepository.simulatedMonthlyNet]) - orange dashed is the same
/// "simulated" visual convention forecast_chart.dart already uses for its
/// own simulated-purchase overlay, reused here on purpose for a consistent
/// meaning across the app. Both start from today's real combined/per-account
/// balance ([MmexRepository.accountBalance]), so they only ever diverge from
/// what the scenario actually changes.
class _SimulationChart extends StatelessWidget {
  final MmexRepository repo;
  final int scenarioId;
  final int? accountId;
  final List<Account> accounts;
  final int horizonMonths;
  final CurrencyFormat? currency;

  const _SimulationChart({
    required this.repo,
    required this.scenarioId,
    required this.accountId,
    required this.accounts,
    required this.horizonMonths,
    required this.currency,
  });

  double _startingBalance() {
    final now = DateTime.now();
    if (accountId != null) return repo.accountBalance(accountId!, asOf: now);
    // Sums every *visible* account (see the caller's own filtering) - a
    // hidden account's balance has no place in "tous les comptes" here
    // either, same reasoning as the account dropdown itself.
    return accounts.fold(0.0, (sum, a) => sum + repo.accountBalance(a.id, asOf: now));
  }

  List<double> _cumulative(Map<DateTime, double> monthlyNet, double startingBalance) {
    final keys = monthlyNet.keys.toList()..sort();
    var running = startingBalance;
    return [for (final k in keys) running += monthlyNet[k]!];
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final anchor = DateTime(now.year, now.month + horizonMonths - 1, 1);
    final startingBalance = _startingBalance();

    final baselineNet =
        repo.recurringMonthlyNet(anchor: anchor, months: horizonMonths, accountId: accountId);
    final scenarioNet = repo.simulatedMonthlyNet(
        scenarioId: scenarioId, anchor: anchor, months: horizonMonths, accountId: accountId);
    final months = (baselineNet.keys.toList()..sort());

    final baseline = _cumulative(baselineNet, startingBalance);
    final scenario = _cumulative(scenarioNet, startingBalance);

    final allValues = [...baseline, ...scenario];
    final minY = allValues.reduce((a, b) => a < b ? a : b);
    final maxY = allValues.reduce((a, b) => a > b ? a : b);
    final pad = (maxY - minY).abs() * 0.1 + 1;

    final labelInterval = (months.length / 8).clamp(1, 60).roundToDouble();
    final axisFormat = DateFormat(months.length > 24 ? 'yyyy' : 'MMM yy', 'fr_FR');

    return Column(
      children: [
        Row(
          children: [
            _Legend(color: AppTheme.accent, label: 'Sans changement'),
            const SizedBox(width: 16),
            _Legend(color: Colors.orange.shade700, label: 'Avec ce scénario', dashed: true),
            const Spacer(),
            if (months.isNotEmpty)
              Text(
                'Écart en ${DateFormat('MMM yyyy', 'fr_FR').format(months.last)} : '
                '${currency?.format(scenario.last - baseline.last) ?? (scenario.last - baseline.last).toStringAsFixed(2)}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: LineChart(
            LineChartData(
              minY: minY - pad,
              maxY: maxY + pad,
              gridData: const FlGridData(drawVerticalLine: false),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 32,
                    interval: labelInterval,
                    getTitlesWidget: (value, meta) {
                      final i = value.round();
                      if (i < 0 || i >= months.length) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(axisFormat.format(months[i]), style: const TextStyle(fontSize: 10)),
                      );
                    },
                  ),
                ),
              ),
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  fitInsideHorizontally: true,
                  fitInsideVertically: true,
                  getTooltipItems: (spots) => [
                    for (final s in spots)
                      LineTooltipItem(
                        '${DateFormat('MMM yyyy', 'fr_FR').format(months[s.x.round()])}\n'
                        '${currency?.format(s.y) ?? s.y.toStringAsFixed(2)}'
                        '${s.barIndex == 1 ? ' (scénario)' : ''}',
                        const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                  ],
                ),
              ),
              lineBarsData: [
                LineChartBarData(
                  spots: [for (var i = 0; i < baseline.length; i++) FlSpot(i.toDouble(), baseline[i])],
                  isCurved: false,
                  color: AppTheme.accent,
                  barWidth: 2.5,
                  dotData: const FlDotData(show: false),
                ),
                LineChartBarData(
                  spots: [for (var i = 0; i < scenario.length; i++) FlSpot(i.toDouble(), scenario[i])],
                  isCurved: false,
                  color: Colors.orange.shade700,
                  barWidth: 2.5,
                  dashArray: const [6, 5],
                  dotData: const FlDotData(show: false),
                ),
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

  const _Legend({required this.color, required this.label, this.dashed = false});

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
                          margin: EdgeInsets.only(right: i < 3 ? 2 : 0), color: i.isEven ? color : null),
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
