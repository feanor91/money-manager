import 'package:sqlite3/wasm.dart';
import 'package:typed_data/typed_data.dart';

import 'mmex_database.dart';

// NOTE (web target): the browser has no arbitrary filesystem path access,
// so "choose the database location" on web means "pick a .mmb file with the
// file picker, load its bytes here, and export/download the updated bytes
// when done" rather than true in-place editing like on Android/desktop.
//
// This seeds package:sqlite3's in-memory VFS (InMemoryFileSystem) directly
// via its public `fileData` map, since the VFS itself has no createFile/
// read/write helpers - only the low level xOpen/xRead/xWrite hooks sqlite
// calls internally.
const _dbPath = '/mmex.mmb';

Future<MmexDatabase> openFromPath(String path, {bool createIfMissing = false}) {
  throw UnsupportedError(
    'Web builds cannot open a database by file path. Use the file picker '
    '(openFromBytes) to choose your .mmb file instead.',
  );
}

Future<MmexDatabase> openFromBytes(List<int> bytes, {String? label}) async {
  final sqlite3 = await WasmSqlite3.loadFromUrl(Uri.parse('sqlite3.wasm'));
  final fs = InMemoryFileSystem();
  sqlite3.registerVirtualFileSystem(fs, makeDefault: true);
  fs.fileData[_dbPath] = Uint8Buffer()..addAll(bytes);

  final db = sqlite3.open(_dbPath, mode: OpenMode.readWrite);
  return _WebMmexDatabase(db, fs, label ?? 'base importée');
}

class _WebMmexDatabase implements MmexDatabase {
  final CommonDatabase _db;
  final InMemoryFileSystem _fs;
  final String _label;

  _WebMmexDatabase(this._db, this._fs, this._label);

  @override
  String get label => _label;

  @override
  bool get isDirectlyPersisted => false;

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
  List<int> exportBytes() {
    final buffer = _fs.fileData[_dbPath];
    if (buffer == null) return const [];
    return buffer.buffer.asUint8List(0, buffer.length);
  }

  @override
  void dispose() => _db.dispose();
}
