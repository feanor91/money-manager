import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/mmex_repository.dart';
import '../models/account.dart';
import '../models/category.dart';
import '../models/currency.dart';
import '../models/payee.dart';
import '../models/transaction.dart';
import '../state/database_provider.dart';
import '../theme/app_theme.dart';
import '../utils/list_utils.dart';
import '../widgets/responsive_body.dart';
import '../widgets/searchable_select_field.dart';

class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key});

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  @override
  Widget build(BuildContext context) {
    final dbProvider = context.watch<DatabaseProvider>();
    final repo = dbProvider.repository!;
    final accounts = repo.getAccounts();
    final visibleAccounts =
        accounts.where((a) => !dbProvider.isAccountHidden(a.id)).toList();

    // Always the same account as the dashboard's selection - falls back to
    // the first visible account if nothing (valid) is selected yet, same
    // rule the dashboard itself uses, so the two screens can never disagree.
    final accountId =
        visibleAccounts.any((a) => a.id == dbProvider.selectedAccountId)
            ? dbProvider.selectedAccountId
            : (visibleAccounts.isEmpty ? null : visibleAccounts.first.id);

    final currency = repo.getBaseCurrency();
    final accountsById = {for (final a in accounts) a.id: a};
    final categories = {for (final c in repo.getCategories()) c.id: c};
    final payees = {for (final p in repo.getPayees(onlyActive: false)) p.id: p};
    final rows = accountId == null
        ? const <TransactionWithBalance>[]
        : repo.getTransactionsWithRunningBalance(accountId);

    return Scaffold(
      appBar: AppBar(
        title: Text(
            accountId == null ? 'Transactions' : accountsById[accountId]!.name),
        actions: [
          PopupMenuButton<int>(
            icon: const Icon(Icons.filter_list),
            onSelected: (id) => dbProvider.selectAccount(id),
            itemBuilder: (context) => [
              for (final a in visibleAccounts)
                PopupMenuItem(value: a.id, child: Text(a.name)),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(context),
        icon: const Icon(Icons.add),
        label: const Text('Ajouter'),
      ),
      body: rows.isEmpty
          ? const Center(child: Text('Aucune transaction'))
          : LayoutBuilder(builder: (context, constraints) {
              // The desktop-style ledger grid needs its full column width
              // (~1050px) to read comfortably - below that it's cramped
              // even with horizontal scroll, so narrow/mobile screens get a
              // stacked card layout instead, same data, no scroll needed.
              if (constraints.maxWidth < 640) {
                return _LedgerCards(
                  rows: rows,
                  accountId: accountId!,
                  accountsById: accountsById,
                  categoriesById: categories,
                  payeesById: payees,
                  currency: currency,
                  onTapRow: (tx) => _openEditor(context, existing: tx),
                  onToggleReconciled: (tx, value) {
                    repo.setReconciled(tx.id, value);
                    dbProvider.touch();
                  },
                  onEditDate: (tx, date) {
                    repo.updateTransaction(tx.copyWith(date: date));
                    dbProvider.touch();
                  },
                );
              }
              return ResponsiveBody(
                maxWidth: 1200,
                child: _LedgerTable(
                  rows: rows,
                  accountId: accountId!,
                  accountsById: accountsById,
                  categoriesById: categories,
                  payeesById: payees,
                  currency: currency,
                  onTapRow: (tx) => _openEditor(context, existing: tx),
                  onToggleReconciled: (tx, value) {
                    repo.setReconciled(tx.id, value);
                    dbProvider.touch();
                  },
                  onEditDate: (tx, date) {
                    repo.updateTransaction(tx.copyWith(date: date));
                    dbProvider.touch();
                  },
                ),
              );
            }),
    );
  }

  Future<void> _openEditor(BuildContext context,
      {MoneyTransaction? existing}) async {
    final dbProvider = context.read<DatabaseProvider>();
    final repo = dbProvider.repository!;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _TransactionEditorSheet(existing: existing, repo: repo),
    );
    dbProvider.touch();
  }
}

/// MMEX-style ledger grid: Date / Tiers / Statut / Categorie / Debit /
/// Credit / Solde / Remarques, with the running account balance after each
/// transaction. Fixed-width columns wrapped in a horizontal scroll (like
/// the desktop app's own transaction list), rows virtualized vertically.
class _LedgerTable extends StatelessWidget {
  static const _colCheck = 40.0;
  static const _colDate = 76.0;
  static const _colTiers = 140.0;
  static const _colStatut = 56.0;
  static const _colCategorie = 170.0;
  static const _colMontant = 90.0;
  static const _colSolde = 100.0;
  static const _colRemarques = 200.0;
  static const _colGap = 12.0;
  static const _columnCount =
      9; // check, date, tiers, statut, categorie, debit, credit, solde, remarques
  // +24 for the 12px horizontal padding on each side of every row (header
  // and data rows both wrap their Row in EdgeInsets.symmetric(horizontal:
  // 12)), which isn't otherwise accounted for in the fixed column widths.
  static const _totalWidth = _colCheck +
      _colDate +
      _colTiers +
      _colStatut +
      _colCategorie +
      _colMontant * 2 +
      _colSolde +
      _colRemarques +
      _colGap * (_columnCount - 1) +
      24;

  final List<TransactionWithBalance> rows;
  final int accountId;
  final Map<int, Account> accountsById;
  final Map<int, Category> categoriesById;
  final Map<int, Payee> payeesById;
  final CurrencyFormat? currency;
  final ValueChanged<MoneyTransaction> onTapRow;
  final void Function(MoneyTransaction, bool) onToggleReconciled;
  final void Function(MoneyTransaction tx, DateTime date) onEditDate;

  const _LedgerTable({
    required this.rows,
    required this.accountId,
    required this.accountsById,
    required this.categoriesById,
    required this.payeesById,
    required this.onTapRow,
    required this.onToggleReconciled,
    required this.onEditDate,
    this.currency,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: _totalWidth,
        child: Column(
          children: [
            _headerRow(context),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: rows.length,
                itemBuilder: (context, index) =>
                    _row(context, rows[index], index),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _headerRow(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    Widget h(double width, String label, {TextAlign align = TextAlign.left}) =>
        SizedBox(
          width: width,
          child: Text(
            label,
            textAlign: align,
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: onSurface),
          ),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          const SizedBox(width: _colCheck),
          const SizedBox(width: _colGap),
          h(_colDate, 'Date'),
          const SizedBox(width: _colGap),
          h(_colTiers, 'Tiers'),
          const SizedBox(width: _colGap),
          h(_colStatut, 'Statut'),
          const SizedBox(width: _colGap),
          h(_colCategorie, 'Categorie'),
          const SizedBox(width: _colGap),
          h(_colMontant, 'Debit', align: TextAlign.right),
          const SizedBox(width: _colGap),
          h(_colMontant, 'Credit', align: TextAlign.right),
          const SizedBox(width: _colGap),
          h(_colSolde, 'Solde', align: TextAlign.right),
          const SizedBox(width: _colGap),
          h(_colRemarques, 'Remarques'),
        ],
      ),
    );
  }

  /// The Date column opens its own date picker directly, independent of
  /// the row's onTap (which opens the full editor sheet) - a quick way to
  /// fix a date without going through the whole form, e.g. right when
  /// reconciling against a bank statement that posted it a day or two off.
  Future<void> _editDate(BuildContext context, MoneyTransaction tx) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: tx.date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: 'Modifier la date',
    );
    if (picked != null && picked != tx.date) onEditDate(tx, picked);
  }

  Widget _row(BuildContext context, TransactionWithBalance row, int index) {
    final tx = row.transaction;
    final isTransfer = tx.transCode == TransCode.transfer;
    final reconciled = tx.isReconciled;
    final signed = tx.signedAmountFor(accountId);
    final debit = signed < 0 ? -signed : null;
    final credit = signed >= 0 ? signed : null;

    // Not-yet-happened rows (a future-dated recurring occurrence recorded
    // ahead of time, for instance): shown italic and never bold, regardless
    // of the reconciled/solde weight rules below, so they read as "not yet
    // real" at a glance.
    final today = DateTime.now();
    final isFuture =
        tx.date.isAfter(DateTime(today.year, today.month, today.day));

    final tiers = isTransfer
        ? '${accountsById[tx.accountId]?.name ?? '?'} → ${accountsById[tx.toAccountId]?.name ?? '?'}'
        : (payeesById[tx.payeeId]?.name ?? 'Payé inconnu');
    final categorie = isTransfer
        ? 'Virement'
        : categoryFullPath(tx.categoryId, categoriesById);

    Widget cell(double width, String text,
        {TextAlign align = TextAlign.left, Color? color, FontWeight? weight}) {
      return SizedBox(
        width: width,
        child: Text(
          text,
          textAlign: align,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            color: color,
            fontStyle: isFuture ? FontStyle.italic : FontStyle.normal,
            fontWeight: isFuture
                ? FontWeight.normal
                : (weight ??
                    (reconciled ? FontWeight.normal : FontWeight.w700)),
          ),
        ),
      );
    }

    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: index.isEven ? scheme.surfaceContainerLowest : scheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () => onTapRow(tx),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: _colCheck,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  iconSize: 20,
                  tooltip: reconciled
                      ? 'Pointee - toucher pour depointer'
                      : 'Non pointee - toucher pour pointer',
                  icon: Icon(
                    reconciled
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    color: reconciled ? AppTheme.positive : Colors.grey[400],
                  ),
                  onPressed: () => onToggleReconciled(tx, !reconciled),
                ),
              ),
              const SizedBox(width: _colGap),
              InkWell(
                onTap: () => _editDate(context, tx),
                child: cell(_colDate, DateFormat('dd/MM/yy').format(tx.date)),
              ),
              const SizedBox(width: _colGap),
              cell(_colTiers, tiers),
              const SizedBox(width: _colGap),
              cell(_colStatut, reconciled ? 'R' : '', align: TextAlign.center),
              const SizedBox(width: _colGap),
              cell(_colCategorie, categorie),
              const SizedBox(width: _colGap),
              cell(
                _colMontant,
                debit == null
                    ? ''
                    : (currency?.format(debit) ?? debit.toStringAsFixed(2)),
                align: TextAlign.right,
                color: debit == null ? null : AppTheme.negative,
              ),
              const SizedBox(width: _colGap),
              cell(
                _colMontant,
                credit == null
                    ? ''
                    : (currency?.format(credit) ?? credit.toStringAsFixed(2)),
                align: TextAlign.right,
                color: credit == null ? null : AppTheme.positive,
              ),
              const SizedBox(width: _colGap),
              cell(
                _colSolde,
                currency?.format(row.balanceAfter) ??
                    row.balanceAfter.toStringAsFixed(2),
                align: TextAlign.right,
                weight: FontWeight.w700,
                color: row.balanceAfter < 0 ? AppTheme.negative : null,
              ),
              const SizedBox(width: _colGap),
              cell(_colRemarques, tx.notes ?? '',
                  weight: FontWeight.normal, color: Colors.grey[700]),
            ],
          ),
        ),
      ),
    );
  }
}

