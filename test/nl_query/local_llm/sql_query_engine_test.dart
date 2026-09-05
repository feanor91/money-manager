import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_manager/data/mmex_database.dart';
import 'package:money_manager/data/mmex_repository.dart';
import 'package:money_manager/models/account.dart';
import 'package:money_manager/models/category.dart';
import 'package:money_manager/models/payee.dart';
import 'package:money_manager/services/nl_query/local_llm/llama_server_client.dart';
import 'package:money_manager/services/nl_query/local_llm/llm_engine.dart';
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

    test(
        'rejects a WHERE clause with an unparenthesized top-level OR mixed '
        'with AND - regression test for the 2026-08-23 report that a real '
        'model response silently dropped the parens around a multi-month '
        'date filter ("novembre et décembre 2025"), which SQL precedence '
        'reinterprets as breaking the category/status filters instead of '
        'the intended "(nov OR dec) AND category AND status"', () {
      // The exact ambiguous shape the live model produced.
      expect(
        extractValidatedSql('{"sql":"SELECT * FROM CHECKINGACCOUNT_V1 T '
            "WHERE (T.CATEGID = 1 OR T.CATEGID = 2) AND T.TRANSDATE LIKE "
            "'2025-11%' OR T.TRANSDATE LIKE '2025-12%' AND T.STATUS != "
            '\'V\'"}'),
        isNull,
      );
      // The corrected, fully-parenthesized version must still pass.
      expect(
        extractValidatedSql('{"sql":"SELECT * FROM CHECKINGACCOUNT_V1 T '
            "WHERE (T.CATEGID = 1 OR T.CATEGID = 2) AND (T.TRANSDATE LIKE "
            "'2025-11%' OR T.TRANSDATE LIKE '2025-12%') AND T.STATUS != "
            '\'V\'"}'),
        isNotNull,
      );
    });

    test(
        'does not false-positive on an unrelated AND in a JOIN...ON clause '
        'alongside a top-level WHERE OR with no top-level AND', () {
      expect(
        extractValidatedSql('{"sql":"SELECT * FROM CHECKINGACCOUNT_V1 T '
            'JOIN CATEGORY_V1 C ON T.CATEGID = C.CATEGID AND C.ACTIVE = 1 '
            "WHERE T.CATEGID = 1 OR T.CATEGID = 2\"}"),
        isNotNull,
      );
    });

    test('does not false-positive on a WHERE using only OR, or only AND',
        () {
      expect(
        extractValidatedSql(
            '{"sql":"SELECT * FROM CATEGORY_V1 WHERE CATEGID = 1 OR '
            'CATEGID = 2"}'),
        isNotNull,
      );
      expect(
        extractValidatedSql(
            '{"sql":"SELECT * FROM CATEGORY_V1 WHERE CATEGID = 1 AND '
            'ACTIVE = 1"}'),
        isNotNull,
      );
    });

    test(
        'does not false-positive on a literal apostrophe/parenthesis inside '
        'a string value', () {
      expect(
        extractValidatedSql('{"sql":"SELECT * FROM CHECKINGACCOUNT_V1 '
            'WHERE NOTES = \'and (or) a b\'\'s trip\' OR STATUS = \'V\'"}'),
        isNotNull,
      );
    });
  });

  test('defaultSqlSystemPrompt documents the read-only/single-statement contract', () {
    expect(defaultSqlSystemPrompt, contains('SELECT'));
    expect(defaultSqlSystemPrompt, contains('lecture seule'));
    expect(defaultSqlSystemPrompt, contains('CHECKINGACCOUNT_V1'));
    expect(defaultSqlSystemPrompt, contains('ACCOUNTLIST_V1'));
    expect(defaultSqlSystemPrompt, contains('BILLSDEPOSITS_V1'));
  });

  test('defaultSqlSystemPrompt documents the multi-step, thematic and '
      'aggregation rules', () {
    expect(defaultSqlSystemPrompt, contains('"steps"'));
    expect(defaultSqlSystemPrompt, contains('C.CATEGNAME'));
    expect(defaultSqlSystemPrompt, contains('jamais par le texte des NOTES'));
    expect(defaultSqlSystemPrompt, contains('AGREGUE en SQL'));
    expect(defaultSqlSystemPrompt, contains('GROUP BY'));
    expect(defaultSqlSystemPrompt, contains('vocabulaire réel'));
  });

  test(
      'defaultSqlSystemPrompt tells the model a hypothetical impact/'
      'simulation question is answerable, not out of scope - 2026-09-02 '
      "user request: \"quel serait l'impact d'une perte de revenu de "
      '1300€"', () {
    expect(defaultSqlSystemPrompt, contains('hypothétique'));
    expect(defaultSqlSystemPrompt, contains("N'EST PAS une question hors cadre"));
    expect(defaultSqlSystemPrompt, contains('court terme'));
    expect(defaultSqlSystemPrompt, contains('moyen terme'));
    expect(defaultSqlSystemPrompt, contains('long terme'));
  });

  test(
      'defaultSqlSystemPrompt warns against matching CATEGNAME against the full '
      '"Parent:Enfant" vocabulary path - regression test for the 2026-08-23 report of a '
      'real subcategory ("Loisirs:Vacances") never being found', () {
    expect(defaultSqlSystemPrompt, contains('ne contient JAMAIS le chemin complet'));
    expect(defaultSqlSystemPrompt, contains("LIKE '%Loisirs:Vacances%'"));
  });

  test(
      'defaultSqlSystemPrompt requires a thematic search to also roll up '
      'sub-categories via a parent join - regression test for the '
      '2026-08-23 report that a real "Vacances" category (parent of '
      '"Voyages", "Resto", "Logement"...) came back at 7,93€ instead of '
      'the ~3 500€ actually spent, because almost every real transaction '
      'is filed on a sub-category whose own name never contains the '
      'theme word', () {
    expect(defaultSqlSystemPrompt, contains('LEFT JOIN CATEGORY_V1 P ON C.PARENTID = P.CATEGID'));
    expect(defaultSqlSystemPrompt,
        contains("(C.CATEGNAME LIKE '%vacance%' OR P.CATEGNAME LIKE '%vacance%')"));
    expect(defaultSqlSystemPrompt, contains('sous-estimation massive et silencieuse'));
  });

  test(
      'defaultSqlSystemPrompt includes a second, distinct worked example '
      '("Nourriture") of the parent-join rollup, alongside the "Vacances" '
      'one - regression test for the 2026-08-24 report that a single '
      'worked example was not enough for the model to reliably generalize '
      'the rule to other questions: it inconsistently dropped the parent '
      'join (missing sub-category data entirely) or the OR-parentheses '
      '(rejected by the ambiguity guard) depending on phrasing, until a '
      'second concrete example - explicitly including the SELECT column '
      'for the sub-category name, which the model was also silently '
      'omitting - was added', () {
    expect(defaultSqlSystemPrompt, contains('Second exemple'));
    expect(
        defaultSqlSystemPrompt,
        contains(
            "(C.CATEGNAME LIKE '%nourriture%' OR P.CATEGNAME LIKE '%nourriture%')"));
    expect(defaultSqlSystemPrompt,
        contains('C.CATEGNAME AS sous_categorie'));
    expect(defaultSqlSystemPrompt, contains('GROUP BY mois, sous_categorie'));
  });

  test(
      'defaultSqlSystemPrompt requires DELETEDTIME IS NULL OR = \'\', never = '
      "'' alone - regression test for the 2026-08-23 report that a real "
      'category with real transactions ("Vacances") always came back empty: '
      'the real database stores "not deleted" as either NULL or \'\' '
      "depending on the row (confirmed directly against MesComptes.mmb - "
      "most rows are NULL), so a bare DELETEDTIME = '' filter silently "
      'dropped the vast majority of real transactions, not just this one '
      'category.', () {
    expect(defaultSqlSystemPrompt,
        contains("(DELETEDTIME IS NULL OR DELETEDTIME = '')"));
    expect(defaultSqlSystemPrompt,
        contains("(T.DELETEDTIME IS NULL OR T.DELETEDTIME = '')"));
    expect(defaultSqlSystemPrompt, isNot(contains("AND T.DELETEDTIME = ''")));
  });

  group('extractValidatedSqlPlan', () {
    test('accepts the single-sql form as one unlabeled step', () {
      final plan =
          extractValidatedSqlPlan('{"sql":"SELECT * FROM CATEGORY_V1"}');
      expect(plan, hasLength(1));
      expect(plan!.first.objectif, isEmpty);
      expect(plan.first.sql, 'SELECT * FROM CATEGORY_V1');
    });

    test('accepts a multi-step plan, preserving order and labels', () {
      final plan = extractValidatedSqlPlan(
          '{"steps":[{"objectif":"total","sql":"SELECT 1"},'
          '{"objectif":"détail","sql":"SELECT 2"}]}');
      expect(plan, hasLength(2));
      expect(plan!.first.objectif, 'total');
      expect(plan.first.sql, 'SELECT 1');
      expect(plan[1].objectif, 'détail');
      expect(plan[1].sql, 'SELECT 2');
    });

    test('a missing objectif is tolerated and filled in', () {
      final plan =
          extractValidatedSqlPlan('{"steps":[{"sql":"SELECT 1"}]}');
      expect(plan, hasLength(1));
      expect(plan!.first.objectif, 'résultat');
    });

    test('rejects a response with neither sql nor steps', () {
      expect(extractValidatedSqlPlan('{"raison":"non"}'), isNull);
    });

    test('rejects an empty steps array', () {
      expect(extractValidatedSqlPlan('{"steps":[]}'), isNull);
    });

    test('rejects a step whose sql is not a SELECT', () {
      expect(
        extractValidatedSqlPlan(
            '{"steps":[{"objectif":"a","sql":"Voici la réponse : 42"}]}'),
        isNull,
      );
    });

    test('rejects a step containing a write keyword', () {
      expect(
        extractValidatedSqlPlan(
            '{"steps":[{"objectif":"a","sql":"DELETE FROM CATEGORY_V1"}]}'),
        isNull,
      );
    });

    test('rejects a step with an empty sql string', () {
      expect(
        extractValidatedSqlPlan('{"steps":[{"sql":""}]}'),
        isNull,
      );
    });

    test('rejects invalid JSON entirely', () {
      expect(extractValidatedSqlPlan('pas du json du tout'), isNull);
    });

    test('rejects a plan with more than the maximum number of steps', () {
      final steps = List.generate(
        5,
        (i) => '{"objectif":"a$i","sql":"SELECT $i"}',
      ).join(',');
      expect(extractValidatedSqlPlan('{"steps":[$steps]}'), isNull);
    });

    test('accepts a plan at exactly the maximum number of steps', () {
      final steps = List.generate(
        4,
        (i) => '{"objectif":"a$i","sql":"SELECT $i"}',
      ).join(',');
      final plan = extractValidatedSqlPlan('{"steps":[$steps]}');
      expect(plan, hasLength(4));
    });
  });

  group('buildEffectiveSqlSystemPrompt', () {
    test('appends the real account, category path and payee names', () {
      final prompt = buildEffectiveSqlSystemPrompt(
        'Prompt de base.',
        accounts: const [
          Account(
              id: 1,
              name: 'Compte Courant',
              type: 'Checking',
              status: 'Open',
              initialBalance: 0,
              currencyId: 1,
              favorite: false)
        ],
        categories: const [
          Category(id: 1, name: 'Alimentation', parentId: null, active: true),
          Category(id: 2, name: 'Restaurant', parentId: 1, active: true),
        ],
        payees: const [
          Payee(id: 1, name: 'Carrefour', active: true)
        ],
      );
      expect(prompt, startsWith('Prompt de base.'));
      expect(prompt, contains('Compte Courant'));
      expect(prompt, contains('Alimentation:Restaurant'));
      expect(prompt, contains('Carrefour'));
    });

    test('is a pure function: the base prompt text is never mutated', () {
      const base = 'Prompt de base.';
      buildEffectiveSqlSystemPrompt(
        base,
        accounts: const [],
        categories: const [],
      );
      expect(base, 'Prompt de base.');
    });
  });

  group('buildAnswerFormattingPrompt', () {
    final oneResult = [
      const StepResult(
        objectif: '',
        rowsJson: '[{"total": 100}]',
        rowCount: 1,
        truncated: false,
      )
    ];

    test('a simple question gets the short-answer instruction, no truncation notice',
        () {
      final prompt = buildAnswerFormattingPrompt(
        'combien ai-je dépensé ?',
        oneResult,
        truncated: false,
      );
      expect(prompt, contains('une ou deux phrases'));
      expect(prompt, isNot(contains('tronqué')));
    });

    test('an analysis-style question gets the structured report instruction',
        () {
      final prompt = buildAnswerFormattingPrompt(
        'analyse mes dépenses sur 3 mois',
        oneResult,
        truncated: false,
      );
      expect(prompt, contains('rapport'));
      expect(prompt, contains('sections'));
      expect(prompt, isNot(contains('une ou deux phrases')));
    });

    test(
        'an impact/simulation question also gets the structured report '
        'instruction - 2026-09-02 user request: "quel serait l\'impact à '
        'court, moyen et long terme d\'une perte de revenu de 1300€"',
        () {
      final prompt = buildAnswerFormattingPrompt(
        "Quel serait l'impact à court, moyen et long terme d'une perte de "
        'revenu de 1300€ sur mon compte',
        oneResult,
        truncated: false,
      );
      expect(prompt, contains('rapport'));
      expect(prompt, contains('sections'));
      expect(prompt, isNot(contains('une ou deux phrases')));
    });

    test('a truncated result is explicitly announced to the model', () {
      final prompt = buildAnswerFormattingPrompt(
        'analyse mes dépenses sur 3 mois',
        oneResult,
        truncated: true,
      );
      expect(prompt, contains('partiel'));
    });

    test('the per-step flag marks which specific result is partial', () {
      final results = [
        const StepResult(
          objectif: 'total',
          rowsJson: '[{"total": 100}]',
          rowCount: 1,
          truncated: false,
        ),
        const StepResult(
          objectif: 'détail',
          rowsJson: '[{"categorie": "Loisirs"}]',
          rowCount: 1,
          truncated: true,
        ),
      ];
      final prompt = buildAnswerFormattingPrompt(
        'analyse mes dépenses',
        results,
        truncated: true,
      );
      // The notice is attached to the truncated step's result, right after
      // its JSON, not the complete one's.
      expect(
        prompt.indexOf('Ce résultat est partiel'),
        greaterThan(prompt.indexOf('« détail »')),
      );
      expect(
        prompt.indexOf('Ce résultat est partiel'),
        greaterThan(prompt.indexOf('Loisirs')),
      );
      expect(
        prompt.indexOf('Ce résultat est partiel'),
        greaterThan(prompt.indexOf('« total »')),
      );
    });
  });

  group('answerViaFullSqlAccess', () {
    test('runs every step in order and grounds the answer in all results',
        () async {
      final repo = _FakeRepo(perStepResults: [
        [{'total': 100}],
        [{'categorie': 'Loisirs', 'total': 60}],
      ]);
      final engine = _FakeEngine(responses: [
        '{"steps":[{"objectif":"total","sql":"SELECT 1"},{"objectif":"détail","sql":"SELECT 2"}]}',
        'Réponse finale.',
      ]);
      final outcome = await answerViaFullSqlAccess(
        question: 'analyse mes dépenses',
        readOnlyRepo: repo,
        systemPrompt: 'Prompt.',
        engine: engine,
      );
      final answer = (outcome as SqlAccessSuccess).answer;
      expect(answer.text, 'Réponse finale.');
      expect(repo.executed, [
        'SELECT * FROM (SELECT 1) LIMIT 5000',
        'SELECT * FROM (SELECT 2) LIMIT 5000',
      ]);
      // engine.prompts holds the SQL-generation call AND the answer
      // formatting call - the formatting one is the last.
      final formattingPrompt = engine.prompts.last;
      expect(formattingPrompt, contains('total'));
      expect(formattingPrompt, contains('détail'));
      expect(formattingPrompt, contains('100'));
      expect(formattingPrompt, contains('Loisirs'));
      expect(formattingPrompt, contains('rapport'));
    });

    test(
        'the CSV alongside the answer has one labeled section per step, '
        'with a header row, and stays a separate table per step rather '
        'than merging them - regression test for the 2026-08-27 "export '
        'en CSV" request', () async {
      final repo = _FakeRepo(perStepResults: [
        [{'total': 100}],
        [
          {'categorie': 'Loisirs', 'total': 60},
          {'categorie': 'Nourriture', 'total': 40},
        ],
      ]);
      final engine = _FakeEngine(responses: [
        '{"steps":[{"objectif":"Total","sql":"SELECT 1"},{"objectif":"Détail","sql":"SELECT 2"}]}',
        'Réponse finale.',
      ]);
      final outcome = await answerViaFullSqlAccess(
        question: 'analyse mes dépenses',
        readOnlyRepo: repo,
        systemPrompt: 'Prompt.',
        engine: engine,
      );
      expect(outcome, isA<SqlAccessSuccess>());
      final csv = (outcome as SqlAccessSuccess).answer.csv;
      expect(csv, contains('# Total'));
      expect(csv, contains('# Détail'));
      expect(csv, contains('total\n100'));
      expect(csv, contains('categorie,total'));
      expect(csv, contains('Loisirs,60'));
      expect(csv, contains('Nourriture,40'));
    });

    test('CSV fields containing a comma or a quote are RFC 4180-escaped',
        () async {
      final repo = _FakeRepo(perStepResults: [
        [
          {'libelle': 'Un, avec virgule', 'note': 'Il a dit "salut"'}
        ],
      ]);
      final engine = _FakeEngine(responses: [
        '{"sql":"SELECT 1"}',
        'Réponse finale.',
      ]);
      final outcome = await answerViaFullSqlAccess(
        question: 'liste',
        readOnlyRepo: repo,
        systemPrompt: 'Prompt.',
        engine: engine,
      );
      final answer = (outcome as SqlAccessSuccess).answer;
      expect(answer.csv, contains('"Un, avec virgule"'));
      expect(answer.csv, contains('"Il a dit ""salut"""'));
    });

    test(
        'the answer-formatting call is warned that JSON numbers use a '
        'decimal POINT, not a French thousands separator - regression test '
        'for the 2026-08-23 report of a real 7.93€ transaction being '
        'reformatted as "7 930,00 €" (a 1000x error)', () async {
      final repo = _FakeRepo(perStepResults: [
        [{'total': 7.93}]
      ]);
      final engine = _FakeEngine(responses: [
        '{"sql":"SELECT 1"}',
        'Réponse finale.',
      ]);
      await answerViaFullSqlAccess(
        question: 'combien ?',
        readOnlyRepo: repo,
        systemPrompt: 'Prompt.',
        engine: engine,
      );
      final formattingPrompt = engine.prompts.last;
      expect(formattingPrompt, contains('7.93'));
      expect(formattingPrompt, contains('séparateur DÉCIMAL'));
      expect(formattingPrompt, contains('"7,93 €"'));
    });

    test('still supports the single-sql form', () async {
      final repo = _FakeRepo(perStepResults: [
        [{'total': 42}]
      ]);
      final engine = _FakeEngine(responses: [
        '{"sql":"SELECT 1"}',
        'Réponse finale.',
      ]);
      final outcome = await answerViaFullSqlAccess(
        question: 'combien ?',
        readOnlyRepo: repo,
        systemPrompt: 'Prompt.',
        engine: engine,
      );
      expect((outcome as SqlAccessSuccess).answer.text, 'Réponse finale.');
      expect(repo.executed, ['SELECT * FROM (SELECT 1) LIMIT 5000']);
    });

    test('an invalid plan is retried once, and reported as unavailable '
        '(not an error) if the retry is invalid too, without touching the '
        'database', () async {
      final repo = _FakeRepo(perStepResults: []);
      final engine = _FakeEngine(responses: [
        '{"raison":"non"}',
        '{"raison":"non"}', // the one whole-plan retry - still declines
      ]);
      final outcome = await answerViaFullSqlAccess(
        question: 'x',
        readOnlyRepo: repo,
        systemPrompt: 'Prompt.',
        engine: engine,
      );
      expect(outcome, isA<SqlAccessUnavailable>());
      expect(repo.executed, isEmpty);
      expect(engine.systemPrompts, hasLength(2));
      // Two SQL-generation attempts - no answer-formatting call.
      expect(engine.prompts, hasLength(2));
    });

    test('an invalid plan on the first attempt is retried once and '
        'succeeds if the second attempt is valid - regression test for the '
        '2026-09-05 user report of a question falling all the way to a '
        'plain, data-blind AI reply ("je n\'ai pas accès à vos données...") '
        'that a fresh identical attempt would very likely have answered',
        () async {
      final repo = _FakeRepo(perStepResults: [
        [{'total': 42}]
      ]);
      final engine = _FakeEngine(responses: [
        'Voici une explication au lieu du JSON attendu.',
        '{"sql":"SELECT 1"}',
        'Réponse finale.',
      ]);
      final outcome = await answerViaFullSqlAccess(
        question: 'x',
        readOnlyRepo: repo,
        systemPrompt: 'Prompt.',
        engine: engine,
      );
      expect((outcome as SqlAccessSuccess).answer.text, 'Réponse finale.');
      expect(engine.systemPrompts, hasLength(2));
    });

    test(
        'a query that keeps erroring even after a fix attempt fails closed '
        'with a real SqlAccessError, never throws and never silently looks '
        'like "not understood" - regression test for the 2026-09-01 user '
        'report of a real cloud AI failure surfacing as a misleading '
        'fallback answer instead of a real error', () async {
      final repo = _FakeRepo(perStepResults: [], failOnQuery: true);
      final engine = _FakeEngine(responses: [
        '{"sql":"SELECT 1"}',
        '{"sql":"SELECT 1"}', // the one fix attempt - still fails, repo
        // always fails regardless of the SQL text.
      ]);
      final outcome = await answerViaFullSqlAccess(
        question: 'x',
        readOnlyRepo: repo,
        systemPrompt: 'Prompt.',
        engine: engine,
      );
      expect(outcome, isA<SqlAccessError>());
      // The SQL-generation call, then one fix attempt - no answer-
      // formatting call, since the SQL never actually ran successfully.
      expect(engine.prompts, hasLength(2));
    });

    test(
        'a query with a typo the model can fix is retried once and '
        'succeeds - regression test for the 2026-09-05 user report of '
        '"TRANSSDATE" (typo for TRANSDATE) surfacing as a raw '
        'SqliteException instead of ever giving the model a chance to '
        'notice and correct its own mistake', () async {
      final repo = _FakeRepo(
        perStepResults: [
          [{'total': 42}]
        ],
        failFirstNQueries: 1,
      );
      final engine = _FakeEngine(responses: [
        '{"sql":"SELECT T.TRANSSDATE FROM CHECKINGACCOUNT_V1 T"}',
        '{"sql":"SELECT T.TRANSDATE FROM CHECKINGACCOUNT_V1 T"}', // the fix
        'Réponse finale.',
      ]);
      final outcome = await answerViaFullSqlAccess(
        question: 'x',
        readOnlyRepo: repo,
        systemPrompt: 'Prompt.',
        engine: engine,
      );
      expect((outcome as SqlAccessSuccess).answer.text, 'Réponse finale.');
      // The fix prompt names the exact failing SQL and the real error.
      expect(engine.prompts[1], contains('TRANSSDATE'));
      expect(engine.prompts[1], contains('erreur simulée'));
      // The corrected SQL is what actually reached the database.
      expect(repo.executed.last,
          'SELECT * FROM (SELECT T.TRANSDATE FROM CHECKINGACCOUNT_V1 T) LIMIT 5000');
    });

    test('the SQL-generation call itself failing is reported as a '
        'SqlAccessError, not silently swallowed', () async {
      final repo = _FakeRepo(perStepResults: []);
      final engine = _FakeEngine(responses: [], failNextCall: true);
      final outcome = await answerViaFullSqlAccess(
        question: 'x',
        readOnlyRepo: repo,
        systemPrompt: 'Prompt.',
        engine: engine,
      );
      expect(outcome, isA<SqlAccessError>());
      expect(repo.executed, isEmpty);
    });

    test('an oversized result is truncated and the notice reaches the model',
        () async {
      final bigRows = List.generate(
          2000,
          (i) => {
                'id': i,
                'notes': 'x' * 50,
              });
      final repo = _FakeRepo(perStepResults: [bigRows]);
      final engine = _FakeEngine(responses: [
        '{"sql":"SELECT 1"}',
        'Réponse finale.',
      ]);
      final outcome = await answerViaFullSqlAccess(
        question: 'analyse mes dépenses',
        readOnlyRepo: repo,
        systemPrompt: 'Prompt.',
        engine: engine,
      );
      expect((outcome as SqlAccessSuccess).answer.text, 'Réponse finale.');
      // The answer-formatting call is the last one recorded.
      final formattingPrompt = engine.prompts.last;
      expect(formattingPrompt, contains('partiel'));
      expect(formattingPrompt, contains('retirées'));
      // The model must still receive *valid* JSON - the truncation drops
      // whole rows from the end, never cuts mid-string/mid-number.
      final jsonStart = formattingPrompt.indexOf('[{');
      final jsonEnd = formattingPrompt.indexOf(']', jsonStart);
      expect(jsonStart, isNot(-1));
      expect(jsonEnd, isNot(-1));
      expect(
        () => jsonDecode(formattingPrompt.substring(jsonStart, jsonEnd + 1)),
        returnsNormally,
      );
    });

    test('the effective system prompt (vocabulary appended) is used as-is',
        () async {
      final repo = _FakeRepo(perStepResults: [
        [{'total': 1}]
      ]);
      final engine = _FakeEngine(responses: [
        '{"sql":"SELECT 1"}',
        'Réponse finale.',
      ]);
      await answerViaFullSqlAccess(
        question: 'combien ?',
        readOnlyRepo: repo,
        systemPrompt: 'Prompt.\n\nVocabulaire réel : Compte Courant',
        engine: engine,
      );
      expect(engine.systemPrompts.single,
          contains('Vocabulaire réel : Compte Courant'));
    });
  });
}

