import 'package:flutter/material.dart';

import '../data/mmex_repository.dart';
import '../state/database_provider.dart';

/// A just-saved category edit on an existing transaction or recurring bill,
/// passed back through Navigator.pop so the caller - only once the editor
/// sheet has actually closed - can offer [offerBulkCategoryReassign]. See
/// TransactionEditorSheet._save (transactions_screen.dart) and
/// RecurringEditorSheet._save (recurring_screen.dart).
///
/// Exactly one of [payeeId] or the (transferAccountId, transferToAccountId)
/// pair is set, never both - a transfer has no meaningful payee in this app
/// (PAYEEID is always forced to -1), so its "identical operations" match key
/// is the account pair instead. See [offerBulkCategoryReassign].
///
/// [oldNotes] is the edited transaction's remarque *before* this save - now
/// part of the match too (2026-09 user report: two unrelated loan
/// repayments, one ~255€ "Complément prêt travaux" and one ~1218€ "Prêt
/// immobilier", shared the same payee and category without sharing an
/// amount - the remarque was the only thing left distinguishing them, and
/// the old payee+category-only match silently swept both together).
typedef CategoryChange = ({
  int? payeeId,
  int? transferAccountId,
  int? transferToAccountId,
  int oldCategoryId,
  int newCategoryId,
  String? oldNotes,
});

/// After a category change on an existing transaction or recurring bill,
/// checks whether other real ledger transactions are "identical" (same
/// payee, or for a transfer the same source/destination account pair - see
/// [CategoryChange]) and previously shared the same category *and remarque*
/// - if so, offers to reassign them too in one go. No-op if nothing else
/// matches, or if [context] is no longer mounted.
Future<void> offerBulkCategoryReassign({
  required BuildContext context,
  required MmexRepository repo,
  required DatabaseProvider dbProvider,
  required CategoryChange change,
}) async {
  final isTransfer = change.transferAccountId != null;
  final count = isTransfer
      ? repo.countTransfersMatching(
          accountId: change.transferAccountId!,
          toAccountId: change.transferToAccountId!,
          categoryId: change.oldCategoryId,
          notes: change.oldNotes,
        )
      : repo.countTransactionsMatching(
          payeeId: change.payeeId!,
          categoryId: change.oldCategoryId,
          notes: change.oldNotes,
        );
  if (count == 0 || !context.mounted) return;

  final plural = count > 1 ? 's' : '';
  final matchDescription = isTransfer ? 'même virement (mêmes comptes)' : 'même tiers';
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Opérations identiques'),
      content: Text(
        '$count autre$plural opération$plural identique$plural trouvée$plural ($matchDescription, même '
        'ancienne catégorie, même remarque) dans le grand livre. Les mettre à jour aussi ?',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Non merci')),
        FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Mettre à jour')),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  if (isTransfer) {
    repo.bulkReassignTransferCategory(
      accountId: change.transferAccountId!,
      toAccountId: change.transferToAccountId!,
      oldCategoryId: change.oldCategoryId,
      newCategoryId: change.newCategoryId,
      notes: change.oldNotes,
    );
  } else {
    repo.bulkReassignTransactionCategory(
      payeeId: change.payeeId!,
      oldCategoryId: change.oldCategoryId,
      newCategoryId: change.newCategoryId,
      notes: change.oldNotes,
    );
  }
  dbProvider.touch();
}
