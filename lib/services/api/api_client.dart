import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:money_manager_core/models/account.dart';

/// Client HTTP minimal pour le futur serveur API (voir
/// PLAN_ARCHITECTURE_CLIENT_SERVEUR.md) - preuve de concept de bout en
/// bout pour l'étape 2/3 du chantier, pas encore le vrai client utilisé
/// par les écrans réels de l'appli (ça, c'est l'étape 4, écran par
/// écran). Volontairement minimal : login + une seule route RPC
/// (getAccounts), pour prouver que le principe fonctionne réellement
/// depuis l'appli Flutter elle-même, pas seulement en curl.
class ApiClientException implements Exception {
  final String message;
  ApiClientException(this.message);
  @override
  String toString() => message;
}

class ApiClient {
  final String baseUrl;
  String? _token;

  ApiClient({required this.baseUrl});

  bool get isLoggedIn => _token != null;

  Future<void> login(String pin) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/login'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'pin': pin}),
    );
    if (response.statusCode != 200) {
      final body = _tryDecodeError(response.body);
      throw ApiClientException(body ?? 'Échec de connexion (${response.statusCode})');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    _token = json['token'] as String;
  }

  Future<List<Account>> getAccounts({bool onlyOpen = false}) async {
    final token = _token;
    if (token == null) {
      throw ApiClientException('Pas connecté - appeler login() d\'abord.');
    }
    final uri = Uri.parse('$baseUrl/rpc/getAccounts')
        .replace(queryParameters: onlyOpen ? {'onlyOpen': 'true'} : null);
    final response = await http.post(uri, headers: {'authorization': 'Bearer $token'});
    if (response.statusCode != 200) {
      final body = _tryDecodeError(response.body);
      throw ApiClientException(body ?? 'Échec de la requête (${response.statusCode})');
    }
    final list = jsonDecode(response.body) as List;
    return [for (final row in list) Account.fromJson(row as Map<String, dynamic>)];
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
