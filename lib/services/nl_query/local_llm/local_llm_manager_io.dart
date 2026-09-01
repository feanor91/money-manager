import 'dart:async';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../../../data/mmex_database.dart';
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
import 'model_downloader.dart' as downloader;
import 'sql_query_engine.dart' as sql_engine;

/// Android also compiles this file (dart.library.io covers both, same
/// reason as update_prompt_io.dart). Windows desktop gets the full local-
/// model experience below (spawns its own `llama-server.exe`, gated on
/// [Platform.isWindows] throughout, unchanged since this file's original
/// Windows-only design) - plus, since 2026-08-31, the option to switch to
/// the same cloud backend Android uses instead (see [useCloudLlm]).
/// Android (2026-08-31) only ever has the cloud path - see
/// [_isAndroid]/[_supported]/[_ensureCloudEngine] - a phone can neither
/// download a multi-gigabyte model nor spawn a process, so it only ever
/// talks to an external OpenAI-compatible endpoint ([CloudLlmClient]): a
/// real hosted provider, or the user's own PC reached remotely (see
/// cloud_llm_client.dart's doc comment). Every desktop-only setting below
/// (model selection/download, runtime folder, spawned-server
/// host/port/context/GPU layers) stays gated on [Platform.isWindows] alone
/// and is simply never shown to Android by local_llm_settings_card.dart's
/// Android variant.
bool get _isAndroid => Platform.isAndroid;
bool get _supported => Platform.isWindows || Platform.isAndroid;

const _prefsKeyEnabled = 'mmex_local_llm_enabled';
const _prefsKeyUseCloud = 'mmex_local_llm_use_cloud';
const _prefsKeySelectedModel = 'mmex_local_llm_selected_model';
const _prefsKeyServerHost = 'mmex_local_llm_server_host';
const _prefsKeyServerPort = 'mmex_local_llm_server_port';
const _prefsKeyContextSize = 'mmex_local_llm_context_size';
const _prefsKeyGpuLayers = 'mmex_local_llm_gpu_layers';
const _prefsKeySqlSystemPrompt = 'mmex_local_llm_sql_system_prompt';

/// Whether "Poser une question" talks to a cloud/remote OpenAI-compatible
/// endpoint ([CloudLlmClient]) instead of this machine's own spawned local
/// model - always true on Android (there is no other option there, see
/// this file's own doc comment); on Windows a genuine user choice,
/// defaulting to false so an existing desktop setup never silently
/// switches backend under an upgrade. False (never persisted, nothing to
/// switch) everywhere else.
Future<bool> useCloudLlm() async {
  if (_isAndroid) return true;
  if (!Platform.isWindows) return false;
  final prefs = await AppPreferences.getInstance();
  return prefs.getString(_prefsKeyUseCloud) == 'true';
}

Future<void> setUseCloudLlm(bool value) async {
  if (!Platform.isWindows) return; // Android has no toggle to flip
  final prefs = await AppPreferences.getInstance();
  await prefs.setString(_prefsKeyUseCloud, value ? 'true' : 'false');
  await _disposeEngine();
}

/// Cloud/remote AI settings - see [useCloudLlm]/[_ensureCloudEngine].
/// Device-local like every other setting in this file (CLAUDE.md's "must
/// stay local" exception doesn't apply here either, same reasoning as the
/// rest of this file: this describes a resource/credential tied to *this
/// machine*, not a property of the database).
const _prefsKeyCloudEndpoint = 'mmex_cloud_llm_endpoint';
const _prefsKeyCloudModel = 'mmex_cloud_llm_model';
const _prefsKeyCloudApiKey = 'mmex_cloud_llm_api_key';

Future<String> cloudLlmEndpoint() async {
  if (!_supported) return '';
  final prefs = await AppPreferences.getInstance();
  return prefs.getString(_prefsKeyCloudEndpoint) ?? '';
}

