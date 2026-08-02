import '../../../models/account.dart';
import '../../../models/category.dart';
import '../../../models/payee.dart';
import '../query_intent.dart';
import 'model_catalog.dart';

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

Future<({QueryIntent? intent, bool periodWasExplicit})> extractIntentWithLocalLlm(
  String question, {
  required List<Category> categories,
  required List<Account> accounts,
  required List<Payee> payees,
  DateTime? now,
}) async =>
    (intent: null, periodWasExplicit: false);
