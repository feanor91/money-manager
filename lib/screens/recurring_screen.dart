import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/mmex_repository.dart';
import '../models/bill_deposit.dart';
import '../models/category.dart';
import '../models/currency.dart';
import '../models/payee.dart';
import '../models/recurrence.dart';
import '../models/transaction.dart';
import '../state/database_provider.dart';
import '../theme/app_theme.dart';
import '../utils/date_picker.dart';
import '../utils/list_utils.dart';
import '../widgets/bulk_category_reassign.dart';
import '../widgets/confirm_delete.dart';
import '../widgets/responsive_body.dart';
import '../widgets/searchable_select_field.dart';

class RecurringScreen extends StatefulWidget {
  const RecurringScreen({super.key});

  @override
  State<RecurringScreen> createState() => _RecurringScreenState();
}

class _RecurringScreenState extends State<RecurringScreen> {
  int? _accountFilter;
  String _searchQuery = '';

  @override
  Widget build(BuildContext context) {
    final dbProvider = context.watch<DatabaseProvider>();
    final repo = dbProvider.repository!;
    final currency = repo.getBaseCurrency();
    final allBills = repo.getBillDeposits();
    final accounts = {for (final a in repo.getAccounts()) a.id: a};
    final visibleAccounts = accounts.values
        .where((a) => !dbProvider.isAccountHidden(a.id))
        .toList();
    final categories = {for (final c in repo.getCategories()) c.id: c};
    final payees = {for (final p in repo.getPayees(onlyActive: false)) p.id: p};
    final occurrenceTotals = repo.billOccurrenceTotals();

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

    // Paused operations first, so they stay visible/easy to find (and
    // un-pause) instead of blending into the rest of the list - everything
    // else sorted by next-occurrence date, soonest first.
    final bills = allBills.where(matchesBill).toList()
      ..sort((a, b) {
        if (a.paused != b.paused) return a.paused ? -1 : 1;
        return a.nextOccurrence.compareTo(b.nextOccurrence);
      });

    return Scaffold(
      appBar: AppBar(
        title: Text(_accountFilter == null
            ? 'Opérations récurrentes'
            : 'Opérations récurrentes - ${accounts[_accountFilter]?.name}'),
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
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Paramètres',
            onPressed: () => Navigator.of(context).pushNamed('/settings'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(context),
        icon: const Icon(Icons.add),
        label: const Text('Ajouter'),
      ),
      body: ResponsiveBody(
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
                              onTap: () => _openEditor(context, existing: bill),
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
                                      onChanged: (v) {
                                        repo.setBillPaused(bill.id, v ?? false);
                                        dbProvider.touch();
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
      ),
    );
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
      {BillDeposit? existing}) async {
    final dbProvider = context.read<DatabaseProvider>();
    final repo = dbProvider.repository!;
    final categoryChange = await showModalBottomSheet<CategoryChange?>(
      context: context,
      isScrollControlled: true,
      builder: (_) => RecurringEditorSheet(existing: existing, repo: repo),
    );
    dbProvider.touch();
    if (categoryChange != null && context.mounted) {
      await offerBulkCategoryReassign(
        context: context,
        repo: repo,
        dbProvider: dbProvider,
        change: categoryChange,
      );
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

/// Public (not file-private) so [TransactionsScreen] can also open it - lets
/// you create a recurring bill straight from the ledger without switching
/// to the "Récurrentes" tab first.
class RecurringEditorSheet extends StatefulWidget {
  final BillDeposit? existing;
  final MmexRepository repo;
  final int? defaultAccountId;

  const RecurringEditorSheet({
    super.key,
    this.existing,
    required this.repo,
    this.defaultAccountId,
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

  @override
  void initState() {
    super.initState();
    final bill = widget.existing;
    _accountId = bill?.accountId ?? widget.defaultAccountId;
    _toAccountId = bill?.toAccountId;
    _categoryId = bill?.categoryId;
    _payeeId = bill?.payeeId;
    _transCode = bill?.transCode ?? TransCode.withdrawal;
    _nextOccurrence = bill?.nextOccurrence ?? DateTime.now();
    _period = bill?.period ?? RecurrencePeriod.monthly;
    _autoExecute = bill?.autoExecute ?? RecurrenceAutoExecute.notify;
    _amountController.text = bill != null ? bill.amount.toStringAsFixed(2) : '';
    _limitedOccurrences = (bill?.numOccurrences ?? -1) >= 0;
    // For the "dans/tous les X jours/mois" periods, NUMOCCURRENCES holds the
    // interval X rather than a remaining-occurrences count (see
    // recurrence.dart periodUsesXParam) - always show/edit it, independent
    // of the "durée limitée" toggle which doesn't apply to these periods.
    _occurrencesController.text = periodUsesXParam(_period)
        ? (bill?.numOccurrences != null && bill!.numOccurrences > 0
            ? bill.numOccurrences.toString()
            : '1')
        : (_limitedOccurrences ? bill!.numOccurrences.toString() : '');
    _notesController.text = bill?.notes ?? '';
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
                        widget.repo.deleteBillDeposit(widget.existing!.id);
                        context.read<DatabaseProvider>().touch();
                        Navigator.of(context).pop();
                      },
                      child: const Text('Supprimer'),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _save,
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

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final amount = double.parse(_amountController.text.replaceAll(',', '.'));
    final isTransfer = _transCode == TransCode.transfer;
    // See TransactionEditorSheet._save's identical resolution for why -
    // reuses a matching existing payee case-insensitively, or creates one,
    // instead of silently dropping newly-typed text that was never
    // explicitly selected/created.
    final typedPayeeText = _payeeText.trim();
    // -1 (never a real PAYEEID) means "no payee resolved" here just as much
    // as null does - see transactions_screen.dart's identical fix.
    final hasResolvedPayeeId = _payeeId != null && _payeeId != -1;
    final payeeId = isTransfer
        ? -1
        : (hasResolvedPayeeId
            ? _payeeId!
            : (typedPayeeText.isEmpty
                ? -1
                : widget.repo.resolveOrCreatePayee(
                    name: typedPayeeText, categoryId: _categoryId)));
    final numOccurrences = periodUsesXParam(_period)
        ? int.parse(_occurrencesController.text)
        : (_limitedOccurrences ? int.parse(_occurrencesController.text) : -1);
    CategoryChange? categoryChange;
    if (widget.existing == null) {
      final id = widget.repo.insertBillDeposit(
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
    } else {
      widget.repo.updateBillDeposit(BillDeposit(
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
      ));
      if (_limitedOccurrences && !periodUsesXParam(_period)) {
        widget.repo.ensureBillOccurrenceTotal(widget.existing!.id, numOccurrences);
      }
      // The bill's category just changed - offer to also fix every real
      // ledger transaction still sitting under the old category for this
      // payee (not just future occurrences of this one bill), see
      // offerBulkCategoryReassign in _openEditor below.
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
    context.read<DatabaseProvider>().touch();
    Navigator.of(context).pop(categoryChange);
  }
}

/// Lets the user record one occurrence of a recurring transaction: confirm
/// (or edit) the actual execution date, and mark it reconciled right away
/// if it already appeared on a bank statement.
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
            ),
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
                date: _date, reconciled: _reconciled);
            Navigator.of(context).pop();
          },
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}
