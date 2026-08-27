import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform, Uint8List;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/mmex_repository.dart';
import '../models/account.dart';
import '../models/category.dart';
import '../models/currency.dart';
import '../models/payee.dart';
import '../models/transaction.dart';
import '../services/voice_entry/voice_transaction_parser.dart';
import '../state/database_provider.dart';
import '../theme/app_theme.dart';
import '../utils/date_picker.dart';
import '../utils/list_utils.dart';
import '../widgets/bill_amount_sync.dart';
import '../widgets/bulk_category_reassign.dart';
import '../widgets/confirm_delete.dart';
import '../widgets/responsive_body.dart';
import '../widgets/searchable_select_field.dart';
import '../widgets/transaction_entry_flow.dart';
import 'recurring_screen.dart' show RecurringEditorSheet;

/// True on every platform except web - i.e. desktop (Windows/Linux/macOS)
/// *and* Android. Simplifies to `!kIsWeb` rather than enumerating
/// TargetPlatform values: Android belongs on this side too (added
/// 2026-08-04), since it runs the same native AOT-compiled Dart + native FFI
/// SQLite as desktop (see pubspec.yaml's sqlite3_flutter_libs comment -
/// "bundle la lib native sqlite3 pour Android/desktop"), not web's slower
/// Dart-compiled-to-JS/Wasm + sqlite3.wasm combination. See
/// [getTransactionsWithRunningBalance]'s doc comment for what this actually
/// gates (skipping the month-bounded ledger query).
bool get _showFullLedger => !kIsWeb;

/// Android-specific, unlike [_showFullLedger] - gates the voice-entry option
/// (speech_to_text via Android's own SpeechRecognizer), same convention as
/// webdav_settings_card.dart's _isAndroidPlatform.
bool get _isAndroidPlatform =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// The grand livre's customizable columns (desktop-style `_LedgerTable`
/// only - the narrow-screen `_LedgerCards` layout isn't column-based, same
/// reasoning as the account carousel's "narrow follows the saved order but
/// isn't itself draggable"). The leading "pointée" checkbox is deliberately
/// not a member of this enum - it's an action control, not a data column,
/// and always renders fixed-first regardless of customization. Declaration
/// order here is also the default display order (see
/// DatabaseProvider.ledgerColumnOrder's doc comment).
enum LedgerColumnId {
  date,
  tiers,
  statut,
  categorie,
  montant,
  solde,
  remarques
}

String _ledgerColumnLabel(LedgerColumnId id) {
  switch (id) {
    case LedgerColumnId.date:
      return 'Date';
    case LedgerColumnId.tiers:
      return 'Tiers';
    case LedgerColumnId.statut:
      return 'Statut';
    case LedgerColumnId.categorie:
      return 'Catégorie';
    case LedgerColumnId.montant:
      return 'Débit / Crédit';
    case LedgerColumnId.solde:
      return 'Solde';
    case LedgerColumnId.remarques:
      return 'Remarques';
  }
}

/// The full set of known columns, in [dbProvider]'s saved custom order -
/// including hidden ones, so the column-settings sheet can still show and
/// reorder them. A column id saved from an older/newer app version that no
/// longer exists is silently dropped; one never yet saved (new in this
/// version) is appended at the end in its declared enum order - same
/// "unlisted = appended at the end" convention as `sortByAccountOrder`.
List<LedgerColumnId> _allLedgerColumnsInOrder(DatabaseProvider dbProvider) {
  final byName = {for (final c in LedgerColumnId.values) c.name: c};
  final saved = dbProvider.ledgerColumnOrder
      .map((s) => byName[s])
      .whereType<LedgerColumnId>()
      .toList();
  final missing = LedgerColumnId.values.where((c) => !saved.contains(c));
  return [...saved, ...missing];
}

/// [_allLedgerColumnsInOrder] filtered down to what should actually render
/// in `_LedgerTable`.
List<LedgerColumnId> _visibleLedgerColumns(DatabaseProvider dbProvider) {
  return _allLedgerColumnsInOrder(dbProvider)
      .where((c) => !dbProvider.ledgerHiddenColumns.contains(c.name))
      .toList();
}

/// Same tiers/catégorie label rules [_LedgerTable]/[_LedgerCards] already
/// render inline - factored out here purely for [_compareLedgerRows] to
/// reuse, without touching either widget's own rendering code.
String _ledgerTiersLabel(MoneyTransaction tx, Map<int, Account> accountsById,
    Map<int, Payee> payeesById) {
  return tx.transCode == TransCode.transfer
      ? '${accountsById[tx.accountId]?.name ?? '?'} → ${accountsById[tx.toAccountId]?.name ?? '?'}'
      : (payeesById[tx.payeeId]?.name ?? 'Tiers inconnu');
}

String _ledgerCategorieLabel(
    MoneyTransaction tx, Map<int, Category> categoriesById) {
  final label = categoryFullPath(tx.categoryId, categoriesById);
  return tx.transCode == TransCode.transfer && label.isEmpty
      ? 'Virement'
      : label;
}

/// Sort key for [LedgerColumnId.statut]: paused ranks after reconciled
/// ranks after neither, matching the column's own "V"/"R"/"" display order.
int _ledgerStatutRank(MoneyTransaction tx) {
  if (tx.isVoid) return 2;
  if (tx.isReconciled) return 1;
  return 0;
}

int _compareLedgerRows(
  TransactionWithBalance a,
  TransactionWithBalance b,
  LedgerColumnId column,
  int accountId,
  Map<int, Account> accountsById,
  Map<int, Category> categoriesById,
  Map<int, Payee> payeesById,
) {
  final txA = a.transaction;
  final txB = b.transaction;
  switch (column) {
    case LedgerColumnId.date:
      return txA.date.compareTo(txB.date);
    case LedgerColumnId.tiers:
      return _ledgerTiersLabel(txA, accountsById, payeesById)
          .toLowerCase()
          .compareTo(
              _ledgerTiersLabel(txB, accountsById, payeesById).toLowerCase());
    case LedgerColumnId.statut:
      return _ledgerStatutRank(txA).compareTo(_ledgerStatutRank(txB));
    case LedgerColumnId.categorie:
      return _ledgerCategorieLabel(txA, categoriesById)
          .toLowerCase()
          .compareTo(_ledgerCategorieLabel(txB, categoriesById).toLowerCase());
    case LedgerColumnId.montant:
      return txA
          .signedAmountFor(accountId)
          .compareTo(txB.signedAmountFor(accountId));
    case LedgerColumnId.solde:
      return a.balanceAfter.compareTo(b.balanceAfter);
    case LedgerColumnId.remarques:
      return (txA.notes ?? '')
          .toLowerCase()
          .compareTo((txB.notes ?? '').toLowerCase());
  }
}

