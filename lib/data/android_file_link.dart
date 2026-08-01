import 'android_file_link_io.dart'
    if (dart.library.js_interop) 'android_file_link_stub.dart' as impl;

/// Android counterpart to WebFileLink (see its own doc comment for the full
/// rationale, and CLAUDE.md's "Android file access" section) - a remembered
/// Storage Access Framework directory grant, so the app reads/writes the
/// real .mmb file (and a settings file alongside it) wherever the user
/// actually keeps it (e.g. a Nextcloud-synced folder), instead of the
/// throwaway private-cache copy a plain `FilePicker.pickFiles()` gives on
/// Android.
///
/// The real implementation (android_file_link_io.dart) depends on
/// `package:saf_stream`, which pulls in `dart:ffi` on native platforms -
/// unavailable on web, so this file conditionally imports a no-op stub
/// there instead (same mechanism WebFileLink uses in the other direction).
/// Never actually reached on web regardless, since every call site is
/// gated behind DatabaseProvider's `_isAndroid` check first.
abstract class AndroidFileLink {
  /// Opens the SAF folder picker and remembers both the folder and the
  /// single database file found inside it. Throws [StateError] if the
  /// chosen folder has zero or more than one `.mmb`/`.db`/`.sqlite`
  /// candidate file. Returns null if the user cancelled the folder picker.
  static Future<AndroidFileLink?> pickAndRemember() => impl.pickAndRemember();

  /// Reuses the folder+file remembered from a previous session without
  /// showing any picker - null if nothing was ever remembered, or the
  /// permission has lapsed.
  static Future<AndroidFileLink?> tryRestore() => impl.tryRestore();

  /// File name, for display purposes (matches WebFileLink.name).
  String get name;

  /// Reads the main database file's current bytes fresh from the real
  /// folder (matches WebFileLink.readBytes).
  Future<List<int>> readBytes();

  /// Overwrites the main database file's contents (matches
  /// WebFileLink.writeBytes).
  Future<void> writeBytes(List<int> bytes);

  /// Writes a dated snapshot into a `backup` subfolder, same principle as
  /// WebFileLink.writeBackup - best-effort, never throws.
  Future<void> writeBackup(List<int> bytes, String backupFileName);

  /// Reads a file directly inside the same folder as the main database -
  /// null if it doesn't exist yet or can't be read (matches
  /// WebFileLink.readCompanionFile).
  Future<List<int>?> readCompanionFile(String fileName);

  /// Writes a file directly inside the same folder as the main database,
  /// creating it if needed - false on failure (matches
  /// WebFileLink.writeCompanionFile).
  Future<bool> writeCompanionFile(String fileName, List<int> bytes);
}
