import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'app_preferences.dart';

const _prefsKeyPinHash = 'mmex_pin_hash';
const _prefsKeyPinSalt = 'mmex_pin_salt';
const _prefsKeyFailedAttempts = 'mmex_pin_failed_attempts';
const _prefsKeyLockedUntil = 'mmex_pin_locked_until_epoch_ms';
const _prefsKeyMaxAttempts = 'mmex_pin_max_attempts';
const _prefsKeyLockoutMinutes = 'mmex_pin_lockout_minutes';

/// Outcome of a [PinLockProvider.verify] call - richer than a plain bool so
/// the lock screen can tell "wrong code, N tries left" apart from "you're
/// locked out for the next N seconds" and word the error accordingly.
class PinVerifyResult {
  final bool ok;
  final int? attemptsRemaining;
  final Duration? lockoutRemaining;

  const PinVerifyResult._(this.ok, this.attemptsRemaining, this.lockoutRemaining);

  static const success = PinVerifyResult._(true, null, null);
  factory PinVerifyResult.wrong(int attemptsRemaining) =>
      PinVerifyResult._(false, attemptsRemaining, null);
  factory PinVerifyResult.lockedOut(Duration remaining) =>
      PinVerifyResult._(false, null, remaining);
}

/// What [PinLockProvider] currently shows for, driven entirely by
/// [PinLockProvider.attachDatabase] - see that method for when each value
/// applies.
enum PinGateStatus {
  /// No database open (yet) - irrelevant, _RootGate shows the database
  /// picker regardless of PIN state.
  none,

  /// Web only: a database is open, but this browser doesn't have (or has
  /// lost) permission to the folder the PIN would live in - genuinely
  /// unknown whether a PIN is configured, so this fails *closed* (blocks
  /// entry until access is granted) rather than silently letting a
  /// configured PIN through unchecked.
  needsCompanionAccess,

  /// A PIN is configured for this database and hasn't been entered yet
  /// this session.
  locked,

  /// Either no PIN is configured for this database, or it has been entered
  /// correctly this session.
  unlocked,
}

/// A simple applicative PIN lock, scoped to whichever database is currently
/// open (see [attachDatabase]) rather than to the app/device as a whole -
/// meant as a deterrent against casual/opportunistic access (a found phone,
/// a guessed URL), not as cryptographic protection of the data at rest.
/// Never stores the PIN itself, only a salted hash.
///
/// The PIN hash/salt and the two settings below live in the current
/// database's companion settings file (see db_companion_settings.dart), not
/// in this device's own local storage - so they follow the database itself
/// to every device/browser that opens it, and survive a browser/app data
/// wipe. See CLAUDE.md.
class PinLockProvider extends ChangeNotifier {
  /// Defaults and valid ranges for the two settings below - enforced in
  /// [setMaxAttempts]/[setLockoutMinutes] so a stray value from the
  /// Paramètres screen's free-entry fields (a fat-fingered "1" or "999")
  /// can't make the lock either pointless or a self-lockout trap.
  static const defaultMaxAttempts = 5;
  static const minAttempts = 3;
  static const maxAttemptsAllowed = 20;
  static const defaultLockoutMinutes = 1;
  static const minLockoutMinutes = 1;
  static const maxLockoutMinutes = 60;

  AppPreferences? _prefs;
  PinGateStatus _status = PinGateStatus.none;
  bool _hasPin = false;
  int _maxAttempts = defaultMaxAttempts;
  int _lockoutMinutes = defaultLockoutMinutes;

  PinGateStatus get status => _status;
  bool get hasPin => _hasPin;
  bool get isUnlocked => _status == PinGateStatus.unlocked;
  int get maxAttempts => _maxAttempts;
  int get lockoutMinutes => _lockoutMinutes;
  Duration get lockoutDuration => Duration(minutes: _lockoutMinutes);

