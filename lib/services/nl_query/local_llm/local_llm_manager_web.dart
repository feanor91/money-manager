import '../../../data/mmex_repository.dart';
import '../../../models/account.dart';
import '../../../models/category.dart';
import '../../../models/payee.dart';
import '../../../state/app_preferences.dart';
import '../query_intent.dart';
import 'cloud_llm_client.dart';
import 'intent_json_codec.dart';
import 'llama_server_client.dart';
import 'llm_engine.dart';
import 'model_catalog.dart';
import 'sql_query_engine.dart' as sql_engine;

/// Web's local-AI implementation: the browser cannot load a multi-gigabyte
/// model or spawn a process, so there is no model download, no runtime
/// folder, and no process management here. Two backends instead (see
/// [useCloudLlm]), same choice local_llm_manager_io.dart's desktop build
/// now offers:
///
/// - "Mon PC" (default, unchanged since this file's original design): the
///   user runs `llama-server.exe` (or any llama.cpp server build)
///   themselves, on their PC, pointed at their model, and this file talks
///   HTTP to it via [LlamaServerClient] - its address is host/port below.
/// - "Cloud" (2026-08-31): talks to any OpenAI-compatible endpoint via
///   [CloudLlmClient] instead - a real hosted provider, or (see that
///   class's own doc comment) the same PC reached remotely instead of over
///   the local network.
///
/// Every setting here is remembered per browser in AppPreferences (device-
/// local, like the web file handle itself - see CLAUDE.md's "Where app
/// preferences/settings live" for the rule and why this is a legitimate
/// device-local case: none of this describes a property of the database).
const _prefsKeyEnabled = 'mmex_local_llm_enabled';
const _prefsKeyUseCloud = 'mmex_local_llm_use_cloud';
const _prefsKeyServerHost = 'mmex_local_llm_server_host';
const _prefsKeyServerPort = 'mmex_local_llm_server_port';
const _prefsKeySqlSystemPrompt = 'mmex_local_llm_sql_system_prompt';
const _prefsKeyCloudEndpoint = 'mmex_cloud_llm_endpoint';
const _prefsKeyCloudModel = 'mmex_cloud_llm_model';
const _prefsKeyCloudApiKey = 'mmex_cloud_llm_api_key';

const _defaultServerHost = '127.0.0.1';
const _defaultServerPort = 8792;

LlamaServerClient? _client;
CloudLlmClient? _cloudClient;

/// (endpoint, model, apiKey) the currently-held [_cloudClient] was built
/// from - same "notice a config change and rebuild" role
/// local_llm_manager_io.dart's own `_cloudConfig` plays.
(String, String, String)? _cloudConfig;

