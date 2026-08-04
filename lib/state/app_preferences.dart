import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/encrypted_settings_codec.dart';

/// Thin facade over local key-value storage, so the rest of the app
/// doesn't need to know or care whether it's actually talking to the
/// [SharedPreferences] plugin (web, Android, an installed desktop build)
/// or a hand-rolled encrypted file living next to the executable (a
/// portable desktop build - see [_portableStoreFilePath]). Every call
/// site that used to say `SharedPreferences.getInstance()` now says
/// `AppPreferences.getInstance()` instead; the get/set method names are
/// unchanged, so this is a drop-in swap.
abstract class AppPreferences {
  static AppPreferences? _instance;

  static Future<AppPreferences> getInstance() async {
    final existing = _instance;
    if (existing != null) return existing;
    final portablePath = await _portableStoreFilePath();
    final instance = portablePath != null
        ? await EncryptedFilePreferences.load(portablePath)
        : _SharedPreferencesAdapter(await SharedPreferences.getInstance());
    _instance = instance;
    return instance;
  }

  /// Bypasses the portable-marker detection to directly construct the
  /// encrypted-file backend against an arbitrary path - lets tests
  /// exercise the real encrypt/decrypt round-trip without needing an
  /// actual `portable.txt` sitting next to whatever executable happens to
  /// be running the test.
  @visibleForTesting
  static Future<AppPreferences> forTestingAtPath(String path) =>
      EncryptedFilePreferences.load(path);

  /// Seeds the singleton [getInstance] returns, so any code that calls
  /// `AppPreferences.getInstance()` internally (not just code a test can
  /// pass an instance to directly) gets this one instead of ever reaching
  /// [_portableStoreFilePath]'s real file I/O.
  ///
  /// Found 2026-08-04 diagnosing why nl_query_dialog_test.dart's 3 widget
  /// tests that trigger NlQueryDialog._ask() hung forever on
  /// pumpAndSettle: that path calls isLocalLlmEnabled(), which calls this
  /// class's real getInstance(), which - with no seeded instance -
  /// evaluates _portableStoreFilePath() and awaits `File(...).exists()`
  /// against a path next to flutter_tester.exe. That await never resolves
  /// inside a widget test's pumped/faked execution (confirmed via prints:
  /// execution reached "about to check marker.exists()" and never printed
  /// again) - real, uncontrolled OS file I/O doesn't integrate with
  /// WidgetTester.pumpAndSettle the way Timers/microtasks do. Seeding the
  /// cache in setUpAll (see nl_query_dialog_test.dart) makes getInstance()
  /// take its early `existing != null` return instead, so that file check
  /// is never reached at all.
  @visibleForTesting
  static void debugOverrideInstance(AppPreferences instance) {
    _instance = instance;
  }

  /// Pairs with [debugOverrideInstance] - clears the seeded instance so a
  /// later, unrelated test/run doesn't keep reusing it.
  @visibleForTesting
  static void debugResetInstance() {
    _instance = null;
  }

  /// A "portable" build is one distributed as a folder that runs from
  /// anywhere (a USB stick, a different PC) without installing - detected
  /// by a `portable.txt` marker file sitting next to the executable (the
  /// portable ZIP's build step drops one in; the Inno Setup installer's
  /// output never does). Only meaningful on native desktop: web has no
  /// executable path to check, and mobile builds are never "portable" in
  /// this sense.
  static Future<String?> _portableStoreFilePath() async {
    if (kIsWeb) return null;
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return null;
    }
    final exeDir = File(Platform.resolvedExecutable).parent;
    final marker = File('${exeDir.path}${Platform.pathSeparator}portable.txt');
    if (!await marker.exists()) return null;
    return '${exeDir.path}${Platform.pathSeparator}preferences.dat';
  }

  String? getString(String key);
  Future<bool> setString(String key, String value);
  int? getInt(String key);
  Future<bool> setInt(String key, int value);
  List<String>? getStringList(String key);
  Future<bool> setStringList(String key, List<String> value);
  Future<bool> remove(String key);
}

class _SharedPreferencesAdapter implements AppPreferences {
  final SharedPreferences _prefs;

  _SharedPreferencesAdapter(this._prefs);

  @override
  String? getString(String key) => _prefs.getString(key);
  @override
  Future<bool> setString(String key, String value) =>
      _prefs.setString(key, value);
  @override
  int? getInt(String key) => _prefs.getInt(key);
  @override
  Future<bool> setInt(String key, int value) => _prefs.setInt(key, value);
  @override
  List<String>? getStringList(String key) => _prefs.getStringList(key);
  @override
  Future<bool> setStringList(String key, List<String> value) =>
      _prefs.setStringList(key, value);
  @override
  Future<bool> remove(String key) => _prefs.remove(key);
}

/// Stores every key in a single JSON object, AES-256-CBC encrypted, in a
/// file at an arbitrary given path - used both for the portable-desktop
/// case above (next to the executable) and for [DatabaseCompanionSettings]
/// (next to the currently open .mmb file, see lib/data/
/// db_companion_settings_io.dart), which is why this is public rather than
/// private to this file. "Encrypted" here means resistant to casually being
/// opened in a text editor, not real security: the key is embedded in the
/// app itself (same security posture as [PinLockProvider]'s PIN hash - a
/// deterrent, not cryptographic protection of data at rest, since anyone
/// with the app's source/binary can derive the key too). That's an
/// acceptable tradeoff here since files using this class only ever hold app
/// preferences/settings (PIN hash/salt, UI settings) - never the actual
/// financial data, which stays in the plain .mmb SQLite file as MMEX itself
/// always has it.
class EncryptedFilePreferences implements AppPreferences {
  final File _file;
  final Map<String, Object?> _data;

  EncryptedFilePreferences._(this._file, this._data);

  static Future<EncryptedFilePreferences> load(String path) async {
    final file = File(path);
    var data = <String, Object?>{};
    if (await file.exists()) {
      try {
        data = decryptSettingsBytes(await file.readAsBytes());
      } catch (_) {
        // Corrupted or foreign file - start fresh rather than crash the
        // whole app over a preferences file, which is recoverable/
        // non-critical (unlike the actual .mmb database).
        data = {};
      }
    }
    return EncryptedFilePreferences._(file, data);
  }

  Future<bool> _persist() async {
    await _file.writeAsBytes(encryptSettingsBytes(_data), flush: true);
    return true;
  }

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
