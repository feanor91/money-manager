import 'dart:convert';
import 'dart:io';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
        ? await _EncryptedFilePreferences.load(portablePath)
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
      _EncryptedFilePreferences.load(path);

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
/// file next to the portable executable. "Encrypted" here means
/// resistant to casually being opened in a text editor off the USB stick,
/// not real security: the key is embedded in the app itself (same
/// security posture as [PinLockProvider]'s PIN hash - a deterrent, not
/// cryptographic protection of data at rest, since anyone with the app's
/// source/binary can derive the key too). That's an acceptable tradeoff
/// here since the file only ever holds app preferences (last file path,
/// PIN hash/salt, UI settings) - never the actual financial data, which
/// stays in the plain .mmb SQLite file as MMEX itself always has it.
class _EncryptedFilePreferences implements AppPreferences {
  static final _key = enc.Key.fromUtf8('Mn8rF2kLpX9qT4wZaC7uJ6yH1sE3bV0d');

  final File _file;
  final Map<String, Object?> _data;

  _EncryptedFilePreferences._(this._file, this._data);

  static Future<_EncryptedFilePreferences> load(String path) async {
    final file = File(path);
    var data = <String, Object?>{};
    if (await file.exists()) {
      try {
        data = _decrypt(await file.readAsBytes());
      } catch (_) {
        // Corrupted or foreign file - start fresh rather than crash the
        // whole app over a preferences file, which is recoverable/
        // non-critical (unlike the actual .mmb database).
        data = {};
      }
    }
    return _EncryptedFilePreferences._(file, data);
  }

  static Map<String, Object?> _decrypt(Uint8List raw) {
    if (raw.length <= 16) return {};
    final iv = enc.IV(raw.sublist(0, 16));
    final encrypter = enc.Encrypter(enc.AES(_key, mode: enc.AESMode.cbc));
    final plain = encrypter.decrypt(enc.Encrypted(raw.sublist(16)), iv: iv);
    return (jsonDecode(plain) as Map).cast<String, Object?>();
  }

  Future<bool> _persist() async {
    final iv = enc.IV.fromSecureRandom(16);
    final encrypter = enc.Encrypter(enc.AES(_key, mode: enc.AESMode.cbc));
    final cipher = encrypter.encrypt(jsonEncode(_data), iv: iv);
    await _file.writeAsBytes([...iv.bytes, ...cipher.bytes], flush: true);
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
