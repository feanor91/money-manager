import 'mmex_database_stub.dart'
    if (dart.library.io) 'mmex_database_io.dart'
    if (dart.library.js_interop) 'mmex_database_web.dart' as impl;

/// Cross-platform handle to an open MMEX (.mmb) SQLite database.
///
/// On Android/desktop this wraps a native `sqlite3` connection opened
/// directly on the chosen file path (true read/write in place).
/// On web there is no arbitrary filesystem access, so the file is loaded
/// fully into an in-memory sqlite3 (wasm) database; [exportBytes] lets the
/// UI offer a "save back to disk" download after edits.
abstract class MmexDatabase {
  /// [createIfMissing] must only be true for genuinely creating a brand-new
  /// file at a path that doesn't exist yet (see createNewDatabase) - false
  /// (the default) makes a missing path a clean error instead of silently
  /// opening an empty, schema-less new file where a real one was expected.
  static Future<MmexDatabase> openFromPath(String path, {bool createIfMissing = false}) =>
      impl.openFromPath(path, createIfMissing: createIfMissing);

  static Future<MmexDatabase> openFromBytes(List<int> bytes, {String? label}) =>
      impl.openFromBytes(bytes, label: label);

  /// Human readable origin (file path on native, file name on web).
  String get label;

  /// True on platforms where writes go straight back to the original file.
  bool get isDirectlyPersisted;

  List<Map<String, Object?>> query(String sql, [List<Object?> params = const []]);

  /// Executes a write statement and returns the last inserted row id.
  int execute(String sql, [List<Object?> params = const []]);

  void transaction(void Function() action);

  /// Returns the full database file bytes (used for web "download" export).
  List<int> exportBytes();

  void dispose();
}
