import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_manager_core/models/account.dart';
import 'package:money_manager_core/models/recurrence.dart';
import 'package:money_manager_core/models/transaction.dart';

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

    test('the Dashboard accessors throw a StateError when not connected', () {
      final provider = ApiSessionProvider();
      expect(() => provider.getTransactions(), throwsStateError);
      expect(() => provider.forecastAccountBalance(1, DateTime(2026, 12, 31)), throwsStateError);
      expect(() => provider.forecastNegativeDate(1), throwsStateError);
    });

    test('the ForecastChart accessors throw a StateError when not connected', () {
      final provider = ApiSessionProvider();
      expect(() => provider.dailyNetTotals(anchor: DateTime(2026, 3, 15), days: 1),
          throwsStateError);
      expect(
          () => provider.futureDailyNet(after: DateTime(2026, 3, 15), end: DateTime(2026, 4, 15)),
          throwsStateError);
      expect(() => provider.recurringDailyNet(anchor: DateTime(2026, 5, 1), days: 60),
          throwsStateError);
      expect(
          () => provider.recurringOccurrencesInRange(
              start: DateTime(2026, 4, 1), end: DateTime(2026, 4, 30)),
          throwsStateError);
    });

    test('the write accessors throw a StateError when not connected', () {
      final provider = ApiSessionProvider();
      final tx = MoneyTransaction(
        id: 1,
        accountId: 1,
        payeeId: 1,
        transCode: TransCode.withdrawal,
        amount: 10,
        toAmount: 10,
        status: '',
        date: DateTime(2026, 3, 15),
      );
      const account = Account(
          id: 1, name: 'x', type: 'Checking', status: 'Open', initialBalance: 0, currencyId: 2, favorite: false);
      expect(
          () => provider.insertTransaction(
              accountId: 1,
              payeeId: 1,
              transCode: TransCode.withdrawal,
              amount: 10,
              date: DateTime(2026, 3, 15)),
          throwsStateError);
      expect(() => provider.updateTransaction(tx), throwsStateError);
      expect(() => provider.deleteTransaction(1), throwsStateError);
      expect(() => provider.restoreTransaction(tx), throwsStateError);
      expect(() => provider.setReconciled(1, true), throwsStateError);
      expect(() => provider.resolveOrCreatePayee(name: 'x'), throwsStateError);
      expect(() => provider.syncPausedTracking(1, paused: true, reconciled: false),
          throwsStateError);
      expect(() => provider.billIdForTransaction(1), throwsStateError);
      expect(() => provider.wasReconciledBeforePause(1), throwsStateError);
      expect(
          () => provider.insertAccount(
              name: 'x', type: 'Checking', initialBalance: 0, currencyId: 2),
          throwsStateError);
      expect(() => provider.updateAccount(account), throwsStateError);
      expect(() => provider.deleteAccount(1), throwsStateError);
      expect(() => provider.insertCategory(name: 'x'), throwsStateError);
      expect(() => provider.renameCategory(1, 'x'), throwsStateError);
      expect(() => provider.setCategoryActive(1, true), throwsStateError);
      expect(() => provider.deleteCategory(1), throwsStateError);
      expect(() => provider.mergeCategories(fromId: 1, toId: 2), throwsStateError);
      expect(() => provider.renamePayee(1, 'x'), throwsStateError);
      expect(() => provider.deletePayee(1), throwsStateError);
      expect(() => provider.mergePayees(fromId: 1, toId: 2), throwsStateError);
      expect(
          () => provider.insertBillDeposit(
              accountId: 1,
              payeeId: 1,
              transCode: TransCode.withdrawal,
              amount: 10,
              nextOccurrence: DateTime(2026, 4, 1),
              period: RecurrencePeriod.monthly,
              autoExecute: RecurrenceAutoExecute.manual),
          throwsStateError);
      expect(() => provider.deleteBillDeposit(1), throwsStateError);
      expect(() => provider.setBillPaused(1, true), throwsStateError);
      expect(
          () => provider.setBillAnnualIncrease(1, percent: 2, anchor: DateTime(2026, 1, 1)),
          throwsStateError);
      expect(() => provider.clearBillAnnualIncrease(1), throwsStateError);
      expect(
          () => provider.upsertBudgetEnvelope(accountId: 1, categoryId: 1, amount: 10),
          throwsStateError);
      expect(() => provider.deleteBudgetEnvelope(1), throwsStateError);
      expect(() => provider.setIncomeTargetOverride(1, 100), throwsStateError);
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
      provider.useApiForDashboard = true;
      await provider.logout();
      expect(provider.useApiForAccounts, isFalse);
      expect(provider.useApiForPayees, isFalse);
      expect(provider.useApiForCategories, isFalse);
      expect(provider.useApiForBudget, isFalse);
      expect(provider.useApiForDashboard, isFalse);
    });
  });
}
