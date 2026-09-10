import 'dart:convert';

import 'package:money_manager_core/data/mmex_repository.dart';
import 'package:money_manager_core/models/account.dart';
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
  late MmexRepository repo;
  late int accountId;
  late int payeeId;
  late int categoryId;
  late int billId;

  setUp(() async {
    repo = await openBlankTestRepo();
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

  group('POST /rpc/dailyNetTotals', () {
    test('reflects the withdrawal from setUp on its own day', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/dailyNetTotals', token: token, body: {
        'anchor': '2026-03-15T00:00:00.000',
        'days': 1,
        'accountId': accountId,
      }));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json['2026-03-15T00:00:00.000'], -42.5);
    });
  });

  group('POST /rpc/futureDailyNet', () {
    test('is empty when nothing is recorded after the given date', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/futureDailyNet', token: token, body: {
        'after': '2026-03-15T00:00:00.000',
        'end': '2026-04-15T00:00:00.000',
        'accountId': accountId,
      }));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json.values.every((v) => v == 0), isTrue);
    });
  });

  group('POST /rpc/recurringDailyNet', () {
    test('reflects the monthly bill from setUp somewhere in the projection', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/recurringDailyNet', token: token, body: {
        'anchor': '2026-05-01T00:00:00.000',
        'days': 60,
        'accountId': accountId,
      }));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json.values.any((v) => v != 0), isTrue);
    });
  });

  group('POST /rpc/recurringOccurrencesInRange', () {
    test('returns the occurrence from the bill created in setUp', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/recurringOccurrencesInRange', token: token, body: {
        'start': '2026-04-01T00:00:00.000',
        'end': '2026-04-30T00:00:00.000',
        'accountId': accountId,
      }));
      expect(response.statusCode, 200);
      final occurrences = jsonDecode(await response.readAsString()) as List;
      expect(occurrences, hasLength(1));
      expect(occurrences.single['signedAmount'], -15);
    });
  });

  group('Écritures - Transactions', () {
    test('POST /rpc/insertTransaction creates a real transaction', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/insertTransaction', token: token, body: {
        'accountId': accountId,
        'payeeId': payeeId,
        'transCode': 'withdrawal',
        'amount': 12.5,
        'date': '2026-05-01T00:00:00.000',
        'categoryId': categoryId,
      }));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      final newId = json['id'] as int;
      final txns = repo.getTransactions(accountId: accountId);
      expect(txns.any((t) => t.id == newId && t.amount == 12.5), isTrue);
    });

    test('POST /rpc/updateTransaction updates the real transaction', () async {
      final token = tokenStore.issue();
      final tx = repo.getTransactions(accountId: accountId).single;
      final response = await router(post('/rpc/updateTransaction',
          token: token, body: tx.copyWith(amount: 99.99).toJson()));
      expect(response.statusCode, 200);
      expect(repo.getTransactions(accountId: accountId).single.amount, 99.99);
    });

    test('POST /rpc/deleteTransaction removes the real transaction', () async {
      final token = tokenStore.issue();
      final tx = repo.getTransactions(accountId: accountId).single;
      final response =
          await router(post('/rpc/deleteTransaction', token: token, body: {'transId': tx.id}));
      expect(response.statusCode, 200);
      expect(repo.getTransactions(accountId: accountId), isEmpty);
    });

    test('POST /rpc/restoreTransaction recreates a deleted transaction', () async {
      final token = tokenStore.issue();
      final tx = repo.getTransactions(accountId: accountId).single;
      repo.deleteTransaction(tx.id);
      final response = await router(post('/rpc/restoreTransaction',
          token: token, body: {'transaction': tx.toJson()}));
      expect(response.statusCode, 200);
      expect(repo.getTransactions(accountId: accountId), hasLength(1));
    });

    test('POST /rpc/setReconciled marks the real transaction reconciled', () async {
      final token = tokenStore.issue();
      final tx = repo.getTransactions(accountId: accountId).single;
      final response = await router(post('/rpc/setReconciled',
          token: token, body: {'transId': tx.id, 'reconciled': true}));
      expect(response.statusCode, 200);
      expect(repo.getTransactions(accountId: accountId).single.isReconciled, isTrue);
    });
  });

  group('Écritures - Transactions (auxiliaires)', () {
    test('POST /rpc/resolveOrCreatePayee creates a payee when none matches', () async {
      final token = tokenStore.issue();
      final response = await router(
          post('/rpc/resolveOrCreatePayee', token: token, body: {'name': 'Nouveau tiers'}));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(repo.getPayees(onlyActive: false).any((p) => p.id == json['id']), isTrue);
    });

    test('POST /rpc/resolveOrCreatePayee reuses an existing payee', () async {
      final token = tokenStore.issue();
      final response = await router(
          post('/rpc/resolveOrCreatePayee', token: token, body: {'name': 'Carrefour'}));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json['id'], payeeId);
    });

    test('POST /rpc/syncPausedTracking records the paused transaction', () async {
      final token = tokenStore.issue();
      final tx = repo.getTransactions(accountId: accountId).single;
      final response = await router(post('/rpc/syncPausedTracking',
          token: token, body: {'transId': tx.id, 'paused': true, 'reconciled': true}));
      expect(response.statusCode, 200);
      expect(repo.wasReconciledBeforePause(tx.id), isTrue);
    });

    test('POST /rpc/billIdForTransaction returns null when unlinked', () async {
      final token = tokenStore.issue();
      final tx = repo.getTransactions(accountId: accountId).single;
      final response = await router(
          post('/rpc/billIdForTransaction', token: token, body: {'transId': tx.id}));
      expect(response.statusCode, 200);
      expect(await response.readAsString(), '{"billId":null}');
    });

    test('POST /rpc/wasReconciledBeforePause returns false when never paused', () async {
      final token = tokenStore.issue();
      final tx = repo.getTransactions(accountId: accountId).single;
      final response = await router(
          post('/rpc/wasReconciledBeforePause', token: token, body: {'transId': tx.id}));
      expect(response.statusCode, 200);
      expect(await response.readAsString(), '{"result":false}');
    });

    test('POST /rpc/countTransactionsMatching counts every transaction sharing payee and category',
        () async {
      final token = tokenStore.issue();
      repo.insertTransaction(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 12,
        date: DateTime(2026, 3, 20),
        categoryId: categoryId,
      );
      final response = await router(post('/rpc/countTransactionsMatching',
          token: token, body: {'payeeId': payeeId, 'categoryId': categoryId}));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json['count'], 2);
    });

    test('POST /rpc/bulkReassignTransactionCategory updates every matching transaction', () async {
      final token = tokenStore.issue();
      final newCategoryId = repo.insertCategory(name: 'Nouvelle catégorie RPC');
      repo.insertTransaction(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 12,
        date: DateTime(2026, 3, 20),
        categoryId: categoryId,
      );
      final response = await router(post('/rpc/bulkReassignTransactionCategory', token: token, body: {
        'payeeId': payeeId,
        'oldCategoryId': categoryId,
        'newCategoryId': newCategoryId,
      }));
      expect(response.statusCode, 200);
      final updated = repo.getTransactions(accountId: accountId);
      expect(updated.every((t) => t.categoryId == newCategoryId), isTrue);
    });

    test('POST /rpc/countTransfersMatching counts transfers sharing the same account pair and category',
        () async {
      final token = tokenStore.issue();
      final otherAccountId = repo.insertAccount(
          name: 'Compte Épargne', type: 'Savings', initialBalance: 0, currencyId: 2);
      repo.insertTransaction(
        accountId: accountId,
        toAccountId: otherAccountId,
        payeeId: -1,
        transCode: TransCode.transfer,
        amount: 100,
        toAmount: 100,
        date: DateTime(2026, 3, 21),
        categoryId: categoryId,
      );
      final response = await router(post('/rpc/countTransfersMatching', token: token, body: {
        'accountId': accountId,
        'toAccountId': otherAccountId,
        'categoryId': categoryId,
      }));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json['count'], 1);
    });

    test('POST /rpc/bulkReassignTransferCategory updates every matching transfer', () async {
      final token = tokenStore.issue();
      final otherAccountId = repo.insertAccount(
          name: 'Compte Épargne', type: 'Savings', initialBalance: 0, currencyId: 2);
      final newCategoryId = repo.insertCategory(name: 'Nouvelle catégorie virement RPC');
      repo.insertTransaction(
        accountId: accountId,
        toAccountId: otherAccountId,
        payeeId: -1,
        transCode: TransCode.transfer,
        amount: 100,
        toAmount: 100,
        date: DateTime(2026, 3, 21),
        categoryId: categoryId,
      );
      final response = await router(post('/rpc/bulkReassignTransferCategory', token: token, body: {
        'accountId': accountId,
        'toAccountId': otherAccountId,
        'oldCategoryId': categoryId,
        'newCategoryId': newCategoryId,
      }));
      expect(response.statusCode, 200);
      final transfer =
          repo.getTransactions(accountId: accountId).firstWhere((t) => t.transCode == TransCode.transfer);
      expect(transfer.categoryId, newCategoryId);
    });
  });

  group('Écritures - Comptes', () {
    test('POST /rpc/insertAccount creates a real account', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/insertAccount', token: token, body: {
        'name': 'Nouveau compte',
        'type': 'Checking',
        'initialBalance': 500.0,
        'currencyId': 2,
      }));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(repo.getAccounts().any((a) => a.id == json['id'] && a.name == 'Nouveau compte'), isTrue);
    });

    test('POST /rpc/updateAccount renames the real account', () async {
      final token = tokenStore.issue();
      final account = repo.getAccounts().single;
      final renamed = Account(
        id: account.id,
        name: 'Renommé',
        type: account.type,
        status: account.status,
        initialBalance: account.initialBalance,
        currencyId: account.currencyId,
        favorite: account.favorite,
        notes: account.notes,
      );
      final response =
          await router(post('/rpc/updateAccount', token: token, body: renamed.toJson()));
      expect(response.statusCode, 200);
      expect(repo.getAccounts().single.name, 'Renommé');
    });

    test('POST /rpc/deleteAccount removes the real account', () async {
      final token = tokenStore.issue();
      final extraId = repo.insertAccount(
          name: 'À supprimer', type: 'Checking', initialBalance: 0, currencyId: 2);
      final response =
          await router(post('/rpc/deleteAccount', token: token, body: {'accountId': extraId}));
      expect(response.statusCode, 200);
      expect(repo.getAccounts().any((a) => a.id == extraId), isFalse);
    });
  });

  group('Écritures - Catégories', () {
    test('POST /rpc/insertCategory creates a real category', () async {
      final token = tokenStore.issue();
      final response = await router(
          post('/rpc/insertCategory', token: token, body: {'name': 'Nouvelle catégorie test'}));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(repo.getCategories(onlyActive: false).any((c) => c.id == json['id']), isTrue);
    });

    test('POST /rpc/renameCategory renames the real category', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/renameCategory',
          token: token, body: {'categoryId': categoryId, 'newName': 'Renommée'}));
      expect(response.statusCode, 200);
      expect(repo.getCategories(onlyActive: false).firstWhere((c) => c.id == categoryId).name,
          'Renommée');
    });

    test('POST /rpc/setCategoryActive archives the real category', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/setCategoryActive',
          token: token, body: {'categoryId': categoryId, 'active': false}));
      expect(response.statusCode, 200);
      expect(repo.getCategories(onlyActive: false).firstWhere((c) => c.id == categoryId).active,
          isFalse);
    });

    test('POST /rpc/deleteCategory removes an unused real category', () async {
      final token = tokenStore.issue();
      final extraId = repo.insertCategory(name: 'À supprimer test');
      final response = await router(
          post('/rpc/deleteCategory', token: token, body: {'categoryId': extraId}));
      expect(response.statusCode, 200);
      expect(repo.getCategories(onlyActive: false).any((c) => c.id == extraId), isFalse);
    });

    test('POST /rpc/mergeCategories repoints the transaction to the target category', () async {
      final token = tokenStore.issue();
      final targetId = repo.insertCategory(name: 'Cible du merge');
      final response = await router(post('/rpc/mergeCategories',
          token: token, body: {'fromId': categoryId, 'toId': targetId}));
      expect(response.statusCode, 200);
      expect(repo.getTransactions(accountId: accountId).single.categoryId, targetId);
    });

    test('POST /rpc/moveCategory reparents the real category', () async {
      final token = tokenStore.issue();
      final parentId = repo.insertCategory(name: 'Nouvelle mère');
      final response = await router(post('/rpc/moveCategory',
          token: token, body: {'categoryId': categoryId, 'newParentId': parentId}));
      expect(response.statusCode, 200);
      expect(repo.getCategories(onlyActive: false).firstWhere((c) => c.id == categoryId).parentId,
          parentId);
    });
  });

  group('Écritures - Tiers', () {
    test('POST /rpc/renamePayee renames the real payee', () async {
      final token = tokenStore.issue();
      final response = await router(
          post('/rpc/renamePayee', token: token, body: {'payeeId': payeeId, 'newName': 'Renommé'}));
      expect(response.statusCode, 200);
      expect(repo.getPayees(onlyActive: false).firstWhere((p) => p.id == payeeId).name, 'Renommé');
    });

    test('POST /rpc/deletePayee removes an unused real payee', () async {
      final token = tokenStore.issue();
      final extraId = repo.insertPayee(name: 'À supprimer test');
      final response =
          await router(post('/rpc/deletePayee', token: token, body: {'payeeId': extraId}));
      expect(response.statusCode, 200);
      expect(repo.getPayees(onlyActive: false).any((p) => p.id == extraId), isFalse);
    });

    test('POST /rpc/mergePayees repoints the transaction to the target payee', () async {
      final token = tokenStore.issue();
      final targetId = repo.insertPayee(name: 'Cible du merge');
      final response = await router(
          post('/rpc/mergePayees', token: token, body: {'fromId': payeeId, 'toId': targetId}));
      expect(response.statusCode, 200);
      expect(repo.getTransactions(accountId: accountId).single.payeeId, targetId);
    });
  });

  group('Écritures - Opérations récurrentes', () {
    test('POST /rpc/insertBillDeposit creates a real bill', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/insertBillDeposit', token: token, body: {
        'accountId': accountId,
        'payeeId': payeeId,
        'transCode': 'withdrawal',
        'amount': 20.0,
        'nextOccurrence': '2026-06-01T00:00:00.000',
        'period': 'monthly',
        'autoExecute': 'manual',
      }));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(repo.getBillDeposits().any((b) => b.id == json['id'] && b.amount == 20.0), isTrue);
    });

    test('POST /rpc/updateBillDeposit updates the real bill', () async {
      final token = tokenStore.issue();
      final bill = repo.getBillDeposits().single;
      final response = await router(post('/rpc/updateBillDeposit',
          token: token, body: bill.copyWith(amount: 77.0).toJson()));
      expect(response.statusCode, 200);
      expect(repo.getBillDeposits().single.amount, 77.0);
    });

    test('POST /rpc/deleteBillDeposit removes the real bill', () async {
      final token = tokenStore.issue();
      final response =
          await router(post('/rpc/deleteBillDeposit', token: token, body: {'bdId': billId}));
      expect(response.statusCode, 200);
      expect(repo.getBillDeposits(), isEmpty);
    });

    test('POST /rpc/setBillPaused pauses the real bill', () async {
      final token = tokenStore.issue();
      final response = await router(
          post('/rpc/setBillPaused', token: token, body: {'billId': billId, 'paused': true}));
      expect(response.statusCode, 200);
      expect(repo.getBillDeposits().single.paused, isTrue);
    });

    test('POST /rpc/setBillAnnualIncrease saves a real annual increase', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/setBillAnnualIncrease', token: token, body: {
        'billId': billId,
        'percent': 2.5,
        'anchor': '2026-01-01T00:00:00.000',
      }));
      expect(response.statusCode, 200);
      expect(repo.getBillAnnualIncrease(billId)?.percent, 2.5);
    });

    test('POST /rpc/clearBillAnnualIncrease removes the real annual increase', () async {
      final token = tokenStore.issue();
      repo.setBillAnnualIncrease(billId, percent: 2.5, anchor: DateTime(2026, 1, 1));
      final response = await router(
          post('/rpc/clearBillAnnualIncrease', token: token, body: {'billId': billId}));
      expect(response.statusCode, 200);
      expect(repo.getBillAnnualIncrease(billId), isNull);
    });

    test('POST /rpc/ensureBillOccurrenceTotal saves the real occurrence total', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/ensureBillOccurrenceTotal',
          token: token, body: {'billId': billId, 'total': 12}));
      expect(response.statusCode, 200);
      expect(repo.billOccurrenceTotals()[billId], 12);
    });

    test('POST /rpc/recordBillOccurrence creates a real transaction and advances the bill',
        () async {
      final token = tokenStore.issue();
      final bill = repo.getBillDeposits().singleWhere((b) => b.id == billId);
      final response = await router(post('/rpc/recordBillOccurrence', token: token, body: {
        'bill': bill.toJson(),
        'date': '2026-04-01T00:00:00.000',
      }));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      final newId = json['transId'] as int;
      expect(repo.getTransactions(accountId: accountId).any((t) => t.id == newId), isTrue);
      expect(repo.getBillDeposits().single.nextOccurrence, DateTime(2026, 5, 1));
    });

    test('POST /rpc/catchUpBillDeposit records every missed occurrence and advances the bill',
        () async {
      final token = tokenStore.issue();
      final bill = repo.getBillDeposits().singleWhere((b) => b.id == billId);
      final response = await router(post('/rpc/catchUpBillDeposit', token: token, body: {
        'bill': bill.toJson(),
        'asOf': '2026-06-01T00:00:00.000',
      }));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      final ids = (json['ids'] as List).cast<int>();
      expect(ids, isNotEmpty);
      for (final id in ids) {
        expect(repo.getTransactions(accountId: accountId).any((t) => t.id == id), isTrue);
      }
      expect(repo.getBillDeposits().single.nextOccurrence.isAfter(DateTime(2026, 6, 1)) ||
          repo.getBillDeposits().single.nextOccurrence.isAtSameMomentAs(DateTime(2026, 6, 1)),
          isTrue);
    });
  });

  group('Écritures - Budget (vue enveloppes)', () {
    test('POST /rpc/upsertBudgetEnvelope creates a real envelope', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/upsertBudgetEnvelope', token: token, body: {
        'accountId': accountId,
        'categoryId': categoryId,
        'amount': 150.0,
      }));
      expect(response.statusCode, 200);
      expect(repo.getBudgetEnvelopes(accountId).single.amount, 150.0);
    });

    test('POST /rpc/upsertBudgetEnvelope updates amount and name together', () async {
      final token = tokenStore.issue();
      repo.upsertBudgetEnvelope(accountId: accountId, categoryId: categoryId, amount: 100);
      final id = repo.getBudgetEnvelopes(accountId).single.id;
      final response = await router(post('/rpc/upsertBudgetEnvelope', token: token, body: {
        'id': id,
        'accountId': accountId,
        'categoryId': categoryId,
        'amount': 200.0,
        'name': 'Loisirs',
      }));
      expect(response.statusCode, 200);
      final envelope = repo.getBudgetEnvelopes(accountId).single;
      expect(envelope.amount, 200.0);
      expect(envelope.name, 'Loisirs');
    });

    test('POST /rpc/deleteBudgetEnvelope removes the real envelope', () async {
      final token = tokenStore.issue();
      repo.upsertBudgetEnvelope(accountId: accountId, categoryId: categoryId, amount: 100);
      final id = repo.getBudgetEnvelopes(accountId).single.id;
      final response =
          await router(post('/rpc/deleteBudgetEnvelope', token: token, body: {'id': id}));
      expect(response.statusCode, 200);
      expect(repo.getBudgetEnvelopes(accountId), isEmpty);
    });

    test('POST /rpc/setIncomeTargetOverride saves the real override', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/setIncomeTargetOverride',
          token: token, body: {'accountId': accountId, 'amount': 3000.0}));
      expect(response.statusCode, 200);
      expect(repo.expectedIncomeForBudget(accountId), 3000.0);
    });

    test('POST /rpc/getIncomeTargetOverride returns the real override', () async {
      final token = tokenStore.issue();
      repo.setIncomeTargetOverride(accountId, 2500.0);
      final response = await router(
          post('/rpc/getIncomeTargetOverride', token: token, body: {'accountId': accountId}));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json['override'], 2500.0);
    });

    test('POST /rpc/getIncomeTargetOverride returns null when unset', () async {
      final token = tokenStore.issue();
      final response = await router(
          post('/rpc/getIncomeTargetOverride', token: token, body: {'accountId': accountId}));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json['override'], isNull);
    });

    test('POST /rpc/clearIncomeTargetOverride removes the real override', () async {
      final token = tokenStore.issue();
      repo.setIncomeTargetOverride(accountId, 2500.0);
      final response = await router(
          post('/rpc/clearIncomeTargetOverride', token: token, body: {'accountId': accountId}));
      expect(response.statusCode, 200);
      expect(repo.getIncomeTargetOverride(accountId), isNull);
    });

    test('POST /rpc/monthlyRecurringIncome reflects a real recurring deposit', () async {
      final token = tokenStore.issue();
      repo.insertBillDeposit(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.deposit,
        amount: 1500,
        nextOccurrence: DateTime(2026, 4, 1),
        period: RecurrencePeriod.monthly,
        autoExecute: RecurrenceAutoExecute.manual,
      );
      final response = await router(
          post('/rpc/monthlyRecurringIncome', token: token, body: {'accountId': accountId}));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json['income'], 1500.0);
    });

    test('POST /rpc/incomeCategoryTotalsForPeriod reflects a real deposit', () async {
      final token = tokenStore.issue();
      repo.insertTransaction(
        accountId: accountId,
        payeeId: payeeId,
        transCode: TransCode.deposit,
        amount: 900,
        date: DateTime(2026, 3, 20),
        categoryId: categoryId,
      );
      final response = await router(post('/rpc/incomeCategoryTotalsForPeriod', token: token, body: {
        'start': '2026-03-01T00:00:00.000',
        'end': '2026-04-01T00:00:00.000',
        'accountId': accountId,
      }));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      final totals = json['totals'] as Map<String, dynamic>;
      expect(totals['$categoryId'], 900.0);
    });

    test('POST /rpc/lastSpendDatePerCategory reflects the real transaction from setUp', () async {
      final token = tokenStore.issue();
      final response = await router(post('/rpc/lastSpendDatePerCategory', token: token, body: {
        'start': '2026-01-01T00:00:00.000',
        'end': '2026-12-31T00:00:00.000',
        'accountId': accountId,
      }));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json['$categoryId'], '2026-03-15T00:00:00.000');
    });

    test('POST /rpc/resetBudgetEnvelopes removes every envelope for the account', () async {
      final token = tokenStore.issue();
      repo.upsertBudgetEnvelope(accountId: accountId, categoryId: categoryId, amount: 100);
      final response = await router(
          post('/rpc/resetBudgetEnvelopes', token: token, body: {'accountId': accountId}));
      expect(response.statusCode, 200);
      expect(repo.getBudgetEnvelopes(accountId), isEmpty);
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
