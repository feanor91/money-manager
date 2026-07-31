import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:money_manager/data/db_companion_settings.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('db_companion_settings_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('forNativePath writes the companion file next to the given db path,'
      ' not inside it', () async {
    final dbPath = '${tempDir.path}${Platform.pathSeparator}MyMoney.mmb';

    final prefs = await DatabaseCompanionSettings.forNativePath(dbPath);
    await prefs.setString('hello', 'world');

    final companionFile =
        File('${tempDir.path}${Platform.pathSeparator}$companionSettingsFileName');
    expect(companionFile.existsSync(), isTrue);
    // Same filename regardless of the .mmb's own name, so every .mmb in a
    // folder (a "current" one and old copies) shares one settings file.
    expect(companionFile.path, isNot(contains('MyMoney')));
  });

  test('reopening the same db path picks up previously persisted settings',
      () async {
    final dbPath = '${tempDir.path}${Platform.pathSeparator}MyMoney.mmb';

    final first = await DatabaseCompanionSettings.forNativePath(dbPath);
    await first.setString('pinHash', 'abc123');

    final reopened = await DatabaseCompanionSettings.forNativePath(dbPath);
    expect(reopened.getString('pinHash'), 'abc123');
  });

  test('two different .mmb files in different folders get independent'
      ' companion settings', () async {
    final dir1 = Directory('${tempDir.path}${Platform.pathSeparator}db1')
      ..createSync();
    final dir2 = Directory('${tempDir.path}${Platform.pathSeparator}db2')
      ..createSync();

    final prefs1 = await DatabaseCompanionSettings.forNativePath(
        '${dir1.path}${Platform.pathSeparator}MyMoney.mmb');
    await prefs1.setString('pinHash', 'from-db1');

    final prefs2 = await DatabaseCompanionSettings.forNativePath(
        '${dir2.path}${Platform.pathSeparator}MyMoney.mmb');
    expect(prefs2.getString('pinHash'), isNull);
  });
}
