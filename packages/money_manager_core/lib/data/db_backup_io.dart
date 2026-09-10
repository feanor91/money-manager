import 'dart:io';
import 'dart:typed_data';

import 'db_backup.dart';

Future<void> save({
  required String label,
  required List<int> bytes,
  required int retentionWeeks,
}) async {
  // `label` is the real file path on native (see MmexDatabase.label) -
  // park backups in a sibling `backup` folder rather than the app's own
  // storage, so they survive an app reinstall and are easy to find next to
  // the original file. Must match the folder name WebFileLink/AndroidFileLink
  // use for their own writeBackup, or the same synced folder ends up with
  // two parallel backup folders depending which platform last wrote one.
  final sourceFile = File(label);
  final backupsDir = Directory('${sourceFile.parent.path}/backup');
  if (!backupsDir.existsSync()) {
    backupsDir.createSync(recursive: true);
  }
  final backupFile = File('${backupsDir.path}/${backupFileName(label)}');
  await backupFile.writeAsBytes(Uint8List.fromList(bytes), flush: true);
  try {
    await _pruneOldBackups(backupsDir, retentionWeeks);
  } catch (_) {
    // Never let a cleanup failure (permission, a file in use) look like
    // the backup itself failed - it already landed on disk above.
  }
}

/// Deletes whatever [backupFileNamesToDelete] flags among [dir]'s own
/// entries - "par défaut on ne garderait que 4 semaines glissantes"
/// (2026-09-05 user request), configurable via
/// DatabaseProvider.backupRetentionWeeks.
Future<void> _pruneOldBackups(Directory dir, int retentionWeeks) async {
  final files = dir.listSync().whereType<File>().toList();
  final names = [for (final f in files) f.uri.pathSegments.last];
  final toDelete =
      backupFileNamesToDelete(names, retentionWeeks: retentionWeeks).toSet();
  for (final file in files) {
    if (!toDelete.contains(file.uri.pathSegments.last)) continue;
    try {
      file.deleteSync();
    } catch (_) {
      // Best-effort - a locked/in-use file must never block the rest.
    }
  }
}
