import 'package:intl/intl.dart';

import '../../models/account.dart';
import '../../models/category.dart';
import '../../models/payee.dart';
import 'query_intent.dart';

String _isoDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

/// Builds the parameterized SQL for a [QueryKind.adHoc] intent - mirrors
/// MmexRepository.categorySpendForPeriod/recurringCategorySpendForPeriod's
/// base WHERE/JOIN pattern (voided/soft-deleted exclusion, the
/// APP_TRANSACTION_BILL_LINKS join for recurringOnly), generalized across
/// any metric/transactionType/groupBy combination. Every value the model
/// could have influenced (category/account/payee names, period text) was
/// already resolved to a real id/DateTime by decodeIntentJson before this
/// ever runs - only validated ids/enums reach here, and this only ever
/// emits a SELECT.
///
/// [groupBy]'s column can't be a bound `?` parameter (SQL doesn't allow
/// parameterizing an identifier) - safe regardless, because the only thing
/// ever interpolated into the SQL text is one of 5 hardcoded literals
/// selected by a closed Dart `switch` over the typed [AdHocGroupBy] enum,
/// never a string that passed through the model. Keep it that way: never
/// change this function to accept a raw `String` column name.
({String sql, List<Object?> params}) buildAdHocSql(
  QueryIntent intent, {
  required List<Category> categories,
}) {
  final metric = intent.adHocMetric;
  final transactionType = intent.adHocTransactionType;
  final groupBy = intent.adHocGroupBy;
  if (metric == null || transactionType == null || groupBy == null) {
    throw ArgumentError(
        'QueryKind.adHoc requires adHocMetric/adHocTransactionType/adHocGroupBy - '
        'decodeIntentJson never produces this kind without all three.');
  }

  final where = <String>[
    'c.TRANSDATE >= ?',
    'c.TRANSDATE < ?',
    "UPPER(TRIM(c.STATUS)) != 'V'",
    "(c.DELETEDTIME IS NULL OR c.DELETEDTIME = '')",
  ];
  final params = <Object?>[_isoDate(intent.period.start), _isoDate(intent.period.end)];

  switch (transactionType) {
    case AdHocTransactionType.withdrawal:
      where.add("c.TRANSCODE = 'Withdrawal'");
    case AdHocTransactionType.deposit:
      where.add("c.TRANSCODE = 'Deposit'");
    case AdHocTransactionType.transfer:
      where.add("c.TRANSCODE = 'Transfer'");
    case AdHocTransactionType.any:
      break; // every TRANSCODE, transfers included - no filter added
  }

  if (intent.accountId != null) {
    where.add('c.ACCOUNTID = ?');
    params.add(intent.accountId);
  }
  if (intent.payeeId != null) {
    where.add('c.PAYEEID = ?');
    params.add(intent.payeeId);
  }

  // Roll-up-only-when-filtered (matches rolledUpSpend/transactionsForCategories
  // elsewhere): a specific categoryId scopes to itself + its direct
  // children. Entirely independent of groupBy, which always buckets by the
  // literal CATEGID as stored (see groupColumn below) - filtering and
  // grouping are two orthogonal concerns.
  if (intent.categoryId != null) {
    final ids = [
      intent.categoryId!,
      for (final c in categories)
        if (c.parentId == intent.categoryId) c.id,
    ];
    where.add('c.CATEGID IN (${ids.map((_) => '?').join(',')})');
    params.addAll(ids);
  }

  var from = 'CHECKINGACCOUNT_V1 c';
  if (intent.recurringOnly) {
    from += ' JOIN APP_TRANSACTION_BILL_LINKS l ON l.TRANSID = c.TRANSID';
  }

  final metricSql = switch (metric) {
    AdHocMetric.sum => 'SUM(c.TRANSAMOUNT)',
    AdHocMetric.count => 'COUNT(*)',
    AdHocMetric.average => 'AVG(c.TRANSAMOUNT)',
  };

  final groupColumn = switch (groupBy) {
    AdHocGroupBy.none => null,
    AdHocGroupBy.category => 'c.CATEGID',
    AdHocGroupBy.payee => 'c.PAYEEID',
    AdHocGroupBy.account => 'c.ACCOUNTID',
    AdHocGroupBy.month => "strftime('%Y-%m', c.TRANSDATE)",
  };

  if (groupColumn == null) {
    return (sql: 'SELECT $metricSql AS value FROM $from WHERE ${where.join(' AND ')}', params: params);
  }

  // Drop the null-bucket row (uncategorized transactions) - matches
  // categorySpendForPeriod's existing `if (categId == null) continue;`.
  // PAYEEID/ACCOUNTID are NOT NULL in the schema so this never trims those.
  where.add('$groupColumn IS NOT NULL');
  var sql = 'SELECT $groupColumn AS bucket, $metricSql AS value FROM $from '
      'WHERE ${where.join(' AND ')} GROUP BY $groupColumn';
  if (groupBy == AdHocGroupBy.month) {
    // Chronological, uncapped - a "top N months by amount" isn't a real
    // need and would fight the zero-filled, chronological contract
    // mapAdHocRows guarantees for month buckets. adHocLimit is deliberately
    // ignored here, never applied as a LIMIT for this one groupBy.
    sql += ' ORDER BY bucket ASC';
  } else {
    sql += ' ORDER BY value DESC';
    if (intent.adHocLimit != null) {
      sql += ' LIMIT ?';
      params.add(intent.adHocLimit);
    }
  }
  return (sql: sql, params: params);
}

