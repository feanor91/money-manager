import 'db_backup_stub.dart' if (dart.library.io) 'db_backup_io.dart' as impl;

/// Saves a timestamped copy of the database, taken right when it's opened
/// (see [DatabaseProvider._swapDatabase]) - a lightweight, always-on safety
/// net independent of whatever external backup habits the user does or
/// doesn't have for the real file. Writes a real file into a `backups`
/// folder next to the source .mmb.
///
/// Native (desktop/Android) only - on web, [DatabaseProvider] instead calls
/// [WebFileLink.writeBackup], since the destination there depends on
/// whichever directory handle the user granted, not a plain path.
abstract class DbBackup {
  static Future<void> save({required String label, required List<int> bytes}) =>
      impl.save(label: label, bytes: bytes);
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
