import 'package:flutter/material.dart';

import '../data/mmex_repository.dart';
import '../models/transaction.dart';
import '../state/database_provider.dart';
import '../utils/list_utils.dart';

/// A just-saved amount edit on an existing transaction that was originally
/// recorded from a recurring bill (see [MmexRepository.billIdForTransaction]),
/// passed back through Navigator.pop so the caller - only once the editor
/// sheet has actually closed - can offer [offerBillAmountSync]. Same
/// deferred-to-after-close convention as bulk_category_reassign.dart's
/// CategoryChange. See TransactionEditorSheet._save.
typedef BillAmountChange = ({int billId, double newAmount});

/// After an amount edit on a transaction linked to a recurring bill, asks
/// whether to update that bill's own amount too (so future occurrences use
/// the new amount) - always asks, never applies silently: the user asked
/// for this feature specifically requesting confirmation, since a ledger
/// edit is often a one-off correction (wrong amount typed originally) but
/// sometimes really is "this bill's amount changed going forward", and
/// only the user knows which. No-op if the bill was deleted in the
/// meantime, or if [context] is no longer mounted.
Future<void> offerBillAmountSync({
  required BuildContext context,
  required MmexRepository repo,
  required DatabaseProvider dbProvider,
  required BillAmountChange change,
}) async {
  final bill = findById(repo.getBillDeposits(), change.billId, (b) => b.id);
  if (bill == null || !context.mounted) return;

  final isTransfer = bill.transCode == TransCode.transfer;
  final accountsById = {for (final a in repo.getAccounts()) a.id: a};
  final payeesById = {for (final p in repo.getPayees(onlyActive: false)) p.id: p};
  final billLabel = isTransfer
      ? '${accountsById[bill.accountId]?.name ?? '?'} → '
          '${accountsById[bill.toAccountId]?.name ?? '?'}'
      : (payeesById[bill.payeeId]?.name ?? 'Tiers inconnu');

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Opération récurrente liée'),
      content: Text(
        'Cette opération provient de l\'opération récurrente "$billLabel". '
        'Mettre aussi à jour son montant pour les prochaines échéances ?',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Non merci')),
        FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Mettre à jour')),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  repo.updateBillDeposit(bill.copyWith(amount: change.newAmount));
  dbProvider.touch();
}