class _FakeEngine extends LlamaServerClient {
  final List<String> responses;
  final List<String> prompts = [];
  final List<String> systemPrompts = [];
  final bool failNextCall;
  int _call = 0;
  _FakeEngine({required this.responses, this.failNextCall = false}) : super(1);

  @override
  Future<LlmResponse> askWithSystemPrompt(String systemPrompt, String question) async {
    if (failNextCall) {
      throw StateError('Le service IA a répondu 429.');
    }
    systemPrompts.add(systemPrompt);
    final sep = String.fromCharCode(0);
    prompts.add('$systemPrompt$sep$question');
    return LlmResponse(responses[_call++]);
  }

  @override
  Future<LlmResponse> askFreeformWithSystemPrompt(String systemPrompt, String question) async {
    final sep = String.fromCharCode(0);
    prompts.add('$systemPrompt$sep$question');
    return LlmResponse(responses[_call++]);
  }
}

class _FakeRepo implements MmexRepository {
  final _FakeDb _db;
  _FakeRepo({
    required List<List<Map<String, Object?>>> perStepResults,
    bool failOnQuery = false,
    int failFirstNQueries = 0,
  }) : _db = _FakeDb(
            results: perStepResults,
            failOnQuery: failOnQuery,
            failFirstNQueries: failFirstNQueries,
          );

