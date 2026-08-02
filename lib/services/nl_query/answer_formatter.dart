import 'package:intl/intl.dart';

import '../../models/account.dart';
import '../../models/category.dart';
import '../../models/currency.dart';
import '../../models/payee.dart';
import 'query_executor.dart';
import 'query_intent.dart';

/// Turns a [QueryAnswer] into a French sentence - always deterministic,
/// template-based text built straight from the numbers [runQuery] computed:
/// never re-derived or reworded by an LLM, so a query answered via the
/// (desktop-only, optional) local AI reads exactly the same as one answered
/// by the rule-based parser, and can never state a number the model itself
/// made up.
String formatAnswer(
  QueryIntent intent,
  QueryAnswer answer, {
  required bool periodWasExplicit,
  required List<Category> categories,
  required List<Account> accounts,
  required List<Payee> payees,
  CurrencyFormat? currency,
}) {
  String money(double v) => currency?.format(v) ?? v.toStringAsFixed(2);
  final categoriesById = {for (final c in categories) c.id: c};
  final accountsById = {for (final a in accounts) a.id: a};
  final payeesById = {for (final p in payees) p.id: p};

  final periodNote = periodWasExplicit
      ? ''
      : ' (aucune période reconnue dans la question - ${intent.period.label} par défaut)';
  final accountNote =
      intent.accountId != null ? ' sur ${accountsById[intent.accountId]?.name ?? "ce compte"}' : '';

  switch (intent.kind) {
    case QueryKind.expenseTotal:
      final total = answer.total ?? 0;
      if (intent.categoryId != null) {
        final name = categoryFullPath(intent.categoryId, categoriesById);
        return 'Dépenses en ${name.isEmpty ? "cette catégorie" : name} pour '
            '${intent.period.label}$accountNote : ${money(total)}.$periodNote';
      }
      final breakdown = answer.categoryBreakdown ?? const {};
      final parts = breakdown.entries
          .where((e) => e.value > 0)
          .map((e) => '${categoryFullPath(e.key, categoriesById)} (${money(e.value)})')
          .join(', ');
      final detail = parts.isEmpty ? '' : ' - principalement : $parts';
      return 'Dépenses totales pour ${intent.period.label}$accountNote : '
          '${money(total)}.$detail$periodNote';

    case QueryKind.incomeTotal:
      return 'Revenus pour ${intent.period.label}$accountNote : '
          '${money(answer.income ?? 0)}.$periodNote';

    case QueryKind.incomeVsExpense:
      final income = answer.income ?? 0;
      final expense = answer.expense ?? 0;
      final net = income - expense;
      final netWord = net >= 0 ? 'excédent' : 'déficit';
      return 'Pour ${intent.period.label}$accountNote : revenus ${money(income)}, '
          'dépenses ${money(expense)}, soit un $netWord de ${money(net.abs())}.$periodNote';

    case QueryKind.balance:
      final accountName = accountsById[intent.accountId]?.name ?? 'ce compte';
      final asOf = intent.asOf;
      final asOfNote =
          asOf != null ? ' au ${DateFormat('d MMMM yyyy', 'fr_FR').format(asOf)}' : " aujourd'hui";
      return 'Solde de $accountName$asOfNote : ${money(answer.total ?? 0)}.';

    case QueryKind.topExpenses:
      final transactions = answer.transactions ?? const [];
      if (transactions.isEmpty) {
        return 'Aucune dépense trouvée pour ${intent.period.label}$accountNote.$periodNote';
      }
      final lines = transactions.map((t) {
        final payeeName = payeesById[t.payeeId]?.name ?? 'inconnu';
        final categoryName = categoryFullPath(t.categoryId, categoriesById);
        final categoryPart = categoryName.isEmpty ? '' : ' ($categoryName)';
        final dateText = DateFormat('d MMM yyyy', 'fr_FR').format(t.date);
        return '${money(t.amount)} - $payeeName$categoryPart le $dateText';
      }).join('\n');
      return 'Plus grosses dépenses pour ${intent.period.label}$accountNote :\n'
          '$lines$periodNote';

    case QueryKind.payeeSpend:
      final name = payeesById[intent.payeeId]?.name ?? 'ce tiers';
      return 'Dépenses chez $name pour ${intent.period.label}$accountNote : '
          '${money(answer.total ?? 0)}.$periodNote';
  }
}