/// Narrow-screen alternative to [_LedgerTable]: the same data, one card per
/// transaction, stacked instead of laid out as fixed-width columns - the
/// desktop-style grid doesn't have room to breathe below ~640px.
class _LedgerCards extends StatelessWidget {
  final List<TransactionWithBalance> rows;
  final int accountId;
  final Map<int, Account> accountsById;
  final Map<int, Category> categoriesById;
  final Map<int, Payee> payeesById;
  final CurrencyFormat? currency;
  final ValueChanged<MoneyTransaction> onTapRow;
  final void Function(MoneyTransaction, bool) onToggleReconciled;
  final void Function(MoneyTransaction tx, DateTime date) onEditDate;

  const _LedgerCards({
    required this.rows,
    required this.accountId,
    required this.accountsById,
    required this.categoriesById,
    required this.payeesById,
    required this.onTapRow,
    required this.onToggleReconciled,
    required this.onEditDate,
    this.currency,
  });

  Future<void> _editDate(BuildContext context, MoneyTransaction tx) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: tx.date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: 'Modifier la date',
    );
    if (picked != null && picked != tx.date) onEditDate(tx, picked);
  }

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) => _card(context, rows[index]),
    );
  }

  Widget _card(BuildContext context, TransactionWithBalance row) {
    final tx = row.transaction;
    final isTransfer = tx.transCode == TransCode.transfer;
    final reconciled = tx.isReconciled;
    final signed = tx.signedAmountFor(accountId);
    final debit = signed < 0 ? -signed : null;
    final credit = signed >= 0 ? signed : null;
    final amountColor = debit != null ? AppTheme.negative : AppTheme.positive;
    final amount = debit ?? credit ?? 0;

    final today = DateTime.now();
    final isFuture =
        tx.date.isAfter(DateTime(today.year, today.month, today.day));
    final fontStyle = isFuture ? FontStyle.italic : FontStyle.normal;
    final weight = isFuture ? FontWeight.normal : FontWeight.w700;

    final tiers = isTransfer
        ? '${accountsById[tx.accountId]?.name ?? '?'} → ${accountsById[tx.toAccountId]?.name ?? '?'}'
        : (payeesById[tx.payeeId]?.name ?? 'Payé inconnu');
    final categorie = isTransfer
        ? 'Virement'
        : categoryFullPath(tx.categoryId, categoriesById);

    return Material(
      color: Theme.of(context).cardColor,
      borderRadius: BorderRadius.circular(AppTheme.cardRadius),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        onTap: () => onTapRow(tx),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    iconSize: 20,
                    tooltip: reconciled
                        ? 'Pointee - toucher pour depointer'
                        : 'Non pointee - toucher pour pointer',
                    icon: Icon(
                      reconciled
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      color: reconciled ? AppTheme.positive : Colors.grey[400],
                    ),
                    onPressed: () => onToggleReconciled(tx, !reconciled),
                  ),
                  const SizedBox(width: 4),
                  InkWell(
                    onTap: () => _editDate(context, tx),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        DateFormat('dd/MM/yy').format(tx.date),
                        style: TextStyle(
                            fontStyle: fontStyle,
                            fontWeight: weight,
                            fontSize: 13),
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${debit != null ? '-' : '+'}${currency?.format(amount) ?? amount.toStringAsFixed(2)}',
                    style: TextStyle(
                      color: amountColor,
                      fontWeight: FontWeight.w700,
                      fontStyle: fontStyle,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                tiers,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontWeight: weight, fontStyle: fontStyle, fontSize: 15),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      categorie,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: Colors.grey[600],
                          fontSize: 12,
                          fontStyle: fontStyle),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Solde: ${currency?.format(row.balanceAfter) ?? row.balanceAfter.toStringAsFixed(2)}',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      color: row.balanceAfter < 0
                          ? AppTheme.negative
                          : Colors.grey[700],
                    ),
                  ),
                ],
              ),
              if ((tx.notes ?? '').isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  tx.notes!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: Colors.grey[500],
                      fontSize: 12,
                      fontStyle: FontStyle.italic),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TransactionEditorSheet extends StatefulWidget {
  final MoneyTransaction? existing;
  final MmexRepository repo;

  const _TransactionEditorSheet({this.existing, required this.repo});

  @override
  State<_TransactionEditorSheet> createState() =>
      _TransactionEditorSheetState();
}