/// Turns raw rows (as returned by running [buildAdHocSql]'s query) into the
/// final ordered, display-ready result - see QueryAnswer.adHocResult's doc
/// comment for the ordering/labeling contract. For [AdHocGroupBy.month]
/// specifically, zero-fills every calendar month in [intent.period] that
/// had no matching row, same convention as
/// MmexRepository.categorySpendByMonth/[QueryKind.expenseByMonth] -
/// duplicated here (not shared) since this SQL path is entirely separate.
List<MapEntry<String, double>> mapAdHocRows(
  List<Map<String, Object?>> rows,
  QueryIntent intent, {
  required List<Category> categories,
  required List<Account> accounts,
  required List<Payee> payees,
}) {
  final groupBy = intent.adHocGroupBy!;
  if (groupBy == AdHocGroupBy.none) {
    final value = rows.isEmpty ? 0.0 : (rows.first['value'] as num?)?.toDouble() ?? 0.0;
    return [MapEntry('', value)];
  }

  final categoriesById = {for (final c in categories) c.id: c};
  final accountsById = {for (final a in accounts) a.id: a};
  final payeesById = {for (final p in payees) p.id: p};

  if (groupBy == AdHocGroupBy.month) {
    // Constructed here, not unconditionally above - a DateFormat with an
    // explicit locale needs that locale's data initialized
    // (initializeDateFormatting), which every *other* groupBy has no reason
    // to require.
    final monthFormat = DateFormat('MMMM yyyy', 'fr_FR');
    String monthLabel(DateTime month) {
      final label = monthFormat.format(month);
      return label[0].toUpperCase() + label.substring(1);
    }

    final byMonthKey = {
      for (final row in rows)
        row['bucket'] as String: (row['value'] as num?)?.toDouble() ?? 0.0,
    };
    final result = <MapEntry<String, double>>[];
    var cursor = DateTime(intent.period.start.year, intent.period.start.month, 1);
    final stop = intent.period.end;
    while (cursor.isBefore(stop)) {
      final key =
          '${cursor.year.toString().padLeft(4, '0')}-${cursor.month.toString().padLeft(2, '0')}';
      result.add(MapEntry(monthLabel(cursor), byMonthKey[key] ?? 0.0));
      cursor = DateTime(cursor.year, cursor.month + 1, 1);
    }
    return result;
  }

  String labelFor(Object? bucket) => switch (groupBy) {
        AdHocGroupBy.category => categoryFullPath(bucket as int, categoriesById),
        AdHocGroupBy.payee => payeesById[bucket as int]?.name ?? 'Tiers inconnu',
        AdHocGroupBy.account => accountsById[bucket as int]?.name ?? 'Compte inconnu',
        AdHocGroupBy.month || AdHocGroupBy.none => throw StateError('handled above'),
      };

  return [
    for (final row in rows) MapEntry(labelFor(row['bucket']), (row['value'] as num?)?.toDouble() ?? 0.0),
  ];
}
