import 'package:flutter_test/flutter_test.dart';

import 'package:money_manager/state/app_preferences.dart';
import 'package:money_manager/state/pin_lock_provider.dart';

/// Minimal in-memory stand-in for a database's companion settings file -
/// PinLockProvider doesn't know or care which concrete AppPreferences it's
/// given (that's the whole point of the interface), so tests don't need
/// real file I/O to exercise its own attempt-counting/lockout logic. The
/// encrypted-file backend itself (shared by both the portable-desktop
/// preferences file and the database companion file) is covered separately
/// by app_preferences_test.dart's round-trip tests.
class _FakeCompanionPrefs implements AppPreferences {
  final Map<String, Object?> _data = {};

  @override
  String? getString(String key) => _data[key] as String?;
  @override
  Future<bool> setString(String key, String value) async {
    _data[key] = value;
    return true;
  }

  @override
  int? getInt(String key) => _data[key] as int?;
  @override
  Future<bool> setInt(String key, int value) async {
    _data[key] = value;
    return true;
  }

  @override
  List<String>? getStringList(String key) {
    final v = _data[key];
    return v is List ? v.cast<String>() : null;
  }

  @override
  Future<bool> setStringList(String key, List<String> value) async {
    _data[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    _data.remove(key);
    return true;
  }
}

void main() {
  group('attachDatabase gate status', () {
    test('no database open is PinGateStatus.none, not locked', () {
      final provider = PinLockProvider();
      provider.attachDatabase(databaseReady: false, companionPrefs: null);
      expect(provider.status, PinGateStatus.none);
      expect(provider.isUnlocked, isFalse);
    });

    test(
        'database open but companion unreachable is needsCompanionAccess - '
        'fails closed rather than guessing', () {
      final provider = PinLockProvider();
      provider.attachDatabase(
        databaseReady: true,
        companionPrefs: null,
        companionUnreachable: true,
      );
      expect(provider.status, PinGateStatus.needsCompanionAccess);
    });

    test(
        'database open with no companion mechanism at all (web without File '
        'System Access support) proceeds unlocked - nothing to protect and '
        'nothing recoverable', () {
      final provider = PinLockProvider();
      provider.attachDatabase(
        databaseReady: true,
        companionPrefs: null,
        companionUnreachable: false,
      );
      expect(provider.status, PinGateStatus.unlocked);
    });

    test('a database with no PIN configured is immediately unlocked', () {
      final provider = PinLockProvider();
      provider.attachDatabase(
          databaseReady: true, companionPrefs: _FakeCompanionPrefs());
      expect(provider.status, PinGateStatus.unlocked);
      expect(provider.hasPin, isFalse);
    });
  });

  test('setting a PIN locks the *next* attach, not the current session', () async {
    final prefs = _FakeCompanionPrefs();
    final provider = PinLockProvider();
    provider.attachDatabase(databaseReady: true, companionPrefs: prefs);
    await provider.setPin('1234');
    expect(provider.status, PinGateStatus.unlocked); // just set it, still in session

    // Re-attaching (simulating reopening this same database) must require
    // the PIN again rather than remembering "unlocked" from before.
    final reattached = PinLockProvider();
    reattached.attachDatabase(databaseReady: true, companionPrefs: prefs);
    expect(reattached.status, PinGateStatus.locked);
    expect((await reattached.verify('1234')).ok, isTrue);
    expect(reattached.status, PinGateStatus.unlocked);
  });

  test(
      'locks out after maxAttempts wrong codes, and the lockout survives a '
      'fresh provider instance attached to the same companion prefs '
      '(simulating an app restart, or reopening from another device)',
      () async {
    final prefs = _FakeCompanionPrefs();
    final provider = PinLockProvider();
    provider.attachDatabase(databaseReady: true, companionPrefs: prefs);
    await provider.setPin('1234');

    for (var i = 0; i < PinLockProvider.defaultMaxAttempts - 1; i++) {
      final result = await provider.verify('0000');
      expect(result.ok, isFalse);
      expect(result.lockoutRemaining, isNull);
    }
    final tripped = await provider.verify('0000');
    expect(tripped.ok, isFalse);
    expect(tripped.lockoutRemaining, isNotNull);
    expect(tripped.lockoutRemaining! > Duration.zero, isTrue);

    // Even the correct PIN is refused while locked out.
    final duringLockout = await provider.verify('1234');
    expect(duringLockout.ok, isFalse);
    expect(duringLockout.lockoutRemaining, isNotNull);

    // Same companion prefs, brand new provider instance.
    final freshProvider = PinLockProvider();
    freshProvider.attachDatabase(databaseReady: true, companionPrefs: prefs);
    final afterRestart = await freshProvider.verify('1234');
    expect(afterRestart.ok, isFalse);
    expect(afterRestart.lockoutRemaining, isNotNull);
  });

  test('a correct PIN before the limit resets the failed-attempt counter',
      () async {
    final prefs = _FakeCompanionPrefs();
    final provider = PinLockProvider();
    provider.attachDatabase(databaseReady: true, companionPrefs: prefs);
    await provider.setPin('4321');

    await provider.verify('0000');
    await provider.verify('0000');
    expect((await provider.verify('4321')).ok, isTrue);

    final result = await provider.verify('0000');
    expect(result.lockoutRemaining, isNull);
    expect(result.attemptsRemaining, PinLockProvider.defaultMaxAttempts - 1);
  });

  test('removing the PIN also clears any pending lockout state', () async {
    final prefs = _FakeCompanionPrefs();
    final provider = PinLockProvider();
    provider.attachDatabase(databaseReady: true, companionPrefs: prefs);
    await provider.setPin('1234');
    for (var i = 0; i < PinLockProvider.defaultMaxAttempts; i++) {
      await provider.verify('0000');
    }
    await provider.removePin();

    expect((await provider.verify('anything')).ok, isTrue);
  });

  test('switching to a different database does not carry over PIN state',
      () async {
    final prefsA = _FakeCompanionPrefs();
    final provider = PinLockProvider();
    provider.attachDatabase(databaseReady: true, companionPrefs: prefsA);
    await provider.setPin('1234');
    expect(provider.hasPin, isTrue);

    // A different database's companion file has never had a PIN set.
    final prefsB = _FakeCompanionPrefs();
    provider.attachDatabase(databaseReady: true, companionPrefs: prefsB);
    expect(provider.hasPin, isFalse);
    expect(provider.status, PinGateStatus.unlocked);
  });

  test('setMaxAttempts/setLockoutMinutes clamp to their valid range',
      () async {
    final prefs = _FakeCompanionPrefs();
    final provider = PinLockProvider();
    provider.attachDatabase(databaseReady: true, companionPrefs: prefs);

    await provider.setMaxAttempts(999);
    expect(provider.maxAttempts, PinLockProvider.maxAttemptsAllowed);
    await provider.setMaxAttempts(1);
    expect(provider.maxAttempts, PinLockProvider.minAttempts);

    await provider.setLockoutMinutes(0);
    expect(provider.lockoutMinutes, PinLockProvider.minLockoutMinutes);
    await provider.setLockoutMinutes(9999);
    expect(provider.lockoutMinutes, PinLockProvider.maxLockoutMinutes);
  });
}
