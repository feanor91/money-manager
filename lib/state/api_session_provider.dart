import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:money_manager_core/models/account.dart';
import 'package:money_manager_core/models/currency.dart';

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
  bool _useApiForAccounts = false;

  /// [httpClient] injectable pour les tests (voir
  /// test/state/api_session_provider_test.dart) - un vrai client HTTP par
  /// défaut sinon.
  ApiSessionProvider({http.Client? httpClient}) : _httpClient = httpClient;

  bool get isConnected => _client?.isLoggedIn ?? false;
  bool get isBusy => _busy;
  String? get error => _error;
  String? get serverUrl => _client?.baseUrl;

  /// Bascule de lecture pour l'écran Comptes (étape 4) - en mémoire
  /// seulement pour l'instant (pas persistée entre deux lancements de
  /// l'appli), remise à faux si la session se déconnecte pour ne jamais
  /// laisser l'écran essayer de lire un serveur qui n'est plus joignable.
  bool get useApiForAccounts => _useApiForAccounts && isConnected;
  set useApiForAccounts(bool value) {
    _useApiForAccounts = value;
    notifyListeners();
  }

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
    notifyListeners();
  }

  Future<List<Account>> getAccounts({bool onlyOpen = false}) {
    final client = _client;
    if (client == null) throw StateError('Pas connecté au serveur API.');
    return client.getAccounts(onlyOpen: onlyOpen);
  }

  Future<CurrencyFormat?> getBaseCurrency() {
    final client = _client;
    if (client == null) throw StateError('Pas connecté au serveur API.');
    return client.getBaseCurrency();
  }

  Future<double> accountBalance(int accountId, {DateTime? asOf}) {
    final client = _client;
    if (client == null) throw StateError('Pas connecté au serveur API.');
    return client.accountBalance(accountId, asOf: asOf);
  }
}
