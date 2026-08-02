import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:money_manager/models/account.dart';
import 'package:money_manager/models/category.dart';
import 'package:money_manager/models/currency.dart';
import 'package:money_manager/models/payee.dart';
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

  test('topExpenses with no results says so rather than an empty list', () {
    final text = format(
      QueryIntent(kind: QueryKind.topExpenses, period: july),
      const QueryAnswer(transactions: []),
    );
    expect(text, contains('Aucune dépense trouvée'));
  });
}
