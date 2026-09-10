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
import 'package:money_manager_core/models/transaction.dart';
import '../state/api_session_provider.dart';
import '../state/database_provider.dart';
import '../theme/app_theme.dart';
import '../utils/date_picker.dart';
import '../utils/list_utils.dart';
import '../widgets/bulk_category_reassign.dart';
import '../widgets/confirm_delete.dart';
import '../widgets/responsive_body.dart';
import '../widgets/searchable_select_field.dart';

/// Bundle des données nécessaires pour dessiner la liste, qu'elles viennent
/// du fichier local ou du serveur API - étape 4 du chantier client/serveur
/// (voir PLAN_ARCHITECTURE_CLIENT_SERVEUR.md). L'éditeur (ajouter/modifier/
/// dupliquer/enregistrer une occurrence, augmentation annuelle...) continue
/// de passer par [DatabaseProvider.repository] directement, indépendamment
/// de cette bascule - voir [_RecurringScreenState._openEditor].
class _RecurringData {
  final CurrencyFormat? currency;
  final List<BillDeposit> bills;
  final Map<int, Account> accounts;
  final Map<int, Category> categories;
  final Map<int, Payee> payees;
  final Map<int, int> occurrenceTotals;

  _RecurringData({
    required this.currency,
    required this.bills,
    required this.accounts,
    required this.categories,
    required this.payees,
    required this.occurrenceTotals,
  });
}

/// Adds [months] calendar months to [date], clamping to the destination
/// month's real last day - same small helper every screen that needs it
/// keeps its own private copy of (see forecast_chart.dart/budget_screen.dart).
/// Used by _RecordOccurrenceDialog to preview a split occurrence's
/// installment dates - the actual installments are dated the same way,
/// server-side, by MmexRepository.recordBillOccurrence.
DateTime _addMonths(DateTime date, int months) {
  final total = date.year * 12 + (date.month - 1) + months;
  final year = total ~/ 12;
  final month = total % 12 + 1;
  final lastDay = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, date.day > lastDay ? lastDay : date.day);
}

class RecurringScreen extends StatefulWidget {
  const RecurringScreen({super.key});

  @override
  State<RecurringScreen> createState() => _RecurringScreenState();
}

class _RecurringScreenState extends State<RecurringScreen> {
  int? _accountFilter;
  String _searchQuery = '';
  Future<_RecurringData>? _apiFuture;
  _RecurringData? _lastData;

  _RecurringData _localData(MmexRepository repo) {
    return _RecurringData(
      currency: repo.getBaseCurrency(),
      bills: repo.getBillDeposits(),
      accounts: {for (final a in repo.getAccounts()) a.id: a},
      categories: {for (final c in repo.getCategories()) c.id: c},
      payees: {for (final p in repo.getPayees(onlyActive: false)) p.id: p},
      occurrenceTotals: repo.billOccurrenceTotals(),
    );
  }

  /// Lecture seule - l'éditeur (ajouter/modifier/enregistrer une
  /// occurrence...) continue de passer par le fichier local même en mode
  /// API, voir [_openEditor]. Pas de rafraîchissement automatique après une
  /// modification - même nuance que les autres écrans déjà migrés.
  Future<_RecurringData> _loadViaApi(ApiSessionProvider session) async {
    final currency = await session.getBaseCurrency();
    final bills = await session.getBillDeposits();
    final accounts = await session.getAccounts();
    final categories = await session.getCategories();
    final payees = await session.getPayees(onlyActive: false);
    final occurrenceTotals = await session.billOccurrenceTotals();
    return _RecurringData(
      currency: currency,
      bills: bills,
      accounts: {for (final a in accounts) a.id: a},
      categories: {for (final c in categories) c.id: c},
      payees: {for (final p in payees) p.id: p},
      occurrenceTotals: occurrenceTotals,
    );
  }

  void _refreshApi(ApiSessionProvider session) {
    setState(() => _apiFuture = _loadViaApi(session));
  }

