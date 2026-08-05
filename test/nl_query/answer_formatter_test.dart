import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:money_manager/models/account.dart';
import 'package:money_manager/models/category.dart';
import 'package:money_manager/models/currency.dart';
import 'package:money_manager/models/payee.dart';
import 'package:money_manager/models/transaction.dart';
import 'package:money_manager/services/nl_query/answer_formatter.dart';
import 'package:money_manager/services/nl_query/query_executor.dart';
import 'package:money_manager/services/nl_query/query_intent.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('fr_FR');
  });

  const currency = CurrencyFormat(
    id: 1,
    name: 'Euro',
    prefixSymbol: '',
    suffixSymbol: ' €',
    decimalPoint: ',',
    groupSeparator: ' ',
  );

  const alimentation = Category(id: 1, name: 'Alimentation', active: true);
  const restaurant = Category(id: 2, name: 'Restaurant', active: true, parentId: 1);
  const categories = [alimentation, restaurant];

  const compteCourant = Account(
    id: 10,
    name: 'Compte Courant',
    type: 'Checking',
    status: 'Open',
    initialBalance: 0,
    currencyId: 1,
    favorite: true,
  );
  const accounts = [compteCourant];

  const carrefour = Payee(id: 20, name: 'Carrefour', active: true);
  const payees = [carrefour];

  final july = DateRange(
      start: DateTime(2026, 7, 1), end: DateTime(2026, 8, 1), label: 'Juillet 2026');

  String format(QueryIntent intent, QueryAnswer answer, {bool periodWasExplicit = true}) =>
      formatAnswer(
        intent,
        answer,
        periodWasExplicit: periodWasExplicit,
        categories: categories,
        accounts: accounts,
        payees: payees,
        currency: currency,
      );

  test('expenseTotal without a category mentions the breakdown', () {
    final text = format(
      QueryIntent(kind: QueryKind.expenseTotal, period: july),
      const QueryAnswer(total: 65, categoryBreakdown: {1: 40, 2: 25}),
    );
    expect(text, contains('65,00 €'));
    expect(text, contains('Alimentation'));
    expect(text, contains('Restaurant'));
  });

  test('expenseTotal for a specific category names it, not a generic breakdown', () {
    final text = format(
      QueryIntent(kind: QueryKind.expenseTotal, period: july, categoryId: restaurant.id),
      const QueryAnswer(total: 25),
    );
    expect(text, contains('Restaurant'));
    expect(text, contains('25,00 €'));
  });

  test('expenseTotal for a specific category lists the transactions behind the total', () {
    final text = format(
      QueryIntent(kind: QueryKind.expenseTotal, period: july, categoryId: restaurant.id),
      QueryAnswer(total: 25, transactions: [
        MoneyTransaction(
          id: 1,
          accountId: compteCourant.id,
          payeeId: carrefour.id,
          transCode: TransCode.withdrawal,
          amount: 25,
          toAmount: 25,
          status: '',
          categoryId: restaurant.id,
          date: DateTime(2026, 7, 10),
        ),
      ]),
    );
    expect(text, contains('25,00 €'));
    expect(text, contains('Carrefour'));
    expect(text, contains('10 juil. 2026'));
  });

  test('a defaulted (non-explicit) period is called out in the answer', () {
    final text = format(
      QueryIntent(kind: QueryKind.expenseTotal, period: july),
      const QueryAnswer(total: 0),
      periodWasExplicit: false,
    );
    expect(text, contains('aucune période reconnue'));
  });

  test('an explicit period is not called out', () {
    final text = format(
      QueryIntent(kind: QueryKind.expenseTotal, period: july),
      const QueryAnswer(total: 0),
      periodWasExplicit: true,
    );
    expect(text, isNot(contains('aucune période reconnue')));
  });

  test('incomeVsExpense states the net as a surplus when income exceeds expense', () {
    final text = format(
      QueryIntent(kind: QueryKind.incomeVsExpense, period: july),
      const QueryAnswer(income: 1500, expense: 65),
    );
    expect(text, contains('excédent'));
    expect(text, contains('1 435,00 €'));
  });

  test('incomeVsExpense states the net as a deficit when expense exceeds income', () {
    final text = format(
      QueryIntent(kind: QueryKind.incomeVsExpense, period: july),
      const QueryAnswer(income: 100, expense: 300),
    );
    expect(text, contains('déficit'));
  });

  test('balance names the account and the as-of date when one was given', () {
    final text = format(
      QueryIntent(
          kind: QueryKind.balance,
          period: july,
          accountId: compteCourant.id,
          asOf: DateTime(2026, 7, 31)),
      const QueryAnswer(total: 2435),
    );
    expect(text, contains('Compte Courant'));
    expect(text, contains('31 juillet 2026'));
    expect(text, contains('2 435,00 €'));
  });

  test('balance with no as-of date says "aujourd\'hui" instead of a date', () {
    final text = format(
      QueryIntent(kind: QueryKind.balance, period: july, accountId: compteCourant.id),
      const QueryAnswer(total: 1000),
    );
    expect(text, contains("aujourd'hui"));
  });

  test('payeeSpend names the payee', () {
    final text = format(
      QueryIntent(kind: QueryKind.payeeSpend, period: july, payeeId: carrefour.id),
      const QueryAnswer(total: 65),
    );
    expect(text, contains('Carrefour'));
    expect(text, contains('65,00 €'));
  });

  test('payeeSpend lists the transactions behind the total', () {
    final text = format(
      QueryIntent(kind: QueryKind.payeeSpend, period: july, payeeId: carrefour.id),
      QueryAnswer(total: 65, transactions: [
        MoneyTransaction(
          id: 1,
          accountId: compteCourant.id,
          payeeId: carrefour.id,
          transCode: TransCode.withdrawal,
          amount: 40,
          toAmount: 40,
          status: '',
          categoryId: alimentation.id,
          date: DateTime(2026, 7, 5),
        ),
        MoneyTransaction(
          id: 2,
          accountId: compteCourant.id,
          payeeId: carrefour.id,
          transCode: TransCode.withdrawal,
          amount: 25,
          toAmount: 25,
          status: '',
          categoryId: restaurant.id,
          date: DateTime(2026, 7, 10),
        ),
      ]),
    );
    expect(text, contains('40,00 €'));
    expect(text, contains('Alimentation'));
    expect(text, contains('25,00 €'));
    expect(text, contains('Restaurant'));
  });

  test('each transaction behind a total gets its own bulleted line', () {
    final text = format(
      QueryIntent(kind: QueryKind.payeeSpend, period: july, payeeId: carrefour.id),
      QueryAnswer(total: 65, transactions: [
        MoneyTransaction(
          id: 1,
          accountId: compteCourant.id,
          payeeId: carrefour.id,
          transCode: TransCode.withdrawal,
          amount: 40,
          toAmount: 40,
          status: '',
          categoryId: alimentation.id,
          date: DateTime(2026, 7, 5),
        ),
        MoneyTransaction(
          id: 2,
          accountId: compteCourant.id,
          payeeId: carrefour.id,
          transCode: TransCode.withdrawal,
          amount: 25,
          toAmount: 25,
          status: '',
          categoryId: restaurant.id,
          date: DateTime(2026, 7, 10),
        ),
      ]),
    );
    final bulletLines = text.split('\n').where((l) => l.startsWith('• ')).toList();
    expect(bulletLines, hasLength(2));
    expect(bulletLines[0], '• 40,00 € - Carrefour (Alimentation) le 5 juil. 2026');
    expect(bulletLines[1], '• 25,00 € - Carrefour (Alimentation:Restaurant) le 10 juil. 2026');
  });

  test('expenseByMonth lists one bulleted line per month, oldest first', () {
    final text = format(
      QueryIntent(
        kind: QueryKind.expenseByMonth,
        period: DateRange(start: DateTime(2026, 6, 1), end: DateTime(2026, 8, 1), label: 'test'),
        categoryId: alimentation.id,
      ),
      QueryAnswer(monthlyBreakdown: {DateTime(2026, 7): 65, DateTime(2026, 6): 0}),
    );
    final bulletLines = text.split('\n').where((l) => l.startsWith('• ')).toList();
    expect(bulletLines, ['• Juin 2026 : 0,00 €', '• Juillet 2026 : 65,00 €']);
    expect(text, contains('Alimentation'));
  });

  test('expenseByMonth with no results says so rather than an empty list', () {
    final text = format(
      QueryIntent(kind: QueryKind.expenseByMonth, period: july),
      const QueryAnswer(monthlyBreakdown: {}),
    );
    expect(text, contains('Aucune dépense trouvée'));
  });

  test('topExpenses with no results says so rather than an empty list', () {
    final text = format(
      QueryIntent(kind: QueryKind.topExpenses, period: july),
      const QueryAnswer(categoryBreakdown: {}),
    );
    expect(text, contains('Aucune dépense trouvée'));
  });

  test('topExpenses ranks categories by total, biggest first', () {
    final text = format(
      QueryIntent(kind: QueryKind.topExpenses, period: july),
      const QueryAnswer(categoryBreakdown: {2: 25, 1: 40}),
    );
    final alimentationIndex = text.indexOf('Alimentation');
    final restaurantIndex = text.indexOf('Restaurant');
    expect(alimentationIndex, greaterThanOrEqualTo(0));
    expect(restaurantIndex, greaterThanOrEqualTo(0));
    expect(alimentationIndex, lessThan(restaurantIndex));
    expect(text, contains('40,00 €'));
    expect(text, contains('25,00 €'));
  });

  test('outlook staying positive reassures rather than warning', () {
    final text = format(
      QueryIntent(kind: QueryKind.outlook, period: july),
      const QueryAnswer(total: 500, forecastTotal: 350),
    );
    expect(text, contains('ne devrait pas passer en négatif'));
    expect(text, contains('350,00 €'));
    expect(text, contains('500,00 €'));
  });

  test('outlook going negative names the crossing date and the biggest recurring cause', () {
    final text = format(
      QueryIntent(kind: QueryKind.outlook, period: july),
      QueryAnswer(
        total: 100,
        forecastTotal: -200,
        forecastCrossesNegativeOn: DateTime(2026, 7, 15),
        categoryBreakdown: const {1: -300},
      ),
    );
    expect(text, contains('devrait passer en négatif'));
    expect(text, contains('15 juillet'));
    expect(text, contains('-200,00 €'));
    expect(text, contains('Alimentation'));
    expect(text, contains('-300,00 €'));
  });

  test('outlook going negative with no recurring cause found points at the ledger instead', () {
    final text = format(
      QueryIntent(kind: QueryKind.outlook, period: july),
      const QueryAnswer(total: 100, forecastTotal: -50, categoryBreakdown: {}),
    );
    expect(text, contains('devrait passer en négatif'));
    expect(text, contains("Aucune facture récurrente connue ne l'explique"));
  });

  test('outlook already negative today says so, distinctly from a future crossing', () {
    final text = format(
      QueryIntent(kind: QueryKind.outlook, period: july),
      const QueryAnswer(total: -50, forecastTotal: -80, categoryBreakdown: {1: -30}),
    );
    expect(text, contains('est déjà négatif'));
    expect(text, contains('-50,00 €'));
    expect(text, contains('-80,00 €'));
  });
}
