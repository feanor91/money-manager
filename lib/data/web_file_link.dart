import 'web_file_link_stub.dart'
    if (dart.library.js_interop) 'web_file_link_web.dart' as impl;

enum WebFileRestoreStatus {
  /// No file has ever been picked (or the browser doesn't support this API).
  none,

  /// A handle is stored but the browser needs a fresh user gesture (a
  /// button tap) before it will grant read/write access again.
  needsPermission,

  /// The handle is usable right away - [WebFileLink.readBytes] can be
  /// called immediately.
  ready,
}

class WebFileRestoreResult {
  final WebFileRestoreStatus status;
  final WebFileLink? link;

  /// When [status] is [WebFileRestoreStatus.needsPermission], the
  /// remembered file's name (so the UI can say "Reconnect to X.mmb"
  /// instead of a generic message). A handle's name is readable without
  /// needing read/write permission first.
  final String? pendingName;

  const WebFileRestoreResult(this.status, [this.link, this.pendingName]);
}

/// A remembered handle to a file the user picked via the browser's File
/// System Access API - unlike a one-shot byte array from a plain
/// `<input type=file>`, this can be re-used across page reloads (subject to
/// the browser re-confirming permission) and written back to directly, so
/// edits land in the real file on disk instead of only living in memory.
abstract class WebFileLink {
  /// True if this browser exposes `window.showOpenFilePicker` at all
  /// (Chrome/Edge; not Firefox/Safari as of writing).
  static bool get isSupported => impl.isSupported;

  /// Opens the picker, remembers the chosen file's handle for next time,
  /// and returns a link to it. Returns null if the user cancelled.
  static Future<WebFileLink?> pickAndRemember() => impl.pickAndRemember();

  /// Attempts to reuse the handle remembered from a previous session
  /// without showing any picker UI.
  static Future<WebFileRestoreResult> tryRestore() => impl.tryRestore();

  /// Re-requests permission for the remembered handle - must be called
  /// directly from a user gesture (e.g. a button's onPressed), or the
  /// browser will reject it. Returns null if the user declined.
  static Future<WebFileLink?> requestPermissionAndRestore() =>
      impl.requestPermissionAndRestore();

  /// File name, for display purposes.
  String get name;

  /// Reads the file's current bytes fresh from disk.
  Future<List<int>> readBytes();

  /// Overwrites the file's contents on disk.
  Future<void> writeBytes(List<int> bytes);

  /// Writes a dated snapshot into a `backup` subfolder of the directory the
  /// user granted access to alongside the main file (see [pickAndRemember]).
  /// A no-op if that folder access was never granted or its permission has
  /// lapsed - there's no way to write anywhere on disk on the web without
  /// an explicit grant, so this fails silently rather than nagging the user
  /// every single time the app opens.
  Future<void> writeBackup(List<int> bytes, String fileName);
}
