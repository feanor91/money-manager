import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/mmex_repository.dart';
import '../models/bill_deposit.dart';
import '../models/category.dart';
import '../models/payee.dart';
import '../models/recurrence.dart';
import '../models/transaction.dart';
import '../state/database_provider.dart';
import '../theme/app_theme.dart';
import '../utils/list_utils.dart';
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
    // un-pause) instead of blending into the rest of the list sorted by
    // next-occurrence date.
    final bills = allBills.where(matchesBill).toList()
      ..sort((a, b) => (a.paused == b.paused) ? 0 : (a.paused ? -1 : 1));

    return Scaffold(
      appBar: AppBar(title: const Text('Operations recurrentes')),
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
              child: Column(
                children: [
                  TextField(
                    decoration: const InputDecoration(
                      hintText: 'Rechercher (tiers, compte, categorie...)',
                      prefixIcon: Icon(Icons.search),
                      isDense: true,
                    ),
                    onChanged: (v) => setState(() => _searchQuery = v),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int?>(
                    initialValue: _accountFilter,
                    isExpanded: true,
                    decoration: const InputDecoration(
                        labelText: 'Compte', isDense: true),
                    items: [
                      const DropdownMenuItem<int?>(
                          value: null, child: Text('Tous les comptes')),
                      for (final a in visibleAccounts)
                        DropdownMenuItem<int?>(
                            value: a.id, child: Text(a.name)),
                    ],
                    onChanged: (v) => setState(() => _accountFilter = v),
                  ),
                ],
              ),
            ),
            Expanded(
              child: bills.isEmpty
                  ? const Center(child: Text('Aucune operation recurrente'))
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
                            : (payees[bill.payeeId]?.name ?? 'Payé inconnu');
                        final categoryLabel = categoryFullPath(bill.categoryId, categories);
                        final subtitleLine1 = isTransfer
                            ? 'Virement'
                            : '${accounts[bill.accountId]?.name ?? ''} - '
                                '${categoryLabel.isEmpty ? 'Non categorise' : categoryLabel}';
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
                                    message: 'Mettre en pause (ignoree a '
                                        'l\'ajout automatique et dans le '
                                        'previsionnel)',
                                    child: Checkbox(
                                      value: bill.paused,
                                      onChanged: (v) {
                                        repo.setBillPaused(bill.id, v ?? false);
                                        dbProvider.touch();
                                      },
                                    ),
                                  ),
                                  Text(
                                    currency?.format(signed) ??
                                        signed.toStringAsFixed(2),
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
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _RecurringEditorSheet(existing: existing, repo: repo),
    );
    dbProvider.touch();
  }
}

class _RecurringEditorSheet extends StatefulWidget {
  final BillDeposit? existing;
  final MmexRepository repo;

  const _RecurringEditorSheet({this.existing, required this.repo});

  @override
  State<_RecurringEditorSheet> createState() => _RecurringEditorSheetState();
}

class _RecurringEditorSheetState extends State<_RecurringEditorSheet> {
  final _formKey = GlobalKey<FormState>();
  late int? _accountId;
  late int? _toAccountId;
  late int? _categoryId;
  late int? _payeeId;
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
    _accountId = bill?.accountId;
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
                    ? 'Nouvelle operation recurrente'
                    : 'Modifier l\'operation recurrente',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              SegmentedButton<TransCode>(
                segments: const [
                  ButtonSegment(
                      value: TransCode.withdrawal, label: Text('Depense')),
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
                validator: (v) => (double.tryParse(v ?? '') == null)
                    ? 'Montant invalide'
                    : null,
              ),
              const SizedBox(height: 12),
              SearchableSelectField<Category>(
                label: 'Categorie',
                options: sortedCategories,
                labelOf: (c) => categoryFullPath(c.id, categoriesById),
                initialValue: findById(categories, _categoryId, (c) => c.id),
                onSelected: (c) => setState(() => _categoryId = c?.id),
                onCreate: (text) async {
                  final id = widget.repo.insertCategory(name: text);
                  return Category(id: id, name: text, active: true);
                },
              ),
              if (!isTransfer) ...[
                const SizedBox(height: 12),
                SearchableSelectField<Payee>(
                  label: 'Payé',
                  options: payees,
                  labelOf: (p) => p.name,
                  initialValue: findById(payees, _payeeId, (p) => p.id),
                  onSelected: (p) => setState(() => _payeeId = p?.id),
                  onCreate: (text) async {
                    final id = widget.repo
                        .insertPayee(name: text, categoryId: _categoryId);
                    return Payee(id: id, name: text, active: true);
                  },
                ),
              ],
              const SizedBox(height: 12),
              DropdownButtonFormField<RecurrencePeriod>(
                decoration: const InputDecoration(labelText: 'Frequence'),
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
                decoration: const InputDecoration(labelText: 'Execution'),
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
                  title: const Text('Duree limitee'),
                  subtitle: Text(_limitedOccurrences
                      ? 'S\'arrete apres un nombre fixe d\'occurrences'
                      : 'Se repete indefiniment'),
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
                decoration: const InputDecoration(labelText: 'Remarque'),
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  'Prochaine occurrence : ${_nextOccurrence.day}/${_nextOccurrence.month}/${_nextOccurrence.year}',
                ),
                trailing: const Icon(Icons.calendar_today, size: 18),
                onTap: () async {
                  final picked = await showDatePicker(
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
                      onPressed: () {
                        widget.repo.deleteBillDeposit(widget.existing!.id);
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
    final amount = double.parse(_amountController.text);
    final isTransfer = _transCode == TransCode.transfer;
    final numOccurrences = periodUsesXParam(_period)
        ? int.parse(_occurrencesController.text)
        : (_limitedOccurrences ? int.parse(_occurrencesController.text) : -1);
    if (widget.existing == null) {
      widget.repo.insertBillDeposit(
        accountId: _accountId!,
        toAccountId: isTransfer ? _toAccountId : null,
        payeeId: isTransfer ? -1 : (_payeeId ?? -1),
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
    } else {
      widget.repo.updateBillDeposit(BillDeposit(
        id: widget.existing!.id,
        accountId: _accountId!,
        toAccountId: isTransfer ? _toAccountId : null,
        payeeId: isTransfer ? -1 : (_payeeId ?? -1),
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
    }
    Navigator.of(context).pop();
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
  late DateTime _date;
  bool _reconciled = false;

  @override
  void initState() {
    super.initState();
    _date = widget.bill.nextOccurrence;
  }

  @override
  Widget build(BuildContext context) {
    final isTransfer = widget.bill.transCode == TransCode.transfer;
    final accounts = {for (final a in widget.repo.getAccounts()) a.id: a};
    return AlertDialog(
      title: const Text('Enregistrer l\'operation'),
      content: Column(
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
              final picked = await showDatePicker(
                context: context,
                initialDate: _date,
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
              );
              if (picked != null) setState(() => _date = picked);
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Pointee'),
            value: _reconciled,
            onChanged: (v) => setState(() => _reconciled = v),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler')),
        FilledButton(
          onPressed: () {
            widget.repo.recordBillOccurrence(widget.bill,
                date: _date, reconciled: _reconciled);
            Navigator.of(context).pop();
          },
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}
