import '../../../models/account.dart';
import '../../../models/category.dart';
import '../../../models/payee.dart';
import '../query_intent.dart';
import 'model_catalog.dart';

import 'local_llm_manager_stub.dart' if (dart.library.io) 'local_llm_manager_io.dart' as impl;

/// Whether the user has switched local AI on - independent of whether it's
/// actually usable right now (see [isLocalLlmRuntimeAvailable] and
/// [isLocalLlmModelDownloaded]). Device-local (AppPreferences), not the
/// database companion file: like the remembered database path or a web file
/// handle (see CLAUDE.md), this describes a resource that lives on *this*
/// Windows machine's disk - a multi-gigabyte model file and a native DLL
/// nobody would want silently expected on every other device that opens
/// the same database.
Future<bool> isLocalLlmEnabled() => impl.isLocalLlmEnabled();
Future<void> setLocalLlmEnabled(bool value) => impl.setLocalLlmEnabled(value);

Future<String?> selectedLocalLlmModelId() => impl.selectedLocalLlmModelId();
Future<void> setSelectedLocalLlmModelId(String id) => impl.setSelectedLocalLlmModelId(id);

Future<bool> isLocalLlmModelDownloaded(LocalLlmModel model) => impl.isLocalLlmModelDownloaded(model);
Stream<double?> downloadLocalLlmModel(LocalLlmModel model) => impl.downloadLocalLlmModel(model);
Future<void> deleteLocalLlmModel(LocalLlmModel model) => impl.deleteLocalLlmModel(model);

/// Where the user must manually place a compatible llama.cpp Windows
/// runtime (llama.dll + its companion ggml*.dll files) - see
/// local_llm_manager_io.dart's doc comment for why this can't be automated
/// from here. Shown in Settings as a folder path the user can open.
Future<String> localLlmRuntimeFolderPath() => impl.localLlmRuntimeFolderPath();
Future<bool> isLocalLlmRuntimeAvailable() => impl.isLocalLlmRuntimeAvailable();

/// User-configurable `llama-server.exe` launch settings (see Settings'
/// "Paramètres du serveur") - each setter restarts the running server (if
/// any) so a change actually takes effect on the next question, rather
/// than silently continuing to run with the old value until the app
/// restarts.
Future<String> localLlmServerHost() => impl.localLlmServerHost();
Future<void> setLocalLlmServerHost(String value) => impl.setLocalLlmServerHost(value);
Future<int> localLlmServerPort() => impl.localLlmServerPort();
Future<void> setLocalLlmServerPort(int value) => impl.setLocalLlmServerPort(value);
Future<int> localLlmContextSize() => impl.localLlmContextSize();
Future<void> setLocalLlmContextSize(int value) => impl.setLocalLlmContextSize(value);
Future<int> localLlmGpuLayers() => impl.localLlmGpuLayers();
Future<void> setLocalLlmGpuLayers(int value) => impl.setLocalLlmGpuLayers(value);

/// Call once at app startup (see main.dart) so a still-running
/// `llama-server.exe` never outlives the app itself - a no-op on any
/// platform where local AI was never reachable in the first place.
Future<void> shutdownLocalLlmEngine() => impl.shutdownLocalLlmEngine();

/// Call once at app startup, alongside [shutdownLocalLlmEngine] - see
/// local_llm_manager_io.dart's doc comment on why both exist.
void registerLocalLlmSignalShutdownHook() => impl.registerLocalLlmSignalShutdownHook();

/// Attempts to answer [question] using the local model - null if local AI
/// isn't supported/enabled/ready, or on any failure. Never throws: the
/// caller (nl_query_dialog.dart) always falls back to the rule-based
/// parser either way, so a broken or absent local AI setup degrades
/// gracefully rather than breaking the feature.
Future<({QueryIntent? intent, bool periodWasExplicit})> extractIntentWithLocalLlm(
  String question, {
  required List<Category> categories,
  required List<Account> accounts,
  required List<Payee> payees,
  DateTime? now,
}) =>
    impl.extractIntentWithLocalLlm(
      question,
      categories: categories,
      accounts: accounts,
      payees: payees,
      now: now,
    );

/// Free-form fallback once neither the local AI's intent extractor nor the
/// rule-based parser recognized [question] as a financial one - null under
/// the same conditions as [extractIntentWithLocalLlm] (unsupported,
/// disabled, not ready, or any failure). Never throws.
Future<String?> askLocalLlmFreeform(String question) => impl.askLocalLlmFreeform(question);