  /// Called by DatabaseProvider whenever the open database changes: a new
  /// one opened, the previous one closed, or (web) its companion settings
  /// became reachable/unreachable. Re-reads PIN state from scratch every
  /// time rather than assuming anything carries over - unlocking one
  /// database must never grant access to a different one, and switching
  /// away from a database must never leave it looking "unlocked" for
  /// whoever opens it next.
  ///
  /// [companionPrefs] can be null in two different situations, told apart
  /// by [companionUnreachable]: (web) a database is open but its companion
  /// file isn't reachable yet, so whether a PIN exists is genuinely unknown
  /// ([PinGateStatus.needsCompanionAccess], fails closed) - or there's no
  /// mechanism to reach a companion file at all for this database (web
  /// without File System Access support), in which case there is nothing to
  /// protect and nothing recoverable, so this proceeds unlocked exactly
  /// like "no PIN configured".
  void attachDatabase({
    required bool databaseReady,
    required AppPreferences? companionPrefs,
    bool companionUnreachable = false,
  }) {
    if (!databaseReady) {
      _prefs = null;
      _hasPin = false;
      _status = PinGateStatus.none;
      notifyListeners();
      return;
    }
    if (companionPrefs == null && companionUnreachable) {
      _prefs = null;
      _hasPin = false;
      _status = PinGateStatus.needsCompanionAccess;
      notifyListeners();
      return;
    }
    if (companionPrefs == null) {
      _prefs = null;
      _hasPin = false;
      _maxAttempts = defaultMaxAttempts;
      _lockoutMinutes = defaultLockoutMinutes;
      _status = PinGateStatus.unlocked;
      notifyListeners();
      return;
    }
    _prefs = companionPrefs;
    _hasPin = companionPrefs.getString(_prefsKeyPinHash) != null;
    _maxAttempts = companionPrefs.getInt(_prefsKeyMaxAttempts) ?? defaultMaxAttempts;
    _lockoutMinutes = companionPrefs.getInt(_prefsKeyLockoutMinutes) ?? defaultLockoutMinutes;
    _status = _hasPin ? PinGateStatus.locked : PinGateStatus.unlocked;
    notifyListeners();
  }

  /// [value] must already be validated against [minAttempts]/
  /// [maxAttemptsAllowed] by the caller (the Paramètres screen shows an
  /// inline error instead of calling this for an out-of-range value) - this
  /// clamp is just a last line of defense, not the primary validation.
  Future<void> setMaxAttempts(int value) async {
    final prefs = _prefs;
    if (prefs == null) return;
    _maxAttempts = value.clamp(minAttempts, maxAttemptsAllowed);
    await prefs.setInt(_prefsKeyMaxAttempts, _maxAttempts);
    notifyListeners();
  }

  /// See [setMaxAttempts] re: validation being the caller's job.
  Future<void> setLockoutMinutes(int value) async {
    final prefs = _prefs;
    if (prefs == null) return;
    _lockoutMinutes = value.clamp(minLockoutMinutes, maxLockoutMinutes);
    await prefs.setInt(_prefsKeyLockoutMinutes, _lockoutMinutes);
    notifyListeners();
  }

  String _hash(String pin, String salt) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();

  Future<void> setPin(String pin) async {
    final prefs = _prefs;
    if (prefs == null) return;
    final salt =
        List.generate(16, (_) => Random.secure().nextInt(256)).join(',');
    await prefs.setString(_prefsKeyPinSalt, salt);
    await prefs.setString(_prefsKeyPinHash, _hash(pin, salt));
    await _resetAttempts(prefs);
    _hasPin = true;
    _status = PinGateStatus.unlocked;
    notifyListeners();
  }

  Future<void> removePin() async {
    final prefs = _prefs;
    if (prefs == null) return;
    await prefs.remove(_prefsKeyPinHash);
    await prefs.remove(_prefsKeyPinSalt);
    await _resetAttempts(prefs);
    _hasPin = false;
    _status = PinGateStatus.unlocked;
    notifyListeners();
  }

