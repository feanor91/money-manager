import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_manager/data/db_backup.dart';
import 'package:money_manager/data/db_backup_io.dart' as db_backup_io;

void main() {
  group('backupFileName / backupTimestamp round-trip', () {
    test('a name produced by backupFileName is parsed back to the same '
        'moment (to the second)', () {
      final name = backupFileName(r'C:\Comptes\MesComptes.mmb');
      final now = DateTime.now();
      final parsed = backupTimestamp(name)!;

      expect(parsed.year, now.year);
      expect(parsed.month, now.month);
      expect(parsed.day, now.day);
      expect(parsed.hour, now.hour);
      expect(parsed.minute, now.minute);
    });

    test('the base name (with its own underscores) survives untouched', () {
      final name = backupFileName(r'C:\Comptes\Mes_Comptes.mmb');
      expect(name, startsWith('Mes_Comptes_'));
    });
  });

  group('backupTimestamp', () {
    test('parses a well-formed backup filename', () {
      expect(backupTimestamp('MesComptes_2026-07-25_14-32-05.mmb'),
          DateTime(2026, 7, 25, 14, 32, 5));
    });

    test('is null for a file that was never one of our own backups - never '
        'guesses about a file dropped in the folder by hand', () {
      expect(backupTimestamp('MesComptes.mmb'), isNull);
      expect(backupTimestamp('notes.txt'), isNull);
      expect(backupTimestamp('MesComptes_backup.mmb'), isNull);
    });

    test('is case-insensitive on the .mmb extension', () {
      expect(backupTimestamp('MesComptes_2026-07-25_14-32-05.MMB'),
          DateTime(2026, 7, 25, 14, 32, 5));
    });
  });

  group('backupFileNamesToDelete ("4 semaines glissantes", 2026-09-05)', () {
    final now = DateTime(2026, 9, 5, 12, 0, 0);

    test('keeps everything inside the retention window, deletes nothing '
        'when all backups are recent', () {
      final names = [
        'MesComptes_2026-09-05_08-00-00.mmb',
        'MesComptes_2026-09-01_08-00-00.mmb',
      ];
      expect(
          backupFileNamesToDelete(names, retentionWeeks: 4, now: now),
          isEmpty);
    });

    test('deletes exactly the backups older than the retention window, '
        'keeps the ones inside it', () {
      final names = [
        'MesComptes_2026-09-05_08-00-00.mmb', // today - kept
        'MesComptes_2026-08-10_08-00-00.mmb', // ~26 days ago - kept (< 4 weeks)
        'MesComptes_2026-08-01_08-00-00.mmb', // ~35 days ago - deleted (> 4 weeks)
        'MesComptes_2025-01-01_08-00-00.mmb', // ancient - deleted
      ];
      final deleted =
          backupFileNamesToDelete(names, retentionWeeks: 4, now: now);
      expect(deleted, [
        'MesComptes_2026-08-01_08-00-00.mmb',
        'MesComptes_2025-01-01_08-00-00.mmb',
      ]);
    });

    test('never flags a file it can\'t parse as a backup of ours', () {
      final names = ['MesComptes.old', 'notes.txt', 'MesComptes_ancien.mmb'];
      expect(
          backupFileNamesToDelete(names, retentionWeeks: 1, now: now),
          isEmpty);
    });

    test('retentionWeeks: 1 keeps only the last 7 days', () {
      final names = [
        'MesComptes_2026-09-04_08-00-00.mmb', // 1 day ago - kept
        'MesComptes_2026-08-25_08-00-00.mmb', // 11 days ago - deleted
      ];
      expect(
        backupFileNamesToDelete(names, retentionWeeks: 1, now: now),
        ['MesComptes_2026-08-25_08-00-00.mmb'],
      );
    });
  });

  group('DbBackup.save (native) - real filesystem pruning', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('db_backup_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('writes a fresh backup file into a sibling "backup" folder', () async {
      final label = '${tempDir.path}/MesComptes.mmb';
      await db_backup_io.save(
          label: label, bytes: [1, 2, 3], retentionWeeks: 4);

      final backupDir = Directory('${tempDir.path}/backup');
      final files = backupDir.listSync().whereType<File>().toList();
      expect(files, hasLength(1));
      expect(files.single.readAsBytesSync(), [1, 2, 3]);
    });

    test('deletes only backups older than retentionWeeks, keeps recent ones',
        () async {
      final label = '${tempDir.path}/MesComptes.mmb';
      final backupDir = Directory('${tempDir.path}/backup')
        ..createSync(recursive: true);

      String stampFor(DateTime d) {
        String pad(int n) => n.toString().padLeft(2, '0');
        return '${d.year}-${pad(d.month)}-${pad(d.day)}_'
            '${pad(d.hour)}-${pad(d.minute)}-${pad(d.second)}';
      }

      final now = DateTime.now();
      final oldDate = now.subtract(const Duration(days: 40)); // > 4 weeks
      final recentDate = now.subtract(const Duration(days: 5)); // < 4 weeks

      final old =
          File('${backupDir.path}/MesComptes_${stampFor(oldDate)}.mmb')
            ..writeAsBytesSync([9]);
      final recent =
          File('${backupDir.path}/MesComptes_${stampFor(recentDate)}.mmb')
            ..writeAsBytesSync([8]);
      // A file that was never one of ours - must survive regardless of age.
      final foreign = File('${backupDir.path}/notes.txt')
        ..writeAsBytesSync([7]);

      await db_backup_io.save(
          label: label, bytes: [1, 2, 3], retentionWeeks: 4);

      expect(old.existsSync(), isFalse);
      expect(recent.existsSync(), isTrue);
      expect(foreign.existsSync(), isTrue);
    });
  });
}
