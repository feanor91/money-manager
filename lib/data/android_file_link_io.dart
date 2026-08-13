import 'dart:typed_data';

import 'package:saf_stream/saf_stream.dart';
import 'package:saf_util/saf_util.dart';

import '../state/app_preferences.dart';
import 'android_file_link.dart';

const _prefsKeyDirectoryUri = 'mmex_android_dir_uri';
const _prefsKeyFileName = 'mmex_android_file_name';

final _safUtil = SafUtil();
final _safStream = SafStream();

bool _looksLikeDatabase(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.mmb') || lower.endsWith('.db') || lower.endsWith('.sqlite');
}

/// Opens the SAF folder picker, then finds the single database file inside
/// it (see AndroidFileLink's own doc comment for why this is folder-, not
/// file-, based). Remembers both the folder and file name for [tryRestore].
Future<AndroidFileLink?> pickAndRemember() async {
  final dir = await _safUtil.pickDirectory(
    writePermission: true,
    persistablePermission: true,
  );
  if (dir == null) return null;
  final entries = await _safUtil.list(dir.uri);
  final candidates = entries.where((e) => !e.isDir && _looksLikeDatabase(e.name)).toList();
  if (candidates.isEmpty) {
    throw StateError('Aucun fichier .mmb, .db ou .sqlite trouvé dans ce dossier.');
  }
  if (candidates.length > 1) {
    throw StateError(
        'Plusieurs fichiers de base trouvés dans ce dossier - choisissez-en un ne contenant que le vôtre.');
  }
  final fileName = candidates.single.name;
  final prefs = await AppPreferences.getInstance();
  await prefs.setString(_prefsKeyDirectoryUri, dir.uri);
  await prefs.setString(_prefsKeyFileName, fileName);
  return _AndroidFileLinkImpl(dir.uri, fileName);
}

/// Reuses the folder+file remembered from a previous session without
/// showing any picker - null if nothing was ever remembered, or the
/// permission has lapsed (the user will need [pickAndRemember] again).
Future<AndroidFileLink?> tryRestore() async {
  final prefs = await AppPreferences.getInstance();
  final dirUri = prefs.getString(_prefsKeyDirectoryUri);
  final fileName = prefs.getString(_prefsKeyFileName);
  if (dirUri == null || fileName == null) return null;
  final ok = await _safUtil.hasPersistedPermission(dirUri, checkRead: true, checkWrite: true);
  if (!ok) return null;
  return _AndroidFileLinkImpl(dirUri, fileName);
}

/// Deliberately whole-file byte read/write, not a direct SQLite-over-file-
/// descriptor trick some SAF integrations attempt (saf_util's own
/// getFileDescriptor makes that technically possible) - a cloud-storage-
/// backed provider (Nextcloud's own Android app, in this app's real usage)
/// may not support genuine random access for that, and getting it wrong
/// risks silent corruption. Whole-file read/write is exactly what the web
/// version already does successfully against the same kind of synced
/// folder, via the same debounced touch()/write-back in DatabaseProvider.
class _AndroidFileLinkImpl implements AndroidFileLink {
  final String directoryUri;
  final String fileName;

  _AndroidFileLinkImpl(this.directoryUri, this.fileName);

  @override
  String get name => fileName;

  @override
  Future<Uint8List> readBytes() async {
    final file = await _safUtil.child(directoryUri, [fileName]);
    if (file == null) {
      throw StateError('$fileName introuvable - a-t-il été déplacé ou supprimé ?');
    }
    return _safStream.readFileBytes(file.uri);
  }

  @override
  Future<void> writeBytes(List<int> bytes) => _write(fileName, bytes);

  @override
  Future<DateTime?> lastModified() async {
    final file = await _safUtil.child(directoryUri, [fileName]);
    if (file == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(file.lastModified);
  }

  @override
  Future<void> writeBackup(List<int> bytes, String backupFileName) async {
    try {
      final backupDir = await _safUtil.mkdirp(directoryUri, ['backup']);
      await _safStream.writeFileBytes(
        backupDir.uri,
        backupFileName,
        'application/octet-stream',
        Uint8List.fromList(bytes),
        overwrite: true,
      );
    } catch (_) {
      // Best-effort, same as WebFileLink.writeBackup.
    }
  }

  @override
  Future<Uint8List?> readCompanionFile(String name) async {
    final file = await _safUtil.child(directoryUri, [name]);
    if (file == null) return null;
    try {
      return await _safStream.readFileBytes(file.uri);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> writeCompanionFile(String name, List<int> bytes) async {
    try {
      await _write(name, bytes);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _write(String name, List<int> bytes) => _safStream.writeFileBytes(
        directoryUri,
        name,
        'application/octet-stream',
        Uint8List.fromList(bytes),
        overwrite: true,
      );
}
