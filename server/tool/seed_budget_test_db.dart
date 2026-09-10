// Script jetable pour peupler dev_budget_test.mmb avec de quoi voir la vue
// enveloppes du Budget fonctionner en mode API en direct - jamais commité
// dans le dépôt (voir seed_dev_db.dart pour la version minimale déjà
// présente). Usage : dart run tool/seed_budget_test_db.dart <chemin.mmb>
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

void main(List<String> args) {
  final db = sqlite3.open(args[0]);
  db.execute(
    "INSERT INTO ACCOUNTLIST_V1 (ACCOUNTNAME, ACCOUNTTYPE, STATUS, NOTES, INITIALBAL, FAVORITEACCT, CURRENCYID, INITIALDATE) "
    "VALUES ('Compte Test Budget API', 'Checking', 'Open', '', 2000, 'TRUE', 2, date('now'))",
  );
  final accountId = db.lastInsertRowId;
  db.execute(
    "INSERT INTO PAYEE_V1 (PAYEENAME) VALUES ('Supermarché Test')",
  );
  final payeeId = db.lastInsertRowId;
  db.execute(
    "INSERT INTO CATEGORY_V1 (CATEGNAME, ACTIVE) VALUES ('Courses Test API', 1)",
  );
  final categoryId = db.lastInsertRowId;
  db.execute(
    "INSERT INTO CHECKINGACCOUNT_V1 (ACCOUNTID, TOACCOUNTID, PAYEEID, TRANSCODE, TRANSAMOUNT, TOTRANSAMOUNT, "
    "STATUS, TRANSACTIONNUMBER, NOTES, CATEGID, TRANSDATE) "
    "VALUES ($accountId, NULL, $payeeId, 'Withdrawal', 85.30, 85.30, '', '', '', $categoryId, date('now'))",
  );
  db.execute(
    "CREATE TABLE IF NOT EXISTS APP_BUDGET_ENVELOPES ("
    "ENVELOPEID INTEGER PRIMARY KEY AUTOINCREMENT, ACCOUNTID INTEGER NOT NULL, CATEGID INTEGER NOT NULL, "
    "AMOUNT REAL NOT NULL DEFAULT 0, ACTIVE INTEGER NOT NULL DEFAULT 1, NAME TEXT, MANUAL_OVERRIDE INTEGER NOT NULL DEFAULT 0, "
    "UNIQUE(ACCOUNTID, CATEGID))",
  );
  db.execute(
    "INSERT INTO APP_BUDGET_ENVELOPES (ACCOUNTID, CATEGID, AMOUNT, ACTIVE) VALUES ($accountId, $categoryId, 150, 1)",
  );
  db.dispose();
  stdout.writeln('Compte $accountId / catégorie $categoryId / enveloppe créés pour le test Budget API.');
}
