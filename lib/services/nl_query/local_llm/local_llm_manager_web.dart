import '../../../data/mmex_repository.dart';
import '../../../models/account.dart';
import '../../../models/category.dart';
import '../../../models/payee.dart';
import '../../../state/app_preferences.dart';
import '../query_intent.dart';
import 'intent_json_codec.dart';
import 'llama_server_client.dart';
import 'model_catalog.dart';
import 'sql_query_engine.dart' as sql_engine;

/// Web's local-AI implementation: the browser cannot load a multi-gigabyte
/// model or spawn a process, so there is no model download, no runtime
/// folder, and no process management here - the user runs
/// `llama-server.exe` (or any llama.cpp server build) themselves, on their
/// PC, pointed at their model, and this file simply talks HTTP to it using
/// the same pure-HTTP [LlamaServerClient] the desktop build already uses
/// against its own spawned server. The server's address is the only thing
/// this implementation needs to know, and it is remembered per browser in
/// AppPreferences (device-local, like the web file handle itself - see
/// CLAUDE.md's "Where app preferences/settings live" for the rule and why
/// this is a legitimate device-local case: the server runs on *this*
/// machine, it is not a property of the database).
const _prefsKeyEnabled = 'mmex_local_llm_enabled';
const _prefsKeyServerHost = 'mmex_local_llm_server_host';
const _prefsKeyServerPort = 'mmex_local_llm_server_port';
const _prefsKeySqlSystemPrompt = 'mmex_local_llm_sql_system_prompt';

const _defaultServerHost = '127.0.0.1';
const _defaultServerPort = 8792;

LlamaServerClient? _client;

Future<LlamaServerClient?> _ensureClient() async {
  final host = await localLlmServerHost();
  final port = await localLlmServerPort();
  final existing = _client;
  if (existing != null && existing.host == host && existing.port == port) {
    return existing;
  }
  existing?.close();
  final client = LlamaServerClient(port, host: host);
  _client = client;
  return client;
}

Future<void> _disposeClient() async {
  _client?.close();
  _client = null;
}

Future<bool> isLocalLlmEnabled() async {
  final prefs = await AppPreferences.getInstance();
  return prefs.getString(_prefsKeyEnabled) == 'true';
}

Future<void> setLocalLlmEnabled(bool value) async {
  final prefs = await AppPreferences.getInstance();
  await prefs.setString(_prefsKeyEnabled, value ? 'true' : 'false');
  if (!value) await _disposeClient();
}

Future<String?> selectedLocalLlmModelId() async => null;
Future<void> setSelectedLocalLlmModelId(String id) async {}

Future<bool> isLocalLlmModelDownloaded(LocalLlmModel model) async => false;

Stream<double?> downloadLocalLlmModel(LocalLlmModel model) {
  return Stream.error(
      UnsupportedError('Sur le web, le modèle est chargé par le serveur que tu lances toi-même.'));
}

Future<void> deleteLocalLlmModel(LocalLlmModel model) async {}

Future<String> localLlmRuntimeFolderPath() async => '';
Future<bool> isLocalLlmRuntimeAvailable() async => false;

Future<String> localLlmServerHost() async {
  final prefs = await AppPreferences.getInstance();
  return prefs.getString(_prefsKeyServerHost) ?? _defaultServerHost;
}

Future<void> setLocalLlmServerHost(String value) async {
  final prefs = await AppPreferences.getInstance();
  await prefs.setString(_prefsKeyServerHost, value);
  await _disposeClient();
}

Future<int> localLlmServerPort() async {
  final prefs = await AppPreferences.getInstance();
  return prefs.getInt(_prefsKeyServerPort) ?? _defaultServerPort;
}

Future<void> setLocalLlmServerPort(int value) async {
  final prefs = await AppPreferences.getInstance();
  await prefs.setInt(_prefsKeyServerPort, value);
  await _disposeClient();
}

Future<int> localLlmContextSize() async => 32768;
Future<void> setLocalLlmContextSize(int value) async {}
Future<int> localLlmGpuLayers() async => 999;
Future<void> setLocalLlmGpuLayers(int value) async {}

