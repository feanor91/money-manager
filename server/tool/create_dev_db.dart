// Crée une base .mmb vierge pour le développement/test du serveur, à
// partir du même schéma que l'appli utilise (assets/mmex_blank_schema.sql)
// - jamais le vrai fichier Nextcloud (voir PLAN_ARCHITECTURE_CLIENT_SERVEUR.md,
// "Configuration du serveur - deux niveaux distincts").
//
// Usage : dart run tool/create_dev_db.dart <chemin_de_sortie.mmb>
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('Usage : dart run tool/create_dev_db.dart <chemin_de_sortie.mmb>');
    exit(1);
  }
  final outPath = args[0];
  final schemaFile = File('../assets/mmex_blank_schema.sql');
  if (!schemaFile.existsSync()) {
    stderr.writeln('Schéma introuvable : ${schemaFile.path} '
        '(exécuter depuis le dossier server/)');
    exit(1);
  }
  final schema = schemaFile.readAsStringSync();
  final outFile = File(outPath);
  if (outFile.existsSync()) outFile.deleteSync();

  final db = sqlite3.open(outPath);
  db.execute(schema);
  db.dispose();
  stdout.writeln('Base de développement créée : $outPath');
}
