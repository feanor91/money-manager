import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/account.dart';
import '../models/category.dart';
import '../models/currency.dart';
import '../models/payee.dart';
import '../models/transaction.dart';
import '../theme/app_theme.dart';

class TransactionTile extends StatelessWidget {
  final MoneyTransaction transaction;
  final Payee? payee;
  final Category? category;
  final Account? fromAccount;
  final Account? toAccount;
  final CurrencyFormat? currency;
  final VoidCallback? onTap;
  final ValueChanged<bool>? onToggleReconciled;

  /// The account currently being viewed (e.g. the active account filter on
  /// the Transactions screen or the selected account on the dashboard). A
  /// transfer shows as a credit when this matches the destination account,
  /// a debit when it matches the source - without it, transfers default to
  /// the source account's perspective (debit).
  final int? viewpointAccountId;

  const TransactionTile({
    super.key,
    required this.transaction,
    this.payee,
    this.category,
    this.fromAccount,
    this.toAccount,
    this.currency,
    this.onTap,
    this.onToggleReconciled,
    this.viewpointAccountId,
  });

  bool get _isTransfer => transaction.transCode == TransCode.transfer;

  @override
  Widget build(BuildContext context) {
    final signed = transaction.signedAmountFor(viewpointAccountId);
    final positive = signed >= 0;
    final reconciled = transaction.isReconciled;

    final title = _isTransfer
        ? '${fromAccount?.name ?? 'Compte inconnu'} → ${toAccount?.name ?? 'Compte inconnu'}'
        : (payee?.name ?? 'Payé inconnu');

    final subtitleParts = <String>[
      if (_isTransfer) 'Virement' else (category?.name ?? 'Non categorise'),
      DateFormat.yMMMd('fr_FR').format(transaction.date),
    ];
    if ((transaction.notes ?? '').trim().isNotEmpty) {
      subtitleParts.add(transaction.notes!.trim());
    }

    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onToggleReconciled != null)
            GestureDetector(
              onTap: () => onToggleReconciled!(!reconciled),
              child: Tooltip(
                message: reconciled ? 'Pointee - toucher pour depointer' : 'Non pointee - toucher pour pointer',
                child: Icon(
                  reconciled ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: 20,
                  color: reconciled ? AppTheme.positive : Colors.grey[400],
                ),
              ),
            ),
          const SizedBox(width: 8),
          CircleAvatar(
            backgroundColor: (positive ? AppTheme.positive : AppTheme.negative).withValues(alpha: 0.12),
            child: Icon(
              _isTransfer
                  ? Icons.swap_horiz
                  : (positive ? Icons.south_west : Icons.north_east),
              color: positive ? AppTheme.positive : AppTheme.negative,
              size: 18,
            ),
          ),
        ],
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: reconciled ? FontWeight.w600 : FontWeight.w500,
          fontStyle: reconciled ? FontStyle.normal : FontStyle.italic,
          color: reconciled ? null : Colors.grey[600],
        ),
      ),
      subtitle: Text(
        subtitleParts.join(' - '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: reconciled ? null : TextStyle(fontStyle: FontStyle.italic, color: Colors.grey[500]),
      ),
      trailing: Text(
        currency?.format(signed) ?? signed.toStringAsFixed(2),
        style: TextStyle(
          fontWeight: reconciled ? FontWeight.w700 : FontWeight.w500,
          fontStyle: reconciled ? FontStyle.normal : FontStyle.italic,
          color: (positive ? AppTheme.positive : AppTheme.negative)
              .withValues(alpha: reconciled ? 1 : 0.7),
        ),
      ),
    );
  }
}
