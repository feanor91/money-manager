import 'dart:convert';

import 'package:money_manager_core/models/recurrence.dart';
import 'package:money_manager_core/models/transaction.dart';
import 'package:money_manager_server/auth/pin_auth.dart';
import 'package:money_manager_server/auth/token_store.dart';
import 'package:money_manager_server/rpc_router.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  late Handler router;
  late TokenStore tokenStore;
  late int accountId;
  late int payeeId;
  late int categoryId;
  late int billId;

  setUp(() async {
    final repo = await openBlankTestRepo();
    accountId = repo.insertAccount(
        name: 'Compte Courant', type: 'Checking', initialBalance: 1000, currencyId: 2);
    payeeId = repo.insertPayee(name: 'Carrefour');
    categoryId = repo.insertCategory(name: 'Catégorie de test RPC'); // nom garanti absent du schéma vierge seedé
    repo.insertTransaction(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 42.5,
      date: DateTime(2026, 3, 15),
      categoryId: categoryId,
    );
    billId = repo.insertBillDeposit(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 15,
      nextOccurrence: DateTime(2026, 4, 1),
      period: RecurrencePeriod.monthly,
      autoExecute: RecurrenceAutoExecute.manual,
    );
    tokenStore = TokenStore();
    router = buildRouter(
      repo: repo,
      pinAuth: PinAuthenticator(pin: '1234'),
      tokenStore: tokenStore,
    ).call;
  });

  Request post(String path, {Map<String, dynamic>? body, String? token}) {
    return Request(
      'POST',
      Uri.parse('http://localhost$path'),
      body: body == null ? null : jsonEncode(body),
      headers: token == null ? null : {'authorization': 'Bearer $token'},
    );
  }

  group('CORS', () {
    test('every response carries Access-Control-Allow-Origin', () async {
      final response = await router(post('/auth/login', body: {'pin': '1234'}));
      expect(response.headers['Access-Control-Allow-Origin'], '*');
    });

    test('an OPTIONS preflight request succeeds without a token', () async {
      final response = await router(Request('OPTIONS', Uri.parse('http://localhost/rpc/getAccounts')));
      expect(response.statusCode, 200);
      expect(response.headers['Access-Control-Allow-Origin'], '*');
    });
  });

  group('POST /auth/login', () {
    test('correct pin returns a usable token', () async {
      final response = await router(post('/auth/login', body: {'pin': '1234'}));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(tokenStore.isValid(json['token'] as String), isTrue);
    });

    test('wrong pin is rejected with 401', () async {
      final response = await router(post('/auth/login', body: {'pin': '0000'}));
      expect(response.statusCode, 401);
    });
  });

  group('POST /rpc/getAccounts', () {
    test('rejects a request with no token', () async {
      final response = await router(post('/rpc/getAccounts'));
      expect(response.statusCode, 401);
    });

    test('rejects a request with an invalid token', () async {
      final response = await router(post('/rpc/getAccounts', token: 'faux-jeton'));
      expect(response.statusCode, 401);
    });

    test('returns the real accounts for a valid token', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/getAccounts', token: token));
      expect(response.statusCode, 200);
      final accounts = jsonDecode(await response.readAsString()) as List;
      expect(accounts, hasLength(1));
      expect(accounts.single['name'], 'Compte Courant');
      expect(accounts.single['initialBalance'], 1000);
    });
  });

  group('POST /rpc/getBaseCurrency', () {
    test('returns the base currency for a valid token', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/getBaseCurrency', token: token));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json['id'], isNotNull);
    });

    test('rejects a request with no token', () async {
      final response = await router(post('/rpc/getBaseCurrency'));
      expect(response.statusCode, 401);
    });
  });

  group('POST /rpc/accountBalance', () {
    test('returns the real balance (initial balance minus the withdrawal from setUp)', () async {
      final token = tokenStore.issue();
      final response = await router(
          post('/rpc/accountBalance', token: token, body: {'accountId': accountId}));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json['balance'], 1000 - 42.5);
    });

    test('accepts an explicit asOf date', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/accountBalance',
          token: token, body: {'accountId': accountId, 'asOf': '2020-01-01T00:00:00.000'}));
      expect(response.statusCode, 200);
    });
  });

  group('POST /rpc/getPayees', () {
    test('returns the real payees for a valid token', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/getPayees', token: token));
      expect(response.statusCode, 200);
      final payees = jsonDecode(await response.readAsString()) as List;
      expect(payees, hasLength(1));
      expect(payees.single['name'], 'Carrefour');
    });
  });

  group('POST /rpc/payeeUsageCount', () {
    test('returns 2 for the payee referenced by the transaction and bill from setUp', () async {
      final token = tokenStore.issue();
      final response =
          await router(post('/rpc/payeeUsageCount', token: token, body: {'payeeId': payeeId}));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json['count'], 2);
    });
  });

  group('POST /rpc/getCategories', () {
    test('returns the real categories for a valid token', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/getCategories', token: token));
      expect(response.statusCode, 200);
      final categories = jsonDecode(await response.readAsString()) as List;
      expect(categories.any((c) => c['name'] == 'Catégorie de test RPC'), isTrue);
    });
  });

  group('POST /rpc/categoryUsage', () {
    test('reflects the transaction from setUp referencing this category', () async {
      final token = tokenStore.issue();
      final response = await router(
          post('/rpc/categoryUsage', token: token, body: {'categoryId': categoryId}));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json['transactionCount'], 1);
      expect(json['childCategoryCount'], 0);
    });
  });

  group('POST /rpc/getTransactionsFiltered', () {
    test('returns matching transactions with no filters', () async {
      final token = tokenStore.issue();
      final response =
          await router(post('/rpc/getTransactionsFiltered', token: token, body: const {}));
      expect(response.statusCode, 200);
      final transactions = jsonDecode(await response.readAsString()) as List;
      expect(transactions, hasLength(1));
      expect(transactions.single['amount'], 42.5);
    });

    test('an unmatched year filter returns nothing', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/getTransactionsFiltered',
          token: token, body: {'years': [2099]}));
      expect(response.statusCode, 200);
      final transactions = jsonDecode(await response.readAsString()) as List;
      expect(transactions, isEmpty);
    });

    test('a matching category filter returns the transaction', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/getTransactionsFiltered',
          token: token, body: {'categoryIds': [categoryId]}));
      expect(response.statusCode, 200);
      final transactions = jsonDecode(await response.readAsString()) as List;
      expect(transactions, hasLength(1));
    });
  });

  group('POST /rpc/transactionYearRangeAll', () {
    test('returns the min/max year across all transactions', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/transactionYearRangeAll', token: token));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json['min'], 2026);
      expect(json['max'], 2026);
    });
  });

  group('POST /rpc/getBillDeposits', () {
    test('returns the real bill deposits for a valid token', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/getBillDeposits', token: token));
      expect(response.statusCode, 200);
      final bills = jsonDecode(await response.readAsString()) as List;
      expect(bills, hasLength(1));
      expect(bills.single['amount'], 15);
      expect(bills.single['period'], 'monthly');
    });
  });

  group('POST /rpc/billOccurrenceTotals', () {
    test('returns an empty map when no bill has a limited duration', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/billOccurrenceTotals', token: token));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json, isEmpty);
    });
  });

  group('POST /rpc/getBillAnnualIncrease', () {
    test('returns null when none is configured', () async {
      final token = tokenStore.issue();
      final response = await router(
          post('/rpc/getBillAnnualIncrease', token: token, body: {'billId': billId}));
      expect(response.statusCode, 200);
      expect(await response.readAsString(), 'null');
    });
  });

  group('POST /rpc/suggestedAnnualIncrease', () {
    test('returns null with fewer than 2 matching transactions on record', () async {
      final token = tokenStore.issue();
      final response = await router(
          post('/rpc/suggestedAnnualIncrease', token: token, body: {'billId': billId}));
      expect(response.statusCode, 200);
      expect(await response.readAsString(), 'null');
    });
  });

  group('POST /rpc/getTransactionsWithRunningBalance', () {
    test('returns the transaction with a running balance', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/getTransactionsWithRunningBalance',
          token: token, body: {'accountId': accountId}));
      expect(response.statusCode, 200);
      final rows = jsonDecode(await response.readAsString()) as List;
      expect(rows, hasLength(1));
      expect(rows.single['balanceAfter'], 1000 - 42.5);
    });
  });

  group('POST /rpc/transactionYearRange', () {
    test('returns the year range for the account', () async {
      final token = tokenStore.issue();
      final response = await router(
          post('/rpc/transactionYearRange', token: token, body: {'accountId': accountId}));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json['min'], 2026);
      expect(json['max'], 2026);
    });
  });

  group('POST /rpc/recurringTransactionIds', () {
    test('is empty when no transaction was auto-added from a recurring bill', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/recurringTransactionIds', token: token));
      expect(response.statusCode, 200);
      final ids = jsonDecode(await response.readAsString()) as List;
      expect(ids, isEmpty);
    });
  });

  group('POST /rpc/recurringTransactionOccurrences', () {
    test('is empty when no bill has a limited duration', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/recurringTransactionOccurrences', token: token));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json, isEmpty);
    });
  });

  group('POST /rpc/getBudgetEnvelopes', () {
    test('returns the real envelopes for this account', () async {
      final repo = await openBlankTestRepo();
      // Recréé ici plutôt que via setUp() : ce groupe a besoin d'une
      // enveloppe réelle, ce que openBlankTestRepo/setUp ne fournit pas.
      final localAccountId = repo.insertAccount(
          name: 'Compte Courant', type: 'Checking', initialBalance: 1000, currencyId: 2);
      final localCategoryId = repo.insertCategory(name: 'Loisirs test enveloppe');
      repo.upsertBudgetEnvelope(accountId: localAccountId, categoryId: localCategoryId, amount: 80);
      final localTokenStore = TokenStore();
      final localRouter = buildRouter(
        repo: repo,
        pinAuth: PinAuthenticator(pin: '1234'),
        tokenStore: localTokenStore,
      ).call;
      final token = localTokenStore.issue();
      final response = await localRouter(
          post('/rpc/getBudgetEnvelopes', token: token, body: {'accountId': localAccountId}));
      expect(response.statusCode, 200);
      final envelopes = jsonDecode(await response.readAsString()) as List;
      expect(envelopes, hasLength(1));
      expect(envelopes.single['amount'], 80);
      expect(envelopes.single['categoryId'], localCategoryId);
    });

    test('returns an empty list when the account has none', () async {
      final token = tokenStore.issue();
      final response = await router(
          post('/rpc/getBudgetEnvelopes', token: token, body: {'accountId': accountId}));
      expect(response.statusCode, 200);
      final envelopes = jsonDecode(await response.readAsString()) as List;
      expect(envelopes, isEmpty);
    });
  });

  group('POST /rpc/categoryMonthlyRecurringTotals', () {
    test('returns an empty map when no recurring bill has a category', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/categoryMonthlyRecurringTotals',
          token: token, body: {'accountId': accountId}));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json, isEmpty);
    });
  });

  group('POST /rpc/categorySpendForPeriod', () {
    test('reflects the transaction from setUp within the period', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/categorySpendForPeriod', token: token, body: {
        'start': '2026-03-01T00:00:00.000',
        'end': '2026-04-01T00:00:00.000',
        'accountId': accountId,
      }));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json['$categoryId'], 42.5);
    });

    test('an unmatched period returns nothing', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/categorySpendForPeriod', token: token, body: {
        'start': '2020-01-01T00:00:00.000',
        'end': '2020-02-01T00:00:00.000',
        'accountId': accountId,
      }));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json, isEmpty);
    });
  });

  group('POST /rpc/categoriesUsedByAccount', () {
    test('includes the category used by the transaction from setUp', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/categoriesUsedByAccount',
          token: token, body: {'accountId': accountId}));
      expect(response.statusCode, 200);
      final ids = (jsonDecode(await response.readAsString()) as List).cast<int>();
      expect(ids, contains(categoryId));
    });
  });

  group('POST /rpc/incomeForPeriod', () {
    test('is zero for a period with only a withdrawal', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/incomeForPeriod', token: token, body: {
        'start': '2026-03-01T00:00:00.000',
        'end': '2026-04-01T00:00:00.000',
        'accountId': accountId,
      }));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json['income'], 0);
    });
  });

  group('POST /rpc/expectedIncomeForBudget', () {
    test('is zero with no recurring deposit and no manual override', () async {
      final token = tokenStore.issue();
      final response = await router(
          post('/rpc/expectedIncomeForBudget', token: token, body: {'accountId': accountId}));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json['expected'], 0);
    });
  });

  group('POST /rpc/getTransactions', () {
    test('returns the transaction from setUp for its account', () async {
      final token = tokenStore.issue();
      final response = await router(
          post('/rpc/getTransactions', token: token, body: {'accountId': accountId}));
      expect(response.statusCode, 200);
      final transactions = jsonDecode(await response.readAsString()) as List;
      expect(transactions, hasLength(1));
      expect(transactions.single['amount'], 42.5);
    });

    test('respects the limit', () async {
      final token = tokenStore.issue();
      final response = await router(
          post('/rpc/getTransactions', token: token, body: {'accountId': accountId, 'limit': 0}));
      expect(response.statusCode, 200);
      final transactions = jsonDecode(await response.readAsString()) as List;
      expect(transactions, isEmpty);
    });
  });

  group('POST /rpc/forecastAccountBalance', () {
    test('returns a forecast balance for a future date', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/forecastAccountBalance', token: token, body: {
        'accountId': accountId,
        'targetDate': '2026-12-31T00:00:00.000',
      }));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json['balance'], isNotNull);
    });
  });

  group('POST /rpc/forecastNegativeDate', () {
    test('returns null for an account with a comfortably positive balance', () async {
      final token = tokenStore.issue();
      final response = await router(
          post('/rpc/forecastNegativeDate', token: token, body: {'accountId': accountId}));
      expect(response.statusCode, 200);
      expect(await response.readAsString(), 'null');
    });
  });

  group('POST /auth/logout', () {
    test('revokes the token used to call it', () async {
      final token = tokenStore.issue();
      final response = await router(post('/auth/logout', token: token));
      expect(response.statusCode, 200);
      expect(tokenStore.isValid(token), isFalse);
    });

    test('rejects a request with no token', () async {
      final response = await router(post('/auth/logout'));
      expect(response.statusCode, 401);
    });

    test('a revoked token can no longer call /rpc routes', () async {
      final token = tokenStore.issue();
      await router(post('/auth/logout', token: token));
      final response = await router(post('/rpc/getAccounts', token: token));
      expect(response.statusCode, 401);
    });
  });
}
