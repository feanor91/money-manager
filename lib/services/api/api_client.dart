import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:money_manager_core/data/mmex_repository.dart' show RecurringOccurrence;
import 'package:money_manager_core/models/account.dart';
import 'package:money_manager_core/models/bill_deposit.dart';
import 'package:money_manager_core/models/budget.dart';
import 'package:money_manager_core/models/category.dart';
import 'package:money_manager_core/models/currency.dart';
import 'package:money_manager_core/models/payee.dart';
import 'package:money_manager_core/models/recurrence.dart';
import 'package:money_manager_core/models/transaction.dart';

/// Client HTTP pour le serveur API (voir PLAN_ARCHITECTURE_CLIENT_SERVEUR.md).
/// Couvre les routes réellement exposées par le serveur à ce stade de
/// l'étape 4 - lecture seule (comptes, devise de base, solde) pour le
/// premier écran migré (Comptes). Les écritures continuent de passer par
/// [MmexRepository] en local pour l'instant, même en mode API - voir la
/// nuance du plan sur la bascule des écritures (coupure coordonnée, pas
/// progressive comme les lectures).
class ApiClientException implements Exception {
  final String message;
  ApiClientException(this.message);
  @override
  String toString() => message;
}

/// Sentinelle "argument non fourni" pour [ApiClient.upsertBudgetEnvelope] -
/// même principe que [MmexRepository.upsertBudgetEnvelope] côté serveur.
const _unset = Object();

class ApiClient {
  final String baseUrl;
  final http.Client _http;
  String? _token;

  /// [httpClient] injectable pour les tests (voir test/services/api/
  /// api_client_test.dart, qui utilise package:http/testing.dart plutôt
  /// que de taper un vrai réseau) - un vrai [http.Client] par défaut sinon.
  ApiClient({required this.baseUrl, http.Client? httpClient}) : _http = httpClient ?? http.Client();

  bool get isLoggedIn => _token != null;

  Future<void> login(String pin) async {
    final response = await _http.post(
      Uri.parse('$baseUrl/auth/login'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'pin': pin}),
    );
    if (response.statusCode != 200) {
      throw ApiClientException(
          _tryDecodeError(response.body) ?? 'Échec de connexion (${response.statusCode})');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    _token = json['token'] as String;
  }

  /// Révoque le jeton actuel côté serveur - à utiliser en cas de doute sur
  /// une fuite, pas seulement en quittant l'appli (le jeton reste valable
  /// jusqu'à expiration naturelle sinon, voir TokenStore côté serveur).
  Future<void> logout() async {
    final token = _token;
    if (token == null) return;
    await _http.post(Uri.parse('$baseUrl/auth/logout'),
        headers: {'authorization': 'Bearer $token'});
    _token = null;
  }

  Future<List<Account>> getAccounts({bool onlyOpen = false}) async {
    final json = await _rpc('getAccounts',
        query: onlyOpen ? {'onlyOpen': 'true'} : null);
    final list = json as List;
    return [for (final row in list) Account.fromJson(row as Map<String, dynamic>)];
  }

  Future<CurrencyFormat?> getBaseCurrency() async {
    final json = await _rpc('getBaseCurrency');
    return json == null ? null : CurrencyFormat.fromJson(json as Map<String, dynamic>);
  }

  Future<double> accountBalance(int accountId, {DateTime? asOf}) async {
    final json = await _rpc('accountBalance', body: {
      'accountId': accountId,
      if (asOf != null) 'asOf': asOf.toIso8601String(),
    });
    return (json as Map<String, dynamic>)['balance'] as double;
  }

  Future<List<Payee>> getPayees({bool onlyActive = true}) async {
    final json = await _rpc('getPayees', query: {'onlyActive': '$onlyActive'});
    final list = json as List;
    return [for (final row in list) Payee.fromJson(row as Map<String, dynamic>)];
  }

  Future<int> payeeUsageCount(int payeeId) async {
    final json = await _rpc('payeeUsageCount', body: {'payeeId': payeeId});
    return (json as Map<String, dynamic>)['count'] as int;
  }

  Future<List<Category>> getCategories({bool onlyActive = true}) async {
    final json = await _rpc('getCategories', query: {'onlyActive': '$onlyActive'});
    final list = json as List;
    return [for (final row in list) Category.fromJson(row as Map<String, dynamic>)];
  }

  Future<CategoryUsage> categoryUsage(int categoryId) async {
    final json = await _rpc('categoryUsage', body: {'categoryId': categoryId});
    return CategoryUsage.fromJson(json as Map<String, dynamic>);
  }

