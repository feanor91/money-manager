import '../models/transaction.dart';
import 'mmex_repository.dart';

/// How serious a finding is - purely informational, distinct display only.
/// Nothing in this file ever changes the database; see [runDatabaseDiagnostics].
enum DiagnosticSeverity { info, warning, error }

extension DiagnosticSeverityLabel on DiagnosticSeverity {
  String get label => switch (this) {
        DiagnosticSeverity.info => 'Information',
        DiagnosticSeverity.warning => 'À vérifier',
        DiagnosticSeverity.error => 'À corriger',
      };
}

/// One broad kind of anomaly, used to group findings on screen.
enum DiagnosticCategory {
  phantomData,
  orphanedReferences,
  malformedCategories,
  recurringIssues,
  duplicateTransactions,
  orphanedTransfers,
}

extension DiagnosticCategoryLabel on DiagnosticCategory {
  String get label => switch (this) {
        DiagnosticCategory.phantomData => 'Données fantômes',
        DiagnosticCategory.orphanedReferences => 'Références orphelines',
        DiagnosticCategory.malformedCategories => 'Catégories mal formées',
        DiagnosticCategory.recurringIssues => 'Opérations récurrentes',
        DiagnosticCategory.duplicateTransactions => 'Doublons probables',
        DiagnosticCategory.orphanedTransfers => 'Virements orphelins',
      };
}

class DiagnosticFinding {
  final DiagnosticSeverity severity;
  final DiagnosticCategory category;

  /// Why this finding exists - kept short when [transactionIds] is
  /// non-empty (the ledger-style row itself already shows date/tiers/
  /// catégorie/montant, this is only the extra reason on top of that).
  final String message;

  /// Real transactions this finding is about, if any - lets the screen
  /// render them exactly like the transactions ledger, tappable to open
  /// the same editor. Empty for findings that aren't about one specific
  /// transaction (a malformed category, a stuck recurring bill...).
  final List<int> transactionIds;

  const DiagnosticFinding({
    required this.severity,
    required this.category,
    required this.message,
    this.transactionIds = const [],
  });
}

/// Runs every read-only integrity check against [repo] and returns every
/// finding. This never writes to the database - it's a report, not a
/// repair tool; fixing any of these (including the ones shown as editable
/// transaction rows) is a separate, deliberate action the user takes
/// themselves (this codebase has already been bitten once by a silent-
/// data-loss bug, see CLAUDE.md - an auto-fixing diagnostic tool is
/// exactly the kind of thing that could make that worse if it guessed wrong).
List<DiagnosticFinding> runDatabaseDiagnostics(MmexRepository repo) {
  return [
    ..._checkPhantomData(repo),
    ..._checkOrphanedReferences(repo),
    ..._checkMalformedCategories(repo),
    ..._checkRecurringIssues(repo),
    ..._checkDuplicateTransactions(repo),
    ..._checkOrphanedTransfers(repo),
  ];
}

/// Fetches every real (non-deleted) transaction referenced by [findings],
/// keyed by id - the screen uses this to render each flagged transaction
/// as a real ledger-style row instead of just a text description.
Map<int, MoneyTransaction> loadTransactionsForFindings(
    MmexRepository repo, List<DiagnosticFinding> findings) {
  final ids = {for (final f in findings) ...f.transactionIds};
  if (ids.isEmpty) return {};
  final rows = repo.db.query(
    'SELECT * FROM CHECKINGACCOUNT_V1 WHERE TRANSID IN (${ids.map((_) => '?').join(',')})',
    ids.toList(),
  );
  return {for (final row in rows) row['TRANSID'] as int: MoneyTransaction.fromRow(row)};
}

