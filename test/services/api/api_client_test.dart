import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:money_manager/services/api/api_client.dart';

/// Vérifie ApiClient contre un client HTTP simulé (MockClient de
/// package:http/testing.dart), sans réseau réel - voir
/// PLAN_ARCHITECTURE_CLIENT_SERVEUR.md, étape 4. Le serveur réel lui-même
/// est couvert séparément par server/test/rpc_router_test.dart.
void main() {
  group('login', () {
    test('stores the token and marks the client as logged in on success', () async {
      final client = ApiClient(
        baseUrl: 'http://test',
        httpClient: MockClient((request) async {
          expect(request.url.path, '/auth/login');
          expect(jsonDecode(request.body), {'pin': '1234'});
          return http.Response(jsonEncode({'token': 'abc'}), 200);
        }),
      );
      expect(client.isLoggedIn, isFalse);
      await client.login('1234');
      expect(client.isLoggedIn, isTrue);
    });

    test('throws ApiClientException with the server error message on failure', () async {
      final client = ApiClient(
        baseUrl: 'http://test',
        httpClient: MockClient((request) async =>
            http.Response(jsonEncode({'error': 'code incorrect'}), 401)),
      );
      await expectLater(
        client.login('0000'),
        throwsA(isA<ApiClientException>()
            .having((e) => e.message, 'message', 'code incorrect')),
      );
      expect(client.isLoggedIn, isFalse);
    });
  });

  group('getAccounts', () {
    test('throws when not logged in', () {
      final client = ApiClient(baseUrl: 'http://test');
      expect(client.getAccounts(), throwsA(isA<ApiClientException>()));
    });

    test('sends the bearer token and parses the returned accounts', () async {
      final client = ApiClient(
        baseUrl: 'http://test',
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/login') {
            return http.Response(jsonEncode({'token': 'abc'}), 200);
          }
          expect(request.url.path, '/rpc/getAccounts');
          expect(request.headers['authorization'], 'Bearer abc');
          return http.Response(
              jsonEncode([
                {
                  'id': 1,
                  'name': 'Compte Courant',
                  'type': 'Checking',
                  'status': 'Open',
                  'initialBalance': 1000.0,
                  'currencyId': 2,
                  'favorite': false,
                  'notes': null,
                }
              ]),
              200);
        }),
      );
      await client.login('1234');
      final accounts = await client.getAccounts();
      expect(accounts, hasLength(1));
      expect(accounts.single.name, 'Compte Courant');
      expect(accounts.single.initialBalance, 1000.0);
    });
  });

  group('accountBalance', () {
    test('sends the account id and asOf date, returns the balance', () async {
      Map<String, dynamic>? sentBody;
      final client = ApiClient(
        baseUrl: 'http://test',
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/login') {
            return http.Response(jsonEncode({'token': 'abc'}), 200);
          }
          sentBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(jsonEncode({'balance': 42.5}), 200);
        }),
      );
      await client.login('1234');
      final balance = await client.accountBalance(7, asOf: DateTime(2026, 1, 1));
      expect(balance, 42.5);
      expect(sentBody, {'accountId': 7, 'asOf': DateTime(2026, 1, 1).toIso8601String()});
    });
  });

  group('logout', () {
    test('revokes the token and resets isLoggedIn', () async {
      var loggedOutCalled = false;
      final client = ApiClient(
        baseUrl: 'http://test',
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/login') {
            return http.Response(jsonEncode({'token': 'abc'}), 200);
          }
          if (request.url.path == '/auth/logout') {
            loggedOutCalled = true;
            return http.Response('', 200);
          }
          return http.Response('', 404);
        }),
      );
      await client.login('1234');
      await client.logout();
      expect(loggedOutCalled, isTrue);
      expect(client.isLoggedIn, isFalse);
    });

    test('is a no-op when not logged in', () async {
      var calls = 0;
      final client = ApiClient(
        baseUrl: 'http://test',
        httpClient: MockClient((request) async {
          calls++;
          return http.Response('', 200);
        }),
      );
      await client.logout();
      expect(calls, 0);
    });
  });
}
