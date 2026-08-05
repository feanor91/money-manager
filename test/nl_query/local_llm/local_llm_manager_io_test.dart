import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_manager/data/mmex_database_io.dart' as io_db;
import 'package:money_manager/services/nl_query/local_llm/local_llm_manager_io.dart';

/// Real-temp-file pattern (same as test/mmex_database_open_test.dart) rather
/// than `:memory:` - openReadOnlyAdHocRepository reopens the .mmb by real
/// filesystem path, which an in-memory test database has none of.
///
/// openReadOnlyAdHocRepository gates on Platform.isWindows first (this
/// feature, like every other local-AI entry point in this same file, is
/// Windows-only) and returns null on any other platform - CI's own Test job
/// runs on a Linux runner, so every test here that expects a real open to
/// succeed is skipped there rather than failing on a platform this feature
/// was never meant to run on in the first place. Verified for real on
/// Windows (see ROADMAP.md's existing practice for this whole feature).
final _skipReason = Platform.isWindows ? null : 'IA locale : Windows uniquement.';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ad_hoc_readonly_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('opening a real file succeeds and can read', () async {
    final path = '${tempDir.path}/MyMoney.mmb';
    final seed = await io_db.openFromPath(path, createIfMissing: true);
    seed.execute('CREATE TABLE t(x INTEGER)');
    seed.execute('INSERT INTO t(x) VALUES (42)');
    seed.dispose();

    final readOnlyRepo = await openReadOnlyAdHocRepository(path);
    expect(readOnlyRepo, isNotNull);
    expect(readOnlyRepo!.db.query('SELECT x FROM t'), [
      {'x': 42}
    ]);
    readOnlyRepo.db.dispose();
  }, skip: _skipReason);

  test('a nonexistent path returns null, never throws', () async {
    final path = '${tempDir.path}/DoesNotExist.mmb';
    expect(File(path).existsSync(), isFalse);
    final readOnlyRepo = await openReadOnlyAdHocRepository(path);
    expect(readOnlyRepo, isNull);
  }, skip: _skipReason);

  test('a write attempt through the wrapped connection is refused', () async {
    final path = '${tempDir.path}/WriteAttempt.mmb';
    final seed = await io_db.openFromPath(path, createIfMissing: true);
    seed.execute('CREATE TABLE t(x INTEGER)');
    seed.dispose();

    final readOnlyRepo = await openReadOnlyAdHocRepository(path);
    // Two independent guards: the wrapper's own execute()/transaction()
    // throw UnsupportedError immediately (Dart-level), and even if that
    // guard were ever bypassed, the underlying connection was opened with
    // OpenMode.readOnly, so SQLite itself would refuse the write too.
    expect(() => readOnlyRepo!.db.execute('INSERT INTO t(x) VALUES (1)'), throwsUnsupportedError);
    readOnlyRepo!.db.dispose();
  }, skip: _skipReason);
}
