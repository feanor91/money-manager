import 'dart:io';
import 'dart:typed_data';

import 'db_backup.dart';

Future<void> save({required String label, required List<int> bytes}) async {
  // `label` is the real file path on native (see MmexDatabase.label) -
  // park backups in a sibling `backups` folder rather than the app's own
  // storage, so they survive an app reinstall and are easy to find next to
  // the original file.
  final sourceFile = File(label);
  final backupsDir = Directory('${sourceFile.parent.path}/backups');
  if (!backupsDir.existsSync()) {
    backupsDir.createSync(recursive: true);
  }
  final backupFile = File('${backupsDir.path}/${backupFileName(label)}');
  await backupFile.writeAsBytes(Uint8List.fromList(bytes), flush: true);
}
