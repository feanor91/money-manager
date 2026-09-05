import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:money_manager/data/mmex_repository.dart';
import 'package:money_manager/services/nl_query/local_llm/llama_server_client.dart';
import 'package:money_manager/services/nl_query/local_llm/llm_engine.dart';
import 'package:money_manager/services/nl_query/local_llm/local_llm_manager_web.dart';
import 'package:money_manager/services/nl_query/local_llm/model_catalog.dart';
import 'package:money_manager/services/nl_query/query_intent.dart';
import 'package:money_manager/services/nl_query/local_llm/sql_query_engine.dart'
    as sql_engine;
import 'package:money_manager/state/app_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers.dart';

void main() {
  late HttpServer server;
  late int port;
  late List<String> nextResponses;
  late List<String> receivedBodies;
  late List<String> receivedPaths;
  late Directory tempPrefsDir;

  setUpAll(() async {
    await initializeDateFormatting('fr_FR');
    SharedPreferences.setMockInitialValues({});
    tempPrefsDir = Directory.systemTemp.createTempSync('local_llm_web_test_');
    AppPreferences.debugOverrideInstance(
        await AppPreferences.forTestingAtPath(
            '${tempPrefsDir.path}${Platform.pathSeparator}preferences.dat'));
  });

  tearDownAll(() {
    AppPreferences.debugResetInstance();
    tempPrefsDir.deleteSync(recursive: true);
  });

  setUp(() async {
    nextResponses = [];
    receivedBodies = [];
    receivedPaths = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    server.listen((HttpRequest req) async {
      final chunks = <int>[];
      await for (final chunk in req) {
        chunks.addAll(chunk);
      }
      receivedPaths.add(req.uri.path);
      receivedBodies.add(utf8.decode(chunks));
      final res = req.response;
      res.headers.contentType = ContentType('application', 'json');
      if (req.uri.path == '/health') {
        res.write('{"status":"ok"}');
      } else {
        res.write(nextResponses.isEmpty ? '{}' : nextResponses.removeAt(0));
      }
      await res.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await shutdownLocalLlmEngine();
  });

  Future<void> pointAtServer() async {
    await setLocalLlmServerHost('127.0.0.1');
    await setLocalLlmServerPort(port);
  }

  test('healthCheck is true on a 200 and false on a dead port', () async {
    final live = LlamaServerClient(port);
    expect(await live.healthCheck(), isTrue);
    live.close();

    final dead = LlamaServerClient(1);
    expect(await dead.healthCheck(), isFalse);
    dead.close();
  });

  test('extractIntentWithLocalLlm decodes a valid intent from the server',
      () async {
    await pointAtServer();
    await setLocalLlmEnabled(true);
    nextResponses = [
      '{"content":"{\\"kind\\":\\"adHoc\\",\\"period\\":null,\\"category\\":null,'
      '\\"account\\":null,\\"payee\\":null,\\"topN\\":null,\\"metric\\":\\"sum\\",'
      '\\"transactionType\\":\\"withdrawal\\",\\"groupBy\\":\\"none\\",\\"recurringOnly\\":false}"}'
    ];

    final result = await extractIntentWithLocalLlm(
      'total des dépenses ce mois-ci',
      categories: const [],
      accounts: const [],
      payees: const [],
    );

    expect(result.intent, isNotNull);
    expect(result.intent!.kind, QueryKind.adHoc);
    expect(result.periodWasExplicit, isFalse);
    expect(receivedBodies, hasLength(1));
    expect(receivedBodies.single, contains('total des dépenses ce mois-ci'));
    expect(receivedBodies.single, contains('grammar'));
  });

  test('extractIntentWithLocalLlm returns null when disabled', () async {
    await pointAtServer();
    await setLocalLlmEnabled(false);

    final result = await extractIntentWithLocalLlm(
      'total des dépenses',
      categories: const [],
      accounts: const [],
      payees: const [],
    );

    expect(result.intent, isNull);
    expect(receivedBodies, isEmpty);
  });

  test('extractIntentWithLocalLlm returns null when the server is unreachable',
      () async {
    await setLocalLlmServerHost('127.0.0.1');
    await setLocalLlmServerPort(1);
    await setLocalLlmEnabled(true);

    final result = await extractIntentWithLocalLlm(
      'total des dépenses',
      categories: const [],
      accounts: const [],
      payees: const [],
    );

    expect(result.intent, isNull);
  });

  test('extractIntentWithLocalLlm returns null on malformed JSON', () async {
    await pointAtServer();
    await setLocalLlmEnabled(true);
    nextResponses = ['{"content":"this is not json"}'];

    final result = await extractIntentWithLocalLlm(
      'total des dépenses',
      categories: const [],
      accounts: const [],
      payees: const [],
    );

    expect(result.intent, isNull);
  });

  test('askLocalLlmWithFullDataAccess answers from the live repository',
      () async {
    final db = await openBlankTestDb();
    final repo = MmexRepository(db);
    await pointAtServer();
    await setLocalLlmEnabled(true);
    nextResponses = [
      '{"content":"{\\"sql\\":\\"SELECT COUNT(*) AS n FROM ACCOUNTLIST_V1\\"}"}',
      '{"content":"Tu as 0 compte."}',
    ];

    final outcome = await askLocalLlmWithFullDataAccess(
      'combien de comptes ?',
      repo: repo,
    );

    expect((outcome as sql_engine.SqlAccessSuccess).answer.text, 'Tu as 0 compte.');
    expect(receivedBodies, hasLength(2));
    expect(receivedPaths, ['/completion', '/completion']);
    expect(receivedBodies.first, contains('combien de comptes ?'));
    expect(receivedBodies.first, contains('ACCOUNTLIST_V1'));
    final lastDecoded = jsonDecode(receivedBodies.last) as Map<String, dynamic>;
    expect(lastDecoded['prompt'], contains('combien de comptes ?'));
    expect(lastDecoded['prompt'], contains('{"n":0}'));
    expect(lastDecoded['prompt'], isNot(contains('grammar')));
  });

  test(
      'askLocalLlmFreeform recaps the conversation history ahead of the '
      'question - regression test for the 2026-09-01 user report of a '
      'follow-up ("recommence mais analyse...") landing here with zero '
      'context and confusingly denying any financial conversation had '
      'happened at all', () async {
    await pointAtServer();
    await setLocalLlmEnabled(true);
    nextResponses = ['{"content":"D\'accord, je recommence."}'];

    final outcome = await askLocalLlmFreeform(
      'recommence mais analyse tout depuis le 01/01/2024',
      history: const [
        sql_engine.ChatTurn(
          question: 'Analyse mes revenus depuis 1 an',
          answer: 'Tes revenus ont totalisé 12 000 €.',
        ),
      ],
    );

    expect(
        (outcome as LlmFreeformSuccess).text, "D'accord, je recommence.");
    final prompt = jsonDecode(receivedBodies.single)['prompt'] as String;
    expect(prompt, contains('Analyse mes revenus depuis 1 an'));
    expect(prompt, contains('12 000 €'));
    expect(prompt, contains('recommence mais analyse tout depuis le 01/01/2024'));
  });

  test('askLocalLlmWithFullDataAccess is unavailable without a repository',
      () async {
    final outcome = await askLocalLlmWithFullDataAccess('question');
    expect(outcome, isA<sql_engine.SqlAccessUnavailable>());
  });

  test('askLocalLlmWithFullDataAccess is unavailable when disabled', () async {
    final db = await openBlankTestDb();
    final repo = MmexRepository(db);
    await pointAtServer();
    await setLocalLlmEnabled(false);

    final outcome = await askLocalLlmWithFullDataAccess('question', repo: repo);

    expect(outcome, isA<sql_engine.SqlAccessUnavailable>());
  });

  test(
      'askLocalLlmWithFullDataAccess is unavailable on invalid SQL plan, '
      'even after the one whole-plan retry (sql_query_engine.dart, '
      '2026-09-05) also comes back invalid - a DROP TABLE plan is never '
      'executed, however many attempts it takes to give up', () async {
    final db = await openBlankTestDb();
    final repo = MmexRepository(db);
    await pointAtServer();
    await setLocalLlmEnabled(true);
    nextResponses = [
      '{"content":"{\\"sql\\":\\"DROP TABLE ACCOUNTLIST_V1\\"}"}',
      '{"content":"toujours invalide, pas du JSON"}',
    ];

    final outcome = await askLocalLlmWithFullDataAccess(
      'supprime tout',
      repo: repo,
    );

    expect(outcome, isA<sql_engine.SqlAccessUnavailable>());
    // The SQL-generation call, then the one whole-plan retry - never a
    // third call, and never anything reaching the database either way.
    expect(receivedBodies, hasLength(2));
  });

  test('isLocalLlmServerReachable reflects the health endpoint', () async {
    await pointAtServer();
    expect(await isLocalLlmServerReachable(), isTrue);

    await setLocalLlmServerPort(1);
    expect(await isLocalLlmServerReachable(), isFalse);
  });

  test('model download and runtime are inert on web', () async {
    expect(await isLocalLlmModelDownloaded(localLlmModels.first), isFalse);
    expect(await isLocalLlmRuntimeAvailable(), isFalse);
    expect(await localLlmRuntimeFolderPath(), '');
    expect(await selectedLocalLlmModelId(), isNull);
    expect(await localLlmContextSize(), greaterThan(0));
    expect(await localLlmGpuLayers(), greaterThan(0));
    expect(
      await localLlmSqlSystemPrompt(),
      sql_engine.defaultSqlSystemPrompt,
    );
    await shutdownLocalLlmEngine();
  });

  test('host and port settings persist', () async {
    await setLocalLlmServerHost('192.168.1.50');
    await setLocalLlmServerPort(9999);
    expect(await localLlmServerHost(), '192.168.1.50');
    expect(await localLlmServerPort(), 9999);
  });
}
