import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'web_file_link.dart';

const _dbName = 'money_manager_file_handles';
const _storeName = 'handles';
final _handleKey = 'lastFile'.toJS;
final _dirHandleKey = 'backupDir'.toJS;

// --- Raw interop not (yet) covered by package:web -------------------------
//
// package:web 1.1.1 models the File System Access API's read/write surface
// (FileSystemFileHandle.getFile/createWritable) but not the entry points
// used to persist access across reloads: picking a file at all, and
// re-confirming permission for a previously remembered handle.

@JS('showOpenFilePicker')
external JSPromise<JSArray<web.FileSystemFileHandle>> _showOpenFilePicker();

@JS('showDirectoryPicker')
external JSPromise<web.FileSystemDirectoryHandle> _showDirectoryPicker();

extension _FileSystemHandlePermissions on web.FileSystemHandle {
  external JSPromise<JSString> queryPermission([JSObject? descriptor]);
  external JSPromise<JSString> requestPermission([JSObject? descriptor]);
}

extension type _PermissionDescriptor._(JSObject _) implements JSObject {
  external factory _PermissionDescriptor({String mode});
}

final _readWriteDescriptor = _PermissionDescriptor(mode: 'readwrite');

// --- IndexedDB storage of the handles ---------------------------------------
//
// FileSystemFileHandle/FileSystemDirectoryHandle are structured-clonable, so
// browsers support storing them directly as IndexedDB record values - this
// is the only documented way to keep a usable reference to a user-picked
// file/folder across page reloads. package:web's IndexedDB bindings are
// event-based (onsuccess/onerror) rather than Promise-based, so each call is
// wrapped in a Completer below.

Future<web.IDBDatabase> _openHandleStore() {
  final completer = Completer<web.IDBDatabase>();
  final request = web.window.indexedDB.open(_dbName, 1);
  request.onupgradeneeded = ((JSAny _) {
    final db = request.result as web.IDBDatabase;
    if (!db.objectStoreNames.contains(_storeName)) {
      db.createObjectStore(_storeName);
    }
  }).toJS;
  request.onsuccess = ((JSAny _) {
    completer.complete(request.result as web.IDBDatabase);
  }).toJS;
  request.onerror = ((JSAny _) {
    completer.completeError(StateError('Impossible d\'ouvrir IndexedDB.'));
  }).toJS;
  return completer.future;
}

Future<void> _storeValue(JSAny key, JSAny value) async {
  final db = await _openHandleStore();
  final txn = db.transaction(_storeName.toJS, 'readwrite');
  final completer = Completer<void>();
  final request = txn.objectStore(_storeName).put(value, key);
  request.onsuccess = ((JSAny _) => completer.complete()).toJS;
  request.onerror = ((JSAny _) =>
      completer.completeError(StateError('Échec écriture IndexedDB.'))).toJS;
  await completer.future;
}

Future<T?> _loadValue<T>(JSAny key) async {
  final db = await _openHandleStore();
  final txn = db.transaction(_storeName.toJS, 'readonly');
  final completer = Completer<T?>();
  final request = txn.objectStore(_storeName).get(key);
  request.onsuccess = ((JSAny _) {
    completer.complete(request.result as T?);
  }).toJS;
  request.onerror = ((JSAny _) => completer.complete(null)).toJS;
  return completer.future;
}

Future<void> _storeHandle(web.FileSystemFileHandle handle) =>
    _storeValue(_handleKey, handle);
Future<web.FileSystemFileHandle?> _loadStoredHandle() =>
    _loadValue<web.FileSystemFileHandle>(_handleKey);
Future<void> _storeDirHandle(web.FileSystemDirectoryHandle handle) =>
    _storeValue(_dirHandleKey, handle);
Future<web.FileSystemDirectoryHandle?> _loadStoredDirHandle() =>
    _loadValue<web.FileSystemDirectoryHandle>(_dirHandleKey);

// --- Public API --------------------------------------------------------

bool get isSupported {
  try {
    return web.window.has('showOpenFilePicker');
  } catch (_) {
    return false;
  }
}

Future<WebFileLink?> pickAndRemember() async {
  if (!isSupported) return null;
  final handles = await _showOpenFilePicker().toDart;
  if (handles.toDart.isEmpty) return null;
  final handle = handles.toDart.first;
  await _storeHandle(handle);

  // Right after picking the file, in the same user-gesture chain: also ask
  // once for access to its containing folder, purely so automatic backups
  // can be written into a `backup` subfolder there without ever prompting
  // again. Optional and best-effort - if the browser refuses a second
  // picker in this chain, or the user cancels/picks the wrong folder,
  // backups are simply skipped rather than failing the whole file pick.
  web.FileSystemDirectoryHandle? dirHandle;
  try {
    dirHandle = await _showDirectoryPicker().toDart;
    await _storeDirHandle(dirHandle);
  } catch (_) {
    dirHandle = null;
  }

  return _WebFileLinkImpl(handle, dirHandle);
}

