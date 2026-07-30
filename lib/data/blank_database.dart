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
  db.transaction(() {
    for (final statement in sql.split(';')) {
      final trimmed = statement.trim();
      if (trimmed.isEmpty || trimmed.startsWith('--')) continue;
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