Future<LlamaServerClient?> _ensureLocalClient() async {
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

/// Builds a fresh, throwaway [CloudLlmClient] from the current cloud
/// settings - used by [isLocalLlmServerReachable]'s "Tester la connexion"
/// button, which deliberately never reuses or caches a client so a test
/// always reflects whatever is in the fields right now, even before
/// "Appliquer" is pressed. Null if either the endpoint or the model name
/// is blank - nothing meaningful to test yet.
Future<CloudLlmClient?> _buildCloudClient() async {
  final endpoint = await cloudLlmEndpoint();
  final model = await cloudLlmModel();
  if (endpoint.isEmpty || model.isEmpty) return null;
  return CloudLlmClient(
      baseUrl: endpoint, apiKey: await cloudLlmApiKey(), model: model);
}

Future<CloudLlmClient?> _ensureCloudClient() async {
  final endpoint = await cloudLlmEndpoint();
  final model = await cloudLlmModel();
  if (endpoint.isEmpty || model.isEmpty) return null;
  final apiKey = await cloudLlmApiKey();
  final config = (endpoint, model, apiKey);

  if (_cloudClient != null && _cloudConfig == config) return _cloudClient;
  _cloudClient?.close();
  final client = CloudLlmClient(baseUrl: endpoint, apiKey: apiKey, model: model);
  _cloudClient = client;
  _cloudConfig = config;
  return client;
}

/// Picks whichever backend [useCloudLlm] currently selects - the single
/// entry point every question-answering function below goes through.
Future<LlmEngine?> _ensureEngine() async {
  if (await useCloudLlm()) return _ensureCloudClient();
  return _ensureLocalClient();
}

Future<void> _disposeClient() async {
  _client?.close();
  _client = null;
  _cloudClient?.close();
  _cloudClient = null;
  _cloudConfig = null;
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

/// Whether "Poser une question" talks to a cloud/remote OpenAI-compatible
/// endpoint ([CloudLlmClient]) instead of a llama.cpp server pointed at by
/// host/port ([LlamaServerClient]) - see this file's own doc comment.
/// Defaults to false (unchanged pre-2026-08-31 behavior) so an existing
/// setup never silently switches backend under an upgrade.
Future<bool> useCloudLlm() async {
  final prefs = await AppPreferences.getInstance();
  return prefs.getString(_prefsKeyUseCloud) == 'true';
}

Future<void> setUseCloudLlm(bool value) async {
  final prefs = await AppPreferences.getInstance();
  await prefs.setString(_prefsKeyUseCloud, value ? 'true' : 'false');
  await _disposeClient();
}

Future<String?> selectedLocalLlmModelId() async => null;
Future<void> setSelectedLocalLlmModelId(String id) async {}

Future<bool> isLocalLlmModelDownloaded(LocalLlmModel model) async => false;

Stream<double?> downloadLocalLlmModel(LocalLlmModel model) {
  return Stream.error(UnsupportedError(
      'Sur le web, le modèle est chargé par le serveur que tu lances toi-même.'));
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
  if (await useCloudLlm()) {
    final client = await _buildCloudClient();
    if (client == null) return false;
    try {
      return await client.healthCheck();
    } finally {
      client.close();
    }
  }
  final host = await localLlmServerHost();
  final port = await localLlmServerPort();
  final client = LlamaServerClient(port, host: host);
  try {
    final response =
        await client.healthCheck().timeout(const Duration(seconds: 3));
    return response;
  } catch (_) {
    return false;
  } finally {
    client.close();
  }
}

/// See local_llm_manager_io.dart's own copy - null in "Mon PC" mode (a
/// remote llama.cpp server whose model name this app was never told, only
/// its host/port).
Future<String?> currentLlmModelLabel() async {
  if (!await isLocalLlmEnabled()) return null;
  if (await useCloudLlm()) {
    final model = await cloudLlmModel();
    return model.isEmpty ? null : model;
  }
  return null;
}

/// Cloud/remote AI settings (2026-08-31) - see [useCloudLlm]/
/// cloud_llm_client.dart. [cloudLlmEndpoint] has no trailing slash and
/// includes any version segment the provider needs (e.g.
/// "https://api.openai.com/v1") - see CloudLlmClient's own doc comment.
Future<String> cloudLlmEndpoint() async {
  final prefs = await AppPreferences.getInstance();
  return prefs.getString(_prefsKeyCloudEndpoint) ?? '';
}

Future<void> setCloudLlmEndpoint(String value) async {
  final prefs = await AppPreferences.getInstance();
  await prefs.setString(_prefsKeyCloudEndpoint, value);
  await _disposeClient();
}

Future<String> cloudLlmModel() async {
  final prefs = await AppPreferences.getInstance();
  return prefs.getString(_prefsKeyCloudModel) ?? '';
}

Future<void> setCloudLlmModel(String value) async {
  final prefs = await AppPreferences.getInstance();
  await prefs.setString(_prefsKeyCloudModel, value);
  await _disposeClient();
}

Future<String> cloudLlmApiKey() async {
  final prefs = await AppPreferences.getInstance();
  return prefs.getString(_prefsKeyCloudApiKey) ?? '';
}

Future<void> setCloudLlmApiKey(String value) async {
  final prefs = await AppPreferences.getInstance();
  await prefs.setString(_prefsKeyCloudApiKey, value);
  await _disposeClient();
}

Future<({QueryIntent? intent, bool periodWasExplicit})>
    extractIntentWithLocalLlm(
  String question, {
  required List<Category> categories,
  required List<Account> accounts,
  required List<Payee> payees,
  DateTime? now,
}) async {
  if (!await isLocalLlmEnabled()) {
    return (intent: null, periodWasExplicit: false);
  }
  final engine = await _ensureEngine();
  if (engine == null) return (intent: null, periodWasExplicit: false);
  try {
    final raw = await engine.ask(question);
    return decodeIntentJson(
      raw.text,
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

Future<LlmFreeformOutcome> askLocalLlmFreeform(String question) async {
  if (!await isLocalLlmEnabled()) return const LlmFreeformUnavailable();
  final engine = await _ensureEngine();
  if (engine == null) return const LlmFreeformUnavailable();
  try {
    final raw = await engine.askFreeform(question);
    final trimmed = raw.text.trim();
    return trimmed.isEmpty
        ? const LlmFreeformUnavailable()
        : LlmFreeformSuccess(trimmed, tokensPerSecond: raw.tokensPerSecond);
  } catch (e) {
    return LlmFreeformError(e is StateError ? e.message : '$e');
  }
}

Future<MmexRepository?> openReadOnlyAdHocRepository(String dbPath) async =>
    null;

Future<String> localLlmSqlSystemPrompt() async {
  final prefs = await AppPreferences.getInstance();
  return prefs.getString(_prefsKeySqlSystemPrompt) ??
      sql_engine.defaultSqlSystemPrompt;
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
Future<sql_engine.SqlAccessOutcome> askLocalLlmWithFullDataAccess(
  String question, {
  String? dbPath,
  MmexRepository? repo,
  List<sql_engine.ChatTurn> history = const [],
}) async {
  if (!await isLocalLlmEnabled()) return const sql_engine.SqlAccessUnavailable();
  if (repo == null) return const sql_engine.SqlAccessUnavailable();
  final engine = await _ensureEngine();
  if (engine == null) return const sql_engine.SqlAccessUnavailable();
  final basePrompt = await localLlmSqlSystemPrompt();
  final systemPrompt = sql_engine.buildEffectiveSqlSystemPrompt(
    basePrompt,
    accounts: repo.getAccounts(),
    categories: repo.getCategories(onlyActive: false),
    payees: repo.getPayees(onlyActive: false),
  );
  return sql_engine.answerViaFullSqlAccess(
    question: question,
    readOnlyRepo: repo,
    systemPrompt: systemPrompt,
    engine: engine,
    history: history,
  );
}
