import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'mmex_database.dart';

Future<MmexDatabase> openFromPath(String path, {bool createIfMissing = false}) async {
  // sqlite3.open defaults to OpenMode.readWriteCreate - silently creating a
  // fresh, empty (and schema-less: none of MMEX's own tables) file if `path`
  // doesn't exist, rather than throwing. That's exactly wrong for reopening
  // a remembered path: a renamed/moved/deleted real database would open
  // "successfully" into a blank new file with no prompt to pick the right
  // one instead - confirmed 2026-08-01 as the actual cause of a "blank app,
  // no way to open the new database" report after a plain file rename.
  // Only createNewDatabase() genuinely wants create-if-missing (a brand new
  // path from a save-file dialog, which never exists yet by construction).
  final db = sqlite3.open(
    path,
    mode: createIfMissing ? OpenMode.readWriteCreate : OpenMode.readWrite,
  );
  return _IoMmexDatabase(db, path, path);
}

Future<MmexDatabase> openFromBytes(List<int> bytes, {String? label}) async {
  // Load the provided bytes into a temp file then open it, so the full
  // on-disk schema (indices, etc.) round-trips exactly like the source file.
  final tempDir = Directory.systemTemp.createTempSync('money_manager_');
  final tempFile = File('${tempDir.path}/imported.mmb');
  await tempFile.writeAsBytes(Uint8List.fromList(bytes), flush: true);
  final real = sqlite3.open(tempFile.path);
  return _IoMmexDatabase(real, tempFile.path, label ?? tempFile.path, isTemp: true);
}

class _IoMmexDatabase implements MmexDatabase {
  final Database _db;
  final String _path;
  final String _label;
  final bool isTemp;

  _IoMmexDatabase(this._db, this._path, this._label, {this.isTemp = false});

  @override
  String get label => _label;

  @override
  bool get isDirectlyPersisted => !isTemp;

  @override
  List<Map<String, Object?>> query(String sql, [List<Object?> params = const []]) {
    final result = _db.select(sql, params);
    return result.map((row) => row).toList();
  }

  @override
  int execute(String sql, [List<Object?> params = const []]) {
    _db.execute(sql, params);
    return _db.lastInsertRowId;
  }

  @override
  void transaction(void Function() action) {
    _db.execute('BEGIN');
    try {
      action();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  List<int> exportBytes() => File(_path).readAsBytesSync();

  @override
  void dispose() => _db.dispose();
}
