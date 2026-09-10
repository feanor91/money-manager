import 'db_backup_stub.dart' if (dart.library.io) 'db_backup_io.dart' as impl;

/// Saves a timestamped copy of the database, taken right when it's opened
/// (see [DatabaseProvider._swapDatabase]) - a lightweight, always-on safety
/// net independent of whatever external backup habits the user does or
/// doesn't have for the real file. Writes a real file into a `backup`
/// folder next to the source .mmb - same folder name as
/// WebFileLink/AndroidFileLink's own writeBackup, deliberately, so every
/// platform's automatic snapshots land in one place instead of splitting
/// across `backup`/`backups` depending which app last wrote one.
///
/// Native (desktop/Android) only - on web, [DatabaseProvider] instead calls
/// [WebFileLink.writeBackup], since the destination there depends on
/// whichever directory handle the user granted, not a plain path.
abstract class DbBackup {
  static Future<void> save({
    required String label,
    required List<int> bytes,
    required int retentionWeeks,
  }) =>
      impl.save(label: label, bytes: bytes, retentionWeeks: retentionWeeks);
}

/// `MyMoney_2026-07-25_14-32-05.mmb` - the copy's own name carries the
/// moment it was taken, per the user's explicit request to version backups
/// by date and time rather than just overwriting a single "latest" copy.
String backupFileName(String sourceLabel) {
  final segments = sourceLabel.replaceAll('\\', '/').split('/');
  final rawName = segments.isEmpty ? sourceLabel : segments.last;
  final baseName =
      rawName.replaceAll(RegExp(r'\.mmb$', caseSensitive: false), '');
  final now = DateTime.now();
  String pad(int n) => n.toString().padLeft(2, '0');
  final stamp =
      '${now.year}-${pad(now.month)}-${pad(now.day)}_${pad(now.hour)}-${pad(now.minute)}-${pad(now.second)}';
  return '${baseName}_$stamp.mmb';
}

/// The moment a backup was taken, parsed back out of its own filename per
/// [backupFileName]'s convention (`<base>_YYYY-MM-DD_HH-MM-SS.mmb`) - null
/// for anything that doesn't match that exact shape (a file dropped into
/// the `backup` folder by hand, or one predating this naming scheme), so
/// [backupFileNamesToDelete] never guesses about a file it doesn't
/// recognize.
DateTime? backupTimestamp(String fileName) {
  final match = RegExp(
    r'_(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})\.mmb$',
    caseSensitive: false,
  ).firstMatch(fileName);
  if (match == null) return null;
  try {
    return DateTime(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
    );
  } catch (_) {
    return null;
  }
}

/// Which of [fileNames] (every file currently in a `backup` folder, names
/// only - no path) are older than [retentionWeeks] rolling weeks from
/// [now] and should be deleted (2026-09-05 user request: "par défaut on
/// ne garderait que 4 semaines glissantes, les plus récentes"). A pure
/// function, deliberately independent of how each platform actually
/// lists/deletes files (`dart:io` on desktop, IndexedDB-tracked manifest
/// on web, SAF listing on Android) - the retention *rule* itself is
/// directly unit-tested here once, rather than three times, slightly
/// differently, embedded in each platform's own I/O code. A file
/// [backupTimestamp] can't parse is never included, so an unrecognized
/// file already in that folder is always left alone.
List<String> backupFileNamesToDelete(
  List<String> fileNames, {
  required int retentionWeeks,
  DateTime? now,
}) {
  final cutoff =
      (now ?? DateTime.now()).subtract(Duration(days: retentionWeeks * 7));
  return [
    for (final name in fileNames)
      if (backupTimestamp(name)?.isBefore(cutoff) ?? false) name,
  ];
}