Future<void> setCloudLlmEndpoint(String value) async {
  if (!_supported) return;
  final prefs = await AppPreferences.getInstance();
  await prefs.setString(_prefsKeyCloudEndpoint, value);
  await _disposeEngine();
}

Future<String> cloudLlmModel() async {
  if (!_supported) return '';
  final prefs = await AppPreferences.getInstance();
  return prefs.getString(_prefsKeyCloudModel) ?? '';
}

Future<void> setCloudLlmModel(String value) async {
  if (!_supported) return;
  final prefs = await AppPreferences.getInstance();
  await prefs.setString(_prefsKeyCloudModel, value);
  await _disposeEngine();
}

Future<String> cloudLlmApiKey() async {
  if (!_supported) return '';
  final prefs = await AppPreferences.getInstance();
  return prefs.getString(_prefsKeyCloudApiKey) ?? '';
}

Future<void> setCloudLlmApiKey(String value) async {
  if (!_supported) return;
  final prefs = await AppPreferences.getInstance();
  await prefs.setString(_prefsKeyCloudApiKey, value);
  await _disposeEngine();
}

/// Loopback-only by default (nothing outside this PC can reach it unless
/// the user deliberately opens it up via Settings) - distinct from this
/// project's own web dev-server port (8791) purely so the two are never
/// confused in logs/discussion, not because they could ever actually
/// collide (this is desktop-only; the web build never reaches this file at
/// all).
const _defaultServerHost = '127.0.0.1';
const _defaultServerPort = 8792;

/// Generous enough for a multi-turn-feeling conversation and long-ish
/// financial questions without a real reason not to be - see Settings if a
/// user wants to trade this for lower RAM/VRAM use.
const _defaultContextSize = 32768;

/// 999 is llama.cpp's own convention for "offload every layer that fits" -
/// harmless even on a build with no GPU backend compiled in (ggml just
/// keeps everything on CPU then) or on a GPU too small to fit them all
/// (llama.cpp falls back to keeping the remainder on CPU rather than
/// failing outright).
const _defaultGpuLayers = 999;

/// How long a model load may take before giving up - a multi-gigabyte
/// model, especially the first time it's read from a cold disk cache, is
/// genuinely slow to start.
const _startupTimeout = Duration(seconds: 90);

Future<String> localLlmServerHost() async {
  if (!Platform.isWindows) return _defaultServerHost;
  final prefs = await AppPreferences.getInstance();
  return prefs.getString(_prefsKeyServerHost) ?? _defaultServerHost;
}

Future<void> setLocalLlmServerHost(String value) async {
  if (!Platform.isWindows) return;
  final prefs = await AppPreferences.getInstance();
  await prefs.setString(_prefsKeyServerHost, value);
  await _disposeEngine(); // the running server was bound to the old host
}

Future<int> localLlmServerPort() async {
  if (!Platform.isWindows) return _defaultServerPort;
  final prefs = await AppPreferences.getInstance();
  return prefs.getInt(_prefsKeyServerPort) ?? _defaultServerPort;
}

Future<void> setLocalLlmServerPort(int value) async {
  if (!Platform.isWindows) return;
  final prefs = await AppPreferences.getInstance();
  await prefs.setInt(_prefsKeyServerPort, value);
  await _disposeEngine(); // the running server was bound to the old port
}

Future<int> localLlmContextSize() async {
  if (!Platform.isWindows) return _defaultContextSize;
  final prefs = await AppPreferences.getInstance();
  return prefs.getInt(_prefsKeyContextSize) ?? _defaultContextSize;
}

Future<void> setLocalLlmContextSize(int value) async {
  if (!Platform.isWindows) return;
  final prefs = await AppPreferences.getInstance();
  await prefs.setInt(_prefsKeyContextSize, value);
  await _disposeEngine(); // context size is only applied at model load time
}

Future<int> localLlmGpuLayers() async {
  if (!Platform.isWindows) return _defaultGpuLayers;
  final prefs = await AppPreferences.getInstance();
  return prefs.getInt(_prefsKeyGpuLayers) ?? _defaultGpuLayers;
}