  @override
  Widget build(BuildContext context) {
    final dbProvider = context.watch<DatabaseProvider>();
    final apiSession = context.watch<ApiSessionProvider>();
    final repo = dbProvider.repository!;

    if (apiSession.useApiForRecurring) {
      _apiFuture ??= _loadViaApi(apiSession);
      return FutureBuilder<_RecurringData>(
        future: _apiFuture,
        builder: (context, snapshot) {
          if (snapshot.hasData) _lastData = snapshot.data;
          if (_lastData == null) {
            if (snapshot.hasError) {
              return Scaffold(body: Center(child: Text('Erreur : ${snapshot.error}')));
            }
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          return _buildScaffold(context, dbProvider, repo, _lastData!,
              apiSession: apiSession, apiRefresh: () => _refreshApi(apiSession));
        },
      );
    }

    _apiFuture = null;
    return _buildScaffold(context, dbProvider, repo, _localData(repo));
  }

  /// [apiRefresh] non-null seulement en mode API - ajoute le bouton de
  /// rafraîchissement manuel dans l'AppBar (voir [_loadViaApi]). [repo] est
  /// toujours le dépôt local, quel que soit le mode - voir [_buildBody].
  Widget _buildScaffold(
      BuildContext context, DatabaseProvider dbProvider, MmexRepository repo, _RecurringData data,
      {ApiSessionProvider? apiSession, VoidCallback? apiRefresh}) {
    final visibleAccounts = data.accounts.values
        .where((a) => !dbProvider.isAccountHidden(a.id))
        .toList();
    final baseTitle = apiRefresh != null ? 'Opérations récurrentes (via API)' : 'Opérations récurrentes';
    return Scaffold(
      appBar: AppBar(
        title: Text(_accountFilter == null
            ? baseTitle
            : '$baseTitle - ${data.accounts[_accountFilter]?.name}'),
        actions: [
          PopupMenuButton<int?>(
            icon: const Icon(Icons.filter_list),
            tooltip: 'Filtrer par compte',
            onSelected: (id) => setState(() => _accountFilter = id),
            itemBuilder: (context) => [
              const PopupMenuItem<int?>(value: null, child: Text('Tous les comptes')),
              for (final a in visibleAccounts) PopupMenuItem<int?>(value: a.id, child: Text(a.name)),
            ],
          ),
          if (apiRefresh != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Rafraîchir',
              onPressed: apiRefresh,
            ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Paramètres',
            onPressed: () => Navigator.of(context).pushNamed('/settings'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(context, apiSession: apiSession, apiRefresh: apiRefresh),
        icon: const Icon(Icons.add),
        label: const Text('Ajouter'),
      ),
      body: _buildBody(context, dbProvider, repo, data,
          apiSession: apiSession, apiRefresh: apiRefresh),
    );
  }

  /// [repo] est toujours le dépôt local pour l'enregistrement d'une
  /// occurrence (voir [_recordOccurrence]) - opération plus complexe
  /// (création d'une vraie transaction, parfois répartie en plusieurs
  /// mensualités) laissée de côté pour cette passe, décision de périmètre
  /// documentée dans PLAN_ARCHITECTURE_CLIENT_SERVEUR.md ("Précision
  /// ajoutée le 2026-09-10"). Le reste (ajouter/modifier/supprimer une
  /// opération récurrente, mettre en pause, augmentation annuelle) passe
  /// par [apiSession] quand fourni et connecté.
  Widget _buildBody(
      BuildContext context, DatabaseProvider dbProvider, MmexRepository repo, _RecurringData data,
      {ApiSessionProvider? apiSession, VoidCallback? apiRefresh}) {
    final useApi = apiSession != null && apiSession.useApiForRecurring && apiSession.isConnected;
    final currency = data.currency;
    final accounts = data.accounts;
    final categories = data.categories;
    final payees = data.payees;
    final occurrenceTotals = data.occurrenceTotals;

    bool matchesBill(BillDeposit bill) {
      if (_accountFilter != null &&
          bill.accountId != _accountFilter &&
          bill.toAccountId != _accountFilter) {
        return false;
      }
      final query = _searchQuery.trim().toLowerCase();
      if (query.isEmpty) return true;
      final haystack = [
        payees[bill.payeeId]?.name,
        accounts[bill.accountId]?.name,
        accounts[bill.toAccountId]?.name,
        categoryFullPath(bill.categoryId, categories),
        bill.notes,
      ].whereType<String>().join(' ').toLowerCase();
      return haystack.contains(query);
    }

    // Paused operations last, out of the way of the active schedule -
    // everything else sorted by next-occurrence date, soonest first (2026-09
    // user request, reversing the original "paused first" order).
    final bills = data.bills.where(matchesBill).toList()
      ..sort((a, b) {
        if (a.paused != b.paused) return a.paused ? 1 : -1;
        return a.nextOccurrence.compareTo(b.nextOccurrence);
      });

    return ResponsiveBody(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                decoration: const InputDecoration(
                  hintText: 'Rechercher (tiers, compte, catégorie...)',
                  prefixIcon: Icon(Icons.search),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _searchQuery = v),
              ),
            ),
            // Only when scoped to a single account - a "total" across every
            // account mixed together isn't a meaningful number (different
            // currencies/purposes), and the user explicitly asked for this
            // to stay off the "tous les comptes" view (2026-08-07).
            if (_accountFilter != null)
              _RecurringTotalsBar(bills: bills, currency: currency, accountId: _accountFilter!),
            Expanded(
              child: bills.isEmpty
                  ? const Center(child: Text('Aucune opération récurrente'))
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      itemCount: bills.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, i) {
                        final bill = bills[i];
                        final isTransfer = bill.transCode == TransCode.transfer;
                        final signed = bill.transCode == TransCode.deposit
                            ? bill.amount
                            : -bill.amount;
                        final positive = signed >= 0;
                        final today = DateTime.now();
                        final overdue = bill.nextOccurrence.isBefore(
                            DateTime(today.year, today.month, today.day));
                        final title = isTransfer
                            ? '${accounts[bill.accountId]?.name ?? '?'} → ${accounts[bill.toAccountId]?.name ?? '?'}'
                            : (payees[bill.payeeId]?.name ?? 'Tiers inconnu');
                        final categoryLabel = categoryFullPath(bill.categoryId, categories);
                        final occurrenceTotal = occurrenceTotals[bill.id];
                        final remainingLabel = (!periodUsesXParam(bill.period) &&
                                bill.numOccurrences >= 0 &&
                                occurrenceTotal != null)
                            ? ' (${bill.numOccurrences}/$occurrenceTotal)'
                            : '';
                        final subtitleLine1 = isTransfer
                            ? (categoryLabel.isEmpty ? 'Virement' : 'Virement - $categoryLabel')
                            : '${accounts[bill.accountId]?.name ?? ''} - '
                                '${categoryLabel.isEmpty ? 'Non catégorisé' : categoryLabel}';
                        return Card(
                          child: Opacity(
                            opacity: bill.paused ? 0.55 : 1,
                            child: ListTile(
                              onTap: () => _openEditor(context,
                                  existing: bill, apiSession: apiSession, apiRefresh: apiRefresh),
                              leading: CircleAvatar(
                                backgroundColor: (positive
                                        ? AppTheme.positive
                                        : AppTheme.negative)
                                    .withValues(alpha: 0.12),
                                child: Icon(
                                  isTransfer ? Icons.swap_horiz : Icons.autorenew,
                                  color: positive
                                      ? AppTheme.positive
                                      : AppTheme.negative,
                                  size: 18,
                                ),
                              ),
                              title: Text(title,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                '$subtitleLine1\n'
                                '${recurrencePeriodLabelWithX(bill.period, bill.numOccurrences)} - prochaine: '
                                '${DateFormat.yMMMd('fr_FR').format(bill.nextOccurrence)}'
                                '${overdue ? ' (en retard)' : ''}'
                                '${bill.paused ? ' (en pause)' : ''}',
                              ),
                              isThreeLine: true,
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Tooltip(
                                    message: 'Mettre en pause (ignorée à '
                                        'l\'ajout automatique et dans le '
                                        'prévisionnel)',
                                    child: Checkbox(
                                      value: bill.paused,
                                      onChanged: (v) async {
                                        if (useApi) {
                                          await apiSession.setBillPaused(bill.id, v ?? false);
                                          apiRefresh?.call();
                                        } else {
                                          repo.setBillPaused(bill.id, v ?? false);
                                          dbProvider.touch();
                                        }
                                      },
                                    ),
                                  ),
                                  Text(
                                    '${currency?.format(signed) ?? signed.toStringAsFixed(2)}'
                                    '$remainingLabel',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: overdue
                                          ? AppTheme.negative
                                          : (positive
                                              ? AppTheme.positive
                                              : AppTheme.negative),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: bill.annualIncreasePercent != 0
                                        ? 'Augmentation annuelle : '
                                            '${bill.annualIncreasePercent.toStringAsFixed(1)} % '
                                            '(le ${bill.annualIncreaseAnchor != null ? DateFormat.MMMd('fr_FR').format(bill.annualIncreaseAnchor!) : '?'})'
                                        : 'Définir une augmentation annuelle',
                                    icon: Icon(
                                      Icons.trending_up,
                                      color: bill.annualIncreasePercent != 0
                                          ? Theme.of(context).colorScheme.primary
                                          : null,
                                    ),
                                    onPressed: () => _editAnnualIncrease(context, bill,
                                        apiSession: apiSession, apiRefresh: apiRefresh),
                                  ),
                                  IconButton(
                                    tooltip: 'Enregistrer cette occurrence',
                                    icon: const Icon(Icons.playlist_add_check),
                                    onPressed: () =>
                                        _recordOccurrence(context, bill),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      );
  }

  Future<void> _editAnnualIncrease(BuildContext context, BillDeposit bill,
      {ApiSessionProvider? apiSession, VoidCallback? apiRefresh}) async {
    final dbProvider = context.read<DatabaseProvider>();
    final repo = dbProvider.repository!;
    final result = await showDialog<_AnnualIncreaseResult>(
      context: context,
      builder: (_) => _AnnualIncreaseDialog(repo: repo, bill: bill),
    );
    if (result == null) return;
    final useApi = apiSession != null && apiSession.useApiForRecurring && apiSession.isConnected;
    if (useApi) {
      if (result.cleared) {
        await apiSession.clearBillAnnualIncrease(bill.id);
      } else {
        await apiSession.setBillAnnualIncrease(bill.id,
            percent: result.percent!, anchor: result.anchor!);
      }
      apiRefresh?.call();
    } else {
      if (result.cleared) {
        repo.clearBillAnnualIncrease(bill.id);
      } else {
        repo.setBillAnnualIncrease(bill.id,
            percent: result.percent!, anchor: result.anchor!);
      }
      dbProvider.touch();
    }
  }

  Future<void> _recordOccurrence(BuildContext context, BillDeposit bill) async {
    final dbProvider = context.read<DatabaseProvider>();
    final repo = dbProvider.repository!;
    await showDialog(
      context: context,
      builder: (_) => _RecordOccurrenceDialog(bill: bill, repo: repo),
    );
    dbProvider.touch();
  }

  Future<void> _openEditor(BuildContext context,
      {BillDeposit? existing,
      BillDeposit? duplicateFrom,
      ApiSessionProvider? apiSession,
      VoidCallback? apiRefresh}) async {
    final dbProvider = context.read<DatabaseProvider>();
    final repo = dbProvider.repository!;
    final useApi = apiSession != null && apiSession.useApiForRecurring && apiSession.isConnected;
    final result = await showModalBottomSheet<RecurringEditorResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => RecurringEditorSheet(
          existing: existing, repo: repo, duplicateFrom: duplicateFrom, apiSession: apiSession),
    );
    if (useApi) {
      apiRefresh?.call();
    } else {
      dbProvider.touch();
    }
    // Réassignation en masse de catégorie - reste locale uniquement, même
    // nuance que TransactionEditorSheet._save (voir
    // PLAN_ARCHITECTURE_CLIENT_SERVEUR.md, "Précision ajoutée le
    // 2026-09-10") : elle passerait par le dépôt local sans savoir qu'une
    // écriture vient de partir vers le serveur.
    if (!useApi && result?.categoryChange != null && context.mounted) {
      await offerBulkCategoryReassign(
        context: context,
        repo: repo,
        dbProvider: dbProvider,
        change: result!.categoryChange!,
      );
    }
    // "Dupliquer" was tapped - reopen a fresh "Nouvelle opération
    // récurrente" sheet seeded from the source bill, only once this one
    // has fully closed (same deferred-to-after-close convention as
    // openTransactionEditor's identical duplicate handling).
    if (result?.duplicateFrom != null && context.mounted) {
      await _openEditor(context,
          duplicateFrom: result!.duplicateFrom, apiSession: apiSession, apiRefresh: apiRefresh);
    }
  }
}

/// Dépenses / Revenus / Différence for the currently visible (account +
/// search filtered) recurring operations - only shown when scoped to a
/// single account (see [_RecurringScreenState.build]).
///
/// Corrections made 2026-08-07 after the first version looked wrong to the
/// user testing it:
/// - Each bill's raw [BillDeposit.amount] is converted to its
///   monthly-equivalent cost via [recurrencePeriodToMonthlyFactor] (same
///   conversion [MmexRepository.categoryMonthlyRecurringTotals] already
///   uses for the budget screen's "auto" envelopes) - summing raw amounts
///   made a single yearly bill's full annual cost look like a monthly one,
///   and made the total swing depending on which bills happen to be due
///   soonest rather than reflecting a stable "what this costs me per
///   month" figure.
/// - A transfer (virement) counts as Revenus or Dépenses for [accountId]
///   depending on which side of it this account is on - money arriving via
///   a transfer from another account (e.g. Crédit Agricole -> Boursorama)
///   is real incoming cash flow for *this* account, same as
///   [MmexRepository.monthlyRecurringIncome]'s own "incoming transfer
///   counts as income" rule, just without that method's Épargne-category
///   exception (not relevant to a single-account cash-flow summary the way
///   it is to a whole-budget income figure). An outgoing transfer (this
///   account is the source) counts as Dépenses the same way, for the
///   symmetric reason. **Confirmed explicitly 2026-08-07 after an earlier
///   version excluded transfers from both totals entirely** - the exact
///   opposite of what was actually wanted: excluding them made a real
///   700€/month incoming transfer invisible from "Revenus" instead of
///   counted, which is what triggered this whole correction.
///
/// Paused operations are excluded, same as everywhere else a total/
/// forecast is derived from this schedule (paused explicitly means
/// "excluded from ... le prévisionnel" per its own checkbox tooltip).
class _RecurringTotalsBar extends StatelessWidget {
  final List<BillDeposit> bills;
  final CurrencyFormat? currency;
  final int accountId;

  const _RecurringTotalsBar({required this.bills, required this.currency, required this.accountId});

  @override
  Widget build(BuildContext context) {
    var expense = 0.0;
    var income = 0.0;
    for (final bill in bills) {
      if (bill.paused) continue;
      final factor = recurrencePeriodToMonthlyFactor(bill.period, bill.numOccurrences);
      if (factor <= 0) continue;
      switch (bill.transCode) {
        case TransCode.withdrawal:
          expense += bill.amount * factor;
        case TransCode.deposit:
          income += bill.amount * factor;
        case TransCode.transfer:
          if (bill.toAccountId == accountId) {
            income += bill.toAmount * factor;
          } else if (bill.accountId == accountId) {
            expense += bill.amount * factor;
          }
      }
    }
    final diff = income - expense;
    String format(double value) => currency?.format(value) ?? value.toStringAsFixed(2);

    Widget stat(String label, double value, Color color) => Expanded(
          child: Column(
            children: [
              Text(label, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey)),
              const SizedBox(height: 2),
              Text(
                format(value),
                style: TextStyle(fontWeight: FontWeight.w700, color: color),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          child: Row(
            children: [
              stat('Dépenses', expense, AppTheme.negative),
              stat('Revenus', income, AppTheme.positive),
              stat('Différence', diff, diff >= 0 ? AppTheme.positive : AppTheme.negative),
            ],
          ),
        ),
      ),
    );
  }
}

/// [RecurringEditorSheet]'s pop value - `categoryChange` triggers the same
/// bulk-reassign offer [TransactionEditorResult] does; `duplicateFrom`
/// triggers _RecurringScreenState._openEditor reopening a fresh sheet
/// seeded from the source bill, same "Dupliquer" convention as the ledger's
/// own TransactionEditorResult/openTransactionEditor (2026-09-03 user
/// request: "possibilité de dupliquer une opération récurrente comme pour
/// les transactions du grand livre").
typedef RecurringEditorResult = ({
  CategoryChange? categoryChange,
  BillDeposit? duplicateFrom,
});

/// Public (not file-private) so [TransactionsScreen] can also open it - lets
/// you create a recurring bill straight from the ledger without switching
/// to the "Récurrentes" tab first.
class RecurringEditorSheet extends StatefulWidget {
  final BillDeposit? existing;
  final MmexRepository repo;
  final int? defaultAccountId;

  /// Non-null ET connecté : l'enregistrement/suppression passe par le
  /// serveur au lieu du fichier local (chantier écriture, base de test
  /// uniquement - voir PLAN_ARCHITECTURE_CLIENT_SERVEUR.md, "Précision
  /// ajoutée le 2026-09-10").
  final ApiSessionProvider? apiSession;

  /// Seeds every field a duplicated bill should copy, exactly like
  /// [existing] would - unlike the ledger's own duplicateFrom (which
  /// deliberately blanks amount/date since those vary transaction to
  /// transaction), a recurring bill is a template whose amount/date are
  /// normally stable, so "Dupliquer" here copies everything and lets the
  /// user tweak whichever field actually needs to differ (e.g. splitting a
  /// bill across two accounts) before saving. Ignored when [existing] is
  /// set, same as [existing] always winning over a seed.
  final BillDeposit? duplicateFrom;

  const RecurringEditorSheet({
    super.key,
    this.existing,
    required this.repo,
    this.defaultAccountId,
    this.duplicateFrom,
    this.apiSession,
  });

  @override
  State<RecurringEditorSheet> createState() => _RecurringEditorSheetState();
}

class _RecurringEditorSheetState extends State<RecurringEditorSheet> {
  final _formKey = GlobalKey<FormState>();
  late int? _accountId;
  late int? _toAccountId;
  late int? _categoryId;
  late int? _payeeId;
  // Mirrors the Tiers field's raw typed text - see
  // TransactionEditorSheet._payeeText for why this exists (_save resolves/
  // auto-creates a payee from it if the user never picked a match or
  // tapped the field's own "create" button).
  String _payeeText = '';
  late TransCode _transCode;
  late DateTime _nextOccurrence;
  late RecurrencePeriod _period;
  late RecurrenceAutoExecute _autoExecute;
  final _amountController = TextEditingController();
  // NUMOCCURRENCES in MMEX: -1 means "repeats forever". A limited count is
  // how many occurrences remain before the template stops firing (each
  // catch-up/manual record decrements it, deleting the template at 0).
  late bool _limitedOccurrences;
  final _occurrencesController = TextEditingController();
  final _notesController = TextEditingController();

  bool get _useApi =>
      widget.apiSession != null &&
      widget.apiSession!.useApiForRecurring &&
      widget.apiSession!.isConnected;

  @override
  void initState() {
    super.initState();
    final bill = widget.existing;
    // A duplicate only ever seeds a brand-new bill - ignored the moment
    // there's a real [existing] to edit instead, same convention as
    // TransactionEditorSheet's dup/draft handling.
    final seed = bill ?? widget.duplicateFrom;
    _accountId = seed?.accountId ?? widget.defaultAccountId;
    _toAccountId = seed?.toAccountId;
    _categoryId = seed?.categoryId;
    _payeeId = seed?.payeeId;
    _transCode = seed?.transCode ?? TransCode.withdrawal;
    _nextOccurrence = seed?.nextOccurrence ?? DateTime.now();
    _period = seed?.period ?? RecurrencePeriod.monthly;
    _autoExecute = seed?.autoExecute ?? RecurrenceAutoExecute.notify;
    _amountController.text = seed != null ? seed.amount.toStringAsFixed(2) : '';
    _limitedOccurrences = (seed?.numOccurrences ?? -1) >= 0;
    // For the "dans/tous les X jours/mois" periods, NUMOCCURRENCES holds the
    // interval X rather than a remaining-occurrences count (see
    // recurrence.dart periodUsesXParam) - always show/edit it, independent
    // of the "durée limitée" toggle which doesn't apply to these periods.
    _occurrencesController.text = periodUsesXParam(_period)
        ? (seed?.numOccurrences != null && seed!.numOccurrences > 0
            ? seed.numOccurrences.toString()
            : '1')
        : (_limitedOccurrences ? seed!.numOccurrences.toString() : '');
    _notesController.text = seed?.notes ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final dbProvider = context.watch<DatabaseProvider>();
    // Same rule as the transaction editor: hide hidden accounts from
    // selection, but keep one already in use by this bill so editing an
    // existing template against a since-hidden account doesn't break.
    final accounts = widget.repo
        .getAccounts()
        .where((a) =>
            !dbProvider.isAccountHidden(a.id) ||
            a.id == _accountId ||
            a.id == _toAccountId)
        .toList();
    final categories = widget.repo.getCategories();
    final categoriesById = {for (final c in categories) c.id: c};
    final sortedCategories = [...categories]..sort((a, b) =>
        categoryFullPath(a.id, categoriesById)
            .toLowerCase()
            .compareTo(categoryFullPath(b.id, categoriesById).toLowerCase()));
    final payees = widget.repo.getPayees(onlyActive: false);
    final isTransfer = _transCode == TransCode.transfer;

    return Padding(
      // viewInsets.bottom covers the keyboard when it's open; padding.bottom
      // covers Android's own system nav bar / gesture strip, which is
      // otherwise still there (and can cover the Enregistrer/Supprimer row)
      // even with the keyboard closed.
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom +
            MediaQuery.of(context).padding.bottom +
            20,
      ),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.existing == null
                    ? 'Nouvelle opération récurrente'
                    : 'Modifier l\'opération récurrente',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              SegmentedButton<TransCode>(
                segments: const [
                  ButtonSegment(
                      value: TransCode.withdrawal, label: Text('Dépense')),
                  ButtonSegment(
                      value: TransCode.deposit, label: Text('Revenu')),
                  ButtonSegment(
                      value: TransCode.transfer, label: Text('Virement')),
                ],
                selected: {_transCode},
                onSelectionChanged: (s) => setState(() => _transCode = s.first),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                decoration: InputDecoration(
                    labelText: isTransfer ? 'Compte source' : 'Compte'),
                initialValue: _accountId,
                items: [
                  for (final a in accounts)
                    DropdownMenuItem(value: a.id, child: Text(a.name))
                ],
                onChanged: (v) => setState(() => _accountId = v),
                validator: (v) => v == null ? 'Requis' : null,
              ),
              if (isTransfer) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  decoration:
                      const InputDecoration(labelText: 'Compte destination'),
                  initialValue: _toAccountId,
                  items: [
                    for (final a in accounts)
                      if (a.id != _accountId)
                        DropdownMenuItem(value: a.id, child: Text(a.name)),
                  ],
                  onChanged: (v) => setState(() => _toAccountId = v),
                  validator: (v) =>
                      v == null ? 'Requis pour un virement' : null,
                ),
              ],
              const SizedBox(height: 12),
              TextFormField(
                controller: _amountController,
                decoration: const InputDecoration(labelText: 'Montant'),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                validator: (v) =>
                    (double.tryParse((v ?? '').replaceAll(',', '.')) == null)
                        ? 'Montant invalide'
                        : null,
              ),
              const SizedBox(height: 12),
              SearchableSelectField<Category>(
                label: 'Catégorie',
                options: sortedCategories,
                labelOf: (c) => categoryFullPath(c.id, categoriesById),
                initialValue: findById(categories, _categoryId, (c) => c.id),
                onSelected: (c) => setState(() => _categoryId = c?.id),
                enableVoiceInput: true,
                onCreate: (text) async {
                  final id = widget.repo.insertCategory(name: text);
                  context.read<DatabaseProvider>().touch();
                  return Category(id: id, name: text, active: true);
                },
              ),
              if (!isTransfer) ...[
                const SizedBox(height: 12),
                SearchableSelectField<Payee>(
                  label: 'Tiers',
                  options: payees,
                  labelOf: (p) => p.name,
                  initialValue: findById(payees, _payeeId, (p) => p.id),
                  onSelected: (p) => setState(() => _payeeId = p?.id),
                  onTextChanged: (text) {
                    _payeeText = text;
                    // See transactions_screen.dart's identical fix (same
                    // 2026-08-14 bug: editing an existing recurring
                    // operation and retyping a brand-new payee name kept
                    // saving under the original payee, since _payeeId
                    // starts pre-filled from bill.payeeId and never got
                    // cleared).
                    final selectedName = findById(payees, _payeeId, (p) => p.id)?.name;
                    if (selectedName != null && selectedName != text) {
                      _payeeId = null;
                    }
                  },
                  enableVoiceInput: true,
                ),
              ],
              const SizedBox(height: 12),
              DropdownButtonFormField<RecurrencePeriod>(
                decoration: const InputDecoration(labelText: 'Fréquence'),
                initialValue: _period,
                items: RecurrencePeriod.values
                    .where((p) => p != RecurrencePeriod.none)
                    .map((p) => DropdownMenuItem(
                        value: p, child: Text(recurrencePeriodLabel(p))))
                    .toList(),
                onChanged: (v) => setState(() {
                  _period = v ?? _period;
                  if (periodUsesXParam(_period) &&
                      int.tryParse(_occurrencesController.text) == null) {
                    _occurrencesController.text = '1';
                  }
                }),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<RecurrenceAutoExecute>(
                decoration: const InputDecoration(labelText: 'Exécution'),
                initialValue: _autoExecute,
                items: const [
                  DropdownMenuItem(
                      value: RecurrenceAutoExecute.manual,
                      child: Text('Manuelle')),
                  DropdownMenuItem(
                      value: RecurrenceAutoExecute.notify,
                      child: Text('Automatique (avec confirmation)')),
                  DropdownMenuItem(
                      value: RecurrenceAutoExecute.silent,
                      child: Text('Automatique (silencieuse)')),
                ],
                onChanged: (v) =>
                    setState(() => _autoExecute = v ?? _autoExecute),
              ),
              const SizedBox(height: 12),
              if (periodUsesXParam(_period)) ...[
                // "Dans/tous les X jours/mois": NUMOCCURRENCES holds the
                // interval X here, not a remaining-occurrences count, so
                // "durée limitée" doesn't apply - MMEX hardcodes "tous les
                // X" as repeating forever and "dans X" as exactly 2
                // firings, X apart (see recurrence.dart periodIsFixedTwoShot
                // and MmexRepository._advanceSchedule).
                TextFormField(
                  controller: _occurrencesController,
                  decoration: InputDecoration(
                    labelText: _period == RecurrencePeriod.inXDays ||
                            _period == RecurrencePeriod.everyXDays
                        ? 'Nombre de jours'
                        : 'Nombre de mois',
                  ),
                  keyboardType: TextInputType.number,
                  validator: (v) => (int.tryParse(v ?? '') == null ||
                          int.parse(v ?? '0') < 1)
                      ? 'Nombre invalide'
                      : null,
                ),
              ] else ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Durée limitée'),
                  subtitle: Text(_limitedOccurrences
                      ? 'S\'arrête après un nombre fixe d\'occurrences'
                      : 'Se répète indéfiniment'),
                  value: _limitedOccurrences,
                  onChanged: (v) => setState(() => _limitedOccurrences = v),
                ),
                if (_limitedOccurrences) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _occurrencesController,
                    decoration: const InputDecoration(
                        labelText: 'Nombre d\'occurrences restantes'),
                    keyboardType: TextInputType.number,
                    validator: (v) => _limitedOccurrences &&
                            (int.tryParse(v ?? '') == null ||
                                int.parse(v ?? '0') < 1)
                        ? 'Nombre invalide'
                        : null,
                  ),
                ],
              ],
              const SizedBox(height: 12),
              TextFormField(
                controller: _notesController,
                decoration: const InputDecoration(
                  labelText: 'Remarque',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
                // Same fix as transactions_screen.dart's own Notes field
                // (2026-09-01 user report) - a note spanning several lines
                // only showed its first line, with the rest silently
                // inaccessible while editing/viewing despite being saved
                // intact.
                minLines: 3,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  'Prochaine occurrence : ${_nextOccurrence.day}/${_nextOccurrence.month}/${_nextOccurrence.year}',
                ),
                trailing: const Icon(Icons.calendar_today, size: 18),
                onTap: () async {
                  final picked = await pickDate(
                    context: context,
                    initialDate: _nextOccurrence,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null) setState(() => _nextOccurrence = picked);
                },
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  if (widget.existing != null)
                    TextButton(
                      onPressed: () async {
                        final confirmed = await confirmDelete(
                          context,
                          title: 'Supprimer cette opération récurrente',
                          message: 'Supprimer définitivement ce modèle récurrent ? '
                              'Les opérations déjà enregistrées dans le grand livre ne sont pas concernées.',
                        );
                        if (!confirmed || !context.mounted) return;
                        if (_useApi) {
                          await widget.apiSession!.deleteBillDeposit(widget.existing!.id);
                        } else {
                          widget.repo.deleteBillDeposit(widget.existing!.id);
                          context.read<DatabaseProvider>().touch();
                        }
                        if (!context.mounted) return;
                        Navigator.of(context).pop();
                      },
                      child: const Text('Supprimer'),
                    ),
                  // Closes this sheet with the source bill attached -
                  // _RecurringScreenState._openEditor reopens a fresh
                  // "Nouvelle opération récurrente" sheet from it once this
                  // one has actually closed, same convention as the
                  // ledger's own "Dupliquer" (transactions_screen.dart).
                  if (widget.existing != null)
                    TextButton(
                      onPressed: () => Navigator.of(context).pop((
                        categoryChange: null,
                        duplicateFrom: widget.existing,
                      )),
                      child: const Text('Dupliquer'),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => _save(),
                    child: const Text('Enregistrer'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final amount = double.parse(_amountController.text.replaceAll(',', '.'));
    final isTransfer = _transCode == TransCode.transfer;
    final useApi = _useApi;
    final apiSession = widget.apiSession;
    // See TransactionEditorSheet._save's identical resolution for why -
    // reuses a matching existing payee case-insensitively, or creates one,
    // instead of silently dropping newly-typed text that was never
    // explicitly selected/created.
    final typedPayeeText = _payeeText.trim();
    // -1 (never a real PAYEEID) means "no payee resolved" here just as much
    // as null does - see transactions_screen.dart's identical fix.
    final hasResolvedPayeeId = _payeeId != null && _payeeId != -1;
    final int payeeId;
    if (isTransfer) {
      payeeId = -1;
    } else if (hasResolvedPayeeId) {
      payeeId = _payeeId!;
    } else if (typedPayeeText.isEmpty) {
      payeeId = -1;
    } else if (useApi) {
      payeeId =
          await apiSession!.resolveOrCreatePayee(name: typedPayeeText, categoryId: _categoryId);
    } else {
      payeeId = widget.repo.resolveOrCreatePayee(name: typedPayeeText, categoryId: _categoryId);
    }
    final numOccurrences = periodUsesXParam(_period)
        ? int.parse(_occurrencesController.text)
        : (_limitedOccurrences ? int.parse(_occurrencesController.text) : -1);
    CategoryChange? categoryChange;
    if (widget.existing == null) {
      final int id;
      if (useApi) {
        id = await apiSession!.insertBillDeposit(
          accountId: _accountId!,
          toAccountId: isTransfer ? _toAccountId : null,
          payeeId: payeeId,
          transCode: _transCode,
          amount: amount,
          toAmount: isTransfer ? amount : null,
          nextOccurrence: _nextOccurrence,
          period: _period,
          autoExecute: _autoExecute,
          categoryId: _categoryId,
          numOccurrences: numOccurrences,
          notes: _notesController.text,
        );
        if (_limitedOccurrences && !periodUsesXParam(_period)) {
          await apiSession.ensureBillOccurrenceTotal(id, numOccurrences);
        }
      } else {
        id = widget.repo.insertBillDeposit(
          accountId: _accountId!,
          toAccountId: isTransfer ? _toAccountId : null,
          payeeId: payeeId,
          transCode: _transCode,
          amount: amount,
          toAmount: isTransfer ? amount : null,
          nextOccurrence: _nextOccurrence,
          period: _period,
          autoExecute: _autoExecute,
          categoryId: _categoryId,
          numOccurrences: numOccurrences,
          notes: _notesController.text,
        );
        if (_limitedOccurrences && !periodUsesXParam(_period)) {
          widget.repo.ensureBillOccurrenceTotal(id, numOccurrences);
        }
      }
    } else {
      final updated = BillDeposit(
        id: widget.existing!.id,
        accountId: _accountId!,
        toAccountId: isTransfer ? _toAccountId : null,
        payeeId: payeeId,
        transCode: _transCode,
        amount: amount,
        toAmount: amount,
        nextOccurrence: _nextOccurrence,
        period: _period,
        autoExecute: _autoExecute,
        notes: _notesController.text,
        numOccurrences: numOccurrences,
        categoryId: _categoryId,
      );
      if (useApi) {
        await apiSession!.updateBillDeposit(updated);
        if (_limitedOccurrences && !periodUsesXParam(_period)) {
          await apiSession.ensureBillOccurrenceTotal(widget.existing!.id, numOccurrences);
        }
      } else {
        widget.repo.updateBillDeposit(updated);
        if (_limitedOccurrences && !periodUsesXParam(_period)) {
          widget.repo.ensureBillOccurrenceTotal(widget.existing!.id, numOccurrences);
        }
      }
      // The bill's category just changed - offer to also fix every real
      // ledger transaction still sitting under the old category for this
      // payee (not just future occurrences of this one bill), see
      // offerBulkCategoryReassign in _openEditor below. Reste local
      // uniquement, même nuance que TransactionEditorSheet._save (voir
      // PLAN_ARCHITECTURE_CLIENT_SERVEUR.md, "Précision ajoutée le
      // 2026-09-10").
      if (!useApi) {
        final oldCategoryId = widget.existing!.categoryId;
        if (oldCategoryId != null && _categoryId != null && _categoryId != oldCategoryId) {
          if (isTransfer && _toAccountId != null) {
            categoryChange = (
              payeeId: null,
              transferAccountId: _accountId,
              transferToAccountId: _toAccountId,
              oldCategoryId: oldCategoryId,
              newCategoryId: _categoryId!,
            );
          } else if (!isTransfer && payeeId != -1) {
            categoryChange = (
              payeeId: payeeId,
              transferAccountId: null,
              transferToAccountId: null,
              oldCategoryId: oldCategoryId,
              newCategoryId: _categoryId!,
            );
          }
        }
      }
    }
    if (!mounted) return;
    if (!useApi) {
      context.read<DatabaseProvider>().touch();
    }
    Navigator.of(context)
        .pop((categoryChange: categoryChange, duplicateFrom: null));
  }
}

/// Lets the user record one occurrence of a recurring transaction: confirm
/// (or edit) the actual execution date, and mark it reconciled right away
/// if it already appeared on a bank statement.
class _AnnualIncreaseResult {
  final bool cleared;
  final double? percent;
  final DateTime? anchor;
  const _AnnualIncreaseResult.cleared()
      : cleared = true,
        percent = null,
        anchor = null;
  const _AnnualIncreaseResult.set({required this.percent, required this.anchor})
      : cleared = false;
}

/// "Augmentation annuelle" (2026-09 user request) - lets the user say a
/// real recurring bill's projected amount should compound by X% every
/// year (rent indexation, a subscription that always creeps up, ...),
/// something a flat recurring-bill schedule can't otherwise express. Global
/// to every simulation scenario at once, not a per-scenario override (see
/// [BillDeposit.annualIncreasePercent]'s own doc comment) - so this lives
/// here, in the recurring-operations screen itself, not inside a scenario.
/// A suggested percentage/anchor date is offered when there's enough real
/// history to compute one ([MmexRepository.suggestedAnnualIncrease]) - the
/// user can accept it, adjust it, or ignore it and type their own.
class _AnnualIncreaseDialog extends StatefulWidget {
  final MmexRepository repo;
  final BillDeposit bill;

  const _AnnualIncreaseDialog({required this.repo, required this.bill});

  @override
  State<_AnnualIncreaseDialog> createState() => _AnnualIncreaseDialogState();
}

class _AnnualIncreaseDialogState extends State<_AnnualIncreaseDialog> {
  late final _suggestion = widget.repo.suggestedAnnualIncrease(widget.bill.id);
  late final _existing = widget.repo.getBillAnnualIncrease(widget.bill.id);
  late double _percent = _existing?.percent ?? _suggestion?.percent ?? 0;
  late DateTime _anchor =
      _existing?.anchor ?? _suggestion?.anchor ?? widget.bill.nextOccurrence;
  late final _percentController =
      TextEditingController(text: _percent.toStringAsFixed(1));

  @override
  void dispose() {
    _percentController.dispose();
    super.dispose();
  }

  void _applySuggestion() {
    final s = _suggestion;
    if (s == null) return;
    setState(() {
      _percent = s.percent;
      _anchor = s.anchor;
      _percentController.text = _percent.toStringAsFixed(1);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Augmentation annuelle'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Le montant projeté dans la simulation augmente de ce '
              'pourcentage chaque année, à partir de la date anniversaire '
              '(seuls le jour et le mois comptent, pas l\'année). Le '
              'montant réel de cette opération n\'est jamais modifié.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            if (_suggestion != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Suggestion d\'après l\'historique '
                        '(${_suggestion.yearsSpan.toStringAsFixed(1)} ans) : '
                        '${_suggestion.percent.toStringAsFixed(1)} %',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    TextButton(
                        onPressed: _applySuggestion, child: const Text('Utiliser')),
                  ],
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'Pas assez d\'historique pour suggérer une valeur (3 ans '
                  'minimum) - saisis-la à la main si tu la connais.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            TextField(
              controller: _percentController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: const InputDecoration(labelText: 'Pourcentage par an'),
              onChanged: (v) =>
                  _percent = double.tryParse(v.replaceAll(',', '.')) ?? _percent,
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: () async {
                final picked = await pickDate(
                  context: context,
                  initialDate: _anchor,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(DateTime.now().year + 60),
                  helpText: 'Date anniversaire',
                );
                if (picked != null) setState(() => _anchor = picked);
              },
              child: InputDecorator(
                decoration: const InputDecoration(labelText: 'Date anniversaire'),
                child: Text(DateFormat('d MMMM', 'fr_FR').format(_anchor)),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (_existing != null)
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(const _AnnualIncreaseResult.cleared()),
            child: const Text('Supprimer'),
          ),
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
              _AnnualIncreaseResult.set(percent: _percent, anchor: _anchor)),
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}

class _RecordOccurrenceDialog extends StatefulWidget {
  final BillDeposit bill;
  final MmexRepository repo;

  const _RecordOccurrenceDialog({required this.bill, required this.repo});

  @override
  State<_RecordOccurrenceDialog> createState() =>
      _RecordOccurrenceDialogState();
}

class _RecordOccurrenceDialogState extends State<_RecordOccurrenceDialog> {
  final _formKey = GlobalKey<FormState>();
  late DateTime _date;
  bool _reconciled = false;
  late final TextEditingController _amountController;

  /// 1 = record as a single transaction (the previous, only behaviour) -
  /// see [_maxSplitInto]/[recurrenceMonthSpan] for why this control only
  /// ever appears at all for a period spanning several months (2026-09-02
  /// user request: "je découpe Axeria en 2 ou 3 paiements... à présent je
  /// le fais manuellement").
  int _splitInto = 1;

  /// Null hides the "Répartir en X fois" control entirely - either this
  /// period has no fixed monthly interval at all (weekly/daily/"X-param"),
  /// or it's already exactly 1 month (splitting a monthly bill into
  /// smaller monthly pieces makes no sense). Otherwise the largest X that
  /// still keeps every installment strictly before the bill's own next
  /// real due date: the last of X monthly installments starting on the due
  /// date lands X-1 months later, and the next due date is [span] months
  /// later, so X-1 < span, i.e. X <= span - equality allowed (2026-09-02
  /// user request: "autorise l'égalité de la période trimestrielle = 3
  /// fois, semestrielle 6, et ainsi de suite" - a 3-month/6-month period
  /// really can take 3/6 monthly installments before the next due date,
  /// not one fewer).
  int? get _maxSplitInto {
    final span = recurrenceMonthSpan(widget.bill.period);
    if (span == null || span < 2) return null;
    return span;
  }

  @override
  void initState() {
    super.initState();
    _date = widget.bill.nextOccurrence;
    _amountController =
        TextEditingController(text: widget.bill.amount.toStringAsFixed(2));
  }

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isTransfer = widget.bill.transCode == TransCode.transfer;
    final accounts = {for (final a in widget.repo.getAccounts()) a.id: a};
    return AlertDialog(
      title: const Text('Enregistrer l\'opération'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isTransfer)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '${accounts[widget.bill.accountId]?.name ?? '?'} → '
                  '${accounts[widget.bill.toAccountId]?.name ?? '?'}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Date : ${_date.day}/${_date.month}/${_date.year}'),
              trailing: const Icon(Icons.calendar_today, size: 18),
              onTap: () async {
                final picked = await pickDate(
                  context: context,
                  initialDate: _date,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (picked != null) setState(() => _date = picked);
              },
            ),
            TextFormField(
              controller: _amountController,
              decoration: const InputDecoration(labelText: 'Montant'),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              validator: (v) =>
                  (double.tryParse((v ?? '').replaceAll(',', '.')) == null)
                      ? 'Montant invalide'
                      : null,
              onChanged: (_) => setState(() {}), // keeps the preview below in sync
            ),
            if (_maxSplitInto != null) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<int>(
                initialValue: _splitInto,
                decoration: const InputDecoration(labelText: 'Répartir en'),
                items: [
                  const DropdownMenuItem(value: 1, child: Text('1 fois (normal)')),
                  for (var n = 2; n <= _maxSplitInto!; n++)
                    DropdownMenuItem(value: n, child: Text('$n fois')),
                ],
                onChanged: (v) => setState(() => _splitInto = v ?? 1),
              ),
              if (_splitInto > 1) ...[
                const SizedBox(height: 4),
                Builder(builder: (context) {
                  final amount =
                      double.tryParse(_amountController.text.replaceAll(',', '.'));
                  if (amount == null) return const SizedBox.shrink();
                  final cents = (amount * 100).round();
                  final base = cents ~/ _splitInto;
                  final remainder = cents - base * _splitInto;
                  final perInstallment = (base + (remainder > 0 ? 1 : 0)) / 100;
                  final dates = [
                    for (var i = 0; i < _splitInto; i++) _addMonths(_date, i)
                  ];
                  return Text(
                    '$_splitInto paiements d\'environ ${perInstallment.toStringAsFixed(2)} € '
                    'les ${dates.map((d) => '${d.day}/${d.month}/${d.year}').join(', ')}',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  );
                }),
              ],
            ],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Pointée'),
              value: _reconciled,
              onChanged: (v) => setState(() => _reconciled = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler')),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            final amount = double.parse(_amountController.text.replaceAll(',', '.'));
            widget.repo.recordBillOccurrence(
                widget.bill.copyWith(amount: amount),
                date: _date, reconciled: _reconciled, splitInto: _splitInto);
            Navigator.of(context).pop();
          },
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}
