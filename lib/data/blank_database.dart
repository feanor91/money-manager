import 'package:flutter/services.dart' show rootBundle;

import 'mmex_database.dart';

/// Default base currency for a freshly created database - EUR (CURRENCYID
/// 2 in the bundled schema), matching this app's only user. Real MMEX
/// desktop doesn't auto-pick one at all (it forces a wizard), but a
/// headless "create new database" flow needs *something* so
/// [MmexRepository.getBaseCurrency] resolves immediately.
const defaultBaseCurrencyId = 2;

/// Turns a brand-new, completely empty SQLite file (as freshly opened by
/// `MmexDatabase.openFromPath` on a path that didn't exist yet) into a
/// real, minimal-but-functional MMEX database - same tables, indices, and
/// default category/currency seed rows a real upstream MMEX "New Database"
/// would produce (see assets/mmex_blank_schema.sql, adapted from upstream's
/// own src/table/tables_en.sql), so the file this creates is genuinely
/// openable by the real desktop app too, not just this one.
Future<void> initializeBlankSchema(
  MmexDatabase db, {
  int baseCurrencyId = defaultBaseCurrencyId,
}) async {
  final sql = await rootBundle.loadString('assets/mmex_blank_schema.sql');
  // Strip comment *lines* before splitting on ';', not after: the file's
  // leading comment block (see its own header) has no semicolon of its
  // own, so splitting first left it glued to CREATE TABLE ACCOUNTLIST_V1's
  // full statement text as one combined fragment - which, starting with
  // "--", then got silently skipped whole, table and all. Confirmed
  // 2026-07-31 this meant "Créer une nouvelle base" never actually created
  // ACCOUNTLIST_V1 at all (every table/index depending on it then failed
  // too, aborting the whole transaction with nothing committed).
  final withoutComments =
      sql.split('\n').where((line) => !line.trim().startsWith('--')).join('\n');
  db.transaction(() {
    for (final statement in withoutComments.split(';')) {
      final trimmed = statement.trim();
      if (trimmed.isEmpty) continue;
      db.execute(trimmed);
    }
    final today = DateTime.now();
    final iso = '${today.year.toString().padLeft(4, '0')}-'
        '${today.month.toString().padLeft(2, '0')}-'
        '${today.day.toString().padLeft(2, '0')}';
    db.execute(
      "INSERT INTO INFOTABLE_V1 (INFONAME, INFOVALUE) VALUES ('MMEXVERSION', '1.0')",
    );
    db.execute(
      "INSERT INTO INFOTABLE_V1 (INFONAME, INFOVALUE) VALUES ('CREATEDATE', ?)",
      [iso],
    );
    db.execute(
      "INSERT INTO INFOTABLE_V1 (INFONAME, INFOVALUE) VALUES ('DATEFORMAT', '%Y-%m-%d')",
    );
    db.execute(
      "INSERT INTO INFOTABLE_V1 (INFONAME, INFOVALUE) VALUES ('BASECURRENCYID', ?)",
      ['$baseCurrencyId'],
    );
    db.execute('PRAGMA user_version = 21');
  });
}