  Future<List<MoneyTransaction>> getTransactionsFiltered({
    List<int>? years,
    List<int>? categoryIds,
    List<int>? payeeIds,
    List<int>? accountIds,
  }) async {
    final json = await _rpc('getTransactionsFiltered', body: {
      if (years != null) 'years': years,
      if (categoryIds != null) 'categoryIds': categoryIds,
      if (payeeIds != null) 'payeeIds': payeeIds,
      if (accountIds != null) 'accountIds': accountIds,
    });
    final list = json as List;
    return [for (final row in list) MoneyTransaction.fromJson(row as Map<String, dynamic>)];
  }

  Future<({int min, int max})?> transactionYearRangeAll() async {
    final json = await _rpc('transactionYearRangeAll');
    if (json == null) return null;
    final map = json as Map<String, dynamic>;
    return (min: map['min'] as int, max: map['max'] as int);
  }

  Future<List<BillDeposit>> getBillDeposits() async {
    final json = await _rpc('getBillDeposits');
    final list = json as List;
    return [for (final row in list) BillDeposit.fromJson(row as Map<String, dynamic>)];
  }

  Future<Map<int, int>> billOccurrenceTotals() async {
    final json = await _rpc('billOccurrenceTotals') as Map<String, dynamic>;
    return json.map((k, v) => MapEntry(int.parse(k), v as int));
  }

  Future<({double percent, DateTime anchor})?> getBillAnnualIncrease(int billId) async {
    final json = await _rpc('getBillAnnualIncrease', body: {'billId': billId});
    if (json == null) return null;
    final map = json as Map<String, dynamic>;
    return (percent: (map['percent'] as num).toDouble(), anchor: DateTime.parse(map['anchor'] as String));
  }

  Future<({double percent, DateTime anchor, double yearsSpan})?> suggestedAnnualIncrease(
      int billId) async {
    final json = await _rpc('suggestedAnnualIncrease', body: {'billId': billId});
    if (json == null) return null;
    final map = json as Map<String, dynamic>;
    return (
      percent: (map['percent'] as num).toDouble(),
      anchor: DateTime.parse(map['anchor'] as String),
      yearsSpan: (map['yearsSpan'] as num).toDouble(),
    );
  }

  Future<List<TransactionWithBalance>> getTransactionsWithRunningBalance(
    int accountId, {
    DateTime? from,
    DateTime? to,
  }) async {
    final json = await _rpc('getTransactionsWithRunningBalance', body: {
      'accountId': accountId,
      if (from != null) 'from': from.toIso8601String(),
      if (to != null) 'to': to.toIso8601String(),
    });
    final list = json as List;
    return [
      for (final row in list) TransactionWithBalance.fromJson(row as Map<String, dynamic>)
    ];
  }

  Future<({int min, int max})?> transactionYearRange(int accountId) async {
    final json = await _rpc('transactionYearRange', body: {'accountId': accountId});
    if (json == null) return null;
    final map = json as Map<String, dynamic>;
    return (min: map['min'] as int, max: map['max'] as int);
  }

  Future<Set<int>> recurringTransactionIds() async {
    final json = await _rpc('recurringTransactionIds') as List;
    return json.cast<int>().toSet();
  }

  Future<Map<int, ({int index, int total})>> recurringTransactionOccurrences() async {
    final json = await _rpc('recurringTransactionOccurrences') as Map<String, dynamic>;
    return json.map((k, v) {
      final map = v as Map<String, dynamic>;
      return MapEntry(int.parse(k), (index: map['index'] as int, total: map['total'] as int));
    });
  }

  // Écran Budget (étape 4) - uniquement la vue "enveloppes" en lecture :
  // le simulateur ("what if") reste entièrement local, voir
  // budget_screen.dart et PLAN_ARCHITECTURE_CLIENT_SERVEUR.md.
  Future<List<BudgetEnvelope>> getBudgetEnvelopes(int accountId) async {
    final json = await _rpc('getBudgetEnvelopes', body: {'accountId': accountId});
    final list = json as List;
    return [for (final row in list) BudgetEnvelope.fromJson(row as Map<String, dynamic>)];
  }

  Future<Map<int, double>> categoryMonthlyRecurringTotals({int? accountId}) async {
    final json = await _rpc('categoryMonthlyRecurringTotals', body: {
      if (accountId != null) 'accountId': accountId,
    }) as Map<String, dynamic>;
    return json.map((k, v) => MapEntry(int.parse(k), (v as num).toDouble()));
  }