List<DiagnosticFinding> _checkPhantomData(MmexRepository repo) {
  final findings = <DiagnosticFinding>[];
  final db = repo.db;

  // MMEX's own soft-delete: a non-empty DELETEDTIME marks a transaction as
  // gone, but the row itself is never actually removed. Not a problem by
  // itself (every read path in this app already filters it out - see
  // MmexRepository), but a transaction-bill link left pointing at one is
  // dead bookkeeping worth knowing about. Left as plain text (no
  // transactionIds) since the transaction itself is deleted - there's
  // nothing to open in the editor.
  final orphanedLinksCount = db.query('''
    SELECT COUNT(*) AS n FROM APP_TRANSACTION_BILL_LINKS l
    JOIN CHECKINGACCOUNT_V1 t ON t.TRANSID = l.TRANSID
    WHERE t.DELETEDTIME IS NOT NULL AND t.DELETEDTIME != ''
  ''').first['n'] as int;
  if (orphanedLinksCount > 0) {
    findings.add(DiagnosticFinding(
      severity: DiagnosticSeverity.info,
      category: DiagnosticCategory.phantomData,
      message: '$orphanedLinksCount transaction(s) supprimée(s) gardent un lien vers '
          'une opération récurrente - sans conséquence, juste des identifiants oubliés.',
    ));
  }

  // A status this app's own code doesn't recognise ('' none, 'R'
  // reconciled, 'V' void are the only ones handled - see
  // MoneyTransaction.isReconciled/isVoid) silently falls through as if the
  // transaction were neither reconciled nor void, which can quietly skew
  // spend/forecast totals.
  final unknownStatus = db.query('''
    SELECT TRANSID, STATUS FROM CHECKINGACCOUNT_V1
    WHERE (DELETEDTIME IS NULL OR DELETEDTIME = '')
      AND STATUS IS NOT NULL AND STATUS NOT IN ('', 'R', 'V')
  ''');
  for (final row in unknownStatus) {
    findings.add(DiagnosticFinding(
      severity: DiagnosticSeverity.warning,
      category: DiagnosticCategory.phantomData,
      message: 'Statut non reconnu ("${row['STATUS']}") - traitée comme normale par l\'appli.',
      transactionIds: [row['TRANSID'] as int],
    ));
  }

  return findings;
}

List<DiagnosticFinding> _checkOrphanedReferences(MmexRepository repo) {
  final findings = <DiagnosticFinding>[];
  final db = repo.db;

  final orphanCategId = db.query('''
    SELECT TRANSID FROM CHECKINGACCOUNT_V1
    WHERE (DELETEDTIME IS NULL OR DELETEDTIME = '') AND CATEGID IS NOT NULL
      AND CATEGID NOT IN (SELECT CATEGID FROM CATEGORY_V1)
  ''');
  for (final row in orphanCategId) {
    findings.add(DiagnosticFinding(
      severity: DiagnosticSeverity.error,
      category: DiagnosticCategory.orphanedReferences,
      message: 'Catégorie introuvable - supprimée définitivement depuis.',
      transactionIds: [row['TRANSID'] as int],
    ));
  }

  // -1 is MMEX's own "no payee" sentinel (transfers and a few other
  // cases legitimately have no tiers) - not a deleted reference.
  final orphanPayeeId = db.query('''
    SELECT TRANSID FROM CHECKINGACCOUNT_V1
    WHERE (DELETEDTIME IS NULL OR DELETEDTIME = '') AND PAYEEID != -1
      AND PAYEEID NOT IN (SELECT PAYEEID FROM PAYEE_V1)
  ''');
  for (final row in orphanPayeeId) {
    findings.add(DiagnosticFinding(
      severity: DiagnosticSeverity.error,
      category: DiagnosticCategory.orphanedReferences,
      message: 'Tiers ("payé") supprimé définitivement depuis.',
      transactionIds: [row['TRANSID'] as int],
    ));
  }

  final orphanAccountId = db.query('''
    SELECT TRANSID FROM CHECKINGACCOUNT_V1
    WHERE (DELETEDTIME IS NULL OR DELETEDTIME = '')
      AND ACCOUNTID NOT IN (SELECT ACCOUNTID FROM ACCOUNTLIST_V1)
  ''');
  for (final row in orphanAccountId) {
    findings.add(DiagnosticFinding(
      severity: DiagnosticSeverity.error,
      category: DiagnosticCategory.orphanedReferences,
      message: 'Compte introuvable - supprimé définitivement depuis.',
      transactionIds: [row['TRANSID'] as int],
    ));
  }

  // Bill/envelope orphans aren't real transactions (a recurring template
  // and a budget envelope are both their own kind of record), so they stay
  // as plain text - nothing to open in the transaction editor for these.
  // Same -1 "no payee" sentinel as CHECKINGACCOUNT_V1 - see above.
  final orphanBillRefs = db.query('''
    SELECT BDID, TRANSDATE, TRANSAMOUNT,
      (CATEGID IS NOT NULL AND CATEGID NOT IN (SELECT CATEGID FROM CATEGORY_V1)) AS badCateg,
      (PAYEEID != -1 AND PAYEEID NOT IN (SELECT PAYEEID FROM PAYEE_V1)) AS badPayee,
      (ACCOUNTID NOT IN (SELECT ACCOUNTID FROM ACCOUNTLIST_V1)) AS badAccount
    FROM BILLSDEPOSITS_V1
    WHERE (CATEGID IS NOT NULL AND CATEGID NOT IN (SELECT CATEGID FROM CATEGORY_V1))
       OR (PAYEEID != -1 AND PAYEEID NOT IN (SELECT PAYEEID FROM PAYEE_V1))
       OR (ACCOUNTID NOT IN (SELECT ACCOUNTID FROM ACCOUNTLIST_V1))
  ''');
  for (final row in orphanBillRefs) {
    final what = [
      if (row['badCateg'] == 1) 'sa catégorie',
      if (row['badPayee'] == 1) 'son tiers',
      if (row['badAccount'] == 1) 'son compte',
    ].join(', ');
    findings.add(DiagnosticFinding(
      severity: DiagnosticSeverity.error,
      category: DiagnosticCategory.orphanedReferences,
      message: 'L\'opération récurrente du ${row['TRANSDATE']} '
          '(${row['TRANSAMOUNT']}) a $what qui n\'existe plus.',
    ));
  }

  final orphanEnvelopes = db.query('''
    SELECT AMOUNT FROM APP_BUDGET_ENVELOPES
    WHERE (CATEGID NOT IN (SELECT CATEGID FROM CATEGORY_V1))
       OR (ACCOUNTID NOT IN (SELECT ACCOUNTID FROM ACCOUNTLIST_V1))
  ''');
  for (final row in orphanEnvelopes) {
    findings.add(DiagnosticFinding(
      severity: DiagnosticSeverity.warning,
      category: DiagnosticCategory.orphanedReferences,
      message: 'Une enveloppe de budget (${row['AMOUNT']}) pointe vers une '
          'catégorie ou un compte qui n\'existe plus - déjà ignorée par l\'écran Budget.',
    ));
  }

  final orphanLinkCount = (db.query('''
    SELECT COUNT(*) AS n FROM APP_TRANSACTION_BILL_LINKS
    WHERE BILLID NOT IN (SELECT BDID FROM BILLSDEPOSITS_V1)
  ''').first['n'] as int);
  if (orphanLinkCount > 0) {
    findings.add(DiagnosticFinding(
      severity: DiagnosticSeverity.info,
      category: DiagnosticCategory.orphanedReferences,
      message: '$orphanLinkCount transaction(s) gardent un badge "généré depuis une '
          'récurrence" dont le modèle a depuis été supprimé - sans conséquence, '
          'c\'est un historique normal.',
    ));
  }

  return findings;
}