class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key});

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  final _searchController = TextEditingController();
  String _search = '';

  // Column-header sort - deliberately session-only, unlike column order/
  // visibility below (which persist to the companion settings file): this
  // is closer to the search box than to a real preference, reset on every
  // fresh visit to the screen rather than remembered. Null means the
  // natural order the repository already returns (most recent date first).
  LedgerColumnId? _sortColumn;
  bool _sortAscending = true;

  void _toggleSort(LedgerColumnId column) {
    setState(() {
      if (_sortColumn == column) {
        _sortAscending = !_sortAscending;
      } else {
        _sortColumn = column;
        _sortAscending = true;
      }
    });
  }

  /// Always the 1st of some month - the anchor/latest month of the visible
  /// window. On web (![_showFullLedger]) the ledger shows this month plus
  /// the one immediately before it (see [getTransactionsWithRunningBalance]'s
  /// doc comment for why it stays bounded there at all: computing the
  /// running balance for an account's *entire* history on every rebuild
  /// could freeze the tab once it spanned years). Everywhere else
  /// ([_showFullLedger] - desktop and Android) that restriction is lifted
  /// entirely instead - this field is then only used for the "Aujourd'hui"
  /// button's current-month check, not for bounding any query - since native
  /// AOT-compiled Dart plus native FFI SQLite make the full-history
  /// computation effectively instant even at this user's real data scale
  /// (checked 2026-08-04: ~12k transactions total, largest single account
  /// ~4.5k, across 13 years - comfortably small for a per-keystroke recompute
  /// on native code, and still comfortably small doubled for web's 2-month
  /// window). Starts on the current month; [_shiftMonth] moves it.
  late DateTime _selectedMonth =
      DateTime(DateTime.now().year, DateTime.now().month);

  void _shiftMonth(int delta) {
    setState(() {
      _selectedMonth =
          DateTime(_selectedMonth.year, _selectedMonth.month + delta);
    });
  }

  bool get _isCurrentMonth {
    final now = DateTime.now();
    return _selectedMonth.year == now.year && _selectedMonth.month == now.month;
  }

  static final _monthNames = [
    for (var m = 1; m <= 12; m++)
      DateFormat('MMMM', 'fr_FR').format(DateTime(2000, m))
  ];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

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
    final recurringTxIds = repo.recurringTransactionIds();
    final recurringOccurrences = repo.recurringTransactionOccurrences();
    final previousMonth =
        DateTime(_selectedMonth.year, _selectedMonth.month - 1);
    final nextMonth = DateTime(_selectedMonth.year, _selectedMonth.month + 1);
    final allRows = accountId == null
        ? const <TransactionWithBalance>[]
        : repo.getTransactionsWithRunningBalance(accountId,
            from: _showFullLedger ? null : previousMonth,
            to: _showFullLedger ? null : nextMonth);

    // Bounds the year dropdown to years that actually have data for this
    // account, always widened to also include today's year and whatever
    // year is currently selected (arrow navigation can land outside the
    // account's own data range, e.g. one month past its last transaction).
    final yearRange =
        accountId == null ? null : repo.transactionYearRange(accountId);
    final candidateYears = [
      DateTime.now().year,
      _selectedMonth.year,
      if (yearRange != null) yearRange.min,
      if (yearRange != null) yearRange.max,
    ];
    final yearOptions = [
      for (var y = candidateYears.reduce((a, b) => a > b ? a : b);
          y >= candidateYears.reduce((a, b) => a < b ? a : b);
          y--)
        y
    ];

    final query = foldDiacritics(_search.trim());
    var rows = query.isEmpty
        ? allRows
        : allRows.where((row) {
            final tx = row.transaction;
            final isTransfer = tx.transCode == TransCode.transfer;
            final tiers = isTransfer
                ? '${accountsById[tx.accountId]?.name ?? ''} ${accountsById[tx.toAccountId]?.name ?? ''}'
                : (payees[tx.payeeId]?.name ?? '');
            final txCategoryLabel = categoryFullPath(tx.categoryId, categories);
            final categorie = isTransfer && txCategoryLabel.isEmpty
                ? 'Virement'
                : txCategoryLabel;
            final haystack = foldDiacritics([
              tiers,
              categorie,
              tx.notes ?? '',
              DateFormat('dd/MM/yyyy').format(tx.date),
              currency?.format(tx.amount) ?? tx.amount.toStringAsFixed(2),
            ].join(' '));
            return haystack.contains(query);
          }).toList();

    // Column-header sort (see _sortColumn's doc comment) - a pure display
    // reorder. row.balanceAfter stays whatever the repository already
    // computed in real chronological order; sorting by another column just
    // changes which order the (unchanged) rows are shown in, same as
    // re-sorting a spreadsheet by a different column never recomputes a
    // running-total column underneath it.
    if (_sortColumn != null && accountId != null) {
      final column = _sortColumn!;
      rows = [...rows]..sort((a, b) {
          final cmp = _compareLedgerRows(
              a, b, column, accountId, accountsById, categories, payees);
          return _sortAscending ? cmp : -cmp;
        });
    }

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
          IconButton(
            icon: const Icon(Icons.download_outlined),
            tooltip: 'Exporter en CSV',
            onPressed: rows.isEmpty
                ? null
                : () => _exportLedgerCsv(
                      context,
                      rows: rows,
                      accountId: accountId,
                      accountsById: accountsById,
                      categories: categories,
                      payees: payees,
                    ),
          ),
          IconButton(
            icon: const Icon(Icons.view_column_outlined),
            tooltip: 'Colonnes du grand livre',
            onPressed: () => _openColumnSettings(context, dbProvider),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Paramètres',
            onPressed: () => Navigator.of(context).pushNamed('/settings'),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(_showFullLedger ? 60 : 108),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!_showFullLedger)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.chevron_left),
                        tooltip: 'Mois précédent',
                        onPressed: () => _shiftMonth(-1),
                      ),
                      Expanded(
                        child: DropdownButton<int>(
                          isExpanded: true,
                          value: _selectedMonth.month,
                          items: [
                            for (var m = 1; m <= 12; m++)
                              DropdownMenuItem(
                                  value: m, child: Text(_monthNames[m - 1])),
                          ],
                          onChanged: (m) {
                            if (m == null) return;
                            setState(() => _selectedMonth =
                                DateTime(_selectedMonth.year, m));
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      DropdownButton<int>(
                        value: _selectedMonth.year,
                        items: [
                          for (final y in yearOptions)
                            DropdownMenuItem(value: y, child: Text('$y')),
                        ],
                        onChanged: (y) {
                          if (y == null) return;
                          setState(() => _selectedMonth =
                              DateTime(y, _selectedMonth.month));
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.chevron_right),
                        tooltip: 'Mois suivant',
                        onPressed: () => _shiftMonth(1),
                      ),
                      if (!_isCurrentMonth)
                        TextButton(
                          onPressed: () => setState(() {
                            final now = DateTime.now();
                            _selectedMonth = DateTime(now.year, now.month);
                          }),
                          child: const Text('Aujourd\'hui'),
                        ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText:
                        'Rechercher (tiers, catégorie, remarque, montant...)',
                    isDense: true,
                    border: const OutlineInputBorder(),
                    suffixIcon: _search.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () => setState(() {
                              _searchController.clear();
                              _search = '';
                            }),
                          ),
                  ),
                  onChanged: (v) => setState(() => _search = v),
                ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddChoice(context, accountId),
        icon: const Icon(Icons.add),
        label: const Text('Ajouter'),
      ),
      body: rows.isEmpty
          ? Center(
              child: Text(query.isEmpty
                  ? (_showFullLedger
                      ? 'Aucune transaction'
                      : 'Aucune transaction sur cette période')
                  : (_showFullLedger
                      ? 'Aucun résultat'
                      : 'Aucun résultat sur cette période')),
            )
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
                  recurringTxIds: recurringTxIds,
                  recurringOccurrences: recurringOccurrences,
                  onTapRow: (tx) =>
                      openTransactionEditor(context, existing: tx),
                  onToggleReconciled: (tx, value) {
                    repo.setReconciled(tx.id, value);
                    dbProvider.touch();
                  },
                  onEditDate: (tx, date) {
                    repo.updateTransaction(tx.copyWith(date: date));
                    dbProvider.touch();
                  },
                  onEditAmount: (tx, amount) => _saveQuickAmountEdit(
                      context, repo, dbProvider, tx, amount),
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
                  recurringTxIds: recurringTxIds,
                  recurringOccurrences: recurringOccurrences,
                  columns: _visibleLedgerColumns(dbProvider),
                  sortColumn: _sortColumn,
                  sortAscending: _sortAscending,
                  onSort: _toggleSort,
                  onTapRow: (tx) =>
                      openTransactionEditor(context, existing: tx),
                  onToggleReconciled: (tx, value) {
                    repo.setReconciled(tx.id, value);
                    dbProvider.touch();
                  },
                  onEditDate: (tx, date) {
                    repo.updateTransaction(tx.copyWith(date: date));
                    dbProvider.touch();
                  },
                  onEditAmount: (tx, amount) => _saveQuickAmountEdit(
                      context, repo, dbProvider, tx, amount),
                ),
              );
            }),
    );
  }

  /// The ledger table/cards' own quick amount edit (tap the Débit/Crédit
  /// cell directly, see _LedgerTable/_LedgerCards' onEditAmount) is a
  /// completely separate save path from TransactionEditorSheet - found
  /// 2026-08-06 live-testing that editing a recurring-linked transaction's
  /// amount this way never offered to sync the bill, because that logic
  /// only lived in the full sheet's _save(). Mirrors it here instead of
  /// duplicating it inline at both call sites.
  Future<void> _saveQuickAmountEdit(
    BuildContext context,
    MmexRepository repo,
    DatabaseProvider dbProvider,
    MoneyTransaction tx,
    double amount,
  ) async {
    repo.updateTransaction(tx.copyWith(amount: amount));
    dbProvider.touch();
    final billId = repo.billIdForTransaction(tx.id);
    if (billId == null || !context.mounted) return;
    await offerBillAmountSync(
      context: context,
      repo: repo,
      dbProvider: dbProvider,
      change: (billId: billId, newAmount: amount),
    );
  }

  /// Lets the FAB create either a one-off transaction or a recurring bill
  /// without leaving this screen - avoids a trip to the "Récurrentes" tab
  /// just to set up something recurring noticed while looking at the ledger.
  Future<void> _showAddChoice(BuildContext context, int? accountId) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: const Text('Nouvelle transaction'),
              onTap: () => Navigator.of(context).pop('transaction'),
            ),
            ListTile(
              leading: const Icon(Icons.autorenew),
              title: const Text('Nouvelle opération récurrente'),
              onTap: () => Navigator.of(context).pop('recurring'),
            ),
            if (_isAndroidPlatform)
              ListTile(
                leading: const Icon(Icons.mic_outlined),
                title: const Text('Par la voix'),
                onTap: () => Navigator.of(context).pop('voice'),
              ),
          ],
        ),
      ),
    );
    if (!context.mounted || choice == null) return;
    if (choice == 'transaction') {
      await openTransactionEditor(context, defaultAccountId: accountId);
    } else if (choice == 'voice') {
      await startVoiceEntry(context, accountId);
    } else {
      await _openRecurringEditor(context, defaultAccountId: accountId);
    }
  }

  Future<void> _openRecurringEditor(BuildContext context,
      {int? defaultAccountId}) async {
    final dbProvider = context.read<DatabaseProvider>();
    final repo = dbProvider.repository!;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          RecurringEditorSheet(repo: repo, defaultAccountId: defaultAccountId),
    );
    dbProvider.touch();
  }

  /// Shows/reorders the desktop-style ledger table's columns - changes
  /// apply immediately (persisted to the companion settings file via
  /// DatabaseProvider.setLedgerColumns) rather than needing an explicit
  /// "save", same as the dashboard's account-order drag-and-drop.
  Future<void> _openColumnSettings(
      BuildContext context, DatabaseProvider dbProvider) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _LedgerColumnSettingsSheet(dbProvider: dbProvider),
    );
  }

  /// Exports exactly what's currently on screen - the same filtered/sorted
  /// [rows] the ledger itself renders, not the account's whole history -
  /// via the same cross-platform `FilePicker.saveFile` already used for the
  /// database export (settings_screen.dart) and the AI chat's CSV export
  /// (nl_query_dialog.dart). 2026-08-27 user request ("Ajoute un export csv
  /// sur la page des transactions"), matching the long-standing ROADMAP
  /// suggestion. Amounts use a plain dot-decimal string, not the account's
  /// currency-formatted display text (e.g. "12,34 €") - a spreadsheet needs
  /// a real number to sum, not a locale-formatted label.
  Future<void> _exportLedgerCsv(
    BuildContext context, {
    required List<TransactionWithBalance> rows,
    required int? accountId,
    required Map<int, Account> accountsById,
    required Map<int, Category> categories,
    required Map<int, Payee> payees,
  }) async {
    final buffer = StringBuffer(
        'Date,Compte,Tiers,Catégorie,Débit,Crédit,Solde après,Statut,Notes\n');
    for (final row in rows) {
      final tx = row.transaction;
      final isTransfer = tx.transCode == TransCode.transfer;
      final tiers = isTransfer
          ? '${accountsById[tx.accountId]?.name ?? ''} -> ${accountsById[tx.toAccountId]?.name ?? ''}'
          : (payees[tx.payeeId]?.name ?? '');
      final txCategoryLabel = categoryFullPath(tx.categoryId, categories);
      final categorie =
          isTransfer && txCategoryLabel.isEmpty ? 'Virement' : txCategoryLabel;
      final isCredit = tx.transCode == TransCode.deposit ||
          (isTransfer && tx.accountId != accountId);
      final statut = tx.isVoid
          ? 'Annulée'
          : tx.isReconciled
              ? 'Pointée'
              : '';
      final fields = [
        DateFormat('dd/MM/yyyy').format(tx.date),
        accountsById[tx.accountId]?.name ?? '',
        tiers,
        categorie,
        isCredit ? '' : tx.amount.toStringAsFixed(2),
        isCredit ? tx.amount.toStringAsFixed(2) : '',
        row.balanceAfter.toStringAsFixed(2),
        statut,
        tx.notes ?? '',
      ];
      buffer.write('${fields.map(_csvField).join(',')}\n');
    }
    final timestamp = DateFormat('yyyy-MM-dd_HHmmss').format(DateTime.now());
    try {
      await FilePicker.saveFile(
        fileName: 'transactions_$timestamp.csv',
        // A UTF-8 BOM (2026-08-27 user report: accented characters coming
        // out garbled) - Excel, unlike most tools, does not auto-detect
        // plain UTF-8 without one and falls back to the system's ANSI code
        // page, mangling every accented character on open. The BOM costs
        // nothing for tools that already handle UTF-8 correctly.
        bytes: Uint8List.fromList(
            [0xEF, 0xBB, 0xBF, ...utf8.encode(buffer.toString())]),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Échec de l'export CSV : $e")),
      );
    }
  }
}