  Future<Map<int, double>> categorySpendForPeriod(
    DateTime start,
    DateTime end, {
    int? accountId,
    bool includeCategorizedTransfersAsExpense = false,
  }) async {
    final json = await _rpc('categorySpendForPeriod', body: {
      'start': start.toIso8601String(),
      'end': end.toIso8601String(),
      if (accountId != null) 'accountId': accountId,
      'includeCategorizedTransfersAsExpense': includeCategorizedTransfersAsExpense,
    }) as Map<String, dynamic>;
    return json.map((k, v) => MapEntry(int.parse(k), (v as num).toDouble()));
  }

  Future<Set<int>> categoriesUsedByAccount(int accountId) async {
    final json = await _rpc('categoriesUsedByAccount', body: {'accountId': accountId}) as List;
    return json.cast<int>().toSet();
  }

  Future<double> incomeForPeriod(DateTime start, DateTime end, {int? accountId}) async {
    final json = await _rpc('incomeForPeriod', body: {
      'start': start.toIso8601String(),
      'end': end.toIso8601String(),
      if (accountId != null) 'accountId': accountId,
    });
    return ((json as Map<String, dynamic>)['income'] as num).toDouble();
  }

  Future<double> expectedIncomeForBudget(int accountId) async {
    final json = await _rpc('expectedIncomeForBudget', body: {'accountId': accountId});
    return ((json as Map<String, dynamic>)['expected'] as num).toDouble();
  }

  // Tableau de bord (étape 4) - le graphique de prévision (ForecastChart)
  // reste local pour l'instant, voir dashboard_screen.dart.
  Future<List<MoneyTransaction>> getTransactions({
    int? accountId,
    DateTime? from,
    DateTime? to,
    int limit = 200,
  }) async {
    final json = await _rpc('getTransactions', body: {
      if (accountId != null) 'accountId': accountId,
      if (from != null) 'from': from.toIso8601String(),
      if (to != null) 'to': to.toIso8601String(),
      'limit': limit,
    });
    final list = json as List;
    return [for (final row in list) MoneyTransaction.fromJson(row as Map<String, dynamic>)];
  }

  Future<double> forecastAccountBalance(int accountId, DateTime targetDate) async {
    final json = await _rpc('forecastAccountBalance',
        body: {'accountId': accountId, 'targetDate': targetDate.toIso8601String()});
    return ((json as Map<String, dynamic>)['balance'] as num).toDouble();
  }

  Future<DateTime?> forecastNegativeDate(int accountId, {int horizonDays = 365}) async {
    final json = await _rpc('forecastNegativeDate',
        body: {'accountId': accountId, 'horizonDays': horizonDays});
    return json == null ? null : DateTime.parse(json as String);
  }

  // ForecastChart (dans Tableau de bord) - dernier morceau de l'étape 4.
  Future<Map<DateTime, double>> dailyNetTotals({
    required DateTime anchor,
    required int days,
    int? accountId,
  }) async {
    final json = await _rpc('dailyNetTotals', body: {
      'anchor': anchor.toIso8601String(),
      'days': days,
      if (accountId != null) 'accountId': accountId,
    }) as Map<String, dynamic>;
    return json.map((k, v) => MapEntry(DateTime.parse(k), (v as num).toDouble()));
  }

  Future<Map<DateTime, double>> futureDailyNet({
    required DateTime after,
    required DateTime end,
    int? accountId,
  }) async {
    final json = await _rpc('futureDailyNet', body: {
      'after': after.toIso8601String(),
      'end': end.toIso8601String(),
      if (accountId != null) 'accountId': accountId,
    }) as Map<String, dynamic>;
    return json.map((k, v) => MapEntry(DateTime.parse(k), (v as num).toDouble()));
  }

  Future<Map<DateTime, double>> recurringDailyNet({
    required DateTime anchor,
    required int days,
    int? accountId,
  }) async {
    final json = await _rpc('recurringDailyNet', body: {
      'anchor': anchor.toIso8601String(),
      'days': days,
      if (accountId != null) 'accountId': accountId,
    }) as Map<String, dynamic>;
    return json.map((k, v) => MapEntry(DateTime.parse(k), (v as num).toDouble()));
  }

  Future<List<RecurringOccurrence>> recurringOccurrencesInRange({
    required DateTime start,
    required DateTime end,
    int? accountId,
  }) async {
    final json = await _rpc('recurringOccurrencesInRange', body: {
      'start': start.toIso8601String(),
      'end': end.toIso8601String(),
      if (accountId != null) 'accountId': accountId,
    });
    final list = json as List;
    return [
      for (final row in list)
        RecurringOccurrence(
          date: DateTime.parse((row as Map<String, dynamic>)['date'] as String),
          label: row['label'] as String,
          signedAmount: (row['signedAmount'] as num).toDouble(),
        ),
    ];
  }

