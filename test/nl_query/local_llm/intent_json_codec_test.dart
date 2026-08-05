import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:money_manager/models/account.dart';
import 'package:money_manager/models/category.dart';
import 'package:money_manager/models/payee.dart';
import 'package:money_manager/services/nl_query/local_llm/intent_json_codec.dart';
import 'package:money_manager/services/nl_query/query_intent.dart';

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
  const accounts = [compteCourant];

  const carrefour = Payee(id: 20, name: 'Carrefour', active: true);
  const payees = [carrefour];

  ({QueryIntent? intent, bool periodWasExplicit}) decode(String rawResponse) => decodeIntentJson(
        rawResponse,
        categories: categories,
        accounts: accounts,
        payees: payees,
        now: now,
      );

  test('valid adHoc JSON with a recognized period decodes correctly', () {
    final result = decode('{"kind":"adHoc","period":"juillet","category":null,"account":null,'
        '"payee":null,"topN":null,"metric":"sum","transactionType":"withdrawal","groupBy":"none",'
        '"recurringOnly":false}');
    expect(result.intent!.kind, QueryKind.adHoc);
    expect(result.periodWasExplicit, isTrue);
    expect(result.intent!.period.start, DateTime(2026, 7, 1));
    expect(result.intent!.adHocMetric, AdHocMetric.sum);
    expect(result.intent!.adHocTransactionType, AdHocTransactionType.withdrawal);
    expect(result.intent!.adHocGroupBy, AdHocGroupBy.none);
    expect(result.intent!.recurringOnly, isFalse);
    expect(result.intent!.adHocLimit, isNull);
  });

  test('category/account/payee names are resolved against the real lists, not trusted verbatim',
      () {
    final result = decode('{"kind":"adHoc","period":null,"category":"restaurant",'
        '"account":"compte courant","metric":"sum","transactionType":"withdrawal","groupBy":"none"}');
    expect(result.intent!.categoryId, restaurant.id);
    expect(result.intent!.accountId, compteCourant.id);
    expect(result.periodWasExplicit, isFalse);
  });

  test('a category name the model invents that matches nothing real fails closed, not a guess', () {
    final result = decode('{"kind":"adHoc","category":"un_nom_qui_nexiste_pas",'
        '"metric":"sum","transactionType":"withdrawal","groupBy":"none"}');
    // Unlike a plain omission, a *named-but-unresolved* filter must not
    // silently answer a broader question than what was asked - see
    // decodeIntentJson's namedButUnresolved.
    expect(result.intent, isNull);
  });

  test('an unmentioned category/account/payee (null, not a bad name) is simply absent, not a failure',
      () {
    final result = decode(
        '{"kind":"adHoc","metric":"sum","transactionType":"withdrawal","groupBy":"none"}');
    expect(result.intent, isNotNull);
    expect(result.intent!.categoryId, isNull);
    expect(result.intent!.accountId, isNull);
    expect(result.intent!.payeeId, isNull);
  });

  test('stray text around the JSON object is tolerated', () {
    final result = decode('Voici le résultat :\n{"kind":"balance"}\nFin.');
    expect(result.intent!.kind, QueryKind.balance);
  });

  test('invalid JSON returns a null intent, not a crash', () {
    final result = decode('ceci ne ressemble pas a du json');
    expect(result.intent, isNull);
  });

  test('an unrecognized "kind" value returns a null intent', () {
    final result = decode('{"kind":"somethingMadeUp"}');
    expect(result.intent, isNull);
  });

  test('every retired kind string decodes to null - the model is no longer taught these', () {
    for (final retired in [
      'expenseTotal',
      'incomeTotal',
      'topExpenses',
      'payeeSpend',
      'expenseByMonth',
    ]) {
      final result = decode('{"kind":"$retired"}');
      expect(result.intent, isNull, reason: retired);
    }
  });

  test('adHoc requires metric/transactionType/groupBy - missing or garbage fails closed', () {
    expect(decode('{"kind":"adHoc","transactionType":"withdrawal","groupBy":"none"}').intent, isNull);
    expect(decode('{"kind":"adHoc","metric":"sum","groupBy":"none"}').intent, isNull);
    expect(decode('{"kind":"adHoc","metric":"sum","transactionType":"withdrawal"}').intent, isNull);
    expect(
        decode('{"kind":"adHoc","metric":"invalide","transactionType":"withdrawal","groupBy":"none"}')
            .intent,
        isNull);
  });

  test('adHoc with a payee that resolves works normally', () {
    final result = decode(
        '{"kind":"adHoc","payee":"Carrefour","metric":"sum","transactionType":"withdrawal","groupBy":"none"}');
    expect(result.intent!.kind, QueryKind.adHoc);
    expect(result.intent!.payeeId, carrefour.id);
  });

  test('adHocLimit reads from "topN" but - unlike the shared topN field - never defaults to 5', () {
    final withLimit = decode(
        '{"kind":"adHoc","topN":10,"metric":"sum","transactionType":"withdrawal","groupBy":"category"}');
    expect(withLimit.intent!.adHocLimit, 10);
    final withoutLimit = decode(
        '{"kind":"adHoc","metric":"sum","transactionType":"withdrawal","groupBy":"category"}');
    expect(withoutLimit.intent!.adHocLimit, isNull);
  });

  test('recurringOnly defaults to false when absent, true only when explicitly true', () {
    expect(
        decode('{"kind":"adHoc","metric":"sum","transactionType":"withdrawal","groupBy":"none"}')
            .intent!
            .recurringOnly,
        isFalse);
    expect(
        decode('{"kind":"adHoc","metric":"sum","transactionType":"withdrawal","groupBy":"none",'
                '"recurringOnly":true}')
            .intent!
            .recurringOnly,
        isTrue);
  });

  test('balance with an explicit period sets asOf to the end of that period', () {
    final result = decode('{"kind":"balance","period":"juillet","account":"Compte Courant"}');
    expect(result.intent!.asOf, DateTime(2026, 7, 31));
  });

  test('outlook decodes like any other recognized kind', () {
    final result = decode('{"kind":"outlook"}');
    expect(result.intent!.kind, QueryKind.outlook);
  });

  test('incomeVsExpense decodes like any other recognized kind', () {
    final result = decode('{"kind":"incomeVsExpense"}');
    expect(result.intent!.kind, QueryKind.incomeVsExpense);
  });
}
