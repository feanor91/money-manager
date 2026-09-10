import 'dart:io';

import 'package:money_manager_core/data/mmex_database.dart';
import 'package:money_manager_core/data/mmex_repository.dart';

/// Base en mémoire pour les tests du serveur - même schéma que l'appli
/// utilise (assets/mmex_blank_schema.sql), jamais un vrai fichier. Chemin
/// relatif au dossier server/ (là où `dart test` s'exécute).
Future<MmexRepository> openBlankTestRepo() async {
  final db = await MmexDatabase.openFromPath(':memory:');
  final schema = File('../assets/mmex_blank_schema.sql').readAsStringSync();
  db.transaction(() => db.execute(schema));
  final repo = MmexRepository(db)..ensureAppSchema();
  return repo;
}