Future<void> shutdownLocalLlmEngine() => _disposeClient();

void registerLocalLlmSignalShutdownHook() {}

/// One-shot, never-polling health check - backs Settings' "Tester la
/// connexion" button (the dialog's own question flow deliberately does
/// *not* pre-check: a question is cheap to attempt and the client's own
/// per-request timeout is what bounds the wait, same as desktop's
/// never-throws, fall-back-to-rule-parser contract).
Future<bool> isLocalLlmServerReachable() async {
  final host = await localLlmServerHost();
  final port = await localLlmServerPort();
  final client = LlamaServerClient(port, host: host);
  try {
    final response = await client
        .healthCheck()
        .timeout(const Duration(seconds: 3));
    return response;
  } catch (_) {
    return false;
  } finally {
    client.close();
  }
}

Future<({QueryIntent? intent, bool periodWasExplicit})> extractIntentWithLocalLlm(
  String question, {
  required List<Category> categories,
  required List<Account> accounts,
  required List<Payee> payees,
  DateTime? now,
}) async {
  if (!await isLocalLlmEnabled()) return (intent: null, periodWasExplicit: false);
  final client = await _ensureClient();
  if (client == null) return (intent: null, periodWasExplicit: false);
  try {
    final raw = await client.ask(question);
    return decodeIntentJson(
      raw,
      question: question,
      categories: categories,
      accounts: accounts,
      payees: payees,
      now: now,
    );
  } catch (_) {
    return (intent: null, periodWasExplicit: false);
  }
}

Future<String?> askLocalLlmFreeform(String question) async {
  if (!await isLocalLlmEnabled()) return null;
  final client = await _ensureClient();
  if (client == null) return null;
  try {
    final raw = await client.askFreeform(question);
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  } catch (_) {
    return null;
  }
}

Future<MmexRepository?> openReadOnlyAdHocRepository(String dbPath) async => null;

Future<String> localLlmSqlSystemPrompt() async {
  final prefs = await AppPreferences.getInstance();
  return prefs.getString(_prefsKeySqlSystemPrompt) ?? sql_engine.defaultSqlSystemPrompt;
}

Future<void> setLocalLlmSqlSystemPrompt(String value) async {
  final prefs = await AppPreferences.getInstance();
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed == sql_engine.defaultSqlSystemPrompt) {
    await prefs.remove(_prefsKeySqlSystemPrompt);
  } else {
    await prefs.setString(_prefsKeySqlSystemPrompt, trimmed);
  }
}

/// The web counterpart of the desktop's askLocalLlmWithFullDataAccess
/// (local_llm_manager_io.dart) - same two-call SQL-generate-then-answer
/// flow, but there is no file to reopen read-only here: the browser's
/// database is the in-memory [repo] itself, passed in by the caller
/// (nl_query_dialog.dart's `widget.repo`). The safety boundary is therefore
/// sql_query_engine.dart's own SELECT-only SQL validation - the same guard
/// the desktop's ad-hoc mode already relies on as its second layer on top
/// of the OS-enforced read-only connection - rather than a read-only
/// connection, which is simply not expressible against an in-memory
/// database.
Future<String?> askLocalLlmWithFullDataAccess(
  String question, {
  String? dbPath,
  MmexRepository? repo,
  List<sql_engine.ChatTurn> history = const [],
}) async {
  if (!await isLocalLlmEnabled()) return null;
  if (repo == null) return null;
  final client = await _ensureClient();
  if (client == null) return null;
  try {
    final basePrompt = await localLlmSqlSystemPrompt();
    final systemPrompt = sql_engine.buildEffectiveSqlSystemPrompt(
      basePrompt,
      accounts: repo.getAccounts(),
      categories: repo.getCategories(onlyActive: false),
      payees: repo.getPayees(onlyActive: false),
    );
    return await sql_engine.answerViaFullSqlAccess(
      question: question,
      readOnlyRepo: repo,
      systemPrompt: systemPrompt,
      engine: client,
      history: history,
    );
  } catch (_) {
    return null;
  }
}
