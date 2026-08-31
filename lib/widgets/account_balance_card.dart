import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/account.dart';
import '../models/currency.dart';
import '../theme/app_theme.dart';
import 'bento_card.dart';

IconData iconForAccountType(String type) {
  switch (type) {
    case 'Credit Card':
      return Icons.credit_card;
    case 'Cash':
      return Icons.payments_outlined;
    case 'Savings':
      return Icons.savings_outlined;
    case 'Investment':
    case 'Stock':
      return Icons.trending_up;
    case 'Loan':
      return Icons.request_quote_outlined;
    case 'Term':
      return Icons.lock_clock_outlined;
    case 'Asset':
      return Icons.home_work_outlined;
    default:
      return Icons.account_balance_outlined;
  }
}

class AccountBalanceCard extends StatelessWidget {
  final Account account;
  final double balance;
  final CurrencyFormat? currency;
  final bool selected;
  final VoidCallback? onTap;

  /// Projected balance on [forecastLabel]'s date (e.g. "Prev. au 24 juil."),
  /// using known recurring transactions only - see
  /// [MmexRepository.forecastAccountBalance]. Null hides the row entirely.
  final double? forecastBalance;
  final String? forecastLabel;

  /// First future date the account's projected balance is expected to dip
  /// below zero (see [MmexRepository.forecastNegativeDate]) - null hides
  /// the warning row entirely, whether because the projection stays
  /// non-negative or because the account is already negative today (that's
  /// already visible from [balance]'s own red color, so no separate date
  /// warning is needed on top of it).
  final DateTime? negativeDate;

  const AccountBalanceCard({
    super.key,
    required this.account,
    required this.balance,
    this.currency,
    this.selected = false,
    this.onTap,
    this.forecastBalance,
    this.forecastLabel,
    this.negativeDate,
  });

  @override
  Widget build(BuildContext context) {
    final positive = balance >= 0;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: selected
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(AppTheme.cardRadius),
                border: Border.all(color: AppTheme.accent, width: 2),
              )
            : null,
        child: BentoCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(iconForAccountType(account.type), size: 18, color: AppTheme.accent),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      account.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (selected) Icon(Icons.check_circle, size: 16, color: AppTheme.accent),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                currency?.format(balance) ?? balance.toStringAsFixed(2),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: positive ? AppTheme.positive : AppTheme.negative,
                      fontWeight: FontWeight.w800,
                    ),
              ),
              if (forecastBalance != null) ...[
                const SizedBox(height: 2),
                Text(
                  '$forecastLabel : ${currency?.format(forecastBalance!) ?? forecastBalance!.toStringAsFixed(2)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: forecastBalance! >= 0 ? AppTheme.positive : AppTheme.negative,
                      ),
                ),
              ],
              if (negativeDate != null) ...[
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.warning_amber_rounded, size: 12, color: AppTheme.negative),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        'Négatif dès le ${DateFormat('d MMM', 'fr_FR').format(negativeDate!)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: AppTheme.negative, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