Future<void> setLocalLlmGpuLayers(int value) async {
  if (!Platform.isWindows) return;
  final prefs = await AppPreferences.getInstance();
  await prefs.setInt(_prefsKeyGpuLayers, value);
  await _disposeEngine(); // GPU offload is only applied at model load time
}

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
  if (!Platform.isWindows) return false;
  final host = await localLlmServerHost();
  final port = await localLlmServerPort();
  final client = LlamaServerClient(port, host: host);
  try {
    return await client.healthCheck();
  } catch (_) {
    return false;
  } finally {
    client.close();
  }
}

/// A short human-readable label for whichever model is actually configured
/// right now - nl_query_dialog.dart shows this next to "Discuter avec mes
/// finances" (2026-08-31 user request) so it's clear at a glance which
/// model is answering, especially useful after switching between local/
/// cloud or between cloud models. Null when nothing meaningful can be
/// named: AI disabled, or (Windows, "Mon PC" mode) pointed at a remote
/// llama.cpp server whose model name this app was never told (it only
/// knows a host/port, not what the user launched the server with).
Future<String?> currentLlmModelLabel() async {
  if (!_supported) return null;
  if (!await isLocalLlmEnabled()) return null;
  if (await useCloudLlm()) {
    final model = await cloudLlmModel();
    return model.isEmpty ? null : model;
  }
  if (!Platform.isWindows) return null;
  final modelId = await selectedLocalLlmModelId();
  return localLlmModelById(modelId ?? '')?.label;
}

/// The editable system prompt behind the full-database-access SQL query
/// mode (see sql_query_engine.dart) - device-local like every other local-AI
/// setting here, not the database companion file: it's about tuning this
/// specific installed model's behavior on this machine, not a preference
/// that should follow the database around.
Future<String> localLlmSqlSystemPrompt() async {
  if (!_supported) return sql_engine.defaultSqlSystemPrompt;
  final prefs = await AppPreferences.getInstance();
  return prefs.getString(_prefsKeySqlSystemPrompt) ??
      sql_engine.defaultSqlSystemPrompt;
}

Future<void> setLocalLlmSqlSystemPrompt(String value) async {
  if (!_supported) return;
  final prefs = await AppPreferences.getInstance();
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed == sql_engine.defaultSqlSystemPrompt) {
    await prefs.remove(_prefsKeySqlSystemPrompt);
  } else {
    await prefs.setString(_prefsKeySqlSystemPrompt, trimmed);
  }
}

Future<bool> isLocalLlmEnabled() async {
  if (!_supported) return false;
  final prefs = await AppPreferences.getInstance();
  return prefs.getString(_prefsKeyEnabled) == 'true';
}

Future<void> setLocalLlmEnabled(bool value) async {
  if (!_supported) return;
  final prefs = await AppPreferences.getInstance();
  await prefs.setString(_prefsKeyEnabled, value ? 'true' : 'false');
  if (!value) await _disposeEngine();
}

Future<String?> selectedLocalLlmModelId() async {
  if (!Platform.isWindows) return null;
  final prefs = await AppPreferences.getInstance();
  return prefs.getString(_prefsKeySelectedModel) ?? localLlmModels.first.id;
}

Future<void> setSelectedLocalLlmModelId(String id) async {
  if (!Platform.isWindows) return;
  final prefs = await AppPreferences.getInstance();
  await prefs.setString(_prefsKeySelectedModel, id);
  await _disposeEngine(); // a different model needs a fresh engine load
}

Future<bool> isLocalLlmModelDownloaded(LocalLlmModel model) async {
  if (!Platform.isWindows) return false;
  return downloader.isModelDownloaded(model);
}

Stream<double?> downloadLocalLlmModel(LocalLlmModel model) {
  if (!Platform.isWindows) {
    return Stream.error(UnsupportedError('IA locale : Windows uniquement.'));
  }
  return downloader.downloadModel(model);
}

