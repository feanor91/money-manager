import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_manager/data/mmex_database_io.dart' as io_db;

void main() {
  group('openFromPath missing-file behavior', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mmex_open_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('a missing path throws instead of silently creating an empty database', () async {
      final path = '${tempDir.path}/MyMoney.mmb';
      expect(File(path).existsSync(), isFalse);

      // Regression: sqlite3.open() defaults to create-if-missing, so
      // reopening a remembered path after the real file was renamed/moved
      // used to "succeed" into a brand-new, schema-less empty file instead
      // of surfacing a clear "not found" error - confirmed 2026-08-01 as
      // the cause of a blank app with no prompt to pick the right file.
      await expectLater(() => io_db.openFromPath(path), throwsA(anything));

      // The whole point: no file should have been created as a side effect
      // of the failed open attempt.
      expect(File(path).existsSync(), isFalse);
    });

    test('createIfMissing:true still creates a new file (the "new database" flow)', () async {
      final path = '${tempDir.path}/NewBank.mmb';
      expect(File(path).existsSync(), isFalse);

      final db = await io_db.openFromPath(path, createIfMissing: true);
      db.execute('CREATE TABLE t(x INTEGER)');
      db.dispose();

      expect(File(path).existsSync(), isTrue);
    });

    test('an existing file opens normally without createIfMissing', () async {
      final path = '${tempDir.path}/Existing.mmb';
      // Create it first via the create-allowed path, same as a real .mmb
      // would already exist on disk before ever being "restored".
      final created = await io_db.openFromPath(path, createIfMissing: true);
      created.execute('CREATE TABLE t(x INTEGER)');
      created.execute('INSERT INTO t(x) VALUES (42)');
      created.dispose();

      final reopened = await io_db.openFromPath(path);
      expect(reopened.query('SELECT x FROM t'), [{'x': 42}]);
      reopened.dispose();
    });
  });
}