  Future<void> _resetAttempts(AppPreferences prefs) async {
    await prefs.remove(_prefsKeyFailedAttempts);
    await prefs.remove(_prefsKeyLockedUntil);
  }

  /// Consecutive failed attempts and any active lockout are persisted (not
  /// just held in memory) so force-closing and reopening the app - or
  /// opening the same database from a different device - can't be used to
  /// dodge the lockout, since it's stored in the database's own companion
  /// file, not this device's memory.
  Future<PinVerifyResult> verify(String pin) async {
    final prefs = _prefs;
    if (prefs == null) return PinVerifyResult.success;

    final lockedUntilMs = prefs.getInt(_prefsKeyLockedUntil);
    if (lockedUntilMs != null) {
      final remaining = DateTime.fromMillisecondsSinceEpoch(lockedUntilMs)
          .difference(DateTime.now());
      if (remaining > Duration.zero) {
        return PinVerifyResult.lockedOut(remaining);
      }
      // Lockout expired - clear it and start the attempt count fresh.
      await _resetAttempts(prefs);
    }

    final salt = prefs.getString(_prefsKeyPinSalt);
    final storedHash = prefs.getString(_prefsKeyPinHash);
    if (salt == null || storedHash == null) return PinVerifyResult.success;

    final ok = _hash(pin, salt) == storedHash;
    if (ok) {
      await _resetAttempts(prefs);
      _status = PinGateStatus.unlocked;
      notifyListeners();
      return PinVerifyResult.success;
    }

    final attempts = (prefs.getInt(_prefsKeyFailedAttempts) ?? 0) + 1;
    if (attempts >= _maxAttempts) {
      final until = DateTime.now().add(lockoutDuration);
      await prefs.setInt(_prefsKeyLockedUntil, until.millisecondsSinceEpoch);
      await prefs.setInt(_prefsKeyFailedAttempts, 0);
      return PinVerifyResult.lockedOut(lockoutDuration);
    }
    await prefs.setInt(_prefsKeyFailedAttempts, attempts);
    return PinVerifyResult.wrong(_maxAttempts - attempts);
  }

  /// How long the app can sit in the background before [handleForeground]
  /// re-locks it - a grace period rather than an immediate lock, so a
  /// brief switch-away (a notification, glancing at the app switcher,
  /// answering a call) doesn't demand the PIN again every single time.
  /// Explicit 2026-08-07 user request ("le déverrouillage par code pin est
  /// pénible") after the original design (lock on every single
  /// backgrounding, however brief) proved too aggressive in real daily use
  /// on Android.
  static const backgroundGracePeriod = Duration(minutes: 3);

  DateTime? _backgroundedAt;

  /// Called when the app is backgrounded (mobile) - starts the grace-period
  /// timer rather than locking immediately; see [handleForeground], which
  /// actually decides whether to lock once the app comes back.
  void noteBackgrounded({DateTime? now}) {
    if (_hasPin && _status == PinGateStatus.unlocked) {
      _backgroundedAt = now ?? DateTime.now();
    }
  }

  /// Called when the app returns to the foreground - locks only if the app
  /// was backgrounded for at least [backgroundGracePeriod]; a return within
  /// the grace period stays unlocked. Resets the timer to "not backgrounded"
  /// either way, per the user's own framing ("réinitialiser à 0 quand
  /// l'appli revient au premier plan") - the *next* backgrounding starts a
  /// fresh grace period rather than accumulating.
  void handleForeground({DateTime? now}) {
    final backgroundedAt = _backgroundedAt;
    _backgroundedAt = null;
    if (backgroundedAt == null) return;
    final elapsed = (now ?? DateTime.now()).difference(backgroundedAt);
    if (_hasPin && _status == PinGateStatus.unlocked && elapsed >= backgroundGracePeriod) {
      _status = PinGateStatus.locked;
      notifyListeners();
    }
  }
}
