import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'app_preferences.dart';

const _prefsKeyPinHash = 'mmex_pin_hash';
const _prefsKeyPinSalt = 'mmex_pin_salt';

/// A simple applicative PIN lock, independent of however the .mmb file
/// itself is hosted or reached (the same code path on web and Android) -
/// meant as a deterrent against casual/opportunistic access (a found phone,
/// a guessed URL), not as cryptographic protection of the data at rest.
/// Never stores the PIN itself, only a salted hash.
class PinLockProvider extends ChangeNotifier {
  bool _hasPin = false;
  bool _unlocked = false;
  bool _loaded = false;

  bool get hasPin => _hasPin;
  bool get isUnlocked => !_hasPin || _unlocked;

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await AppPreferences.getInstance();
    _hasPin = prefs.getString(_prefsKeyPinHash) != null;
    _loaded = true;
    notifyListeners();
  }

  String _hash(String pin, String salt) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();

  Future<void> setPin(String pin) async {
    final prefs = await AppPreferences.getInstance();
    final salt =
        List.generate(16, (_) => Random.secure().nextInt(256)).join(',');
    await prefs.setString(_prefsKeyPinSalt, salt);
    await prefs.setString(_prefsKeyPinHash, _hash(pin, salt));
    _hasPin = true;
    _unlocked = true;
    notifyListeners();
  }

  Future<void> removePin() async {
    final prefs = await AppPreferences.getInstance();
    await prefs.remove(_prefsKeyPinHash);
    await prefs.remove(_prefsKeyPinSalt);
    _hasPin = false;
    _unlocked = true;
    notifyListeners();
  }

  Future<bool> verify(String pin) async {
    final prefs = await AppPreferences.getInstance();
    final salt = prefs.getString(_prefsKeyPinSalt);
    final storedHash = prefs.getString(_prefsKeyPinHash);
    if (salt == null || storedHash == null) return true;
    final ok = _hash(pin, salt) == storedHash;
    if (ok) {
      _unlocked = true;
      notifyListeners();
    }
    return ok;
  }

  /// Called when the app is backgrounded (mobile) so returning to it
  /// requires the PIN again - a lock that only checked once at launch
  /// wouldn't do much for a phone left unlocked on a table.
  void lockOnBackground() {
    if (!_hasPin) return;
    _unlocked = false;
    notifyListeners();
  }
}
