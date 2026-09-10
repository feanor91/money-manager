import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:money_manager/state/api_session_provider.dart';

void main() {
  group('login/logout', () {
    test('isConnected reflects a successful login', () async {
      final provider = ApiSessionProvider(
        httpClient: MockClient((request) async => http.Response(jsonEncode({'token': 'abc'}), 200)),
      );
      expect(provider.isConnected, isFalse);
      await provider.login('http://test', '1234');
      expect(provider.isConnected, isTrue);
      expect(provider.error, isNull);
    });

    test('a failed login leaves isConnected false and sets error', () async {
      final provider = ApiSessionProvider(
        httpClient: MockClient(
            (request) async => http.Response(jsonEncode({'error': 'code incorrect'}), 401)),
      );
      await provider.login('http://test', '0000');
      expect(provider.isConnected, isFalse);
      expect(provider.error, isNotNull);
    });

    test('logout clears the session', () async {
      final provider = ApiSessionProvider(
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/login') {
            return http.Response(jsonEncode({'token': 'abc'}), 200);
          }
          return http.Response('', 200);
        }),
      );
      await provider.login('http://test', '1234');
      expect(provider.isConnected, isTrue);
      await provider.logout();
      expect(provider.isConnected, isFalse);
    });
  });

  group('useApiForAccounts', () {
    test('reads back false while not connected even if set true', () async {
      final provider = ApiSessionProvider(
        httpClient: MockClient((request) async => http.Response('', 500)),
      );
      provider.useApiForAccounts = true;
      // Login never succeeded (server returns 500) - must never report the
      // toggle as active against a server that isn't actually connected.
      expect(provider.useApiForAccounts, isFalse);
    });

    test('reads back true once connected and the toggle is set', () async {
      final provider = ApiSessionProvider(
        httpClient: MockClient((request) async => http.Response(jsonEncode({'token': 'abc'}), 200)),
      );
      await provider.login('http://test', '1234');
      provider.useApiForAccounts = true;
      expect(provider.useApiForAccounts, isTrue);
    });

    test('reverts to false after logging out even if it was set true', () async {
      final provider = ApiSessionProvider(
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/login') {
            return http.Response(jsonEncode({'token': 'abc'}), 200);
          }
          return http.Response('', 200);
        }),
      );
      await provider.login('http://test', '1234');
      provider.useApiForAccounts = true;
      await provider.logout();
      expect(provider.useApiForAccounts, isFalse);
    });
  });

  group('data accessors', () {
    test('getAccounts throws a StateError when not connected', () {
      final provider = ApiSessionProvider();
      expect(() => provider.getAccounts(), throwsStateError);
    });

    test('getBaseCurrency throws a StateError when not connected', () {
      final provider = ApiSessionProvider();
      expect(() => provider.getBaseCurrency(), throwsStateError);
    });

    test('accountBalance throws a StateError when not connected', () {
      final provider = ApiSessionProvider();
      expect(() => provider.accountBalance(1), throwsStateError);
    });

    test('getPayees/payeeUsageCount/getCategories/categoryUsage throw when not connected', () {
      final provider = ApiSessionProvider();
      expect(() => provider.getPayees(), throwsStateError);
      expect(() => provider.payeeUsageCount(1), throwsStateError);
      expect(() => provider.getCategories(), throwsStateError);
      expect(() => provider.categoryUsage(1), throwsStateError);
    });

    test('the Budget accessors throw a StateError when not connected', () {
      final provider = ApiSessionProvider();
      expect(() => provider.getBudgetEnvelopes(1), throwsStateError);
      expect(() => provider.categoryMonthlyRecurringTotals(), throwsStateError);
      expect(() => provider.categorySpendForPeriod(DateTime(2026, 3, 1), DateTime(2026, 4, 1)),
          throwsStateError);
      expect(() => provider.categoriesUsedByAccount(1), throwsStateError);
      expect(() => provider.incomeForPeriod(DateTime(2026, 3, 1), DateTime(2026, 4, 1)),
          throwsStateError);
      expect(() => provider.expectedIncomeForBudget(1), throwsStateError);
    });
  });

  group('per-screen toggles are independent', () {
    test('each screen toggle can be set without affecting the others', () async {
      final provider = ApiSessionProvider(
        httpClient: MockClient((request) async => http.Response(jsonEncode({'token': 'abc'}), 200)),
      );
      await provider.login('http://test', '1234');
      provider.useApiForAccounts = true;
      expect(provider.useApiForAccounts, isTrue);
      expect(provider.useApiForPayees, isFalse);
      expect(provider.useApiForCategories, isFalse);

      provider.useApiForCategories = true;
      expect(provider.useApiForAccounts, isTrue);
      expect(provider.useApiForPayees, isFalse);
      expect(provider.useApiForCategories, isTrue);
    });

    test('logout clears every per-screen toggle', () async {
      final provider = ApiSessionProvider(
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/login') {
            return http.Response(jsonEncode({'token': 'abc'}), 200);
          }
          return http.Response('', 200);
        }),
      );
      await provider.login('http://test', '1234');
      provider.useApiForAccounts = true;
      provider.useApiForPayees = true;
      provider.useApiForCategories = true;
      provider.useApiForBudget = true;
      await provider.logout();
      expect(provider.useApiForAccounts, isFalse);
      expect(provider.useApiForPayees, isFalse);
      expect(provider.useApiForCategories, isFalse);
      expect(provider.useApiForBudget, isFalse);
    });
  });
}