List<DiagnosticFinding> _checkMalformedCategories(MmexRepository repo) {
  final findings = <DiagnosticFinding>[];
  final db = repo.db;

  final danglingParent = db.query('''
    SELECT CATEGID, CATEGNAME FROM CATEGORY_V1
    WHERE PARENTID IS NOT NULL AND PARENTID != -1
      AND PARENTID NOT IN (SELECT CATEGID FROM CATEGORY_V1)
  ''');
  for (final row in danglingParent) {
    findings.add(DiagnosticFinding(
      severity: DiagnosticSeverity.error,
      category: DiagnosticCategory.malformedCategories,
      message: 'La catégorie "${row['CATEGNAME']}" a une catégorie mère qui n\'existe plus.',
    ));
  }

  final selfParent = db.query('''
    SELECT CATEGID, CATEGNAME FROM CATEGORY_V1 WHERE PARENTID = CATEGID
  ''');
  for (final row in selfParent) {
    findings.add(DiagnosticFinding(
      severity: DiagnosticSeverity.error,
      category: DiagnosticCategory.malformedCategories,
      message: 'La catégorie "${row['CATEGNAME']}" est sa propre catégorie mère.',
    ));
  }

  // MMEX only supports one level of nesting - a category whose parent is
  // itself a subcategory breaks that assumption (rolledUpSpend and the
  // budget screen's grouping both only look one level up/down).
  final tooDeep = db.query('''
    SELECT c.CATEGID, c.CATEGNAME, p.CATEGNAME AS parentName
    FROM CATEGORY_V1 c
    JOIN CATEGORY_V1 p ON p.CATEGID = c.PARENTID
    WHERE c.PARENTID != -1 AND p.PARENTID != -1
  ''');
  for (final row in tooDeep) {
    findings.add(DiagnosticFinding(
      severity: DiagnosticSeverity.warning,
      category: DiagnosticCategory.malformedCategories,
      message: 'La catégorie "${row['CATEGNAME']}" est sous "${row['parentName']}", '
          'elle-même une sous-catégorie - l\'appli ne gère qu\'un seul niveau, '
          'celle-ci n\'apparaîtra pas correctement dans le budget.',
    ));
  }

  return findings;
}

