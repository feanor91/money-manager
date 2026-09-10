// Ajoute un compte de démonstration dans une base créée par
// create_dev_db.dart - juste pour vérifier en direct que l'écran de
// débogage de l'appli (ApiDebugScreen) affiche bien des vraies données.
// Usage : dart run tool/seed_dev_db.dart <chemin.mmb>
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

void main(List<String> args) {
  final db = sqlite3.open(args[0]);
  db.execute(
    "INSERT INTO ACCOUNTLIST_V1 (ACCOUNTNAME, ACCOUNTTYPE, STATUS, NOTES, INITIALBAL, FAVORITEACCT, CURRENCYID, INITIALDATE) "
    "VALUES ('Compte Test API', 'Checking', 'Open', '', 1234.56, 'FALSE', 2, date('now'))",
  );
  db.dispose();
  stdout.writeln('Compte de démonstration ajouté.');
}
