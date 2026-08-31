import '../../../data/mmex_repository.dart';
import '../../../models/account.dart';
import '../../../models/category.dart';
import '../../../models/payee.dart';
import '../query_intent.dart';
import 'llm_engine.dart' show LlmFreeformOutcome;
import 'model_catalog.dart';
import 'sql_query_engine.dart' show ChatTurn, SqlGroundedAnswer;

export 'llm_engine.dart'
    show LlmFreeformOutcome, LlmFreeformSuccess, LlmFreeformUnavailable, LlmFreeformError;
export 'sql_query_engine.dart' show ChatTurn, SqlGroundedAnswer;

import 'local_llm_manager_stub.dart'
    if (dart.library.js_interop) 'local_llm_manager_web.dart'
    if (dart.library.io) 'local_llm_manager_io.dart' as impl;

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
Future<void> setSelectedLocalLlmModelId(String id) =>
    impl.setSelectedLocalLlmModelId(id);

Future<bool> isLocalLlmModelDownloaded(LocalLlmModel model) =>
    impl.isLocalLlmModelDownloaded(model);
Stream<double?> downloadLocalLlmModel(LocalLlmModel model) =>
    impl.downloadLocalLlmModel(model);
Future<void> deleteLocalLlmModel(LocalLlmModel model) =>
    impl.deleteLocalLlmModel(model);

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
Future<void> setLocalLlmServerHost(String value) =>
    impl.setLocalLlmServerHost(value);
Future<int> localLlmServerPort() => impl.localLlmServerPort();
Future<void> setLocalLlmServerPort(int value) =>
    impl.setLocalLlmServerPort(value);
Future<int> localLlmContextSize() => impl.localLlmContextSize();
Future<void> setLocalLlmContextSize(int value) =>
    impl.setLocalLlmContextSize(value);
Future<int> localLlmGpuLayers() => impl.localLlmGpuLayers();
Future<void> setLocalLlmGpuLayers(int value) =>
    impl.setLocalLlmGpuLayers(value);

/// One-shot, never-polling health check against the configured server
/// address - backs Settings' "Tester la connexion" button. On desktop
/// this checks the app's own spawned server; on web it checks the
/// externally-run server the user pointed at via host/port.
Future<bool> isLocalLlmServerReachable() => impl.isLocalLlmServerReachable();

/// A short human-readable label for whichever model is actually configured
/// right now (a cloud model name, or - desktop only - the selected local
/// GGUF model's own label) - nl_query_dialog.dart shows this next to
/// "Discuter avec mes finances" (2026-08-31 user request). Null when AI is
/// disabled, or the current mode has no nameable model at all (Windows/
/// web "Mon PC" mode: a remote llama.cpp server whose model name this app
/// was never told, only its host/port).
Future<String?> currentLlmModelLabel() => impl.currentLlmModelLabel();

/// Cloud AI settings (2026-08-31) - see cloud_llm_client.dart. On Android
/// this is the only backend there is (no toggle needed - [useCloudLlm]
/// always answers true there). On Windows desktop and web, [useCloudLlm]
/// switches between this and each platform's own existing backend
/// (desktop: spawns its own local model; web: points at a remote
/// llama.cpp server via host/port) - defaults to false so an existing
/// setup never silently switches backend under an upgrade.
/// [cloudLlmEndpoint] has no trailing slash and includes any version
/// segment the provider needs (e.g. "https://api.openai.com/v1") - see
/// CloudLlmClient's own doc comment.
Future<bool> useCloudLlm() => impl.useCloudLlm();
Future<void> setUseCloudLlm(bool value) => impl.setUseCloudLlm(value);

Future<String> cloudLlmEndpoint() => impl.cloudLlmEndpoint();
Future<void> setCloudLlmEndpoint(String value) =>
    impl.setCloudLlmEndpoint(value);
Future<String> cloudLlmModel() => impl.cloudLlmModel();
Future<void> setCloudLlmModel(String value) => impl.setCloudLlmModel(value);
Future<String> cloudLlmApiKey() => impl.cloudLlmApiKey();
Future<void> setCloudLlmApiKey(String value) =>
    impl.setCloudLlmApiKey(value);