  // Écritures (chantier, non branchées en production - voir
  // PLAN_ARCHITECTURE_CLIENT_SERVEUR.md, "Précision ajoutée le
  // 2026-09-10").

  // ---- Transactions ----
  Future<int> insertTransaction({
    required int accountId,
    required int payeeId,
    required TransCode transCode,
    required double amount,
    required DateTime date,
    int? categoryId,
    int? toAccountId,
    double? toAmount,
    String? notes,
    bool reconciled = false,
  }) async {
    final json = await _rpc('insertTransaction', body: {
      'accountId': accountId,
      'payeeId': payeeId,
      'transCode': transCodeToString(transCode),
      'amount': amount,
      'date': date.toIso8601String(),
      if (categoryId != null) 'categoryId': categoryId,
      if (toAccountId != null) 'toAccountId': toAccountId,
      if (toAmount != null) 'toAmount': toAmount,
      if (notes != null) 'notes': notes,
      'reconciled': reconciled,
    });
    return (json as Map<String, dynamic>)['id'] as int;
  }

  Future<void> updateTransaction(MoneyTransaction tx) => _rpc('updateTransaction', body: tx.toJson());

  Future<void> deleteTransaction(int transId) => _rpc('deleteTransaction', body: {'transId': transId});

  Future<int> restoreTransaction(
    MoneyTransaction tx, {
    int? billId,
    int? occurrenceIndex,
    int? occurrenceTotal,
    bool? wasReconciledBeforePause,
  }) async {
    final json = await _rpc('restoreTransaction', body: {
      'transaction': tx.toJson(),
      if (billId != null) 'billId': billId,
      if (occurrenceIndex != null) 'occurrenceIndex': occurrenceIndex,
      if (occurrenceTotal != null) 'occurrenceTotal': occurrenceTotal,
      if (wasReconciledBeforePause != null) 'wasReconciledBeforePause': wasReconciledBeforePause,
    });
    return (json as Map<String, dynamic>)['id'] as int;
  }

  Future<void> setReconciled(int transId, bool reconciled) =>
      _rpc('setReconciled', body: {'transId': transId, 'reconciled': reconciled});

  Future<int> resolveOrCreatePayee({required String name, int? categoryId}) async {
    final json = await _rpc('resolveOrCreatePayee',
        body: {'name': name, if (categoryId != null) 'categoryId': categoryId});
    return (json as Map<String, dynamic>)['id'] as int;
  }

  Future<void> syncPausedTracking(int transId, {required bool paused, required bool reconciled}) =>
      _rpc('syncPausedTracking', body: {'transId': transId, 'paused': paused, 'reconciled': reconciled});

  Future<int?> billIdForTransaction(int transId) async {
    final json = await _rpc('billIdForTransaction', body: {'transId': transId});
    return (json as Map<String, dynamic>)['billId'] as int?;
  }

  Future<bool> wasReconciledBeforePause(int transId) async {
    final json = await _rpc('wasReconciledBeforePause', body: {'transId': transId});
    return (json as Map<String, dynamic>)['result'] as bool;
  }

  // ---- Comptes ----
  Future<int> insertAccount({
    required String name,
    required String type,
    required double initialBalance,
    required int currencyId,
  }) async {
    final json = await _rpc('insertAccount', body: {
      'name': name,
      'type': type,
      'initialBalance': initialBalance,
      'currencyId': currencyId,
    });
    return (json as Map<String, dynamic>)['id'] as int;
  }

  Future<void> updateAccount(Account account) => _rpc('updateAccount', body: account.toJson());

  Future<void> deleteAccount(int accountId) => _rpc('deleteAccount', body: {'accountId': accountId});

  // ---- Catégories ----
  Future<int> insertCategory({required String name, int? parentId}) async {
    final json = await _rpc(
        'insertCategory', body: {'name': name, if (parentId != null) 'parentId': parentId});
    return (json as Map<String, dynamic>)['id'] as int;
  }

  Future<void> renameCategory(int categoryId, String newName) =>
      _rpc('renameCategory', body: {'categoryId': categoryId, 'newName': newName});

  Future<void> setCategoryActive(int categoryId, bool active) =>
      _rpc('setCategoryActive', body: {'categoryId': categoryId, 'active': active});

  Future<void> deleteCategory(int categoryId) =>
      _rpc('deleteCategory', body: {'categoryId': categoryId});

  Future<void> mergeCategories({required int fromId, required int toId}) =>
      _rpc('mergeCategories', body: {'fromId': fromId, 'toId': toId});