List<DiagnosticFinding> _checkRecurringIssues(MmexRepository repo) {
  final findings = <DiagnosticFinding>[];
  final db = repo.db;

  final pausedIds = repo.getPausedBillIds();
  if (pausedIds.isNotEmpty) {
    final existing = db
        .query('SELECT BDID FROM BILLSDEPOSITS_V1')
        .map((r) => r['BDID'] as int)
        .toSet();
    final staleIds = pausedIds.difference(existing);
    if (staleIds.isNotEmpty) {
      findings.add(DiagnosticFinding(
        severity: DiagnosticSeverity.info,
        category: DiagnosticCategory.recurringIssues,
        message: '${staleIds.length} opération(s) récurrente(s) marquée(s) en '
            'pause ont depuis été supprimées - sans effet, juste des identifiants oubliés.',
      ));
    }
  }

  // NUMOCCURRENCES counts down for a limited-duration bill (see
  // lib/models/recurrence.dart) - reaching exactly 0 should have deleted
  // the model on its last run, so one still present means it got stuck.
  // Skipped for the 4 "X"-parameterised periods, where this same column
  // means something else entirely (the day/month interval, not a count).
  final exhausted = db.query('''
    SELECT BDID, TRANSDATE, TRANSAMOUNT, REPEATS
    FROM BILLSDEPOSITS_V1
    WHERE NUMOCCURRENCES = 0 AND (REPEATS % 100) NOT IN (11, 12, 13, 14)
  ''');
  for (final row in exhausted) {
    findings.add(DiagnosticFinding(
      severity: DiagnosticSeverity.warning,
      category: DiagnosticCategory.recurringIssues,
      message: 'L\'opération récurrente du ${row['TRANSDATE']} '
          '(${row['TRANSAMOUNT']}) n\'a plus d\'occurrence restante mais existe '
          'toujours - à vérifier dans l\'écran Récurrentes.',
    ));
  }

  return findings;
}

List<DiagnosticFinding> _checkDuplicateTransactions(MmexRepository repo) {
  final findings = <DiagnosticFinding>[];
  final db = repo.db;

  // Same account, date, amount and payee more than once - a common import
  // artifact, but also a perfectly normal coincidence (two identical
  // coffees on the same day), hence "probable" rather than a hard error:
  // this is a nudge to go look, not a claim something is actually wrong.
  final duplicates = db.query('''
    SELECT GROUP_CONCAT(TRANSID) AS ids, COUNT(*) AS n
    FROM CHECKINGACCOUNT_V1
    WHERE (DELETEDTIME IS NULL OR DELETEDTIME = '') AND STATUS != 'V'
    GROUP BY ACCOUNTID, TRANSDATE, TRANSAMOUNT, PAYEEID
    HAVING COUNT(*) > 1
  ''');
  for (final row in duplicates) {
    final ids = (row['ids'] as String).split(',').map(int.parse).toList();
    findings.add(DiagnosticFinding(
      severity: DiagnosticSeverity.warning,
      category: DiagnosticCategory.duplicateTransactions,
      message: '${row['n']} transactions identiques (même compte, date, montant et tiers).',
      transactionIds: ids,
    ));
  }

  return findings;
}

List<DiagnosticFinding> _checkOrphanedTransfers(MmexRepository repo) {
  final findings = <DiagnosticFinding>[];
  final db = repo.db;

  final missingDestination = db.query('''
    SELECT TRANSID FROM CHECKINGACCOUNT_V1
    WHERE (DELETEDTIME IS NULL OR DELETEDTIME = '')
      AND TRANSCODE = 'Transfer' AND (TOACCOUNTID IS NULL)
  ''');
  for (final row in missingDestination) {
    findings.add(DiagnosticFinding(
      severity: DiagnosticSeverity.error,
      category: DiagnosticCategory.orphanedTransfers,
      message: 'Virement sans compte de destination.',
      transactionIds: [row['TRANSID'] as int],
    ));
  }

  final badDestination = db.query('''
    SELECT TRANSID FROM CHECKINGACCOUNT_V1
    WHERE (DELETEDTIME IS NULL OR DELETEDTIME = '')
      AND TRANSCODE = 'Transfer' AND TOACCOUNTID IS NOT NULL
      AND TOACCOUNTID NOT IN (SELECT ACCOUNTID FROM ACCOUNTLIST_V1)
  ''');
  for (final row in badDestination) {
    findings.add(DiagnosticFinding(
      severity: DiagnosticSeverity.error,
      category: DiagnosticCategory.orphanedTransfers,
      message: 'Compte de destination du virement introuvable - supprimé définitivement depuis.',
      transactionIds: [row['TRANSID'] as int],
    ));
  }

  final unexpectedDestination = db.query('''
    SELECT TRANSID FROM CHECKINGACCOUNT_V1
    WHERE (DELETEDTIME IS NULL OR DELETEDTIME = '')
      AND TRANSCODE != 'Transfer' AND TOACCOUNTID IS NOT NULL
  ''');
  for (final row in unexpectedDestination) {
    findings.add(DiagnosticFinding(
      severity: DiagnosticSeverity.warning,
      category: DiagnosticCategory.orphanedTransfers,
      message: 'A un compte de destination alors que ce n\'est pas un virement.',
      transactionIds: [row['TRANSID'] as int],
    ));
  }

  return findings;
}
