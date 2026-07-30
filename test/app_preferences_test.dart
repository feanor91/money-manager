import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:money_manager/state/app_preferences.dart';

void main() {
  late Directory tempDir;
  late String path;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('app_preferences_test_');
    path = '${tempDir.path}${Platform.pathSeparator}preferences.dat';
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('round-trips string/int/list values through encryption', () async {
    final prefs = await AppPreferences.forTestingAtPath(path);
    await prefs.setString('name', 'MyMoney.mmb');
    await prefs.setInt('forecastDay', 24);
    await prefs.setStringList('hidden', ['1', '2', '3']);

    // Fresh instance from disk - proves it's actually persisted, not just
    // held in memory on the same object.
    final reloaded = await AppPreferences.forTestingAtPath(path);
    expect(reloaded.getString('name'), 'MyMoney.mmb');
    expect(reloaded.getInt('forecastDay'), 24);
    expect(reloaded.getStringList('hidden'), ['1', '2', '3']);
  });

  test('remove deletes a key and persists the removal', () async {
    final prefs = await AppPreferences.forTestingAtPath(path);
    await prefs.setString('pinHash', 'abc123');
    await prefs.remove('pinHash');

    final reloaded = await AppPreferences.forTestingAtPath(path);
    expect(reloaded.getString('pinHash'), isNull);
  });

  test('the on-disk file is not plain-text JSON', () async {
    final prefs = await AppPreferences.forTestingAtPath(path);
    await prefs.setString('pinHash', 'super-secret-hash-value');

    // latin1 never throws on arbitrary bytes (unlike utf8), which is all
    // that's needed here - just searching encrypted bytes for accidental
    // plain-text leakage, not decoding them meaningfully.
    final raw = latin1.decode(File(path).readAsBytesSync());
    expect(raw.contains('super-secret-hash-value'), isFalse);
    expect(raw.contains('pinHash'), isFalse);
  });

  test('a missing file starts out empty rather than throwing', () async {
    final prefs = await AppPreferences.forTestingAtPath(path);
    expect(prefs.getString('anything'), isNull);
  });

  test('a too-short file is treated as empty instead of crashing', () async {
    File(path).writeAsBytesSync([1, 2, 3, 4, 5]);
    final prefs = await AppPreferences.forTestingAtPath(path);
    expect(prefs.getString('anything'), isNull);
  });

  test('a corrupted-but-long-enough file is treated as empty instead of '
      'crashing', () async {
    // 32 garbage bytes: past the 16-byte IV-length guard, so this
    // actually exercises the AES decrypt call failing (bad padding/data)
    // rather than just the length shortcut.
    File(path).writeAsBytesSync(List.generate(32, (i) => i));
    final prefs = await AppPreferences.forTestingAtPath(path);
    expect(prefs.getString('anything'), isNull);
  });
}