Future<void> deleteLocalLlmModel(LocalLlmModel model) async {
  if (!Platform.isWindows) return;
  await downloader.deleteDownloadedModel(model);
  await _disposeEngine();
}

/// A sibling of the models directory (see model_downloader.dart), where the
/// user must manually place a llama.cpp Windows server build - download the
/// latest Windows release zip from the official llama.cpp GitHub releases
/// (github.com/ggml-org/llama.cpp/releases - a `llama-<version>-bin-win-*.zip`
/// asset matching this machine's CPU/GPU) and extract `llama-server.exe`
/// plus every `.dll` next to it from that zip into this folder. Unlike the
/// earlier `llama_cpp_dart`-based approach (see ROADMAP.md, 2026-08-03),
/// this step could plausibly be automated later (llama.cpp's own releases
/// are genuinely ready-to-run, unlike the Dart FFI packages' were) - not
/// done yet since picking the right asset (CPU/CUDA/Vulkan variant) needs
/// real hardware to verify against. GPU offload itself (see
/// [localLlmGpuLayers]) no longer waits on that: it's on by default and
/// simply has no effect on a runtime build with no GPU backend compiled in.
Future<Directory> _runtimeDirectory() async {
  final modelsDir = await downloader.localLlmModelsDirectory();
  final dir = Directory(
      '${modelsDir.parent.path}${Platform.pathSeparator}local_llm_runtime');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

Future<String> localLlmRuntimeFolderPath() async =>
    (await _runtimeDirectory()).path;

Future<String> _serverExePath() async =>
    '${(await _runtimeDirectory()).path}${Platform.pathSeparator}llama-server.exe';

Future<bool> isLocalLlmRuntimeAvailable() async {
  if (!Platform.isWindows) return false;
  return File(await _serverExePath()).exists();
}

Process? _serverProcess;
LlamaServerClient? _serverClient;
String? _engineModelPath;

/// (host, port, contextSize, gpuLayers) the currently-running server was
/// actually launched with - records use value equality, so comparing this
/// against the *current* Settings values is how [_ensureEngine] notices a
/// config change and restarts the server, on top of the explicit
/// [_disposeEngine] each setter already does (belt and suspenders: this
/// catches drift from any future call site that reads these prefs some
/// other way too).
(String, int, int, int)? _engineConfig;

CloudLlmClient? _cloudClient;

/// (endpoint, model, apiKey) the currently-held [_cloudClient] was built
/// from - same "notice a config change and rebuild" role as
/// [_engineConfig] plays for the spawned local server.
(String, String, String)? _cloudConfig;

Future<void> _disposeEngine() async {
  final client = _serverClient;
  final process = _serverProcess;
  _serverClient = null;
  _serverProcess = null;
  _engineModelPath = null;
  _engineConfig = null;
  client?.close();
  if (process != null) {
    process.kill();
    await process.exitCode;
  }
  _cloudClient?.close();
  _cloudClient = null;
  _cloudConfig = null;
}

/// Builds a fresh, throwaway [CloudLlmClient] from the current cloud
/// settings - used by [isLocalLlmServerReachable]'s "Tester la connexion"
/// button, which (unlike [_ensureCloudEngine]) deliberately never reuses
/// or caches a client so a test always reflects whatever is in the fields
/// right now, even before "Appliquer" is pressed. Null if either the
/// endpoint or the model name is blank - nothing meaningful to test yet.
Future<CloudLlmClient?> _buildCloudClient() async {
  final endpoint = await cloudLlmEndpoint();
  final model = await cloudLlmModel();
  if (endpoint.isEmpty || model.isEmpty) return null;
  return CloudLlmClient(
      baseUrl: endpoint, apiKey: await cloudLlmApiKey(), model: model);
}

/// Android counterpart to [_ensureEngine]'s Windows spawned-server path -
/// reuses the same [CloudLlmClient] across questions asked within one open
/// dialog (same rationale as the local engine: no reason to pay any
/// per-request setup cost twice), rebuilding it only when the endpoint/
/// model/key actually changed. Null if cloud AI isn't configured yet.
Future<CloudLlmClient?> _ensureCloudEngine() async {
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

/// Called both when the "Poser une question" dialog closes
/// (nl_query_dialog.dart) and at app startup (see main.dart) so a
/// still-running `llama-server.exe` never outlives either - it would
/// otherwise sit there holding a multi-gigabyte model in RAM/VRAM
/// indefinitely. Safe to call even if no engine was ever started (a no-op
/// then) - the next question after this simply pays the load time again.
Future<void> shutdownLocalLlmEngine() => _disposeEngine();

/// A belt-and-suspenders safety net for `flutter run`/a terminal-launched
/// build specifically - Ctrl+C in the console sends SIGINT, which
/// otherwise bypasses Flutter's own widget-level lifecycle entirely. The
/// primary mechanism for a normally-closed window is main.dart's
/// `AppLifecycleState.detached` observer; this only exists because that
/// path has never actually been exercised against a real
/// `llama-server.exe` on Windows (see ROADMAP.md) and a second, cruder net
/// costs nothing. Registered once; safe to call more than once (each call
/// just adds another listener that does the same idempotent cleanup).
void registerLocalLlmSignalShutdownHook() {
  if (!Platform.isWindows) return;
  ProcessSignal.sigint.watch().listen((_) => _disposeEngine());
}

/// Starts (or reuses) the server for whichever model is currently
/// selected - loading a multi-gigabyte model takes real time, so this is
/// kept alive across questions asked within the same open dialog rather
/// than restarted every time (see [shutdownLocalLlmEngine], called when
/// that dialog closes, for why this isn't kept alive any longer than
/// that). Returns null if anything required is missing
/// (runtime, model file) or starting fails for any reason (wrong build,
/// port already in use, not enough RAM, corrupt file...) - never surfaced
/// as a crash, the caller falls back to the rule-based parser exactly as
/// if AI were disabled.
Future<LlmEngine?> _ensureEngine() async {
  if (await useCloudLlm()) return _ensureCloudEngine();
  if (!await isLocalLlmRuntimeAvailable()) return null;
  final modelId = await selectedLocalLlmModelId();
  final model = localLlmModelById(modelId ?? '') ?? localLlmModels.first;
  final modelPath = await downloader.downloadedModelPath(model);
  if (modelPath == null) return null;

  final host = await localLlmServerHost();
  final port = await localLlmServerPort();
  final contextSize = await localLlmContextSize();
  final gpuLayers = await localLlmGpuLayers();
  final config = (host, port, contextSize, gpuLayers);

  if (_serverClient != null &&
      _engineModelPath == modelPath &&
      _engineConfig == config) {
    return _serverClient;
  }
  await _disposeEngine();
  try {
    final process = await Process.start(await _serverExePath(), [
      '-m',
      modelPath,
      '--port',
      '$port',
      '--host',
      host,
      '-c',
      '$contextSize',
      '-ngl',
      '$gpuLayers',
    ]);
    // Drain stdout/stderr so the process's own pipe buffers can't fill up
    // and stall it - this app never needs to show that output anywhere.
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    var processExited = false;
    unawaited(process.exitCode.then((_) => processExited = true));

    final client = LlamaServerClient(port, host: host);
    await client.waitUntilHealthy(
        timeout: _startupTimeout, hasExited: () => processExited);

    _serverProcess = process;
    _serverClient = client;
    _engineModelPath = modelPath;
    _engineConfig = config;
    return client;
  } catch (_) {
    await _disposeEngine();
    return null;
  }
}

Future<({QueryIntent? intent, bool periodWasExplicit})>
    extractIntentWithLocalLlm(
  String question, {
  required List<Category> categories,
  required List<Account> accounts,
  required List<Payee> payees,
  DateTime? now,
}) async {
  if (!_supported) return (intent: null, periodWasExplicit: false);
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

/// Free-form fallback for a question that matched no financial intent
/// (see [extractIntentWithLocalLlm]) and no rule-based pattern either - see
/// [LlmFreeformOutcome] for why this is three-way rather than a plain
/// nullable success, same never-throws contract as ever (a failure is
/// reported via [LlmFreeformError], never a thrown exception).
///
/// [history] (2026-09-01) is recapped ahead of [question] the same way
/// sql_query_engine.dart's SQL-writing call already does (see
/// [sql_engine.formatChatHistory]) - found from a real user report: a
/// follow-up like "recommence mais analyse tout depuis le 01/01/2024"
/// reached this path (the SQL-writing call declined that turn) and, with no
/// history at all, answered as if no financial conversation had ever
/// started - technically consistent with [freeformSystemPrompt]'s own "tu
/// n'as accès à aucune donnée financière" framing, but confusing mid-chat.
Future<LlmFreeformOutcome> askLocalLlmFreeform(
  String question, {
  List<sql_engine.ChatTurn> history = const [],
}) async {
  if (!_supported) return const LlmFreeformUnavailable();
  if (!await isLocalLlmEnabled()) return const LlmFreeformUnavailable();
  final engine = await _ensureEngine();
  if (engine == null) return const LlmFreeformUnavailable();
  try {
    final raw = await engine
        .askFreeform('${sql_engine.formatChatHistory(history)}$question');
    final trimmed = raw.text.trim();
    return trimmed.isEmpty
        ? const LlmFreeformUnavailable()
        : LlmFreeformSuccess(trimmed, tokensPerSecond: raw.tokensPerSecond);
  } catch (e) {
    // StateError (both backends' own "le service a répondu <code>."/
    // "connexion impossible" text) unwrapped to its bare .message - avoids
    // the generic "Bad state: " prefix Dart's default toString() adds,
    // which would read oddly in a chat bubble. Any other exception type
    // (a timeout, a socket error) falls back to its own toString() - not
    // as polished, but still just a short description, never a stack trace.
    return LlmFreeformError(e is StateError ? e.message : '$e');
  }
}

/// A throwaway [MmexDatabase] wrapping a connection opened with
/// `OpenMode.readOnly` - backs [openReadOnlyAdHocRepository]. Only [query]
/// is ever meaningful; every mutating member throws as a second, Dart-level
/// guard on top of SQLite's own OS-enforced refusal of any write against a
/// connection opened this way - defense in depth for QueryKind.adHoc
/// (ad_hoc_query.dart), whose whole point is running a question the local
/// AI shaped, not one this app wrote itself.
class _ReadOnlyAdHocDatabase implements MmexDatabase {
  final Database _db;
  final String _path;
  _ReadOnlyAdHocDatabase(this._db, this._path);

  @override
  String get label => _path;

  @override
  bool get isDirectlyPersisted => false;

  @override
  List<Map<String, Object?>> query(String sql,
          [List<Object?> params = const []]) =>
      _db.select(sql, params).map((row) => row).toList();

  @override
  int execute(String sql, [List<Object?> params = const []]) =>
      throw UnsupportedError(
          'Connexion IA locale en lecture seule - écriture refusée.');

  @override
  void transaction(void Function() action) => throw UnsupportedError(
      'Connexion IA locale en lecture seule - écriture refusée.');

  @override
  List<int> exportBytes() => throw UnsupportedError(
      'Connexion IA locale en lecture seule - export non applicable.');

  @override
  void dispose() => _db.dispose();
}

/// Opens a brand-new, throwaway, OS/SQLite-enforced READ-ONLY connection to
/// the .mmb file at [dbPath] (callers pass `repo.db.label`, which - on
/// desktop - *is* the real file path, see mmex_database_io.dart's
/// `_IoMmexDatabase` constructor) and wraps it in its own [MmexRepository].
/// This is the defense-in-depth guarantee for QueryKind.adHoc: even if
/// ad_hoc_query.dart's SQL-building ever had a bug, a connection opened
/// this way cannot write to the file no matter what SQL text reaches it.
///
/// A fresh connection per question - open, run one query, dispose
/// immediately (the caller, nl_query_dialog.dart, is responsible for
/// disposing) - rather than caching it the way the llama-server.exe
/// process itself is cached, so every question always sees whatever the
/// app's own read-write connection most recently committed.
///
/// Returns `null` (never throws) if [dbPath] can't be reopened this way -
/// not a real filesystem path (e.g. a `:memory:` test database), the file
/// vanished, or it's otherwise inaccessible - so the caller fails this one
/// question gracefully exactly like any other local-AI failure.
Future<MmexRepository?> openReadOnlyAdHocRepository(String dbPath) async {
  if (!Platform.isWindows) return null;
  try {
    final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    // Tolerates a brief writer lock (this app's own db.transaction(), a
    // second instance, or real MMEX desktop open concurrently - the last of
    // which CLAUDE.md already documents as unsupported/risky) instead of
    // failing this one question outright the instant it's hit.
    db.execute('PRAGMA busy_timeout = 2000');
    return MmexRepository(_ReadOnlyAdHocDatabase(db, dbPath));
  } catch (_) {
    return null;
  }
}

/// Full-database-access alternative to [extractIntentWithLocalLlm]'s closed
/// kind/metric/groupBy vocabulary (see sql_query_engine.dart). Two shapes,
/// mirroring local_llm_manager_web.dart's own web/desktop split:
///
/// - Windows ([dbPath] required): opens its own throwaway read-only
///   connection to [dbPath] (same guarantee as [openReadOnlyAdHocRepository],
///   disposed here rather than left to the caller since this function owns
///   its whole lifetime).
/// - Android ([repo] required): there is no real filesystem path to reopen
///   (the database lives in memory, loaded from SAF-read bytes - see
///   CLAUDE.md's Android file-access notes), so this uses the already-open,
///   live [repo] directly instead - same trade-off local_llm_manager_web.dart
///   already accepts for the exact same reason, defended by
///   sql_query_engine.dart's own SELECT-only SQL validation rather than an
///   OS-enforced read-only connection.
///
/// Either way: loads the user-editable system prompt from Settings, appends
/// the real vocabulary of the currently-open database to it (see
/// sql_engine.buildEffectiveSqlSystemPrompt - computed fresh here, never
/// persisted), and runs the SQL-generate-then-answer flow. Null (never
/// throws) under the same conditions as every other local-AI entry point
/// here - unsupported, disabled, not ready, or any failure at any step.
Future<sql_engine.SqlAccessOutcome> askLocalLlmWithFullDataAccess(
  String question, {
  String? dbPath,
  MmexRepository? repo,
  List<sql_engine.ChatTurn> history = const [],
}) async {
  if (!_supported) return const sql_engine.SqlAccessUnavailable();
  if (!await isLocalLlmEnabled()) return const sql_engine.SqlAccessUnavailable();
  final engine = await _ensureEngine();
  if (engine == null) return const sql_engine.SqlAccessUnavailable();

  if (_isAndroid) {
    if (repo == null) return const sql_engine.SqlAccessUnavailable();
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

  if (dbPath == null) return const sql_engine.SqlAccessUnavailable();
  final readOnlyRepo = await openReadOnlyAdHocRepository(dbPath);
  if (readOnlyRepo == null) {
    return const sql_engine.SqlAccessError(
        "Impossible d'ouvrir la base de données en lecture seule pour cette question.");
  }
  try {
    final basePrompt = await localLlmSqlSystemPrompt();
    final systemPrompt = sql_engine.buildEffectiveSqlSystemPrompt(
      basePrompt,
      accounts: readOnlyRepo.getAccounts(),
      categories: readOnlyRepo.getCategories(onlyActive: false),
      payees: readOnlyRepo.getPayees(onlyActive: false),
    );
    return await sql_engine.answerViaFullSqlAccess(
      question: question,
      readOnlyRepo: readOnlyRepo,
      systemPrompt: systemPrompt,
      engine: engine,
      history: history,
    );
  } finally {
    readOnlyRepo.db.dispose();
  }
}