/// Escapes one CSV field per RFC 4180 - see sql_query_engine.dart's
/// identical helper for the AI chat's own CSV export; duplicated rather
/// than shared since both are small, private, and in otherwise-unrelated
/// files.
///
/// A newline inside a quoted field is technically legal CSV, but reads as
/// a garbled/duplicated row to a human skimming the file in a plain text
/// viewer or a naive parser (2026-08-27 user report: a multi-line Notes
/// value - e.g. a co-op fee notice pasted across several lines - made it
/// look like an unrelated transaction had appeared twice, further down
/// the file). Collapsed to a single space instead, so one transaction is
/// always exactly one line.
String _csvField(Object? value) {
  if (value == null) return '';
  final text = value.toString().replaceAll(RegExp(r'[\n\r]+'), ' ').trim();
  if (text.contains(RegExp('[,"]'))) {
    return '"${text.replaceAll('"', '""')}"';
  }
  return text;
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

  static double _renderedWidth(LedgerColumnId col) {
    switch (col) {
      case LedgerColumnId.date:
        return _colDate;
      case LedgerColumnId.tiers:
        return _colTiers;
      case LedgerColumnId.statut:
        return _colStatut;
      case LedgerColumnId.categorie:
        return _colCategorie;
      // Two sub-cells (Débit/Crédit) side by side with a gap between - kept
      // as a single customizable unit (see LedgerColumnId.montant's doc
      // comment) rather than two independently hideable/orderable columns.
      case LedgerColumnId.montant:
        return _colMontant * 2 + _colGap;
      case LedgerColumnId.solde:
        return _colSolde;
      case LedgerColumnId.remarques:
        return _colRemarques;
    }
  }

  final List<TransactionWithBalance> rows;
  final int accountId;
  final Map<int, Account> accountsById;
  final Map<int, Category> categoriesById;
  final Map<int, Payee> payeesById;
  final CurrencyFormat? currency;
  final ValueChanged<MoneyTransaction> onTapRow;
  final void Function(MoneyTransaction, bool) onToggleReconciled;
  final void Function(MoneyTransaction tx, DateTime date) onEditDate;
  final void Function(MoneyTransaction tx, double amount) onEditAmount;
  final Set<int> recurringTxIds;
  final Map<int, ({int index, int total})> recurringOccurrences;

  /// Visible columns, left to right - see
  /// transactions_screen.dart's `_visibleLedgerColumns`. The leading
  /// "pointée" checkbox is never part of this list, it always renders
  /// fixed-first.
  final List<LedgerColumnId> columns;
  final LedgerColumnId? sortColumn;
  final bool sortAscending;
  final ValueChanged<LedgerColumnId> onSort;

  const _LedgerTable({
    required this.rows,
    required this.accountId,
    required this.accountsById,
    required this.categoriesById,
    required this.payeesById,
    required this.onTapRow,
    required this.onToggleReconciled,
    required this.onEditDate,
    required this.onEditAmount,
    required this.recurringTxIds,
    required this.recurringOccurrences,
    required this.columns,
    required this.sortColumn,
    required this.sortAscending,
    required this.onSort,
    this.currency,
  });

  // +24 for the 12px horizontal padding on each side of every row (header
  // and data rows both wrap their Row in EdgeInsets.symmetric(horizontal:
  // 12)), which isn't otherwise accounted for by the column widths below.
  // Not a static const any more (like the old fixed-column-set version)
  // since it now depends on which/how many columns are actually visible.
  double get _totalWidth =>
      _colCheck +
      24 +
      columns.fold<double>(0, (sum, c) => sum + _colGap + _renderedWidth(c));

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

  /// A single header cell - tappable (toggling sort on [sortKey]) when one
  /// is given, plain otherwise (none of the current columns opt out, but
  /// kept general rather than assuming every future column is sortable).
  Widget _headerCell(
    BuildContext context,
    double width,
    String label, {
    TextAlign align = TextAlign.left,
    LedgerColumnId? sortKey,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final active = sortKey != null && sortKey == sortColumn;
    final color = active ? scheme.primary : scheme.onSurface;
    final icon = active
        ? Icon(sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
            size: 12, color: scheme.primary)
        : null;
    final mainAxisAlignment = switch (align) {
      TextAlign.right => MainAxisAlignment.end,
      TextAlign.center => MainAxisAlignment.center,
      _ => MainAxisAlignment.start,
    };
    final content = SizedBox(
      width: width,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: mainAxisAlignment,
        children: [
          if (align == TextAlign.right && icon != null) ...[
            icon,
            const SizedBox(width: 2)
          ],
          Flexible(
            child: Text(
              label,
              textAlign: align,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontWeight: FontWeight.w700, fontSize: 12, color: color),
            ),
          ),
          if (align != TextAlign.right && icon != null) ...[
            const SizedBox(width: 2),
            icon
          ],
        ],
      ),
    );
    if (sortKey == null) return content;
    return InkWell(onTap: () => onSort(sortKey), child: content);
  }

  List<Widget> _headerCellsFor(BuildContext context, LedgerColumnId col) {
    switch (col) {
      case LedgerColumnId.date:
        return [_headerCell(context, _colDate, 'Date', sortKey: col)];
      case LedgerColumnId.tiers:
        return [_headerCell(context, _colTiers, 'Tiers', sortKey: col)];
      case LedgerColumnId.statut:
        return [
          _headerCell(context, _colStatut, 'Statut',
              align: TextAlign.center, sortKey: col)
        ];
      case LedgerColumnId.categorie:
        return [_headerCell(context, _colCategorie, 'Catégorie', sortKey: col)];
      case LedgerColumnId.montant:
        return [
          _headerCell(context, _colMontant, 'Débit',
              align: TextAlign.right, sortKey: col),
          const SizedBox(width: _colGap),
          _headerCell(context, _colMontant, 'Crédit',
              align: TextAlign.right, sortKey: col),
        ];
      case LedgerColumnId.solde:
        return [
          _headerCell(context, _colSolde, 'Solde',
              align: TextAlign.right, sortKey: col)
        ];
      case LedgerColumnId.remarques:
        return [_headerCell(context, _colRemarques, 'Remarques', sortKey: col)];
    }
  }

  Widget _headerRow(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          const SizedBox(width: _colCheck),
          for (final col in columns) ...[
            const SizedBox(width: _colGap),
            ..._headerCellsFor(context, col),
          ],
        ],
      ),
    );
  }

  /// The Date column opens its own date picker directly, independent of
  /// the row's onTap (which opens the full editor sheet) - a quick way to
  /// fix a date without going through the whole form, e.g. right when
  /// reconciling against a bank statement that posted it a day or two off.
  Future<void> _editDate(BuildContext context, MoneyTransaction tx) async {
    final picked = await pickDate(
      context: context,
      initialDate: tx.date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: 'Modifier la date',
    );
    if (picked != null && picked != tx.date) onEditDate(tx, picked);
  }

  /// Same idea as [_editDate]: a quick way to fix the amount without
  /// opening the full editor, e.g. right when reconciling and noticing the
  /// bank cleared a slightly different amount than what was entered.
  /// Deliberately not offered for transfers - see [MoneyTransaction.copyWith].
  Future<void> _editAmount(BuildContext context, MoneyTransaction tx) async {
    final controller = TextEditingController(
        text: tx.amount.toStringAsFixed(2).replaceAll('.', ','));
    final result = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Modifier le montant'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Montant'),
          onSubmitted: (v) => Navigator.of(context)
              .pop(double.tryParse(v.replaceAll(',', '.'))),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Annuler')),
          FilledButton(
            onPressed: () => Navigator.of(context)
                .pop(double.tryParse(controller.text.replaceAll(',', '.'))),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
    if (result != null && result > 0 && result != tx.amount) {
      onEditAmount(tx, result);
    }
  }

  Widget _row(BuildContext context, TransactionWithBalance row, int index) {
    final tx = row.transaction;
    final isTransfer = tx.transCode == TransCode.transfer;
    final reconciled = tx.isReconciled;
    // MMEX's own Void status, repurposed as "paused" (2026-08-06) - see
    // MmexRepository.syncPausedTracking's doc comment for why this reuses
    // Void rather than a new app-owned exclusion filter: already excluded
    // from every balance/report query in mmex_repository.dart for free.
    final paused = tx.isVoid;
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

    final tiers = _ledgerTiersLabel(tx, accountsById, payeesById);
    final categorie = _ledgerCategorieLabel(tx, categoriesById);

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

    List<Widget> cellsFor(LedgerColumnId col) {
      switch (col) {
        case LedgerColumnId.date:
          return [
            InkWell(
              onTap: () => _editDate(context, tx),
              child: cell(_colDate, DateFormat('dd/MM/yy').format(tx.date)),
            ),
          ];
        case LedgerColumnId.tiers:
          return [
            SizedBox(
              width: _colTiers,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (paused) ...[
                    Tooltip(
                      message: 'En pause - exclue du solde et des rapports',
                      child: Icon(Icons.pause_circle_outline,
                          size: 13, color: scheme.error),
                    ),
                    const SizedBox(width: 3),
                  ],
                  if (recurringTxIds.contains(tx.id)) ...[
                    Tooltip(
                      message: recurringOccurrences[tx.id] != null
                          ? 'Générée par une opération récurrente '
                              '(${recurringOccurrences[tx.id]!.index}/${recurringOccurrences[tx.id]!.total})'
                          : 'Générée par une opération récurrente',
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.autorenew,
                              size: 13, color: scheme.primary),
                          if (recurringOccurrences[tx.id] != null)
                            Text(
                              ' ${recurringOccurrences[tx.id]!.index}/${recurringOccurrences[tx.id]!.total}',
                              style: TextStyle(
                                  fontSize: 10, color: scheme.primary),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 3),
                  ],
                  Expanded(
                    child: Text(
                      tiers,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontStyle:
                            isFuture ? FontStyle.italic : FontStyle.normal,
                        fontWeight: isFuture
                            ? FontWeight.normal
                            : (reconciled
                                ? FontWeight.normal
                                : FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ];
        case LedgerColumnId.statut:
          return [
            cell(_colStatut, paused ? 'V' : (reconciled ? 'R' : ''),
                align: TextAlign.center)
          ];
        case LedgerColumnId.categorie:
          return [cell(_colCategorie, categorie)];
        case LedgerColumnId.montant:
          return [
            InkWell(
              onTap: isTransfer ? null : () => _editAmount(context, tx),
              child: cell(
                _colMontant,
                debit == null
                    ? ''
                    : (currency?.format(debit) ?? debit.toStringAsFixed(2)),
                align: TextAlign.right,
                color: debit == null ? null : AppTheme.negative,
              ),
            ),
            const SizedBox(width: _colGap),
            InkWell(
              onTap: isTransfer ? null : () => _editAmount(context, tx),
              child: cell(
                _colMontant,
                credit == null
                    ? ''
                    : (currency?.format(credit) ?? credit.toStringAsFixed(2)),
                align: TextAlign.right,
                color: credit == null ? null : AppTheme.positive,
              ),
            ),
          ];
        case LedgerColumnId.solde:
          return [
            cell(
              _colSolde,
              currency?.format(row.balanceAfter) ??
                  row.balanceAfter.toStringAsFixed(2),
              align: TextAlign.right,
              weight: FontWeight.w700,
              color: row.balanceAfter < 0 ? AppTheme.negative : null,
            ),
          ];
        case LedgerColumnId.remarques:
          return [
            cell(_colRemarques, tx.notes ?? '',
                weight: FontWeight.normal, color: Colors.grey[700]),
          ];
      }
    }

    return Opacity(
      opacity: paused ? 0.55 : 1,
      child: Material(
        color: index.isEven
            ? scheme.surfaceContainerLowest
            : scheme.surfaceContainerHigh,
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
                        ? 'Pointée - toucher pour dépointer'
                        : 'Non pointée - toucher pour pointer',
                    icon: Icon(
                      reconciled
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      color: reconciled ? AppTheme.positive : Colors.grey[400],
                    ),
                    onPressed: () => onToggleReconciled(tx, !reconciled),
                  ),
                ),
                for (final col in columns) ...[
                  const SizedBox(width: _colGap),
                  ...cellsFor(col),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet letting the user hide/show and reorder [_LedgerTable]'s
/// columns (see LedgerColumnId) - every column stays listed here even when
/// hidden, so it can be dragged back into view. Every change applies (and
/// persists via DatabaseProvider.setLedgerColumns) immediately, same
/// convention as the dashboard's drag-and-drop account order - there's
/// nothing to explicitly "save", so the sheet has no Enregistrer button,
/// only a Fermer.
class _LedgerColumnSettingsSheet extends StatefulWidget {
  final DatabaseProvider dbProvider;

  const _LedgerColumnSettingsSheet({required this.dbProvider});

  @override
  State<_LedgerColumnSettingsSheet> createState() =>
      _LedgerColumnSettingsSheetState();
}

class _LedgerColumnSettingsSheetState
    extends State<_LedgerColumnSettingsSheet> {
  late List<LedgerColumnId> _order;
  late Set<LedgerColumnId> _hidden;

  @override
  void initState() {
    super.initState();
    _order = _allLedgerColumnsInOrder(widget.dbProvider);
    _hidden = widget.dbProvider.ledgerHiddenColumns
        .map((s) => LedgerColumnId.values.where((c) => c.name == s))
        .expand((matches) => matches)
        .toSet();
  }

  void _persist() {
    widget.dbProvider.setLedgerColumns(
      order: _order.map((c) => c.name).toList(),
      hidden: _hidden.map((c) => c.name).toSet(),
    );
  }

  void _toggle(LedgerColumnId col, bool? value) {
    // At least one column must stay visible - an entirely empty grand
    // livre table would just look broken, with no way back to a settings
    // screen from an empty grid.
    if (value == false && _hidden.length >= _order.length - 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Au moins une colonne doit rester visible.')),
      );
      return;
    }
    setState(() {
      if (value == false) {
        _hidden.add(col);
      } else {
        _hidden.remove(col);
      }
    });
    _persist();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Colonnes du grand livre',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Cochez pour afficher/masquer, glissez la poignée pour réordonner.',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ReorderableListView.builder(
                shrinkWrap: true,
                buildDefaultDragHandles: false,
                itemCount: _order.length,
                onReorderItem: (oldIndex, newIndex) {
                  setState(() {
                    final moved = _order.removeAt(oldIndex);
                    _order.insert(newIndex, moved);
                  });
                  _persist();
                },
                itemBuilder: (context, index) {
                  final col = _order[index];
                  return CheckboxListTile(
                    key: ValueKey(col),
                    controlAffinity: ListTileControlAffinity.leading,
                    value: !_hidden.contains(col),
                    onChanged: (v) => _toggle(col, v),
                    title: Text(_ledgerColumnLabel(col)),
                    secondary: ReorderableDragStartListener(
                      index: index,
                      child: const Icon(Icons.drag_handle),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Fermer'),
              ),
            ),
          ],
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
  final void Function(MoneyTransaction tx, double amount) onEditAmount;
  final Set<int> recurringTxIds;
  final Map<int, ({int index, int total})> recurringOccurrences;

  const _LedgerCards({
    required this.rows,
    required this.accountId,
    required this.accountsById,
    required this.categoriesById,
    required this.payeesById,
    required this.onTapRow,
    required this.onToggleReconciled,
    required this.onEditDate,
    required this.onEditAmount,
    required this.recurringTxIds,
    required this.recurringOccurrences,
    this.currency,
  });

  Future<void> _editDate(BuildContext context, MoneyTransaction tx) async {
    final picked = await pickDate(
      context: context,
      initialDate: tx.date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: 'Modifier la date',
    );
    if (picked != null && picked != tx.date) onEditDate(tx, picked);
  }

  Future<void> _editAmount(BuildContext context, MoneyTransaction tx) async {
    final controller = TextEditingController(
        text: tx.amount.toStringAsFixed(2).replaceAll('.', ','));
    final result = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Modifier le montant'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Montant'),
          onSubmitted: (v) => Navigator.of(context)
              .pop(double.tryParse(v.replaceAll(',', '.'))),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Annuler')),
          FilledButton(
            onPressed: () => Navigator.of(context)
                .pop(double.tryParse(controller.text.replaceAll(',', '.'))),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
    if (result != null && result > 0 && result != tx.amount) {
      onEditAmount(tx, result);
    }
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
    // See _LedgerTable._row's identical field for why this reuses MMEX's
    // own Void status as "paused".
    final paused = tx.isVoid;
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
        : (payeesById[tx.payeeId]?.name ?? 'Tiers inconnu');
    final transferCategoryLabel =
        categoryFullPath(tx.categoryId, categoriesById);
    final categorie = isTransfer
        ? (transferCategoryLabel.isEmpty ? 'Virement' : transferCategoryLabel)
        : categoryFullPath(tx.categoryId, categoriesById);

    return Opacity(
      opacity: paused ? 0.55 : 1,
      child: Material(
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
                          ? 'Pointée - toucher pour dépointer'
                          : 'Non pointée - toucher pour pointer',
                      icon: Icon(
                        reconciled
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color:
                            reconciled ? AppTheme.positive : Colors.grey[400],
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
                    InkWell(
                      onTap: isTransfer ? null : () => _editAmount(context, tx),
                      child: Text(
                        '${debit != null ? '-' : '+'}${currency?.format(amount) ?? amount.toStringAsFixed(2)}',
                        style: TextStyle(
                          color: amountColor,
                          fontWeight: FontWeight.w700,
                          fontStyle: fontStyle,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    if (paused) ...[
                      Tooltip(
                        message: 'En pause - exclue du solde et des rapports',
                        child: Icon(Icons.pause_circle_outline,
                            size: 13,
                            color: Theme.of(context).colorScheme.error),
                      ),
                      const SizedBox(width: 4),
                    ],
                    if (recurringTxIds.contains(tx.id)) ...[
                      Tooltip(
                        message: recurringOccurrences[tx.id] != null
                            ? 'Générée par une opération récurrente '
                                '(${recurringOccurrences[tx.id]!.index}/${recurringOccurrences[tx.id]!.total})'
                            : 'Générée par une opération récurrente',
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.autorenew,
                                size: 13,
                                color: Theme.of(context).colorScheme.primary),
                            if (recurringOccurrences[tx.id] != null)
                              Text(
                                ' ${recurringOccurrences[tx.id]!.index}/${recurringOccurrences[tx.id]!.total}',
                                style: TextStyle(
                                    fontSize: 10,
                                    color:
                                        Theme.of(context).colorScheme.primary),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                    Expanded(
                      child: Text(
                        tiers,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontWeight: weight,
                            fontStyle: fontStyle,
                            fontSize: 15),
                      ),
                    ),
                  ],
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
      ),
    );
  }
}

/// [TransactionEditorSheet]'s popped result - either/both may be null; see
/// [offerBulkCategoryReassign]/[offerBillAmountSync], both deferred to
/// after this sheet actually closes (same convention as CategoryChange
/// alone used before this - see bulk_category_reassign.dart).
typedef TransactionEditorResult = ({
  CategoryChange? categoryChange,
  BillAmountChange? billAmountChange,

  /// Set only when "Dupliquer" was tapped - the source transaction to seed
  /// a fresh "Nouvelle transaction" sheet from (see openTransactionEditor,
  /// which reopens itself with this as [TransactionEditorSheet.duplicateFrom]
  /// once this sheet has actually closed).
  MoneyTransaction? duplicateFrom,
});

/// The full transaction edit form, as a modal bottom sheet - shared between
/// the ledger (tapping a row) and anywhere else that needs to edit a real
/// transaction the exact same way (e.g. the database diagnostics screen),
/// so both stay behaviourally identical rather than drifting apart.
class TransactionEditorSheet extends StatefulWidget {
  final MoneyTransaction? existing;
  final MmexRepository repo;
  final int? defaultAccountId;

  /// Seeds the same fields [existing] would, without being a real saved
  /// transaction - Enregistrer still *creates* a new one, exactly like the
  /// plain "Nouvelle transaction" flow. Ignored when [existing] is set (an
  /// edit always wins over a stale draft). See voice_transaction_sheet.dart.
  final VoiceTransactionDraft? voicePrefill;

  /// Seeds every field a duplicated transaction should copy - everything
  /// except amount and date, which "Dupliquer" deliberately leaves blank/
  /// today's date rather than copying (see the button's own doc comment).
  /// Ignored when [existing] is set, same as [voicePrefill].
  final MoneyTransaction? duplicateFrom;

  const TransactionEditorSheet({
    super.key,
    this.existing,
    required this.repo,
    this.defaultAccountId,
    this.voicePrefill,
    this.duplicateFrom,
  });

  @override
  State<TransactionEditorSheet> createState() => _TransactionEditorSheetState();
}

class _TransactionEditorSheetState extends State<TransactionEditorSheet> {
  final _formKey = GlobalKey<FormState>();
  late int? _accountId;
  late int? _toAccountId;
  late int? _categoryId;
  late int? _payeeId;
  // Mirrors the Tiers field's raw typed text, kept in sync via
  // SearchableSelectField.onTextChanged - lets _save() resolve/auto-create
  // a payee from whatever was last typed even if the user never picked a
  // match from the dropdown or tapped its own "create" button (see _save).
  String _payeeText = '';
  late TransCode _transCode;
  late DateTime _date;
  late bool _reconciled;
  late bool _paused;
  // Guards against the modal bottom sheet's own dismiss animation staying
  // tappable for its short duration - found 2026-08-06 live-testing on
  // Android: without this, a couple of impatient taps on "Enregistrer"
  // before the sheet actually finished closing each ran _save() again in
  // full, inserting a duplicate transaction per extra tap (the "new
  // transaction" branch has no id to update against, so every call is a
  // fresh insert). Never reset back to false - the sheet is on its way out
  // once this is set, there's nothing to re-enable for.
  bool _saving = false;
  final _amountController = TextEditingController();
  final _notesController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final tx = widget.existing;
    final draft = tx == null ? widget.voicePrefill : null;
    // Ignored the same way [draft] is when editing a real transaction - a
    // duplicate only ever seeds a brand-new one.
    final dup = tx == null ? widget.duplicateFrom : null;
    _accountId = tx?.accountId ??
        draft?.accountId ??
        dup?.accountId ??
        widget.defaultAccountId;
    _toAccountId = tx?.toAccountId ?? dup?.toAccountId;
    _categoryId = tx?.categoryId ?? draft?.categoryId ?? dup?.categoryId;
    _payeeId = tx?.payeeId ?? draft?.payeeId ?? dup?.payeeId;
    _transCode = tx?.transCode ??
        draft?.transCode ??
        dup?.transCode ??
        TransCode.withdrawal;
    // [dup]'s own date is never read here - "Dupliquer" always lands on
    // today's date, same as this falling through to DateTime.now() below.
    _date = tx?.date ?? draft?.date ?? DateTime.now();
    _paused = tx?.isVoid ?? false;
    // A paused transaction's *live* status is 'V', not 'R' - tx.isReconciled
    // would read false even if it really was reconciled right before being
    // paused, so ask the remembered marker instead in that case (see
    // MmexRepository.wasReconciledBeforePause).
    _reconciled = tx == null
        ? false
        : (_paused
            ? widget.repo.wasReconciledBeforePause(tx.id)
            : tx.isReconciled);
    // [dup]'s amount is never read here either - the whole point of
    // "Dupliquer" is a fresh amount the user types in themselves.
    _amountController.text = tx != null
        ? tx.amount.toStringAsFixed(2)
        : (draft?.amount?.toStringAsFixed(2) ?? '');
    _notesController.text = tx?.notes ?? draft?.notes ?? dup?.notes ?? '';
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
    final categoriesById = {for (final c in categories) c.id: c};
    // "Parent:Child" full paths, sorted by that same path - groups every
    // subcategory under its parent alphabetically (matching how MMEX itself
    // lists categories), instead of the raw CATEGNAME-only order the
    // repository returns (which scatters same-named leaves across
    // unrelated parents).
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
                    ? 'Nouvelle transaction'
                    : 'Modifier la transaction',
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
                  setState(() {});
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
                    // Typing over a previously-selected payee's name (most
                    // notably: editing an existing transaction, where
                    // _payeeId starts pre-filled from tx.payeeId) must not
                    // silently keep pointing at that old payee - found
                    // 2026-08-14: without this, retyping a brand-new payee
                    // name while editing saved under the *original* payee
                    // anyway, since _save()'s `_payeeId ?? resolveOrCreatePayee(...)`
                    // fallback never ran while _payeeId was still non-null.
                    // Never showed up creating a *new* transaction, where
                    // _payeeId starts null already.
                    final selectedName =
                        findById(payees, _payeeId, (p) => p.id)?.name;
                    if (selectedName != null && selectedName != text) {
                      _payeeId = null;
                    }
                  },
                  enableVoiceInput: true,
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
                  final picked = await pickDate(
                    context: context,
                    initialDate: _date,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null) setState(() => _date = picked);
                },
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Pointée'),
                value: _reconciled,
                onChanged: (v) => setState(() => _reconciled = v ?? false),
              ),
              // Existing-only, like Supprimer below: pausing only makes
              // sense for something already affecting the balance.
              if (widget.existing != null)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('En pause'),
                  subtitle: const Text(
                      'Exclue du solde et des rapports, sans être supprimée'),
                  value: _paused,
                  onChanged: (v) => setState(() => _paused = v ?? false),
                ),
              const SizedBox(height: 20),
              Row(
                children: [
                  if (widget.existing != null)
                    TextButton(
                      onPressed: () async {
                        final confirmed = await confirmDelete(
                          context,
                          title: 'Supprimer cette opération',
                          message: 'Supprimer cette opération du grand livre '
                              '? Vous pourrez annuler juste après.',
                        );
                        if (!confirmed || !context.mounted) return;
                        // Everything needed to recreate this exact
                        // transaction has to be captured *before* deleting -
                        // deleteTransaction also wipes the recurring-bill
                        // link and paused-tracking rows it depends on (see
                        // MmexRepository.restoreTransaction's doc comment).
                        final tx = widget.existing!;
                        final billId = widget.repo.billIdForTransaction(tx.id);
                        final occurrence = widget.repo
                            .recurringTransactionOccurrences()[tx.id];
                        final wasReconciledBeforePause = tx.isVoid
                            ? widget.repo.wasReconciledBeforePause(tx.id)
                            : null;
                        widget.repo.deleteTransaction(tx.id);
                        final dbProvider = context.read<DatabaseProvider>();
                        dbProvider.touch();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: const Text('Opération supprimée.'),
                            action: SnackBarAction(
                              label: 'Annuler',
                              onPressed: () {
                                widget.repo.restoreTransaction(
                                  tx,
                                  billId: billId,
                                  occurrenceIndex: occurrence?.index,
                                  occurrenceTotal: occurrence?.total,
                                  wasReconciledBeforePause:
                                      wasReconciledBeforePause,
                                );
                                dbProvider.touch();
                              },
                            ),
                          ),
                        );
                        Navigator.of(context).pop();
                      },
                      child: const Text('Supprimer'),
                    ),
                  // Closes this sheet with the source transaction attached -
                  // openTransactionEditor reopens a fresh "Nouvelle
                  // transaction" sheet from it once this one has actually
                  // closed, rather than trying to swap forms in place.
                  if (widget.existing != null)
                    TextButton(
                      onPressed: () => Navigator.of(context).pop((
                        categoryChange: null,
                        billAmountChange: null,
                        duplicateFrom: widget.existing,
                      )),
                      child: const Text('Dupliquer'),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _saving ? null : _save,
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
    if (_saving) return;
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final amount = double.parse(_amountController.text.replaceAll(',', '.'));
    final isTransfer = _transCode == TransCode.transfer;
    // Resolves whatever was typed into Tiers even if never explicitly
    // selected/created (see SearchableSelectField.onTextChanged above) -
    // reuses a matching existing payee case-insensitively, or creates one,
    // rather than silently dropping it in favor of "Tiers inconnu".
    final typedPayeeText = _payeeText.trim();
    // -1 (never a real PAYEEID) means "no payee resolved" here just as much
    // as null does - an existing transaction with no payee assigned
    // (tx.payeeId == -1, see MoneyTransaction.fromRow) starts _payeeId at
    // -1 rather than null, and without this check would hit the exact same
    // "keeps the stale value, never resolves the typed text" bug the
    // onTextChanged fix above addresses for the more common case.
    final hasResolvedPayeeId = _payeeId != null && _payeeId != -1;
    final payeeId = isTransfer
        ? -1
        : (hasResolvedPayeeId
            ? _payeeId!
            : (typedPayeeText.isEmpty
                ? -1
                : widget.repo.resolveOrCreatePayee(
                    name: typedPayeeText, categoryId: _categoryId)));
    CategoryChange? categoryChange;
    BillAmountChange? billAmountChange;
    if (widget.existing == null) {
      widget.repo.insertTransaction(
        accountId: _accountId!,
        payeeId: payeeId,
        transCode: _transCode,
        amount: amount,
        date: _date,
        categoryId: _categoryId,
        toAccountId: isTransfer ? _toAccountId : null,
        toAmount: isTransfer ? amount : null,
        notes: _notesController.text,
        reconciled: _reconciled,
      );
    } else {
      // Single field shared with "Pointée" (MMEX has no separate flag for
      // this) - _paused always wins, see MmexRepository.syncPausedTracking
      // for how "Pointée" is preserved underneath without being live while
      // paused.
      final status = _paused ? 'V' : (_reconciled ? 'R' : '');
      widget.repo.updateTransaction(MoneyTransaction(
        id: widget.existing!.id,
        accountId: _accountId!,
        toAccountId: isTransfer ? _toAccountId : null,
        payeeId: payeeId,
        transCode: _transCode,
        amount: amount,
        toAmount: amount,
        status: status,
        date: _date,
        categoryId: _categoryId,
        notes: _notesController.text,
      ));
      widget.repo.syncPausedTracking(widget.existing!.id,
          paused: _paused, reconciled: _reconciled);

      // Only a real edit (not a brand new transaction) can have "other
      // identical" occurrences to offer fixing too - see
      // offerBulkCategoryReassign in _openEditor, which runs once this
      // sheet has actually closed.
      final oldCategoryId = widget.existing!.categoryId;
      if (oldCategoryId != null &&
          _categoryId != null &&
          _categoryId != oldCategoryId) {
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

      // Same deferred-to-after-close convention as categoryChange above -
      // see offerBillAmountSync in _openEditor.
      if (widget.existing!.amount != amount) {
        final billId = widget.repo.billIdForTransaction(widget.existing!.id);
        if (billId != null) {
          billAmountChange = (billId: billId, newAmount: amount);
        }
      }
    }
    context.read<DatabaseProvider>().touch();
    Navigator.of(context).pop((
      categoryChange: categoryChange,
      billAmountChange: billAmountChange,
      duplicateFrom: null,
    ));
  }
}
