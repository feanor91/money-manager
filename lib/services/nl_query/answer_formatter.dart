import 'package:intl/intl.dart';

import '../../models/account.dart';
import '../../models/category.dart';
import '../../models/currency.dart';
import '../../models/payee.dart';
import '../../models/transaction.dart';
import 'query_executor.dart';
import 'query_intent.dart';

/// "42,00 € - Carrefour (Alimentation:Courses) le 3 juil. 2026" per
/// transaction, biggest first - the detail behind an otherwise-bare total
/// (see [QueryAnswer.transactions]), one line each, newline-joined.
String _transactionLines(
  List<MoneyTransaction> transactions,
  Map<int, Category> categoriesById,
  Map<int, Payee> payeesById,
  String Function(double) money,
) {
  return transactions.map((t) {
    final payeeName = payeesById[t.payeeId]?.name ?? 'inconnu';
    final categoryName = categoryFullPath(t.categoryId, categoriesById);
    final categoryPart = categoryName.isEmpty ? '' : ' ($categoryName)';
    final dateText = DateFormat('d MMM yyyy', 'fr_FR').format(t.date);
    return '${money(t.amount)} - $payeeName$categoryPart le $dateText';
  }).join('\n');
}

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
        final lines = _transactionLines(answer.transactions ?? const [], categoriesById, payeesById, money);
        final detail = lines.isEmpty ? '' : '\n$lines';
        return 'Dépenses en ${name.isEmpty ? "cette catégorie" : name} pour '
            '${intent.period.label}$accountNote : ${money(total)}.$detail$periodNote';
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
      final breakdown = answer.categoryBreakdown ?? const {};
      final sorted = breakdown.entries.where((e) => e.value > 0).toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      if (sorted.isEmpty) {
        return 'Aucune dépense trouvée pour ${intent.period.label}$accountNote.$periodNote';
      }
      final lines =
          sorted.map((e) => '${money(e.value)} - ${categoryFullPath(e.key, categoriesById)}').join('\n');
      return 'Plus grosses dépenses (par catégorie) pour ${intent.period.label}$accountNote :\n'
          '$lines$periodNote';

    case QueryKind.payeeSpend:
      final name = payeesById[intent.payeeId]?.name ?? 'ce tiers';
      final lines = _transactionLines(answer.transactions ?? const [], categoriesById, payeesById, money);
      final detail = lines.isEmpty ? '' : '\n$lines';
      return 'Dépenses chez $name pour ${intent.period.label}$accountNote : '
          '${money(answer.total ?? 0)}.$detail$periodNote';

    case QueryKind.outlook:
      final current = answer.total ?? 0;
      final forecast = answer.forecastTotal ?? current;
      final periodEndLabel = DateFormat('d MMMM yyyy', 'fr_FR')
          .format(intent.period.end.subtract(const Duration(days: 1)));
      final breakdown = answer.categoryBreakdown ?? const {};
      final parts = breakdown.entries
          .map((e) => '${categoryFullPath(e.key, categoriesById)} (${money(e.value)})')
          .join(', ');
      final explanation = parts.isEmpty
          ? "Aucune facture récurrente connue ne l'explique - regarde les opérations déjà "
              'enregistrées pour cette période dans le grand livre.'
          : 'Principales dépenses récurrentes prévues d\'ici là : $parts.';

      if (current < 0) {
        final detail = parts.isEmpty
            ? ''
            : ' Les prochaines grosses dépenses récurrentes prévues d\'ici le '
                '$periodEndLabel : $parts.';
        return "Ton solde$accountNote est déjà négatif aujourd'hui : ${money(current)} "
            '(prévision au $periodEndLabel : ${money(forecast)}).$detail$periodNote';
      }

      if (forecast >= 0) {
        return 'Ton solde$accountNote ne devrait pas passer en négatif d\'ici le '
            '$periodEndLabel : prévision ${money(forecast)} (contre ${money(current)} '
            "aujourd'hui).$periodNote";
      }

      final crossesOn = answer.forecastCrossesNegativeOn;
      final crossesNote = crossesOn != null
          ? ' à partir du ${DateFormat('d MMMM', 'fr_FR').format(crossesOn)}'
          : '';
      return 'Ton solde$accountNote devrait passer en négatif$crossesNote : autour de '
          '${money(forecast)} au $periodEndLabel (contre ${money(current)} aujourd\'hui). '
          '$explanation$periodNote';
  }
}
