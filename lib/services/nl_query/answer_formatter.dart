import 'package:intl/intl.dart';

import '../../models/account.dart';
import '../../models/category.dart';
import '../../models/currency.dart';
import '../../models/payee.dart';
import '../../models/transaction.dart';
import 'query_executor.dart';
import 'query_intent.dart';

/// "• Alimentation (120,00 €)" per item, one per line, newline-joined - the
/// leading bullet is what visually separates one item from the next in the
/// dialog's plain Text widget (nl_query_dialog.dart), which otherwise has
/// nothing but the newline itself to mark a new line. Shared by every list-
/// shaped piece of an answer (category breakdowns, transaction detail) so
/// they all read the same way instead of some being a comma-separated
/// run-on and others a bulleted list.
String _bulletLines(Iterable<String> items) => items.map((i) => '• $i').join('\n');

/// "42,00 € - Carrefour (Alimentation:Courses) le 3 juil. 2026" per
/// transaction, biggest first - the detail behind an otherwise-bare total
/// (see [QueryAnswer.transactions]).
String _transactionLines(
  List<MoneyTransaction> transactions,
  Map<int, Category> categoriesById,
  Map<int, Payee> payeesById,
  String Function(double) money,
) {
  return _bulletLines(transactions.map((t) {
    final payeeName = payeesById[t.payeeId]?.name ?? 'inconnu';
    final categoryName = categoryFullPath(t.categoryId, categoriesById);
    final categoryPart = categoryName.isEmpty ? '' : ' ($categoryName)';
    final dateText = DateFormat('d MMM yyyy', 'fr_FR').format(t.date);
    return '${money(t.amount)} - $payeeName$categoryPart le $dateText';
  }));
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
      final expenseLabel = intent.recurringOnly ? 'Dépenses récurrentes' : 'Dépenses';
      if (intent.categoryId != null) {
        final name = categoryFullPath(intent.categoryId, categoriesById);
        final lines = _transactionLines(answer.transactions ?? const [], categoriesById, payeesById, money);
        final detail = lines.isEmpty ? '' : '\n$lines';
        return '$expenseLabel en ${name.isEmpty ? "cette catégorie" : name} pour '
            '${intent.period.label}$accountNote : ${money(total)}.$detail$periodNote';
      }
      final breakdown = answer.categoryBreakdown ?? const {};
      final lines = _bulletLines(breakdown.entries
          .where((e) => e.value > 0)
          .map((e) => '${categoryFullPath(e.key, categoriesById)} (${money(e.value)})'));
      final detail = lines.isEmpty ? '' : '\nPrincipalement :\n$lines';
      final totalLabel = intent.recurringOnly ? 'Dépenses récurrentes totales' : 'Dépenses totales';
      return '$totalLabel pour ${intent.period.label}$accountNote : '
          '${money(total)}.$detail$periodNote';

    case QueryKind.expenseByMonth:
      final monthly = answer.monthlyBreakdown ?? const {};
      final months = monthly.keys.toList()..sort();
      if (months.isEmpty) {
        return 'Aucune dépense trouvée pour ${intent.period.label}$accountNote.$periodNote';
      }
      final monthFormat = DateFormat('MMMM yyyy', 'fr_FR');
      final lines = _bulletLines(months.map((m) {
        final label = monthFormat.format(m);
        return '${label[0].toUpperCase()}${label.substring(1)} : ${money(monthly[m]!)}';
      }));
      final categoryName =
          intent.categoryId != null ? categoryFullPath(intent.categoryId, categoriesById) : '';
      final subject = categoryName.isEmpty ? 'Dépenses' : 'Dépenses en $categoryName';
      return '$subject par mois$accountNote (${intent.period.label}) :\n$lines$periodNote';

    case QueryKind.adHoc:
      final metric = intent.adHocMetric ?? AdHocMetric.sum;
      final type = intent.adHocTransactionType ?? AdHocTransactionType.withdrawal;
      final groupBy = intent.adHocGroupBy ?? AdHocGroupBy.none;
      final results = answer.adHocResult ?? const [];

      String valueText(double v) => metric == AdHocMetric.count ? v.round().toString() : money(v);
      final metricWord = switch (metric) {
        AdHocMetric.sum => 'Total',
        AdHocMetric.count => 'Nombre',
        AdHocMetric.average => 'Moyenne',
      };
      final typeLabel = switch (type) {
        AdHocTransactionType.withdrawal => 'dépenses',
        AdHocTransactionType.deposit => 'revenus',
        AdHocTransactionType.transfer => 'virements',
        AdHocTransactionType.any => 'opérations',
      };
      final categoryName = intent.categoryId != null ? categoryFullPath(intent.categoryId, categoriesById) : '';
      final subject = '$typeLabel'
          '${intent.recurringOnly ? " récurrentes" : ""}'
          '${categoryName.isEmpty ? "" : " en $categoryName"}'
          '${intent.payeeId != null ? " chez ${payeesById[intent.payeeId]?.name ?? "ce tiers"}" : ""}';

      if (groupBy == AdHocGroupBy.none) {
        final value = results.isNotEmpty ? results.first.value : 0.0;
        return '$metricWord des $subject pour ${intent.period.label}$accountNote : '
            '${valueText(value)}.$periodNote';
      }
      if (results.isEmpty) {
        return 'Aucune donnée trouvée pour $subject sur ${intent.period.label}$accountNote.$periodNote';
      }
      final groupWord = switch (groupBy) {
        AdHocGroupBy.category => 'par catégorie',
        AdHocGroupBy.payee => 'par tiers',
        AdHocGroupBy.account => 'par compte',
        AdHocGroupBy.month => 'par mois',
        AdHocGroupBy.none => '',
      };
      final adHocLines = _bulletLines(results.map((e) => '${e.key} (${valueText(e.value)})'));
      return '$metricWord des $subject $groupWord pour ${intent.period.label}$accountNote :\n'
          '$adHocLines$periodNote';

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

    case QueryKind.balanceByMonth:
      final monthly = answer.monthlyBreakdown ?? const {};
      final months = monthly.keys.toList()..sort();
      final accountName = accountsById[intent.accountId]?.name ?? 'ce compte';
      if (months.isEmpty) {
        return 'Aucune donnée trouvée pour $accountName sur ${intent.period.label}.$periodNote';
      }
      final monthFormat = DateFormat('MMMM yyyy', 'fr_FR');
      final dayNote =
          intent.balanceDay != null ? ' au ${intent.balanceDay}' : ' en fin de mois';
      final lines = _bulletLines(months.map((m) {
        final label = monthFormat.format(m);
        return '${label[0].toUpperCase()}${label.substring(1)} : ${money(monthly[m]!)}';
      }));
      return 'Solde de $accountName$dayNote, mois par mois (${intent.period.label}) :\n'
          '$lines$periodNote';

    case QueryKind.topExpenses:
      final breakdown = answer.categoryBreakdown ?? const {};
      final sorted = breakdown.entries.where((e) => e.value > 0).toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      if (sorted.isEmpty) {
        return 'Aucune dépense trouvée pour ${intent.period.label}$accountNote.$periodNote';
      }
      final lines = _bulletLines(
          sorted.map((e) => '${money(e.value)} - ${categoryFullPath(e.key, categoriesById)}'));
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
      final breakdownLines = _bulletLines(
          breakdown.entries.map((e) => '${categoryFullPath(e.key, categoriesById)} (${money(e.value)})'));
      final explanation = breakdownLines.isEmpty
          ? "Aucune facture récurrente connue ne l'explique - regarde les opérations déjà "
              'enregistrées pour cette période dans le grand livre.'
          : 'Principales dépenses récurrentes prévues d\'ici là :\n$breakdownLines';

      if (current < 0) {
        final detail = breakdownLines.isEmpty
            ? ''
            : '\nLes prochaines grosses dépenses récurrentes prévues d\'ici le '
                '$periodEndLabel :\n$breakdownLines';
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
