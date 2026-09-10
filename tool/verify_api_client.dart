// Vérification manuelle en direct de ApiClient contre un vrai serveur
// money_manager_server déjà lancé - `flutter test` bloque volontairement
// les vraies requêtes HTTP (TestWidgetsFlutterBinding), donc ce script se
// lance à part, en `dart run`, pas en `flutter test`.
// Usage (depuis la racine du repo, serveur de dev déjà lancé) :
//   dart run tool/verify_api_client.dart
import 'dart:io';

import 'package:money_manager/services/api/api_client.dart';

Future<void> main() async {
  final client = ApiClient(baseUrl: 'http://localhost:8899');
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
  print('OK - ApiClient fonctionne bout en bout contre le vrai serveur.');
}
