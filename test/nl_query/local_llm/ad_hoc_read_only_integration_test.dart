import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_manager/data/mmex_database_io.dart' as io_db;
import 'package:money_manager/data/mmex_repository.dart';
import 'package:money_manager/models/transaction.dart';
import 'package:money_manager/services/nl_query/local_llm/local_llm_manager_io.dart';
import 'package:money_manager/services/nl_query/query_executor.dart';
import 'package:money_manager/services/nl_query/query_intent.dart';

/// The one test that exercises the whole new QueryKind.adHoc path together:
/// a real file-backed MMEX schema (not `:memory:` - openReadOnlyAdHocRepository
/// reopens by real filesystem path), seeded via the app's own read-write
/// repository, then read back through openReadOnlyAdHocRepository's separate
/// read-only connection and a real adHoc query. Everywhere else in this
/// session's test suite, `:memory:` is simpler and sufficient - this is the
/// only layer where the read-only reopen mechanism itself is genuinely
/// exercised end to end.
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ad_hoc_integration_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('a real adHoc question runs correctly through the read-only reopened connection', () async {
    final path = '${tempDir.path}/MyMoney.mmb';
    final writableDb = await io_db.openFromPath(path, createIfMissing: true);
    final sql = File('assets/mmex_blank_schema.sql').readAsStringSync();
    final withoutComments =
        sql.split('\n').where((line) => !line.trim().startsWith('--')).join('\n');
    writableDb.transaction(() {
      for (final statement in withoutComments.split(';')) {
        final trimmed = statement.trim();
        if (trimmed.isEmpty) continue;
        writableDb.execute(trimmed);
      }
    });
    final writableRepo = MmexRepository(writableDb);
    writableRepo.ensureAppSchema();
    final accountId = writableRepo.insertAccount(
        name: 'Compte test', type: 'Checking', initialBalance: 0, currencyId: 2);
    final categoryId = writableRepo.insertCategory(name: 'Alimentation Test');
    final payeeId = writableRepo.insertPayee(name: 'Carrefour');
    writableRepo.insertTransaction(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 40,
      date: DateTime(2026, 7, 5),
      categoryId: categoryId,
    );
    writableDb.dispose();

    final readOnlyRepo = await openReadOnlyAdHocRepository(path);
    expect(readOnlyRepo, isNotNull);
    try {
      final answer = runQuery(
        QueryIntent(
          kind: QueryKind.adHoc,
          period: DateRange(start: DateTime(2026, 7, 1), end: DateTime(2026, 8, 1), label: 'test'),
          adHocMetric: AdHocMetric.sum,
          adHocTransactionType: AdHocTransactionType.withdrawal,
          adHocGroupBy: AdHocGroupBy.none,
        ),
        readOnlyRepo!,
      );
      // MapEntry has no value equality (identity only), so comparing a
      // List<MapEntry> directly against a literal would spuriously fail
      // even for identical-looking entries - compare key/value fields
      // instead.
      expect(answer.adHocResult, hasLength(1));
      expect(answer.adHocResult!.single.key, '');
      expect(answer.adHocResult!.single.value, 40.0);
    } finally {
      readOnlyRepo!.db.dispose();
    }
  });
}
