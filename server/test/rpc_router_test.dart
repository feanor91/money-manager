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

  setUp(() async {
    final repo = await openBlankTestRepo();
    repo.insertAccount(
        name: 'Compte Courant', type: 'Checking', initialBalance: 1000, currencyId: 2);
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
}
