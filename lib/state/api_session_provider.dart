import 'package:flutter/foundation.dart' hide Category;
import 'package:http/http.dart' as http;
import 'package:money_manager_core/models/account.dart';
import 'package:money_manager_core/models/category.dart';
import 'package:money_manager_core/models/currency.dart';
import 'package:money_manager_core/models/payee.dart';
import 'package:money_manager_core/models/transaction.dart';

import '../services/api/api_client.dart';

/// État partagé de connexion au serveur API du chantier client/serveur
/// (voir PLAN_ARCHITECTURE_CLIENT_SERVEUR.md, étape 4) - une seule
/// instance pour toute l'appli, exactement comme [DatabaseProvider]/
/// [PinLockProvider]. L'URL du serveur est mémorisée en mémoire pour
/// cette session seulement (pas encore persistée entre deux lancements
/// de l'appli - limitation connue, à corriger si ce chantier avance).
/// Le jeton, lui, n'est jamais persisté du tout, par prudence (voir la
/// discussion sécurité du plan) - une reconnexion par code PIN est
/// nécessaire à chaque lancement de l'appli.
class ApiSessionProvider extends ChangeNotifier {
  final http.Client? _httpClient;
  ApiClient? _client;
  String? _error;
  bool _busy = false;

  /// Bascules de lecture par écran (étape 4) - un nom d'écran par entrée
  /// ('accounts', 'payees', 'categories', ...), en mémoire seulement pour
  /// l'instant (pas persistées entre deux lancements de l'appli). Vidées
  /// à la déconnexion pour ne jamais laisser un écran croire qu'il peut
  /// encore lire un serveur qui n'est plus joignable.
  final Set<String> _apiScreens = {};

  /// [httpClient] injectable pour les tests (voir
  /// test/state/api_session_provider_test.dart) - un vrai client HTTP par
  /// défaut sinon.
  ApiSessionProvider({http.Client? httpClient}) : _httpClient = httpClient;

  bool get isConnected => _client?.isLoggedIn ?? false;
  bool get isBusy => _busy;
  String? get error => _error;
  String? get serverUrl => _client?.baseUrl;

  bool _useApiFor(String screen) => _apiScreens.contains(screen) && isConnected;
  void _setUseApiFor(String screen, bool value) {
    if (value) {
      _apiScreens.add(screen);
    } else {
      _apiScreens.remove(screen);
    }
    notifyListeners();
  }

  bool get useApiForAccounts => _useApiFor('accounts');
  set useApiForAccounts(bool value) => _setUseApiFor('accounts', value);

  bool get useApiForPayees => _useApiFor('payees');
  set useApiForPayees(bool value) => _setUseApiFor('payees', value);

  bool get useApiForCategories => _useApiFor('categories');
  set useApiForCategories(bool value) => _setUseApiFor('categories', value);

  bool get useApiForSpendingExplorer => _useApiFor('spendingExplorer');
  set useApiForSpendingExplorer(bool value) => _setUseApiFor('spendingExplorer', value);

  Future<void> login(String serverUrl, String pin) async {
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final client = ApiClient(baseUrl: serverUrl, httpClient: _httpClient);
      await client.login(pin);
      _client = client;
    } catch (e) {
      _error = '$e';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    await _client?.logout();
    _client = null;
    _apiScreens.clear();
    notifyListeners();
  }

  Future<List<Account>> getAccounts({bool onlyOpen = false}) => _requireClient().getAccounts(onlyOpen: onlyOpen);

  Future<CurrencyFormat?> getBaseCurrency() => _requireClient().getBaseCurrency();

  Future<double> accountBalance(int accountId, {DateTime? asOf}) =>
      _requireClient().accountBalance(accountId, asOf: asOf);

  Future<List<Payee>> getPayees({bool onlyActive = true}) =>
      _requireClient().getPayees(onlyActive: onlyActive);

  Future<int> payeeUsageCount(int payeeId) => _requireClient().payeeUsageCount(payeeId);

  Future<List<Category>> getCategories({bool onlyActive = true}) =>
      _requireClient().getCategories(onlyActive: onlyActive);

  Future<CategoryUsage> categoryUsage(int categoryId) => _requireClient().categoryUsage(categoryId);

  Future<List<MoneyTransaction>> getTransactionsFiltered({
    List<int>? years,
    List<int>? categoryIds,
    List<int>? payeeIds,
    List<int>? accountIds,
  }) =>
      _requireClient().getTransactionsFiltered(
        years: years,
        categoryIds: categoryIds,
        payeeIds: payeeIds,
        accountIds: accountIds,
      );

  Future<({int min, int max})?> transactionYearRangeAll() => _requireClient().transactionYearRangeAll();

  ApiClient _requireClient() {
    final client = _client;
    if (client == null) throw StateError('Pas connecté au serveur API.');
    return client;
  }
}
