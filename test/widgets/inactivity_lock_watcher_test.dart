import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:money_manager/state/app_preferences.dart';
import 'package:money_manager/state/pin_lock_provider.dart';
import 'package:money_manager/widgets/inactivity_lock_watcher.dart';

/// Same minimal in-memory stand-in pin_lock_provider_test.dart uses.
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
  late PinLockProvider provider;

  setUp(() async {
    provider = PinLockProvider();
    provider.attachDatabase(
        databaseReady: true, companionPrefs: _FakeCompanionPrefs());
    await provider.setPin('1234');
    await provider.setAutoLockMinutes(PinLockProvider.minAutoLockMinutes);
    // A fresh setPin() call leaves the session unlocked (only the *next*
    // attach locks it - see pin_lock_provider_test.dart), matching the
    // real "just configured a PIN, still in Settings" state this watcher
    // is meant to run under.
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<PinLockProvider>.value(
        value: provider,
        child: MaterialApp(
          navigatorObservers: [dialogActivityObserver],
          home: Scaffold(
            body: InactivityLockWatcher(
              child: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      content: const Text('dialog'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('close'),
                        ),
                      ],
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('locks after autoLockDuration with no activity at all',
      (tester) async {
    await pumpApp(tester);
    expect(provider.isUnlocked, isTrue);

    await tester.pump(provider.autoLockDuration + const Duration(seconds: 1));

    expect(provider.isUnlocked, isFalse);
  });

  testWidgets(
      'pauses while a dialog is open - 2026-09 user report: reading a '
      'long AI answer with no pointer/keyboard activity used to lock in '
      'the background, so closing the dialog immediately hit the PIN '
      'screen', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('dialog'), findsOneWidget);

    // Well past autoLockDuration, entirely while the dialog stays open.
    await tester.pump(provider.autoLockDuration * 3);
    expect(provider.isUnlocked, isTrue, reason: 'paused while the dialog is open');

    // Closing it resumes the countdown from zero, not from where it left
    // off - immediately past the same duration must NOT lock yet.
    await tester.tap(find.text('close'));
    await tester.pumpAndSettle();
    await tester.pump(provider.autoLockDuration - const Duration(seconds: 1));
    expect(provider.isUnlocked, isTrue, reason: 'countdown restarted on close, not resumed');

    // ...but the full duration after closing does lock.
    await tester.pump(const Duration(seconds: 2));
    expect(provider.isUnlocked, isFalse);
  });
}
