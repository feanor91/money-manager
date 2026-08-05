import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:money_manager/models/account.dart';
import 'package:money_manager/models/category.dart';
import 'package:money_manager/models/payee.dart';
import 'package:money_manager/services/nl_query/query_intent.dart';
import 'package:money_manager/services/nl_query/rule_based_query_parser.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('fr_FR');
  });

  final now = DateTime(2026, 8, 5, 10);

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
  const livretA = Account(
    id: 11,
    name: 'Livret A',
    type: 'Savings',
    status: 'Open',
    initialBalance: 0,
    currencyId: 1,
    favorite: false,
  );
  const accounts = [compteCourant, livretA];

  const carrefour = Payee(id: 20, name: 'Carrefour', active: true);
  const payees = [carrefour];

  ({QueryIntent? intent, bool periodWasExplicit}) parse(String question) => parseQuestion(
        question,
        categories: categories,
        accounts: accounts,
        payees: payees,
        now: now,
      );

  test('unrecognized question returns a null intent', () {
    final result = parse('quelle heure est-il ?');
    expect(result.intent, isNull);
  });

  test('generic expense question -> expenseTotal, no category, current month default', () {
    final result = parse('quelles ont été mes dépenses ce mois-ci ?');
    expect(result.intent!.kind, QueryKind.expenseTotal);
    expect(result.intent!.categoryId, isNull);
    expect(result.periodWasExplicit, isTrue);
  });

  test('expense question with no period at all falls back to current month, flagged', () {
    final result = parse('quelles ont été mes dépenses ?');
    expect(result.intent!.kind, QueryKind.expenseTotal);
    expect(result.periodWasExplicit, isFalse);
    expect(result.intent!.period.label, 'Août 2026');
  });

  test('expense question naming a subcategory resolves its id', () {
    final result = parse('combien ai-je dépensé en restaurant le mois dernier ?');
    expect(result.intent!.kind, QueryKind.expenseTotal);
    expect(result.intent!.categoryId, restaurant.id);
  });

  test('expense question naming the parent category resolves the parent id', () {
    final result = parse('mes dépenses en alimentation cette année');
    expect(result.intent!.kind, QueryKind.expenseTotal);
    expect(result.intent!.categoryId, alimentation.id);
  });

  test('"transaction"/"operation"/"achat" are recognized as expense synonyms', () {
    for (final phrase in [
      'la somme des transactions le mois dernier',
      'total de mes opérations ce mois-ci',
      'mes achats du mois dernier',
    ]) {
      expect(parse(phrase).intent!.kind, QueryKind.expenseTotal, reason: phrase);
    }
  });

  test('"dépenses récurrentes" sets recurringOnly', () {
    final plain = parse('mes dépenses ce mois-ci');
    expect(plain.intent!.recurringOnly, isFalse);
    final recurring = parse('total de mes dépenses récurrentes ce mois-ci');
    expect(recurring.intent!.kind, QueryKind.expenseTotal);
    expect(recurring.intent!.recurringOnly, isTrue);
  });

  test('"par mois" -> expenseByMonth, with the named category if any', () {
    final withCategory = parse("mes dépenses en alimentation par mois depuis le début de l'année");
    expect(withCategory.intent!.kind, QueryKind.expenseByMonth);
    expect(withCategory.intent!.categoryId, alimentation.id);

    final withoutCategory = parse('mes dépenses par mois cette année');
    expect(withoutCategory.intent!.kind, QueryKind.expenseByMonth);
    expect(withoutCategory.intent!.categoryId, isNull);
  });

  test('account name is resolved and attached regardless of query kind', () {
    final result = parse('mes dépenses sur mon Compte Courant ce mois-ci');
    expect(result.intent!.accountId, compteCourant.id);
  });

  test('income question -> incomeTotal', () {
    final result = parse('combien j\'ai touché en revenus ce mois-ci ?');
    expect(result.intent!.kind, QueryKind.incomeTotal);
  });

  test('income and expense both mentioned -> incomeVsExpense', () {
    final result = parse('mes revenus et mes dépenses de ce mois-ci');
    expect(result.intent!.kind, QueryKind.incomeVsExpense);
  });

  test('solde + account name -> balance with resolved account', () {
    final result = parse('quel est le solde de mon Livret A ?');
    expect(result.intent!.kind, QueryKind.balance);
    expect(result.intent!.accountId, livretA.id);
  });

  test('solde with an explicit period -> asOf set to the end of that period', () {
    final result = parse('quel était le solde de mon Livret A en juillet ?');
    expect(result.intent!.kind, QueryKind.balance);
    expect(result.intent!.asOf, DateTime(2026, 7, 31));
  });

  test('solde with no period at all -> asOf left null (executor defaults to now)', () {
    final result = parse('quel est le solde de mon Livret A ?');
    expect(result.intent!.asOf, isNull);
  });

  test('"chez X" -> payeeSpend with resolved payee', () {
    final result = parse('combien j\'ai dépensé chez Carrefour ce mois-ci ?');
    expect(result.intent!.kind, QueryKind.payeeSpend);
    expect(result.intent!.payeeId, carrefour.id);
  });

  test('top expenses phrasing -> topExpenses with default count', () {
    final result = parse('mes plus grosses dépenses du mois dernier');
    expect(result.intent!.kind, QueryKind.topExpenses);
    expect(result.intent!.topN, 5);
  });

  test('top N expenses phrasing picks up the requested count', () {
    final result = parse('top 10 dépenses de ce mois');
    expect(result.intent!.kind, QueryKind.topExpenses);
    expect(result.intent!.topN, 10);
  });

  test('"pourquoi ... negatif" -> outlook, current month default', () {
    final result = parse('pourquoi vais-je finir le mois en négatif ?');
    expect(result.intent!.kind, QueryKind.outlook);
    expect(result.periodWasExplicit, isFalse);
    expect(result.intent!.period.label, 'Août 2026');
  });

  test('"vais-je finir en negatif" without "pourquoi" still -> outlook', () {
    final result = parse('vais-je finir en négatif ce mois-ci ?');
    expect(result.intent!.kind, QueryKind.outlook);
    expect(result.periodWasExplicit, isTrue);
  });

  test('"a decouvert" phrasing -> outlook too', () {
    final result = parse('vais-je être à découvert ce mois-ci ?');
    expect(result.intent!.kind, QueryKind.outlook);
  });

  test('outlook question naming an account resolves it, like every other kind', () {
    final result = parse('pourquoi vais-je finir en négatif sur mon Livret A ?');
    expect(result.intent!.kind, QueryKind.outlook);
    expect(result.intent!.accountId, livretA.id);
  });
}
