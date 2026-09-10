import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:money_manager_core/models/account.dart';
import 'package:money_manager_core/models/bill_deposit.dart';
import 'package:money_manager_core/models/category.dart';
import 'package:money_manager_core/models/currency.dart';
import 'package:money_manager_core/models/payee.dart';
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
