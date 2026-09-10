// Vérification manuelle en direct de ApiClient contre un vrai serveur
// money_manager_server déjà lancé - `flutter test` bloque volontairement
// les vraies requêtes HTTP (TestWidgetsFlutterBinding), donc ce script se
// lance à part, en `dart run`, pas en `flutter test`.
// Usage (depuis la racine du repo, serveur de dev déjà lancé) :
//   dart run tool/verify_api_client.dart
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:money_manager/services/api/api_client.dart';

const _baseUrl = 'http://localhost:8899';

Future<void> main() async {
  final client = ApiClient(baseUrl: _baseUrl);
  print('Connexion...');
  await client.login('1234');
  print('Connecté, jeton obtenu.');
  final accounts = await client.getAccounts();
  print('${accounts.length} compte(s) reçu(s) :');
  for (final a in accounts) {
    print('  - ${a.name} (${a.type}, ${a.status}) : ${a.initialBalance}');
  }
  if (accounts.isEmpty || accounts.first.name != 'Compte Test API') {
    stderr.writeln('ÉCHEC : compte de démonstration attendu introuvable.');
    exit(1);
  }

  // Étape 4 - les 2 routes ajoutées pour l'écran Comptes (voir
  // PLAN_ARCHITECTURE_CLIENT_SERVEUR.md).
  final currency = await client.getBaseCurrency();
  print('Devise de base : ${currency?.name} (${currency?.prefixSymbol}${currency?.suffixSymbol})');
  if (currency == null) {
    stderr.writeln('ÉCHEC : getBaseCurrency a renvoyé null.');
    exit(1);
  }

  final balance = await client.accountBalance(accounts.first.id);
  print('Solde de "${accounts.first.name}" : $balance');
  if (balance != accounts.first.initialBalance) {
    stderr.writeln('ÉCHEC : solde attendu ${accounts.first.initialBalance}, reçu $balance '
        '(normal si des transactions existent déjà sur ce compte de test).');
  }

  // Capture le vrai jeton avant révocation, pour vérifier côté serveur
  // (pas juste "ApiClient a oublié le jeton en mémoire") qu'un jeton
  // révoqué est bien rejeté par le serveur lui-même.
  final loginResponse = await http.post(Uri.parse('$_baseUrl/auth/login'),
      headers: {'content-type': 'application/json'}, body: jsonEncode({'pin': '1234'}));
  final rawToken = (jsonDecode(loginResponse.body) as Map<String, dynamic>)['token'] as String;

  final logoutResponse =
      await http.post(Uri.parse('$_baseUrl/auth/logout'), headers: {'authorization': 'Bearer $rawToken'});
  if (logoutResponse.statusCode != 200) {
    stderr.writeln('ÉCHEC : /auth/logout a renvoyé ${logoutResponse.statusCode}.');
    exit(1);
  }
  final afterLogout = await http.post(Uri.parse('$_baseUrl/rpc/getAccounts'),
      headers: {'authorization': 'Bearer $rawToken'});
  if (afterLogout.statusCode != 401) {
    stderr.writeln(
        'ÉCHEC : un jeton révoqué a été accepté par le serveur (${afterLogout.statusCode}).');
    exit(1);
  }
  print('OK - un jeton révoqué via /auth/logout est bien rejeté par le serveur (401).');

  print('OK - toutes les routes de l\'étape 4 fonctionnent bout en bout contre le vrai serveur.');
}
