import 'package:flutter/material.dart';

import 'package:money_manager_core/data/mmex_repository.dart';
import '../state/api_session_provider.dart';
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
typedef CategoryChange = ({
  int? payeeId,
  int? transferAccountId,
  int? transferToAccountId,
  int oldCategoryId,
  int newCategoryId,
});

/// After a category change on an existing transaction or recurring bill,
/// checks whether other real ledger transactions are "identical" (same
/// payee, or for a transfer the same source/destination account pair -
/// see [CategoryChange]) and previously shared the same category - if so,
/// offers to reassign them too in one go. No-op if nothing else matches,
/// or if [context] is no longer mounted.
Future<void> offerBulkCategoryReassign({
  required BuildContext context,
  required MmexRepository repo,
  required DatabaseProvider dbProvider,
  required CategoryChange change,
  ApiSessionProvider? apiSession,
  VoidCallback? apiRefresh,
}) async {
  final useApi = apiSession != null && apiSession.useApiForTransactions && apiSession.isConnected;
  final isTransfer = change.transferAccountId != null;
  final count = isTransfer
      ? (useApi
          ? await apiSession.countTransfersMatching(
              accountId: change.transferAccountId!,
              toAccountId: change.transferToAccountId!,
              categoryId: change.oldCategoryId,
            )
          : repo.countTransfersMatching(
              accountId: change.transferAccountId!,
              toAccountId: change.transferToAccountId!,
              categoryId: change.oldCategoryId,
            ))
      : (useApi
          ? await apiSession.countTransactionsMatching(
              payeeId: change.payeeId!, categoryId: change.oldCategoryId)
          : repo.countTransactionsMatching(payeeId: change.payeeId!, categoryId: change.oldCategoryId));
  if (count == 0 || !context.mounted) return;

  final plural = count > 1 ? 's' : '';
  final matchDescription = isTransfer ? 'même virement (mêmes comptes)' : 'même tiers';
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Opérations identiques'),
      content: Text(
        '$count autre$plural opération$plural identique$plural trouvée$plural ($matchDescription, même '
        'ancienne catégorie) dans le grand livre. Les mettre à jour aussi ?',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Non merci')),
        FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Mettre à jour')),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  if (useApi) {
    if (isTransfer) {
      await apiSession.bulkReassignTransferCategory(
        accountId: change.transferAccountId!,
        toAccountId: change.transferToAccountId!,
        oldCategoryId: change.oldCategoryId,
        newCategoryId: change.newCategoryId,
      );
    } else {
      await apiSession.bulkReassignTransactionCategory(
        payeeId: change.payeeId!,
        oldCategoryId: change.oldCategoryId,
        newCategoryId: change.newCategoryId,
      );
    }
    apiRefresh?.call();
  } else {
    if (isTransfer) {
      repo.bulkReassignTransferCategory(
        accountId: change.transferAccountId!,
        toAccountId: change.transferToAccountId!,
        oldCategoryId: change.oldCategoryId,
        newCategoryId: change.newCategoryId,
      );
    } else {
      repo.bulkReassignTransactionCategory(
        payeeId: change.payeeId!,
        oldCategoryId: change.oldCategoryId,
        newCategoryId: change.newCategoryId,
      );
    }
    dbProvider.touch();
  }
}
