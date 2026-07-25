// Standalone smoke test (run via `dart run tool/smoke_test.dart <path-to-mmb>`)
// exercising the repository layer against a real MMEX file, independent of
// any Flutter UI. Opens a throwaway copy so the original file is untouched.
import 'dart:io';

import 'package:money_manager/data/mmex_database_io.dart' as io_db;
import 'package:money_manager/data/mmex_repository.dart';

Future<void> main(List<String> args) async {
  final sourcePath = args.isNotEmpty
      ? args[0]
      : r'C:\Users\bteuile\Nextcloud\Repos\MoneyManager\Bdd\MyMoney.mmb';

  final tempDir = Directory.systemTemp.createTempSync('mm_smoke_');
  final copy = File('${tempDir.path}/copy.mmb');
  await copy.writeAsBytes(await File(sourcePath).readAsBytes());

  final db = await io_db.openFromPath(copy.path);
  final repo = MmexRepository(db);

  final currency = repo.getBaseCurrency();
  print('Devise de base: ${currency?.name} (${currency?.prefixSymbol}${currency?.suffixSymbol})');

  final accounts = repo.getAccounts(onlyOpen: true);
  print('\nComptes ouverts: ${accounts.length}');
  var total = 0.0;
  for (final a in accounts) {
    final balance = repo.accountBalance(a.id);
    total += balance;
    print('  - ${a.name} (${a.type}): ${currency?.format(balance) ?? balance}');
  }
  print('Solde total: ${currency?.format(total) ?? total}');

  // Regression check: the running-balance ledger's most recent row must
  // match accountBalance() exactly (same math, computed two different ways).
  print('\nVerification solde courant (ledger) vs accountBalance():');
  for (final a in accounts) {
    final ledger = repo.getTransactionsWithRunningBalance(a.id);
    final expected = repo.accountBalance(a.id);
    final actual = ledger.isEmpty ? a.initialBalance : ledger.first.balanceAfter;
    final match = (actual - expected).abs() < 0.005;
    print('  - ${a.name}: ledger=${currency?.format(actual) ?? actual} '
        'accountBalance=${currency?.format(expected) ?? expected} => ${match ? 'OK' : 'MISMATCH'}');
    if (ledger.isNotEmpty) {
      final top = ledger.first;
      print('    derniere ligne: ${top.transaction.date.toIso8601String().substring(0, 10)} '
          'solde=${currency?.format(top.balanceAfter) ?? top.balanceAfter}');
    }
  }

  final now = DateTime.now();
  final spend = repo.categorySpendForMonth(now);
  final categories = {for (final c in repo.getCategories(onlyActive: false)) c.id: c};
  print('\nDepenses ce mois (${now.year}-${now.month}):');
  spend.forEach((categId, amount) {
    print('  - ${categories[categId]?.name ?? categId}: ${currency?.format(amount) ?? amount}');
  });

  final net = repo.monthlyNetTotals(anchor: now, months: 6);
  print('\nNet mensuel (6 derniers mois):');
  net.forEach((month, value) {
    print('  - ${month.year}-${month.month.toString().padLeft(2, '0')}: ${currency?.format(value) ?? value}');
  });

  final years = repo.getBudgetYears();
  print('\nExercices budgetaires: ${years.map((y) => y.name).join(', ')}');
  if (years.isNotEmpty) {
    final entries = repo.getBudgetEntries(years.first.id);
    print('Lignes de budget (${years.first.name}): ${entries.length}');
  }

  final transactions = repo.getTransactions(limit: 5);
  print('\n5 dernieres transactions:');
  for (final t in transactions) {
    final status = t.isReconciled ? 'pointee' : 'non pointee';
    print('  - ${t.date.toIso8601String().substring(0, 10)} ${t.transCode} ${currency?.format(t.amount) ?? t.amount} ($status)');
  }

  final bills = repo.getBillDeposits();
  print('\nOperations recurrentes: ${bills.length}');
  for (final b in bills) {
    print('  - ${b.period} / ${b.autoExecute} - prochaine ${b.nextOccurrence.toIso8601String().substring(0, 10)} '
        '- ${currency?.format(b.amount) ?? b.amount}');
  }

  final recurring = repo.recurringMonthlyNet(anchor: now, months: 6);
  print('\nProjection recurrente (6 derniers mois, y compris futurs si anchor futur):');
  recurring.forEach((month, value) {
    print('  - ${month.year}-${month.month.toString().padLeft(2, '0')}: ${currency?.format(value) ?? value}');
  });

  final futureAnchor = DateTime(now.year, now.month + 3, 1);
  final futureRecurring = repo.recurringMonthlyNet(anchor: futureAnchor, months: 4);
  print('\nProjection recurrente sur les 4 prochains mois (test futur):');
  futureRecurring.forEach((month, value) {
    print('  - ${month.year}-${month.month.toString().padLeft(2, '0')}: ${currency?.format(value) ?? value}');
  });

  // Reproduce what ForecastChart computes, for a specific (active) account,
  // to check the recurring-vs-discretionary split fluctuates sensibly.
  final activeAccount = accounts.firstWhere((a) => a.name.contains('Boursorama Perso') && !a.name.contains('Livret'));
  print('\n--- Simulation ForecastChart pour ${activeAccount.name} (id=${activeAccount.id}) ---');
  const historyMonths = 18;
  final history2 = repo.monthlyNetTotals(anchor: now, months: historyMonths, accountId: activeAccount.id);
  final recurring2 = repo.recurringMonthlyNet(anchor: now, months: historyMonths, accountId: activeAccount.id);
  final currentMonthStart = DateTime(now.year, now.month, 1);
  final discretionaryValues = history2.entries
      .where((e) => !e.key.isAfter(currentMonthStart))
      .map((e) => e.value - (recurring2[e.key] ?? 0))
      .toList();
  final avgDiscretionary =
      discretionaryValues.isEmpty ? 0.0 : discretionaryValues.reduce((a, b) => a + b) / discretionaryValues.length;
  print('avgDiscretionary: ${currency?.format(avgDiscretionary) ?? avgDiscretionary}');
  history2.forEach((month, actual) {
    final isFuture = month.isAfter(currentMonthStart);
    final net = isFuture ? (recurring2[month] ?? 0) + avgDiscretionary : actual;
    print('  - ${month.year}-${month.month.toString().padLeft(2, '0')} '
        '${isFuture ? '(future)' : '(passe)'}: net=${currency?.format(net) ?? net} '
        '(actual=${currency?.format(actual) ?? actual}, recurring=${currency?.format(recurring2[month] ?? 0) ?? recurring2[month]})');
  });

  // Regression check: replicate ForecastChart's day-scale seed math (fixed
  // to no longer double-count history) and compare a specific day's
  // cumulative balance against the real running-balance ledger.
  {
    const windowSizeDays = 30;
    const historyPaddingDays = 45;
    final offsetDays = 0;
    final currentBalance = repo.accountBalance(activeAccount.id);
    final today2 = DateTime(now.year, now.month, now.day);
    final endDay = today2.add(Duration(days: offsetDays));
    final start = endDay.subtract(const Duration(days: windowSizeDays - 1));
    final latestDay = endDay.isAfter(today2) ? endDay : today2;
    final earliestDay = start.subtract(const Duration(days: historyPaddingDays));
    final spanDays = latestDay.difference(earliestDay).inDays + 1;

    final dayHistory = repo.dailyNetTotals(anchor: latestDay, days: spanDays, accountId: activeAccount.id);
    final actualSinceEarliest = dayHistory.entries
        .where((e) => !e.key.isBefore(earliestDay) && !e.key.isAfter(today2))
        .fold(0.0, (sum, e) => sum + e.value);
    var cumulative = currentBalance - actualSinceEarliest;

    final targetDay = DateTime(2026, 7, 24);
    var cursor = earliestDay;
    double? cumulativeAtTarget;
    while (!cursor.isAfter(endDay)) {
      cumulative += dayHistory[cursor] ?? 0.0;
      if (cursor.isAtSameMomentAs(targetDay)) cumulativeAtTarget = cumulative;
      cursor = cursor.add(const Duration(days: 1));
    }

    final ledger = repo.getTransactionsWithRunningBalance(activeAccount.id);
    final ledgerMatches = ledger.where((r) => !r.transaction.date.isAfter(targetDay)).toList();
    final ledgerAtTarget = ledgerMatches.isEmpty ? null : ledgerMatches.first.balanceAfter;

    print('\nRegression ForecastChart (jour) pour ${activeAccount.name}, cible ${targetDay.toIso8601String().substring(0, 10)}:');
    print('  solde actuel (accountBalance): ${currency?.format(currentBalance) ?? currentBalance}');
    print('  cumulative reconstruit au ${targetDay.toIso8601String().substring(0, 10)}: '
        '${cumulativeAtTarget == null ? 'HORS FENETRE' : (currency?.format(cumulativeAtTarget) ?? cumulativeAtTarget)}');
    print('  solde reel (ledger) a cette date: ${ledgerAtTarget == null ? 'introuvable' : (currency?.format(ledgerAtTarget) ?? ledgerAtTarget)}');
    if (cumulativeAtTarget != null && ledgerAtTarget != null) {
      final match = (cumulativeAtTarget - ledgerAtTarget).abs() < 0.01;
      print('  => ${match ? 'OK' : 'MISMATCH'}');
    }
  }

  // Breakdown of the projected 26 juillet 2026 figure: forecast is now
  // recurring-only for future buckets (no discretionary-average component -
  // that will come back once budget is factored in). This also guards
  // against the "already-executed occurrence regenerated as still pending"
  // double-count bug (see _occurrencesInRange's nextOccurrence floor).
  {
    const windowSizeDays = 30;
    const historyPaddingDays = 45;
    final today2 = DateTime(now.year, now.month, now.day);
    final endDay = DateTime(2026, 7, 26);
    final start = endDay.subtract(const Duration(days: windowSizeDays - 1));
    final latestDay = endDay.isAfter(today2) ? endDay : today2;
    final earliestDay = start.subtract(const Duration(days: historyPaddingDays));
    final spanDays = latestDay.difference(earliestDay).inDays + 1;

    final dayHistory = repo.dailyNetTotals(anchor: latestDay, days: spanDays, accountId: activeAccount.id);
    final dayRecurring = repo.recurringDailyNet(anchor: latestDay, days: spanDays, accountId: activeAccount.id);

    final currentBalance = repo.accountBalance(activeAccount.id);
    final actualSinceEarliest = dayHistory.entries
        .where((e) => !e.key.isBefore(earliestDay) && !e.key.isAfter(today2))
        .fold(0.0, (sum, e) => sum + e.value);
    var cumulative = currentBalance - actualSinceEarliest;
    var cursor = earliestDay;
    while (!cursor.isAfter(endDay)) {
      final isFuture = cursor.isAfter(today2);
      final net = isFuture ? (dayRecurring[cursor] ?? 0) : (dayHistory[cursor] ?? 0.0);
      cumulative += net;
      if (cursor.isAtSameMomentAs(endDay)) {
        print('\nDetail projection du ${endDay.toIso8601String().substring(0, 10)} pour ${activeAccount.name}:');
        print('  recurrent connu ce jour-la: ${currency?.format(dayRecurring[cursor] ?? 0) ?? dayRecurring[cursor]}');
        print('  net applique ce jour-la (recurrent uniquement): '
            '${currency?.format(net) ?? net}');
        print('  cumulative final: ${currency?.format(cumulative) ?? cumulative}');
      }
      cursor = cursor.add(const Duration(days: 1));
    }
  }

  // Exercise the new due/catch-up/record-occurrence machinery on the
  // throwaway copy (safe: never touches the real file).
  final today = DateTime(now.year, now.month, now.day);
  final due = repo.getDueBillDeposits(today);
  print('\nOperations recurrentes en retard (asOf=${today.toIso8601String().substring(0, 10)}): ${due.length}');
  for (final b in due) {
    print('  - id=${b.id} prochaine=${b.nextOccurrence.toIso8601String().substring(0, 10)} '
        'periode=${b.period} auto=${b.autoExecute}');
  }

  if (due.isNotEmpty) {
    final target = due.first;
    final beforeTx = repo.getTransactions(accountId: target.accountId, limit: 1000).length;
    final insertedIds = repo.catchUpBillDeposit(target, today);
    final afterTx = repo.getTransactions(accountId: target.accountId, limit: 1000).length;
    final refreshed = repo.getBillDeposits().where((b) => b.id == target.id).toList();
    print('\ncatchUpBillDeposit sur id=${target.id}: ${insertedIds.length} transaction(s) inseree(s) '
        '(compte: $beforeTx -> $afterTx transactions)');
    if (refreshed.isEmpty) {
      print('  -> modele supprime (occurrences epuisees)');
    } else {
      print('  -> nouvelle prochaine occurrence: ${refreshed.first.nextOccurrence.toIso8601String().substring(0, 10)}');
    }
  }

  if (bills.isNotEmpty) {
    final manual = bills.firstWhere((b) => b.id != (due.isNotEmpty ? due.first.id : -1), orElse: () => bills.first);
    final txId = repo.recordBillOccurrence(manual, date: manual.nextOccurrence, reconciled: true);
    final recordedTx = repo.getTransactions(accountId: manual.accountId, limit: 1000).where((t) => t.id == txId);
    print('\nrecordBillOccurrence sur id=${manual.id}: transaction #$txId creee, '
        'reconciled=${recordedTx.isNotEmpty ? recordedTx.first.isReconciled : 'introuvable'}');
  }

  // Confirm the 700e recurring transfer (Credit Agricole -> Boursorama)
  // round-trips correctly: both accounts' balances should move.
  final transferBill = repo.getBillDeposits().where((b) => b.transCode.toString() == 'TransCode.transfer').toList();
  print('\nModeles recurrents de type virement: ${transferBill.length}');
  if (transferBill.isNotEmpty) {
    final bill = transferBill.first;
    final fromBefore = repo.accountBalance(bill.accountId);
    final toBefore = repo.accountBalance(bill.toAccountId!);
    final nextBefore = bill.nextOccurrence;
    final txId = repo.recordBillOccurrence(bill, date: bill.nextOccurrence, reconciled: false);
    final fromAfter = repo.accountBalance(bill.accountId);
    final toAfter = repo.accountBalance(bill.toAccountId!);
    // Re-fetch fresh from the DB, exactly like the UI would after touch().
    final refreshedBill = repo.getBillDeposits().where((b) => b.id == bill.id).toList();
    final insertedTx = repo.getTransactions(accountId: bill.accountId, limit: 2000).where((t) => t.id == txId);
    print('  Virement id=${bill.id} ${currency?.format(bill.amount) ?? bill.amount} : '
        'source ${currency?.format(fromBefore) ?? fromBefore} -> ${currency?.format(fromAfter) ?? fromAfter}, '
        'destination ${currency?.format(toBefore) ?? toBefore} -> ${currency?.format(toAfter) ?? toAfter}');
    print('  prochaine occurrence avant: ${nextBefore.toIso8601String().substring(0, 10)}');
    print('  prochaine occurrence apres (refetch): '
        '${refreshedBill.isEmpty ? 'MODELE INTROUVABLE/SUPPRIME' : refreshedBill.first.nextOccurrence.toIso8601String().substring(0, 10)}');
    if (insertedTx.isNotEmpty) {
      final t = insertedTx.first;
      print('  transaction inseree: accountId=${t.accountId} toAccountId=${t.toAccountId} '
          'transCode=${t.transCode} amount=${t.amount} toAmount=${t.toAmount} '
          'signedAmount(source)=${t.signedAmountFor(bill.accountId)} signedAmount(dest)=${t.signedAmountFor(bill.toAccountId)}');
    } else {
      print('  transaction inseree: INTROUVABLE via getTransactions(accountId: source)');
    }
  }

  // Regression check: recording an occurrence with a date BEFORE the
  // template's own scheduled nextOccurrence must still advance the
  // schedule (this used to get stuck forever - see _firstOccurrenceAfter).
  final earlyBillCandidates = repo.getBillDeposits();
  if (earlyBillCandidates.isNotEmpty) {
    final bill = earlyBillCandidates.first;
    final scheduledNext = bill.nextOccurrence;
    final earlyDate = scheduledNext.subtract(const Duration(days: 1));
    repo.recordBillOccurrence(bill, date: earlyDate, reconciled: false);
    final refreshed = repo.getBillDeposits().where((b) => b.id == bill.id).toList();
    final advanced = refreshed.isNotEmpty && refreshed.first.nextOccurrence.isAfter(scheduledNext);
    print('\nRegression "date anterieure a l\'echeance" sur id=${bill.id}:');
    print('  echeance planifiee: ${scheduledNext.toIso8601String().substring(0, 10)}, '
        'date saisie (veille): ${earlyDate.toIso8601String().substring(0, 10)}');
    print('  nouvelle echeance: '
        '${refreshed.isEmpty ? 'MODELE SUPPRIME' : refreshed.first.nextOccurrence.toIso8601String().substring(0, 10)} '
        '=> ${advanced ? 'OK, a bien avance' : 'ECHEC: bloquee'}');
  }

  // Weekly aggregation sanity check (new granularity for the forecast chart).
  final weeklyHistory = repo.weeklyNetTotals(anchor: now, weeks: 8);
  print('\nNet hebdomadaire (8 dernieres semaines, debut dimanche):');
  weeklyHistory.forEach((week, value) {
    print('  - ${week.toIso8601String().substring(0, 10)}: ${currency?.format(value) ?? value}');
  });
  final weeklyRecurring = repo.recurringWeeklyNet(anchor: DateTime(now.year, now.month, now.day + 21), weeks: 6);
  print('\nProjection recurrente hebdomadaire (test futur, 6 semaines):');
  weeklyRecurring.forEach((week, value) {
    print('  - ${week.toIso8601String().substring(0, 10)}: ${currency?.format(value) ?? value}');
  });

  // Daily aggregation sanity check (new granularity for the forecast chart).
  final dailyHistory = repo.dailyNetTotals(anchor: now, days: 10);
  print('\nNet journalier (10 derniers jours):');
  dailyHistory.forEach((day, value) {
    print('  - ${day.toIso8601String().substring(0, 10)}: ${currency?.format(value) ?? value}');
  });
  final dailyRecurring = repo.recurringDailyNet(anchor: DateTime(now.year, now.month, now.day + 21), days: 10);
  print('\nProjection recurrente journaliere (test futur, 10 jours):');
  dailyRecurring.forEach((day, value) {
    print('  - ${day.toIso8601String().substring(0, 10)}: ${currency?.format(value) ?? value}');
  });

  db.dispose();
  print('\nOK - lecture complete sans erreur.');
}
