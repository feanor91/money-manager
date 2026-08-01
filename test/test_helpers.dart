import 'dart:io';

import 'package:money_manager/data/mmex_database.dart';
import 'package:money_manager/data/mmex_database_io.dart' as io_db;
import 'package:money_manager/data/mmex_repository.dart';

/// A blank-but-real MMEX database, in memory - loads the same schema asset
/// used to create a brand-new .mmb (see blank_database.dart), minus its
/// rootBundle dependency (a plain repository test doesn't need Flutter asset
/// bindings), plus this app's own APP_ tables. Shared by any repository-level
/// test that needs a real schema without a Flutter widget test harness.
Future<MmexDatabase> openBlankTestDb() async {
  final db = await io_db.openFromPath(':memory:');
  final sql = File('assets/mmex_blank_schema.sql').readAsStringSync();
  // See blank_database.dart's initializeBlankSchema for why comment lines
  // are stripped before splitting on ';', not after.
  final withoutComments =
      sql.split('\n').where((line) => !line.trim().startsWith('--')).join('\n');
  db.transaction(() {
    for (final statement in withoutComments.split(';')) {
      final trimmed = statement.trim();
      if (trimmed.isEmpty) continue;
      db.execute(trimmed);
    }
  });
  MmexRepository(db).ensureAppSchema();
  return db;
}
