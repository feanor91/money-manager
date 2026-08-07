import 'package:flutter_test/flutter_test.dart';
import 'package:money_manager/services/nl_query/local_llm/sql_query_engine.dart';

/// The real safety boundary against a write is the OS/SQLite-enforced
/// `OpenMode.readOnly` connection (openReadOnlyAdHocRepository, exercised
/// live via a real file in ad_hoc_query_test.dart-style tests) - not this
/// function. What's tested here is quality control: an obviously-bad model
/// response should fail closed with a clean null rather than reaching the
/// database at all or crashing on malformed JSON.
void main() {
  group('extractValidatedSql', () {
    test('accepts a plain SELECT', () {
      expect(extractValidatedSql('{"sql":"SELECT * FROM CATEGORY_V1"}'),
          'SELECT * FROM CATEGORY_V1');
    });

    test('accepts a WITH ... SELECT (CTE)', () {
      expect(
        extractValidatedSql('{"sql":"WITH x AS (SELECT 1) SELECT * FROM x"}'),
        'WITH x AS (SELECT 1) SELECT * FROM x',
      );
    });

    test('is case-insensitive on the leading keyword', () {
      expect(extractValidatedSql('{"sql":"select 1"}'), 'select 1');
    });

    test('tolerates stray text around the JSON object', () {
      expect(
        extractValidatedSql('Voici :\n{"sql":"SELECT 1"}\nFin.'),
        'SELECT 1',
      );
    });

    test('rejects sql: null (the model saying it cannot answer)', () {
      expect(extractValidatedSql('{"sql":null,"raison":"hors sujet"}'), isNull);
    });

    test('rejects a missing sql field', () {
      expect(extractValidatedSql('{"raison":"..."}'), isNull);
    });

    test('rejects invalid JSON entirely', () {
      expect(extractValidatedSql('ceci ne ressemble pas a du json'), isNull);
    });

    test('rejects anything not starting with SELECT/WITH', () {
      expect(extractValidatedSql('{"sql":"Voici la réponse : 42"}'), isNull);
    });

    test('rejects a semicolon - no stacked/multiple statements', () {
      expect(
        extractValidatedSql('{"sql":"SELECT 1; DROP TABLE CATEGORY_V1"}'),
        isNull,
      );
    });

    for (final keyword in [
      'INSERT',
      'UPDATE',
      'DELETE',
      'DROP',
      'ALTER',
      'CREATE',
      'REPLACE',
      'ATTACH',
      'PRAGMA',
      'VACUUM',
    ]) {
      test('rejects a query containing the write/DDL keyword $keyword anywhere in it', () {
        expect(
          extractValidatedSql('{"sql":"SELECT 1 FROM (SELECT $keyword) t"}'),
          isNull,
          reason: keyword,
        );
      });
    }

    test('a keyword appearing only as part of a longer identifier does not false-positive', () {
      // "CREATED" contains "CREATE" as a substring but is a distinct word -
      // the word-boundary check must not reject this.
      expect(
        extractValidatedSql('{"sql":"SELECT CREATED_DATE FROM CATEGORY_V1"}'),
        'SELECT CREATED_DATE FROM CATEGORY_V1',
      );
    });

    test('rejects an empty sql string', () {
      expect(extractValidatedSql('{"sql":""}'), isNull);
      expect(extractValidatedSql('{"sql":"   "}'), isNull);
    });
  });

  test('defaultSqlSystemPrompt documents the read-only/single-statement contract', () {
    expect(defaultSqlSystemPrompt, contains('SELECT'));
    expect(defaultSqlSystemPrompt, contains('lecture seule'));
    expect(defaultSqlSystemPrompt, contains('CHECKINGACCOUNT_V1'));
    expect(defaultSqlSystemPrompt, contains('ACCOUNTLIST_V1'));
    expect(defaultSqlSystemPrompt, contains('BILLSDEPOSITS_V1'));
  });
}
