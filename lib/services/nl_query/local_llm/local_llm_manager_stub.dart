import '../../../data/mmex_repository.dart';
import '../../../models/account.dart';
import '../../../models/category.dart';
import '../../../models/payee.dart';
import '../query_intent.dart';
import 'llm_engine.dart';
import 'model_catalog.dart';
import 'sql_query_engine.dart'
    show ChatTurn, SqlAccessOutcome, SqlAccessUnavailable, defaultSqlSystemPrompt;

Future<bool> isLocalLlmEnabled() async => false;
Future<void> setLocalLlmEnabled(bool value) async {}

Future<String?> selectedLocalLlmModelId() async => null;
Future<void> setSelectedLocalLlmModelId(String id) async {}

Future<bool> isLocalLlmModelDownloaded(LocalLlmModel model) async => false;

Stream<double?> downloadLocalLlmModel(LocalLlmModel model) {
  return Stream.error(UnsupportedError('IA locale : Windows uniquement.'));
}

Future<void> deleteLocalLlmModel(LocalLlmModel model) async {}

Future<String> localLlmRuntimeFolderPath() async => '';
Future<bool> isLocalLlmRuntimeAvailable() async => false;

Future<String> localLlmServerHost() async => '127.0.0.1';
Future<void> setLocalLlmServerHost(String value) async {}
Future<int> localLlmServerPort() async => 8792;
Future<void> setLocalLlmServerPort(int value) async {}
Future<int> localLlmContextSize() async => 32768;
Future<void> setLocalLlmContextSize(int value) async {}
Future<int> localLlmGpuLayers() async => 999;
Future<void> setLocalLlmGpuLayers(int value) async {}
Future<bool> isLocalLlmServerReachable() async => false;

Future<String?> currentLlmModelLabel() async => null;

Future<bool> useCloudLlm() async => false;
Future<void> setUseCloudLlm(bool value) async {}

Future<String> cloudLlmEndpoint() async => '';
Future<void> setCloudLlmEndpoint(String value) async {}
Future<String> cloudLlmModel() async => '';
Future<void> setCloudLlmModel(String value) async {}
Future<String> cloudLlmApiKey() async => '';
Future<void> setCloudLlmApiKey(String value) async {}

Future<void> shutdownLocalLlmEngine() async {}

void registerLocalLlmSignalShutdownHook() {}

Future<({QueryIntent? intent, bool periodWasExplicit})>
    extractIntentWithLocalLlm(
  String question, {
  required List<Category> categories,
  required List<Account> accounts,
  required List<Payee> payees,
  DateTime? now,
}) async =>
        (intent: null, periodWasExplicit: false);

Future<LlmFreeformOutcome> askLocalLlmFreeform(String question) async =>
    const LlmFreeformUnavailable();

Future<MmexRepository?> openReadOnlyAdHocRepository(String dbPath) async =>
    null;

Future<String> localLlmSqlSystemPrompt() async => defaultSqlSystemPrompt;
Future<void> setLocalLlmSqlSystemPrompt(String value) async {}

Future<SqlAccessOutcome> askLocalLlmWithFullDataAccess(
  String question, {
  String? dbPath,
  MmexRepository? repo,
  List<ChatTurn> history = const [],
}) async =>
    const SqlAccessUnavailable();