/// Call once at app startup (see main.dart) so a still-running
/// `llama-server.exe` never outlives the app itself - a no-op on any
/// platform where local AI was never reachable in the first place.
Future<void> shutdownLocalLlmEngine() => impl.shutdownLocalLlmEngine();

/// Call once at app startup, alongside [shutdownLocalLlmEngine] - see
/// local_llm_manager_io.dart's doc comment on why both exist.
void registerLocalLlmSignalShutdownHook() =>
    impl.registerLocalLlmSignalShutdownHook();

/// Attempts to answer [question] using the local model - null if local AI
/// isn't supported/enabled/ready, or on any failure. Never throws: the
/// caller (nl_query_dialog.dart) always falls back to the rule-based
/// parser either way, so a broken or absent local AI setup degrades
/// gracefully rather than breaking the feature.
Future<({QueryIntent? intent, bool periodWasExplicit})>
    extractIntentWithLocalLlm(
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
/// rule-based parser recognized [question] as a financial one - see
/// [LlmFreeformOutcome] for the three possible outcomes (a real answer,
/// silently unavailable, or a genuine backend error worth telling the user
/// about). Never throws.
Future<LlmFreeformOutcome> askLocalLlmFreeform(String question) =>
    impl.askLocalLlmFreeform(question);

/// Opens a throwaway, OS/SQLite-enforced read-only connection to the .mmb
/// file at [dbPath] for running a [QueryKind.adHoc] question - null on any
/// platform other than Windows, or if [dbPath] can't be reopened this way.
/// See local_llm_manager_io.dart's doc comment for the full safety
/// rationale. The caller (nl_query_dialog.dart) owns disposing the
/// returned repository's `.db` once done with it.
Future<MmexRepository?> openReadOnlyAdHocRepository(String dbPath) =>
    impl.openReadOnlyAdHocRepository(dbPath);

/// The editable system prompt behind [askLocalLlmWithFullDataAccess] (see
/// Settings' "Prompt IA (accès complet aux données)") - device-local, same
/// as the rest of this file's settings. Defaults to
/// sql_query_engine.dart's `defaultSqlSystemPrompt`.
Future<String> localLlmSqlSystemPrompt() => impl.localLlmSqlSystemPrompt();
Future<void> setLocalLlmSqlSystemPrompt(String value) =>
    impl.setLocalLlmSqlSystemPrompt(value);

/// Full-database-access alternative to [extractIntentWithLocalLlm]'s closed
/// vocabulary - the model writes real SQL against the schema described in
/// [localLlmSqlSystemPrompt], run against the database, then a second
/// grounded call phrases the answer from the real result rows (see
/// sql_query_engine.dart). Null (never throws) under the same conditions as
/// every other local-AI entry point here.
///
/// [dbPath] is the native (desktop) way to point at the data - the
/// implementation reopens that file with its own OS/SQLite-enforced
/// read-only connection. On web there is no file path to reopen (the
/// database is in-memory, loaded from a picked file), so [repo] - the
/// currently-open, live repository - is passed instead and used directly.
/// Exactly one of the two is required; the other must be omitted.
/// [history] (2026-08-23) - the current chat's prior turns, so a follow-up
/// question ("et l'an dernier ?") resolves against what was just asked. See
/// sql_query_engine.dart's ChatTurn/`_formatHistory`.
Future<SqlGroundedAnswer?> askLocalLlmWithFullDataAccess(
  String question, {
  String? dbPath,
  MmexRepository? repo,
  List<ChatTurn> history = const [],
}) {
  if (dbPath == null && repo == null) {
    throw ArgumentError.value(null, 'dbPath',
        'Passe dbPath (natif) ou repo (web), pas les deux à null.');
  }
  return impl.askLocalLlmWithFullDataAccess(
    question,
    dbPath: dbPath,
    repo: repo,
    history: history,
  );
}