  Future<void> moveCategory(int categoryId, int? newParentId) =>
      _rpc('moveCategory', body: {'categoryId': categoryId, 'newParentId': newParentId});

  // ---- Tiers ----
  Future<void> renamePayee(int payeeId, String newName) =>
      _rpc('renamePayee', body: {'payeeId': payeeId, 'newName': newName});

  Future<void> deletePayee(int payeeId) => _rpc('deletePayee', body: {'payeeId': payeeId});

  Future<void> mergePayees({required int fromId, required int toId}) =>
      _rpc('mergePayees', body: {'fromId': fromId, 'toId': toId});

  // ---- Opérations récurrentes ----
  Future<int> insertBillDeposit({
    required int accountId,
    required int payeeId,
    required TransCode transCode,
    required double amount,
    required DateTime nextOccurrence,
    required RecurrencePeriod period,
    required RecurrenceAutoExecute autoExecute,
    int? categoryId,
    int? toAccountId,
    double? toAmount,
    String? notes,
    int numOccurrences = -1,
  }) async {
    final json = await _rpc('insertBillDeposit', body: {
      'accountId': accountId,
      'payeeId': payeeId,
      'transCode': transCodeToString(transCode),
      'amount': amount,
      'nextOccurrence': nextOccurrence.toIso8601String(),
      'period': period.name,
      'autoExecute': autoExecute.name,
      if (categoryId != null) 'categoryId': categoryId,
      if (toAccountId != null) 'toAccountId': toAccountId,
      if (toAmount != null) 'toAmount': toAmount,
      if (notes != null) 'notes': notes,
      'numOccurrences': numOccurrences,
    });
    return (json as Map<String, dynamic>)['id'] as int;
  }

  Future<void> updateBillDeposit(BillDeposit bill) => _rpc('updateBillDeposit', body: bill.toJson());

  Future<void> deleteBillDeposit(int bdId) => _rpc('deleteBillDeposit', body: {'bdId': bdId});

  Future<void> setBillPaused(int billId, bool paused) =>
      _rpc('setBillPaused', body: {'billId': billId, 'paused': paused});

  Future<void> setBillAnnualIncrease(int billId, {required double percent, required DateTime anchor}) =>
      _rpc('setBillAnnualIncrease',
          body: {'billId': billId, 'percent': percent, 'anchor': anchor.toIso8601String()});

  Future<void> clearBillAnnualIncrease(int billId) =>
      _rpc('clearBillAnnualIncrease', body: {'billId': billId});

  Future<void> ensureBillOccurrenceTotal(int billId, int total) =>
      _rpc('ensureBillOccurrenceTotal', body: {'billId': billId, 'total': total});

  // ---- Budget (vue enveloppes uniquement - le simulateur reste local) ----
  Future<void> upsertBudgetEnvelope({
    int? id,
    required int accountId,
    required int categoryId,
    required double amount,
    Object? name = _unset,
    Object? manualOverride = _unset,
  }) =>
      _rpc('upsertBudgetEnvelope', body: {
        if (id != null) 'id': id,
        'accountId': accountId,
        'categoryId': categoryId,
        'amount': amount,
        if (!identical(name, _unset)) 'name': name,
        if (!identical(manualOverride, _unset)) 'manualOverride': manualOverride,
      });

  Future<void> deleteBudgetEnvelope(int id) => _rpc('deleteBudgetEnvelope', body: {'id': id});

  Future<void> setIncomeTargetOverride(int accountId, double amount) =>
      _rpc('setIncomeTargetOverride', body: {'accountId': accountId, 'amount': amount});

  Future<void> resetBudgetEnvelopes(int accountId) =>
      _rpc('resetBudgetEnvelopes', body: {'accountId': accountId});

  Future<dynamic> _rpc(String method, {Map<String, String>? query, Map<String, dynamic>? body}) async {
    final token = _token;
    if (token == null) {
      throw ApiClientException('Pas connecté - appeler login() d\'abord.');
    }
    final uri = Uri.parse('$baseUrl/rpc/$method').replace(queryParameters: query);
    final response = await _http.post(
      uri,
      headers: {
        'authorization': 'Bearer $token',
        if (body != null) 'content-type': 'application/json',
      },
      body: body == null ? null : jsonEncode(body),
    );
    if (response.statusCode != 200) {
      throw ApiClientException(
          _tryDecodeError(response.body) ?? 'Échec de la requête (${response.statusCode})');
    }
    return jsonDecode(response.body);
  }

  String? _tryDecodeError(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      return json['error'] as String?;
    } catch (_) {
      return null;
    }
  }
}
