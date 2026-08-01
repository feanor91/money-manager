import 'dart:io';
import 'dart:typed_data';

import '../state/app_preferences.dart';
import 'android_file_link.dart';
import 'encrypted_settings_codec.dart';
import 'web_file_link.dart';

/// Name of the encrypted settings file living next to the .mmb database -
/// fixed rather than derived from the database's own name, so every .mmb
/// file in the same folder (e.g. a "current" one and old copies) shares one
/// settings file, and so the two are trivially told apart at a glance.
const companionSettingsFileName = 'money_manager_settings.dat';

/// Where PIN-lock state and every app preference/setting now lives (see
/// CLAUDE.md) - a small AES-encrypted file sitting right next to the
/// currently open .mmb file, instead of AppPreferences (device/browser-local
/// storage). Because it's a sibling of the database itself, it survives a
/// browser "clear site data" or an app reinstall, and it travels with the
/// database to every device/browser that opens it (e.g. a cloud-synced
/// folder) - one PIN, one set of preferences, wherever the file is opened.
///
/// [AppPreferences] itself is still used, but now only for the handful of
/// things that genuinely cannot move here: which database to reopen at
/// startup, and (web) the browser's own remembered file/folder permissions
/// - both are inherently per-device/per-browser, resolved *before* this
/// companion file's location is even known.
abstract class DatabaseCompanionSettings {
  /// Desktop (Windows/macOS/Linux) only: [dbPath] is the real path of the
  /// currently open .mmb file (see MmexDatabase.label on native). Always
  /// succeeds - unlike the web/Android cases, there's no permission to lack.
  ///
  /// NOT used for Android, despite that being "native" too in the sense of
  /// having direct sqlite3 file access - see [forAndroidLink]'s own doc
  /// comment for why a plain file path can't be trusted there.
  static Future<AppPreferences> forNativePath(String dbPath) {
    final dir = File(dbPath).parent.path;
    final siblingPath = '$dir${Platform.pathSeparator}$companionSettingsFileName';
    return EncryptedFilePreferences.load(siblingPath);
  }

  /// Web: reads/writes through [link]'s directory handle (see
  /// [WebFileLink.ensureDirectoryPermission]). Returns null if that
  /// permission isn't available yet - callers should offer
  /// [WebFileLink.ensureDirectoryPermission] (from a button tap) and retry
  /// rather than silently losing the setting the user just changed.
  static Future<AppPreferences?> forWebLink(WebFileLink link) async {
    if (!link.hasDirectoryHandle) return null;
    final raw = await link.readCompanionFile(companionSettingsFileName);
    var data = <String, Object?>{};
    if (raw != null) {
      try {
        data = decryptSettingsBytes(Uint8List.fromList(raw));
      } catch (_) {
        // Corrupted or foreign file - start fresh rather than crash the
        // whole app over a settings file, which is recoverable/non-critical
        // (unlike the actual .mmb database).
        data = {};
      }
    }
    return _WebCompanionPreferences(link, data);
  }

  /// Android: reads/writes through [link]'s Storage Access Framework
  /// folder grant - see AndroidFileLink's own doc comment for why Android
  /// needs this at all instead of [forNativePath], despite running real
  /// `dart:io`/sqlite3 code same as desktop: a plain file picker on Android
  /// only ever hands back a path to a private-cache copy it silently made,
  /// never the real file, so a "sibling path" next to that copy would be
  /// just as disconnected from the real folder as the copy itself.
  ///
  /// Unlike [forWebLink], never returns null - an [AndroidFileLink] only
  /// ever exists with folder access already granted (see
  /// AndroidFileLink.pickAndRemember), there's no "link exists but isn't
  /// reachable yet" state to represent here.
  static Future<AppPreferences> forAndroidLink(AndroidFileLink link) async {
    final raw = await link.readCompanionFile(companionSettingsFileName);
    var data = <String, Object?>{};
    if (raw != null) {
      try {
        data = decryptSettingsBytes(Uint8List.fromList(raw));
      } catch (_) {
        data = {};
      }
    }
    return _AndroidCompanionPreferences(link, data);
  }
}

class _WebCompanionPreferences implements AppPreferences {
  final WebFileLink _link;
  final Map<String, Object?> _data;

  _WebCompanionPreferences(this._link, this._data);

  Future<bool> _persist() =>
      _link.writeCompanionFile(companionSettingsFileName, encryptSettingsBytes(_data));

  @override
  String? getString(String key) => _data[key] as String?;
  @override
  Future<bool> setString(String key, String value) {
    _data[key] = value;
    return _persist();
  }

  @override
  int? getInt(String key) => _data[key] as int?;
  @override
  Future<bool> setInt(String key, int value) {
    _data[key] = value;
    return _persist();
  }

  @override
  List<String>? getStringList(String key) {
    final v = _data[key];
    return v is List ? v.cast<String>() : null;
  }

  @override
  Future<bool> setStringList(String key, List<String> value) {
    _data[key] = value;
    return _persist();
  }

  @override
  Future<bool> remove(String key) {
    _data.remove(key);
    return _persist();
  }
}

class _AndroidCompanionPreferences implements AppPreferences {
  final AndroidFileLink _link;
  final Map<String, Object?> _data;

  _AndroidCompanionPreferences(this._link, this._data);

  Future<bool> _persist() =>
      _link.writeCompanionFile(companionSettingsFileName, encryptSettingsBytes(_data));

  @override
  String? getString(String key) => _data[key] as String?;
  @override
  Future<bool> setString(String key, String value) {
    _data[key] = value;
    return _persist();
  }

  @override
  int? getInt(String key) => _data[key] as int?;
  @override
  Future<bool> setInt(String key, int value) {
    _data[key] = value;
    return _persist();
  }

  @override
  List<String>? getStringList(String key) {
    final v = _data[key];
    return v is List ? v.cast<String>() : null;
  }

  @override
  Future<bool> setStringList(String key, List<String> value) {
    _data[key] = value;
    return _persist();
  }

  @override
  Future<bool> remove(String key) {
    _data.remove(key);
    return _persist();
  }
}