Future<WebFileRestoreResult> tryRestore() async {
  if (!isSupported) {
    return const WebFileRestoreResult(WebFileRestoreStatus.none);
  }
  web.FileSystemFileHandle? handle;
  try {
    handle = await _loadStoredHandle();
  } catch (_) {
    return const WebFileRestoreResult(WebFileRestoreStatus.none);
  }
  if (handle == null) {
    return const WebFileRestoreResult(WebFileRestoreStatus.none);
  }

  final permission = await handle.queryPermission(_readWriteDescriptor).toDart;
  if (permission.toDart == 'granted') {
    final dirHandle = await _restoreUsableDirHandle();
    return WebFileRestoreResult(
        WebFileRestoreStatus.ready, _WebFileLinkImpl(handle, dirHandle));
  }
  return WebFileRestoreResult(
      WebFileRestoreStatus.needsPermission, null, handle.name);
}

Future<WebFileLink?> requestPermissionAndRestore() async {
  if (!isSupported) return null;
  final handle = await _loadStoredHandle();
  if (handle == null) return null;
  final permission =
      await handle.requestPermission(_readWriteDescriptor).toDart;
  if (permission.toDart != 'granted') return null;
  final dirHandle = await _restoreUsableDirHandle();
  return _WebFileLinkImpl(handle, dirHandle);
}

/// Only returns the remembered directory handle if it's already usable
/// without a fresh prompt (`queryPermission`, not `requestPermission` -
/// unlike the main file, backups are opportunistic: silently skipped for
/// this session rather than blocking startup on a second permission dialog).
Future<web.FileSystemDirectoryHandle?> _restoreUsableDirHandle() async {
  try {
    final dirHandle = await _loadStoredDirHandle();
    if (dirHandle == null) return null;
    final permission =
        await dirHandle.queryPermission(_readWriteDescriptor).toDart;
    return permission.toDart == 'granted' ? dirHandle : null;
  } catch (_) {
    return null;
  }
}

class _WebFileLinkImpl implements WebFileLink {
  final web.FileSystemFileHandle _handle;
  web.FileSystemDirectoryHandle? _dirHandle;

  _WebFileLinkImpl(this._handle, this._dirHandle);

  @override
  String get name => _handle.name;

  @override
  Future<List<int>> readBytes() async {
    final file = await _handle.getFile().toDart;
    final buffer = await file.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  }

  @override
  Future<void> writeBytes(List<int> bytes) async {
    final stream = await _handle.createWritable().toDart;
    await stream.write(Uint8List.fromList(bytes).toJS).toDart;
    await stream.close().toDart;
  }

  @override
  Future<void> writeBackup(List<int> bytes, String fileName) async {
    final dir = _dirHandle;
    if (dir == null) return;
    try {
      final backupDir = await dir
          .getDirectoryHandle(
              'backup', web.FileSystemGetDirectoryOptions(create: true))
          .toDart;
      final fileHandle = await backupDir
          .getFileHandle(fileName, web.FileSystemGetFileOptions(create: true))
          .toDart;
      final stream = await fileHandle.createWritable().toDart;
      await stream.write(Uint8List.fromList(bytes).toJS).toDart;
      await stream.close().toDart;
    } catch (_) {
      // Folder access revoked, wrong folder picked, quota, etc. - a failed
      // backup must never block the app from working.
    }
  }

  @override
  bool get hasDirectoryHandle => _dirHandle != null;

  @override
  Future<bool> ensureDirectoryPermission() async {
    final existing = _dirHandle;
    if (existing != null) {
      final permission =
          await existing.queryPermission(_readWriteDescriptor).toDart;
      if (permission.toDart == 'granted') return true;
      try {
        final requested =
            await existing.requestPermission(_readWriteDescriptor).toDart;
        if (requested.toDart == 'granted') return true;
      } catch (_) {
        // Falls through to asking for a folder afresh below.
      }
    }
    // No handle remembered at all, or it's been permanently denied - ask
    // for one fresh. Must be called from a user gesture (the caller's
    // responsibility, same as pickAndRemember).
    try {
      final dir = await _showDirectoryPicker().toDart;
      _dirHandle = dir;
      await _storeDirHandle(dir);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<int>?> readCompanionFile(String fileName) async {
    final dir = _dirHandle;
    if (dir == null) return null;
    try {
      final fileHandle = await dir
          .getFileHandle(fileName, web.FileSystemGetFileOptions(create: false))
          .toDart;
      final file = await fileHandle.getFile().toDart;
      final buffer = await file.arrayBuffer().toDart;
      return buffer.toDart.asUint8List();
    } catch (_) {
      // Doesn't exist yet, permission lapsed, etc.
      return null;
    }
  }

  @override
  Future<bool> writeCompanionFile(String fileName, List<int> bytes) async {
    final dir = _dirHandle;
    if (dir == null) return false;
    try {
      final fileHandle = await dir
          .getFileHandle(fileName, web.FileSystemGetFileOptions(create: true))
          .toDart;
      final stream = await fileHandle.createWritable().toDart;
      await stream.write(Uint8List.fromList(bytes).toJS).toDart;
      await stream.close().toDart;
      return true;
    } catch (_) {
      return false;
    }
  }
}
