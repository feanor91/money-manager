import 'dart:convert';

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

  setUp(() async {
    final repo = await openBlankTestRepo();
    accountId = repo.insertAccount(
        name: 'Compte Courant', type: 'Checking', initialBalance: 1000, currencyId: 2);
    payeeId = repo.insertPayee(name: 'Carrefour');
    categoryId = repo.insertCategory(name: 'Catégorie de test RPC'); // nom garanti absent du schéma vierge seedé
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
    test('returns the real balance for a valid token', () async {
      final token = tokenStore.issue();
      final response = await router(
          post('/rpc/accountBalance', token: token, body: {'accountId': accountId}));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json['balance'], 1000);
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
    test('returns 0 for an unused payee', () async {
      final token = tokenStore.issue();
      final response =
          await router(post('/rpc/payeeUsageCount', token: token, body: {'payeeId': payeeId}));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json['count'], 0);
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
    test('returns zero counts for an unused category', () async {
      final token = tokenStore.issue();
      final response = await router(
          post('/rpc/categoryUsage', token: token, body: {'categoryId': categoryId}));
      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json['transactionCount'], 0);
      expect(json['childCategoryCount'], 0);
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
