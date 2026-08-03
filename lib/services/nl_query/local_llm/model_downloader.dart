import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'model_catalog.dart';

/// `package:crypto` computes a chunked digest via `Hash.startChunkedConversion`,
/// but its own `DigestSink` helper isn't part of its public API - this is
/// the same one-method shape, kept private to this file.
class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// Where downloaded local-LLM model files live on disk - this app's own
/// support directory, never the folder the .mmb database lives in: model
/// weights are a multi-gigabyte, per-device, freely re-downloadable asset,
/// unrelated to the user's actual financial data or its Nextcloud sync.
/// Only ever reached through local_llm_manager.dart's Windows-gated
/// implementation - see that file for why this one doesn't need its own
/// conditional-import shell (it uses dart:io but never dart:ffi, so
/// nothing here breaks a web build merely by existing; the risk CLAUDE.md
/// warns about is only from files that touch dart:ffi).
Future<Directory> localLlmModelsDirectory() async {
  final base = await getApplicationSupportDirectory();
  final dir = Directory('${base.path}${Platform.pathSeparator}local_llm_models');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

Future<File> _modelFile(LocalLlmModel model) async {
  final dir = await localLlmModelsDirectory();
  return File('${dir.path}${Platform.pathSeparator}${model.fileName}');
}

Future<bool> isModelDownloaded(LocalLlmModel model) async {
  return (await _modelFile(model)).exists();
}

/// The full path to [model]'s file on disk, or null if it hasn't been
/// downloaded (or was deleted) - what local_llm_engine.dart loads.
Future<String?> downloadedModelPath(LocalLlmModel model) async {
  final file = await _modelFile(model);
  return await file.exists() ? file.path : null;
}

Future<void> deleteDownloadedModel(LocalLlmModel model) async {
  final file = await _modelFile(model);
  if (await file.exists()) await file.delete();
}

/// Downloads [model] to its final location, yielding progress from 0.0 to
/// 1.0 as it goes (null if the server didn't report a Content-Length, so
/// the caller can show an indeterminate progress indicator instead of a
/// wrong percentage). Always tracks the real HTTP response size - never
/// [LocalLlmModel.approxSizeBytes], which is only a rough label for the
/// "download ~X Go ?" prompt shown before starting.
///
/// Writes to a `.part` file first and only renames it to the real file
/// name on success, so a cancelled or failed download can never leave a
/// half-written file that [isModelDownloaded] would mistake for a complete
/// one. If [LocalLlmModel.sha256] is set, the downloaded bytes are
/// verified against it before the rename; a mismatch deletes the partial
/// file and throws rather than leaving a corrupt model in place.
Stream<double?> downloadModel(LocalLlmModel model) async* {
  final dir = await localLlmModelsDirectory();
  final partFile = File('${dir.path}${Platform.pathSeparator}${model.fileName}.part');
  final finalFile = File('${dir.path}${Platform.pathSeparator}${model.fileName}');

  final request = http.Request('GET', Uri.parse(model.downloadUrl));
  final response = await request.send();
  if (response.statusCode != 200) {
    throw StateError('Téléchargement échoué (code HTTP ${response.statusCode}).');
  }

  final total = response.contentLength;
  var received = 0;
  final sink = partFile.openWrite();
  final digestSink = model.sha256 != null ? _DigestSink() : null;
  final digestInput = digestSink != null ? sha256.startChunkedConversion(digestSink) : null;

  await for (final chunk in response.stream) {
    sink.add(chunk);
    digestInput?.add(chunk);
    received += chunk.length;
    yield (total != null && total > 0) ? received / total : null;
  }
  await sink.close();
  digestInput?.close();

  final expectedSha256 = model.sha256;
  if (expectedSha256 != null) {
    final actual = digestSink!.value.toString();
    if (actual != expectedSha256) {
      await partFile.delete();
      throw StateError('Somme de contrôle invalide - fichier téléchargé corrompu.');
    }
  }

  if (await finalFile.exists()) await finalFile.delete();
  await partFile.rename(finalFile.path);
}
