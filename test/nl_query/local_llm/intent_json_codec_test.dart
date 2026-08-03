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

  test('valid JSON with a recognized kind and period decodes correctly', () {
    final result = decode('{"kind":"expenseTotal","period":"juillet","category":null,'
        '"account":null,"payee":null,"topN":null}');
    expect(result.intent!.kind, QueryKind.expenseTotal);
    expect(result.periodWasExplicit, isTrue);
    expect(result.intent!.period.start, DateTime(2026, 7, 1));
  });

  test('category/account/payee names are resolved against the real lists, not trusted verbatim',
      () {
    final result = decode(
        '{"kind":"expenseTotal","period":null,"category":"restaurant","account":"compte courant"}');
    expect(result.intent!.categoryId, restaurant.id);
    expect(result.intent!.accountId, compteCourant.id);
    expect(result.periodWasExplicit, isFalse);
  });

  test('a name the model invents that matches nothing real resolves to null, not a guess', () {
    final result = decode('{"kind":"expenseTotal","category":"un_nom_qui_nexiste_pas"}');
    expect(result.intent!.categoryId, isNull);
  });

  test('stray text around the JSON object is tolerated', () {
    final result = decode('Voici le résultat :\n{"kind":"incomeTotal"}\nFin.');
    expect(result.intent!.kind, QueryKind.incomeTotal);
  });

  test('invalid JSON returns a null intent, not a crash', () {
    final result = decode('ceci ne ressemble pas a du json');
    expect(result.intent, isNull);
  });

  test('an unrecognized "kind" value returns a null intent', () {
    final result = decode('{"kind":"somethingMadeUp"}');
    expect(result.intent, isNull);
  });

  test('payeeSpend without a payee that actually resolves returns a null intent', () {
    final result = decode('{"kind":"payeeSpend","payee":"un magasin inconnu"}');
    expect(result.intent, isNull);
  });

  test('payeeSpend with a payee that resolves works normally', () {
    final result = decode('{"kind":"payeeSpend","payee":"Carrefour"}');
    expect(result.intent!.kind, QueryKind.payeeSpend);
    expect(result.intent!.payeeId, carrefour.id);
  });

  test('balance with an explicit period sets asOf to the end of that period', () {
    final result = decode('{"kind":"balance","period":"juillet","account":"Compte Courant"}');
    expect(result.intent!.asOf, DateTime(2026, 7, 31));
  });

  test('outlook decodes like any other recognized kind', () {
    final result = decode('{"kind":"outlook"}');
    expect(result.intent!.kind, QueryKind.outlook);
  });

  test('topN as a string is parsed, defaulting to 5 if unparseable', () {
    expect(decode('{"kind":"topExpenses","topN":"10"}').intent!.topN, 10);
    expect(decode('{"kind":"topExpenses","topN":"not a number"}').intent!.topN, 5);
    expect(decode('{"kind":"topExpenses"}').intent!.topN, 5);
  });
}
