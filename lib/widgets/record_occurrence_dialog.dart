import 'package:flutter/material.dart';

import '../data/mmex_repository.dart';
import '../models/bill_deposit.dart';
import '../models/recurrence.dart';
import '../models/transaction.dart';
import '../utils/date_picker.dart';

/// Adds [months] calendar months to [date], clamping to the destination
/// month's real last day - same small helper every screen that needs it
/// keeps its own private copy of (see forecast_chart.dart/budget_screen.dart).
/// Used to preview a split occurrence's installment dates - the actual
/// installments are dated the same way, server-side, by
/// [MmexRepository.recordBillOccurrence].
DateTime _addMonths(DateTime date, int months) {
  final total = date.year * 12 + (date.month - 1) + months;
  final year = total ~/ 12;
  final month = total % 12 + 1;
  final lastDay = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, date.day > lastDay ? lastDay : date.day);
}

/// Records one occurrence of a recurring bill/deposit into the real ledger
/// (via [MmexRepository.recordBillOccurrence]) - shared between
/// recurring_screen.dart's own list (where this originated, 2026-08) and
/// transactions_screen.dart's "opérations à venir" panel (2026-09 user
/// request: record a due occurrence straight from the ledger, without
/// switching screens), so both stay in exact sync rather than risking two
/// diverging copies of the same recording logic/UI.
class RecordOccurrenceDialog extends StatefulWidget {
  final BillDeposit bill;
  final MmexRepository repo;

  const RecordOccurrenceDialog({super.key, required this.bill, required this.repo});

  @override
  State<RecordOccurrenceDialog> createState() =>
      _RecordOccurrenceDialogState();
}

class _RecordOccurrenceDialogState extends State<RecordOccurrenceDialog> {
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