class _TransactionEditorSheetState extends State<_TransactionEditorSheet> {
  final _formKey = GlobalKey<FormState>();
  late int? _accountId;
  late int? _toAccountId;
  late int? _categoryId;
  late int? _payeeId;
  late TransCode _transCode;
  late DateTime _date;
  final _amountController = TextEditingController();
  final _notesController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final tx = widget.existing;
    _accountId = tx?.accountId;
    _toAccountId = tx?.toAccountId;
    _categoryId = tx?.categoryId;
    _payeeId = tx?.payeeId;
    _transCode = tx?.transCode ?? TransCode.withdrawal;
    _date = tx?.date ?? DateTime.now();
    _amountController.text = tx != null ? tx.amount.toStringAsFixed(2) : '';
    _notesController.text = tx?.notes ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final dbProvider = context.watch<DatabaseProvider>();
    // Hidden accounts are excluded from selection - except one already in
    // use by this transaction, so editing an old entry against a since-hidden
    // account doesn't break (a DropdownButtonFormField needs its current
    // value to be among its items).
    final accounts = widget.repo
        .getAccounts()
        .where((a) =>
            !dbProvider.isAccountHidden(a.id) ||
            a.id == _accountId ||
            a.id == _toAccountId)
        .toList();
    final categories = widget.repo.getCategories();
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
                    ? 'Nouvelle transaction'
                    : 'Modifier la transaction',
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
                    DropdownMenuItem(value: a.id, child: Text(a.name)),
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
                options: categories,
                labelOf: (c) => c.name,
                initialValue: findById(categories, _categoryId, (c) => c.id),
                onSelected: (c) => setState(() => _categoryId = c?.id),
                onCreate: (text) async {
                  final id = widget.repo.insertCategory(name: text);
                  setState(() {});
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
                    setState(() {});
                    return Payee(id: id, name: text, active: true);
                  },
                ),
              ],
              const SizedBox(height: 12),
              TextFormField(
                controller: _notesController,
                decoration: const InputDecoration(labelText: 'Notes'),
              ),
              const SizedBox(height: 12),
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
              const SizedBox(height: 20),
              Row(
                children: [
                  if (widget.existing != null)
                    TextButton(
                      onPressed: () {
                        widget.repo.deleteTransaction(widget.existing!.id);
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
    if (widget.existing == null) {
      widget.repo.insertTransaction(
        accountId: _accountId!,
        payeeId: isTransfer ? -1 : (_payeeId ?? -1),
        transCode: _transCode,
        amount: amount,
        date: _date,
        categoryId: _categoryId,
        toAccountId: isTransfer ? _toAccountId : null,
        toAmount: isTransfer ? amount : null,
        notes: _notesController.text,
      );
    } else {
      widget.repo.updateTransaction(MoneyTransaction(
        id: widget.existing!.id,
        accountId: _accountId!,
        toAccountId: isTransfer ? _toAccountId : null,
        payeeId: isTransfer ? -1 : (_payeeId ?? -1),
        transCode: _transCode,
        amount: amount,
        toAmount: amount,
        status: widget.existing!.status,
        date: _date,
        categoryId: _categoryId,
        notes: _notesController.text,
      ));
    }
    Navigator.of(context).pop();
  }
}
