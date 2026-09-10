import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:money_manager/services/api/api_client.dart';
import 'package:money_manager_core/models/recurrence.dart';
import 'package:money_manager_core/models/transaction.dart';

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

  group('getPayees / payeeUsageCount', () {
    test('parses payees and forwards onlyActive as a query param', () async {
      final client = ApiClient(
        baseUrl: 'http://test',
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/login') {
            return http.Response(jsonEncode({'token': 'abc'}), 200);
          }
          expect(request.url.path, '/rpc/getPayees');
          expect(request.url.queryParameters['onlyActive'], 'false');
          return http.Response(
              jsonEncode([
                {'id': 1, 'name': 'Carrefour', 'categoryId': null, 'active': true}
              ]),
              200);
        }),
      );
      await client.login('1234');
      final payees = await client.getPayees(onlyActive: false);
      expect(payees.single.name, 'Carrefour');
    });

    test('returns the usage count', () async {
      final client = ApiClient(
        baseUrl: 'http://test',
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/login') {
            return http.Response(jsonEncode({'token': 'abc'}), 200);
          }
          return http.Response(jsonEncode({'count': 3}), 200);
        }),
      );
      await client.login('1234');
      expect(await client.payeeUsageCount(1), 3);
    });
  });

  group('getCategories / categoryUsage', () {
    test('parses categories', () async {
      final client = ApiClient(
        baseUrl: 'http://test',
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/login') {
            return http.Response(jsonEncode({'token': 'abc'}), 200);
          }
          return http.Response(
              jsonEncode([
                {'id': 9, 'name': 'Alimentation', 'parentId': null, 'active': true}
              ]),
              200);
        }),
      );
      await client.login('1234');
      final categories = await client.getCategories();
      expect(categories.single.name, 'Alimentation');
    });

    test('parses category usage', () async {
      final client = ApiClient(
        baseUrl: 'http://test',
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/login') {
            return http.Response(jsonEncode({'token': 'abc'}), 200);
          }
          return http.Response(
              jsonEncode({
                'childCategoryCount': 0,
                'transactionCount': 5,
                'recurringCount': 0,
                'budgetEntryCount': 0,
                'payeeDefaultCount': 0,
              }),
              200);
        }),
      );
      await client.login('1234');
      final usage = await client.categoryUsage(9);
      expect(usage.transactionCount, 5);
      expect(usage.canDelete, isFalse);
    });
  });

  group('getTransactionsFiltered / transactionYearRangeAll', () {
    test('sends only the non-null filters and parses the transactions', () async {
      Map<String, dynamic>? sentBody;
      final client = ApiClient(
        baseUrl: 'http://test',
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/login') {
            return http.Response(jsonEncode({'token': 'abc'}), 200);
          }
          sentBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
              jsonEncode([
                {
                  'id': 1,
                  'accountId': 1,
                  'toAccountId': null,
                  'payeeId': 1,
                  'transCode': 'withdrawal',
                  'amount': 42.5,
                  'toAmount': 42.5,
                  'status': '',
                  'categoryId': 9,
                  'date': DateTime(2026, 3, 15).toIso8601String(),
                  'notes': null,
                }
              ]),
              200);
        }),
      );
      await client.login('1234');
      final results = await client.getTransactionsFiltered(years: [2026]);
      expect(sentBody, {'years': [2026]});
      expect(results.single.amount, 42.5);
      expect(results.single.transCode, TransCode.withdrawal);
    });

    test('returns the year range', () async {
      final client = ApiClient(
        baseUrl: 'http://test',
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/login') {
            return http.Response(jsonEncode({'token': 'abc'}), 200);
          }
          return http.Response(jsonEncode({'min': 2020, 'max': 2026}), 200);
        }),
      );
      await client.login('1234');
      final range = await client.transactionYearRangeAll();
      expect(range?.min, 2020);
      expect(range?.max, 2026);
    });

    test('returns null when there are no transactions at all', () async {
      final client = ApiClient(
        baseUrl: 'http://test',
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/login') {
            return http.Response(jsonEncode({'token': 'abc'}), 200);
          }
          return http.Response('null', 200);
        }),
      );
      await client.login('1234');
      expect(await client.transactionYearRangeAll(), isNull);
    });
  });

  group('getBillDeposits / billOccurrenceTotals / annual increase', () {
    test('parses bill deposits including the enums', () async {
      final client = ApiClient(
        baseUrl: 'http://test',
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/login') {
            return http.Response(jsonEncode({'token': 'abc'}), 200);
          }
          return http.Response(
              jsonEncode([
                {
                  'id': 1,
                  'accountId': 1,
                  'toAccountId': null,
                  'payeeId': 1,
                  'transCode': 'withdrawal',
                  'amount': 15.0,
                  'toAmount': 15.0,
                  'categoryId': null,
                  'nextOccurrence': DateTime(2026, 4, 1).toIso8601String(),
                  'period': 'monthly',
                  'autoExecute': 'manual',
                  'numOccurrences': -1,
                  'notes': null,
                  'paused': false,
                  'variancePercent': 0.0,
                  'annualIncreasePercent': 0.0,
                  'annualIncreaseAnchor': null,
                }
              ]),
              200);
        }),
      );
      await client.login('1234');
      final bills = await client.getBillDeposits();
      expect(bills.single.period, RecurrencePeriod.monthly);
      expect(bills.single.autoExecute, RecurrenceAutoExecute.manual);
    });

    test('converts billOccurrenceTotals string keys back to ints', () async {
      final client = ApiClient(
        baseUrl: 'http://test',
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/login') {
            return http.Response(jsonEncode({'token': 'abc'}), 200);
          }
          return http.Response(jsonEncode({'7': 3}), 200);
        }),
      );
      await client.login('1234');
      final totals = await client.billOccurrenceTotals();
      expect(totals, {7: 3});
    });

    test('parses getBillAnnualIncrease when configured', () async {
      final client = ApiClient(
        baseUrl: 'http://test',
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/login') {
            return http.Response(jsonEncode({'token': 'abc'}), 200);
          }
          return http.Response(
              jsonEncode({'percent': 2.5, 'anchor': DateTime(2026, 1, 1).toIso8601String()}), 200);
        }),
      );
      await client.login('1234');
      final increase = await client.getBillAnnualIncrease(1);
      expect(increase?.percent, 2.5);
    });

    test('suggestedAnnualIncrease returns null with too little history', () async {
      final client = ApiClient(
        baseUrl: 'http://test',
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/login') {
            return http.Response(jsonEncode({'token': 'abc'}), 200);
          }
          return http.Response('null', 200);
        }),
      );
      await client.login('1234');
      expect(await client.suggestedAnnualIncrease(1), isNull);
    });
  });

  group('getTransactionsWithRunningBalance / transactionYearRange / recurring transaction links', () {
    test('parses rows with a running balance', () async {
      final client = ApiClient(
        baseUrl: 'http://test',
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/login') {
            return http.Response(jsonEncode({'token': 'abc'}), 200);
          }
          return http.Response(
              jsonEncode([
                {
                  'transaction': {
                    'id': 1,
                    'accountId': 1,
                    'toAccountId': null,
                    'payeeId': 1,
                    'transCode': 'withdrawal',
                    'amount': 42.5,
                    'toAmount': 42.5,
                    'status': '',
                    'categoryId': null,
                    'date': DateTime(2026, 3, 15).toIso8601String(),
                    'notes': null,
                  },
                  'balanceAfter': 957.5,
                }
              ]),
              200);
        }),
      );
      await client.login('1234');
      final rows = await client.getTransactionsWithRunningBalance(1);
      expect(rows.single.balanceAfter, 957.5);
      expect(rows.single.transaction.amount, 42.5);
    });

    test('transactionYearRange returns the range', () async {
      final client = ApiClient(
        baseUrl: 'http://test',
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/login') {
            return http.Response(jsonEncode({'token': 'abc'}), 200);
          }
          return http.Response(jsonEncode({'min': 2020, 'max': 2026}), 200);
        }),
      );
      await client.login('1234');
      final range = await client.transactionYearRange(1);
      expect(range?.min, 2020);
      expect(range?.max, 2026);
    });

    test('recurringTransactionIds parses the id list', () async {
      final client = ApiClient(
        baseUrl: 'http://test',
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/login') {
            return http.Response(jsonEncode({'token': 'abc'}), 200);
          }
          return http.Response(jsonEncode([3, 7]), 200);
        }),
      );
      await client.login('1234');
      expect(await client.recurringTransactionIds(), {3, 7});
    });

    test('recurringTransactionOccurrences converts string keys back to ints', () async {
      final client = ApiClient(
        baseUrl: 'http://test',
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/login') {
            return http.Response(jsonEncode({'token': 'abc'}), 200);
          }
          return http.Response(
              jsonEncode({
                '5': {'index': 2, 'total': 6}
              }),
              200);
        }),
      );
      await client.login('1234');
      final occurrences = await client.recurringTransactionOccurrences();
      expect(occurrences[5]?.index, 2);
      expect(occurrences[5]?.total, 6);
    });
  });
}
