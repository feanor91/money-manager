import 'dart:io';

import '../../../models/account.dart';
import '../../../models/category.dart';
import '../../../models/payee.dart';
import '../../../state/app_preferences.dart';
import '../query_intent.dart';
import 'intent_json_codec.dart';
import 'llama_engine.dart';
import 'model_catalog.dart';
import 'model_downloader.dart' as downloader;

/// Android also compiles this file (dart.library.io covers both, same
/// reason as update_prompt_io.dart) but every function gates on
/// Platform.isWindows first and does nothing on any other platform - this
/// feature targets Windows desktop only for now (see CLAUDE.md/ROADMAP.md).
const _prefsKeyEnabled = 'mmex_local_llm_enabled';
const _prefsKeySelectedModel = 'mmex_local_llm_selected_model';

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
/// user must manually place a compatible llama.cpp Windows build
/// (llama.dll + its companion ggml*.dll files extracted from the same
/// zip). This can't be automated the way the GGUF model download is:
/// neither Dart package available for llama.cpp inference
/// (llama_cpp_dart, llamadart) ships a working prebuilt Windows binary as
/// of this writing (see ROADMAP.md for what was checked), and the exact
/// compatible build depends on which llama.cpp version llama_cpp_dart's
/// FFI bindings were generated against - something only verifiable on a
/// real Windows machine, not from this Linux container.
Future<Directory> _runtimeDirectory() async {
  final modelsDir = await downloader.localLlmModelsDirectory();
  final dir = Directory('${modelsDir.parent.path}${Platform.pathSeparator}local_llm_runtime');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

Future<String> localLlmRuntimeFolderPath() async => (await _runtimeDirectory()).path;

Future<bool> isLocalLlmRuntimeAvailable() async {
  if (!Platform.isWindows) return false;
  final dir = await _runtimeDirectory();
  return File('${dir.path}${Platform.pathSeparator}llama.dll').exists();
}

LlamaEngine? _engine;
String? _engineModelPath;

Future<void> _disposeEngine() async {
  final engine = _engine;
  _engine = null;
  _engineModelPath = null;
  if (engine != null) await engine.dispose();
}

/// Loads (or reuses) the engine for whichever model is currently selected -
/// loading a multi-gigabyte model takes real time, so this is kept alive
/// across questions within the same app session rather than reloaded every
/// time. Returns null if anything required is missing (runtime, model
/// file) or loading fails for any reason.
Future<LlamaEngine?> _ensureEngine() async {
  if (!await isLocalLlmRuntimeAvailable()) return null;
  final modelId = await selectedLocalLlmModelId();
  final model = localLlmModelById(modelId ?? '') ?? localLlmModels.first;
  final modelPath = await downloader.downloadedModelPath(model);
  if (modelPath == null) return null;

  if (_engine != null && _engineModelPath == modelPath) return _engine;
  await _disposeEngine();
  try {
    final runtimeDir = await _runtimeDirectory();
    final libraryPath = '${runtimeDir.path}${Platform.pathSeparator}llama.dll';
    final engine = await LlamaEngine.load(modelPath, libraryPath: libraryPath);
    _engine = engine;
    _engineModelPath = modelPath;
    return engine;
  } catch (_) {
    // Model/runtime present but failed to load (wrong DLL version, not
    // enough RAM, corrupt file...) - never surfaced as a crash, the caller
    // falls back to the rule-based parser exactly as if AI were disabled.
    _engine = null;
    _engineModelPath = null;
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