  List<String> get executed => _db.executed;

  @override
  MmexDatabase get db => _db;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('non nécessaire pour ce test');
}

class _FakeDb implements MmexDatabase {
  final List<List<Map<String, Object?>>> results;
  final List<String> executed = [];
  final bool failOnQuery;

  /// The first [failFirstNQueries] calls to [query] throw - lets a test
  /// simulate the model's *fixed* SQL (once retried) actually succeeding,
  /// unlike [failOnQuery] which fails forever.
  final int failFirstNQueries;
  int _call = 0;
  _FakeDb({
    required this.results,
    required this.failOnQuery,
    this.failFirstNQueries = 0,
  });

  @override
  String get label => 'fake';

  @override
  bool get isDirectlyPersisted => false;

  @override
  List<Map<String, Object?>> query(String sql, [List<Object?> params = const []]) {
    executed.add(sql);
    if (failOnQuery || executed.length <= failFirstNQueries) {
      throw StateError('erreur simulée');
    }
    final result = results[_call % results.length];
    _call++;
    return result;
  }

  @override
  int execute(String sql, [List<Object?> params = const []]) =>
      throw UnsupportedError('non applicable');

  @override
  void transaction(void Function() action) =>
      throw UnsupportedError('non applicable');

  @override
  List<int> exportBytes() => throw UnsupportedError('non applicable');

  @override
  void dispose() {}
}
