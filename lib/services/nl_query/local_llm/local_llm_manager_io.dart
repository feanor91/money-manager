import 'dart:async';
import 'dart:io';

import '../../../models/account.dart';
import '../../../models/category.dart';
import '../../../models/payee.dart';
import '../../../state/app_preferences.dart';
import '../query_intent.dart';
import 'intent_json_codec.dart';
import 'llama_server_client.dart';
import 'model_catalog.dart';
import 'model_downloader.dart' as downloader;

/// Android also compiles this file (dart.library.io covers both, same
/// reason as update_prompt_io.dart) but every function gates on
/// Platform.isWindows first and does nothing on any other platform - this
/// feature targets Windows desktop only for now (see CLAUDE.md/ROADMAP.md).
const _prefsKeyEnabled = 'mmex_local_llm_enabled';
const _prefsKeySelectedModel = 'mmex_local_llm_selected_model';

/// Fixed, never user-facing - the server is only ever reached from this
/// same process on 127.0.0.1, so there's nothing to remember or configure.
/// Picked arbitrarily distinct from this project's own web dev-server port
/// (8791) purely so the two are never confused in logs/discussion, not
/// because they could ever actually collide (this is desktop-only; the web
/// build never reaches this file at all).
const _serverPort = 8792;

/// How long a model load may take before giving up - CPU-only inference of
/// a multi-gigabyte model is genuinely slow to start, especially the first
/// time (disk cache cold).
const _startupTimeout = Duration(seconds: 90);

Future<bool> isLocalLlmEnabled() async {
  if (!Platform.isWindows) return false;
  final prefs = await AppPreferences.getInstance();
  return prefs.getString(_prefsKeyEnabled) == 'true';
}

Future<void> setLocalLlmEnabled(bool value) async {
  if (!Platform.isWindows) return;
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
/// asset matching this machine's CPU) and extract `llama-server.exe` plus
/// every `.dll` next to it from that zip into this folder. Unlike the
/// earlier `llama_cpp_dart`-based approach (see ROADMAP.md, 2026-08-03),
/// this step could plausibly be automated later (llama.cpp's own releases
/// are genuinely ready-to-run, unlike the Dart FFI packages' were) - not
/// done yet since picking the right asset (CPU/CUDA/Vulkan variant) needs
/// real hardware to verify against, same reason the GPU path below stays
/// off.
Future<Directory> _runtimeDirectory() async {
  final modelsDir = await downloader.localLlmModelsDirectory();
  final dir = Directory('${modelsDir.parent.path}${Platform.pathSeparator}local_llm_runtime');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

Future<String> localLlmRuntimeFolderPath() async => (await _runtimeDirectory()).path;

Future<String> _serverExePath() async =>
    '${(await _runtimeDirectory()).path}${Platform.pathSeparator}llama-server.exe';

Future<bool> isLocalLlmRuntimeAvailable() async {
  if (!Platform.isWindows) return false;
  return File(await _serverExePath()).exists();
}

Process? _serverProcess;
LlamaServerClient? _serverClient;
String? _engineModelPath;

Future<void> _disposeEngine() async {
  final client = _serverClient;
  final process = _serverProcess;
  _serverClient = null;
  _serverProcess = null;
  _engineModelPath = null;
  client?.close();
  if (process != null) {
    process.kill();
    await process.exitCode;
  }
}

/// Called once at app startup (see main.dart) so a still-running
/// `llama-server.exe` never outlives the app - it would otherwise sit there
/// holding a multi-gigabyte model in RAM indefinitely. Safe to call even if
/// no engine was ever started (a no-op then).
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
/// kept alive across questions within the same app session rather than
/// restarted every time. Returns null if anything required is missing
/// (runtime, model file) or starting fails for any reason (wrong build,
/// port already in use, not enough RAM, corrupt file...) - never surfaced
/// as a crash, the caller falls back to the rule-based parser exactly as
/// if AI were disabled.
Future<LlamaServerClient?> _ensureEngine() async {
  if (!await isLocalLlmRuntimeAvailable()) return null;
  final modelId = await selectedLocalLlmModelId();
  final model = localLlmModelById(modelId ?? '') ?? localLlmModels.first;
  final modelPath = await downloader.downloadedModelPath(model);
  if (modelPath == null) return null;

  if (_serverClient != null && _engineModelPath == modelPath) return _serverClient;
  await _disposeEngine();
  try {
    final process = await Process.start(await _serverExePath(), [
      '-m', modelPath,
      '--port', '$_serverPort',
      '--host', '127.0.0.1',
      '-c', '4096',
      '-ngl', '0', // CPU-only - see this file's own doc comment above.
    ]);
    // Drain stdout/stderr so the process's own pipe buffers can't fill up
    // and stall it - this app never needs to show that output anywhere.
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    var processExited = false;
    unawaited(process.exitCode.then((_) => processExited = true));

    final client = LlamaServerClient(_serverPort);
    await client.waitUntilHealthy(timeout: _startupTimeout, hasExited: () => processExited);

    _serverProcess = process;
    _serverClient = client;
    _engineModelPath = modelPath;
    return client;
  } catch (_) {
    await _disposeEngine();
    return null;
  }
}

Future<({QueryIntent? intent, bool periodWasExplicit})> extractIntentWithLocalLlm(
  String question, {
  required List<Category> categories,
  required List<Account> accounts,
  required List<Payee> payees,
  DateTime? now,
}) async {
  if (!Platform.isWindows) return (intent: null, periodWasExplicit: false);
  if (!await isLocalLlmEnabled()) return (intent: null, periodWasExplicit: false);
  final engine = await _ensureEngine();
  if (engine == null) return (intent: null, periodWasExplicit: false);
  try {
    final raw = await engine.ask(question);
    return decodeIntentJson(
      raw,
      categories: categories,
      accounts: accounts,
      payees: payees,
      now: now,
    );
  } catch (_) {
    return (intent: null, periodWasExplicit: false);
  }
}
