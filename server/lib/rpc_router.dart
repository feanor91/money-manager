import 'dart:convert';

import 'package:money_manager_core/data/mmex_repository.dart';
import 'package:money_manager_core/models/account.dart';
import 'package:money_manager_core/models/bill_deposit.dart';
import 'package:money_manager_core/models/recurrence.dart';
import 'package:money_manager_core/models/transaction.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth/pin_auth.dart';
import 'auth/token_store.dart';

/// Construit le routeur complet du serveur : `/auth/login` (public) et
/// `/rpc/<méthode>` (authentifié par jeton Bearer). Volontairement une
/// route explicite par méthode de [MmexRepository] plutôt qu'un
/// répartiteur générique par réflexion - `dart compile exe` ne supporte
/// pas `dart:mirrors`, donc "une route par méthode" (voir
/// PLAN_ARCHITECTURE_CLIENT_SERVEUR.md) veut dire une petite fonction
/// écrite à la main par méthode exposée, pas un mécanisme automatique.
/// Une seule route pour cette première preuve de concept
/// (`getAccounts`) - les autres arriveront une à une à l'étape 4, au fur
/// et à mesure que chaque écran est basculé.
Handler buildRouter({
  required MmexRepository repo,
  required PinAuthenticator pinAuth,
  required TokenStore tokenStore,
}) {
  final router = Router();

  router.post('/auth/login', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final pin = body['pin'] as String?;
    if (pin == null || pin.isEmpty) {
      return Response(400, body: jsonEncode({'error': 'pin manquant'}));
    }
    final result = pinAuth.verify(pin);
    if (!result.ok) {
      if (result.lockoutRemaining != null) {
        return Response(
          423, // Locked
          body: jsonEncode({
            'error': 'trop de tentatives',
            'lockoutRemainingSeconds': result.lockoutRemaining!.inSeconds,
          }),
        );
      }
      return Response(
        401,
        body: jsonEncode({
          'error': 'code incorrect',
          'attemptsRemaining': result.attemptsRemaining,
        }),
      );
    }
    final token = tokenStore.issue();
    return Response.ok(jsonEncode({'token': token}));
  });

  // Authentifiée (comme /rpc/*) plutôt que publique - un jeton ne peut
  // révoquer que lui-même, jamais un jeton arbitraire passé en paramètre.
  // À utiliser en cas de doute sur une fuite (voir la discussion sécurité
  // dans PLAN_ARCHITECTURE_CLIENT_SERVEUR.md) plutôt que d'attendre
  // l'expiration naturelle (7 jours).
  router.post(
      '/auth/logout',
      const Pipeline().addMiddleware(_bearerAuth(tokenStore)).addHandler((Request request) async {
        tokenStore.revoke(request.context['bearerToken'] as String);
        return Response.ok(jsonEncode({'ok': true}));
      }));

  final rpcRouter = Router();
  rpcRouter.post('/getAccounts', (Request request) async {
    final onlyOpen = request.url.queryParameters['onlyOpen'] == 'true';
    final accounts = repo.getAccounts(onlyOpen: onlyOpen);
    return Response.ok(jsonEncode([for (final a in accounts) a.toJson()]));
  });
  rpcRouter.post('/getBaseCurrency', (Request request) async {
    final currency = repo.getBaseCurrency();
    return Response.ok(jsonEncode(currency?.toJson()));
  });
  rpcRouter.post('/accountBalance', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final accountId = body['accountId'] as int;
    final asOfStr = body['asOf'] as String?;
    final balance = repo.accountBalance(accountId,
        asOf: asOfStr == null ? null : DateTime.parse(asOfStr));
    return Response.ok(jsonEncode({'balance': balance}));
  });
  rpcRouter.post('/getPayees', (Request request) async {
    final onlyActive = request.url.queryParameters['onlyActive'] != 'false';
    final payees = repo.getPayees(onlyActive: onlyActive);
    return Response.ok(jsonEncode([for (final p in payees) p.toJson()]));
  });
  rpcRouter.post('/payeeUsageCount', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final count = repo.payeeUsageCount(body['payeeId'] as int);
    return Response.ok(jsonEncode({'count': count}));
  });
  rpcRouter.post('/getCategories', (Request request) async {
    final onlyActive = request.url.queryParameters['onlyActive'] != 'false';
    final categories = repo.getCategories(onlyActive: onlyActive);
    return Response.ok(jsonEncode([for (final c in categories) c.toJson()]));
  });
  rpcRouter.post('/categoryUsage', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final usage = repo.categoryUsage(body['categoryId'] as int);
    return Response.ok(jsonEncode(usage.toJson()));
  });
  rpcRouter.post('/getTransactionsFiltered', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    List<int>? intList(String key) => (body[key] as List?)?.cast<int>();
    final transactions = repo.getTransactionsFiltered(
      years: intList('years'),
      categoryIds: intList('categoryIds'),
      payeeIds: intList('payeeIds'),
      accountIds: intList('accountIds'),
    );
    return Response.ok(jsonEncode([for (final t in transactions) t.toJson()]));
  });
  rpcRouter.post('/transactionYearRangeAll', (Request request) async {
    final range = repo.transactionYearRangeAll();
    return Response.ok(jsonEncode(range == null ? null : {'min': range.min, 'max': range.max}));
  });
  rpcRouter.post('/getBillDeposits', (Request request) async {
    final bills = repo.getBillDeposits();
    return Response.ok(jsonEncode([for (final b in bills) b.toJson()]));
  });
  rpcRouter.post('/billOccurrenceTotals', (Request request) async {
    final totals = repo.billOccurrenceTotals();
    return Response.ok(jsonEncode(totals.map((k, v) => MapEntry('$k', v))));
  });
  rpcRouter.post('/getBillAnnualIncrease', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final increase = repo.getBillAnnualIncrease(body['billId'] as int);
    return Response.ok(jsonEncode(increase == null
        ? null
        : {'percent': increase.percent, 'anchor': increase.anchor.toIso8601String()}));
  });
  rpcRouter.post('/suggestedAnnualIncrease', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final suggestion = repo.suggestedAnnualIncrease(body['billId'] as int);
    return Response.ok(jsonEncode(suggestion == null
        ? null
        : {
            'percent': suggestion.percent,
            'anchor': suggestion.anchor.toIso8601String(),
            'yearsSpan': suggestion.yearsSpan,
          }));
  });
  rpcRouter.post('/getTransactionsWithRunningBalance', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final fromStr = body['from'] as String?;
    final toStr = body['to'] as String?;
    final rows = repo.getTransactionsWithRunningBalance(
      body['accountId'] as int,
      from: fromStr == null ? null : DateTime.parse(fromStr),
      to: toStr == null ? null : DateTime.parse(toStr),
    );
    return Response.ok(jsonEncode([for (final r in rows) r.toJson()]));
  });
  rpcRouter.post('/transactionYearRange', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final range = repo.transactionYearRange(body['accountId'] as int);
    return Response.ok(jsonEncode(range == null ? null : {'min': range.min, 'max': range.max}));
  });
  rpcRouter.post('/recurringTransactionIds', (Request request) async {
    final ids = repo.recurringTransactionIds();
    return Response.ok(jsonEncode(ids.toList()));
  });
  rpcRouter.post('/recurringTransactionOccurrences', (Request request) async {
    final occurrences = repo.recurringTransactionOccurrences();
    return Response.ok(jsonEncode(occurrences
        .map((k, v) => MapEntry('$k', {'index': v.index, 'total': v.total}))));
  });
  // Écran Budget (étape 4) - uniquement la vue "enveloppes" en lecture :
  // le simulateur ("what if") reste entièrement local, voir
  // budget_screen.dart et PLAN_ARCHITECTURE_CLIENT_SERVEUR.md pour le
  // détail de cette décision de périmètre.
  rpcRouter.post('/getBudgetEnvelopes', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final envelopes = repo.getBudgetEnvelopes(body['accountId'] as int);
    return Response.ok(jsonEncode([for (final e in envelopes) e.toJson()]));
  });
  rpcRouter.post('/categoryMonthlyRecurringTotals', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final totals = repo.categoryMonthlyRecurringTotals(accountId: body['accountId'] as int?);
    return Response.ok(jsonEncode(totals.map((k, v) => MapEntry('$k', v))));
  });
  rpcRouter.post('/categorySpendForPeriod', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final totals = repo.categorySpendForPeriod(
      DateTime.parse(body['start'] as String),
      DateTime.parse(body['end'] as String),
      accountId: body['accountId'] as int?,
      includeCategorizedTransfersAsExpense:
          body['includeCategorizedTransfersAsExpense'] as bool? ?? false,
    );
    return Response.ok(jsonEncode(totals.map((k, v) => MapEntry('$k', v))));
  });
  rpcRouter.post('/lastSpendDatePerCategory', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final dates = repo.lastSpendDatePerCategory(
      DateTime.parse(body['start'] as String),
      DateTime.parse(body['end'] as String),
      accountId: body['accountId'] as int?,
    );
    return Response.ok(
        jsonEncode(dates.map((k, v) => MapEntry('$k', v.toIso8601String()))));
  });
  rpcRouter.post('/categoriesUsedByAccount', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final ids = repo.categoriesUsedByAccount(body['accountId'] as int);
    return Response.ok(jsonEncode(ids.toList()));
  });
  rpcRouter.post('/incomeForPeriod', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final income = repo.incomeForPeriod(
      DateTime.parse(body['start'] as String),
      DateTime.parse(body['end'] as String),
      accountId: body['accountId'] as int?,
    );
    return Response.ok(jsonEncode({'income': income}));
  });
  rpcRouter.post('/expectedIncomeForBudget', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final expected = repo.expectedIncomeForBudget(body['accountId'] as int);
    return Response.ok(jsonEncode({'expected': expected}));
  });
  // Tableau de bord (étape 4).
  rpcRouter.post('/getTransactions', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final fromStr = body['from'] as String?;
    final toStr = body['to'] as String?;
    final transactions = repo.getTransactions(
      accountId: body['accountId'] as int?,
      from: fromStr == null ? null : DateTime.parse(fromStr),
      to: toStr == null ? null : DateTime.parse(toStr),
      limit: body['limit'] as int? ?? 200,
    );
    return Response.ok(jsonEncode([for (final t in transactions) t.toJson()]));
  });
  rpcRouter.post('/forecastAccountBalance', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final balance = repo.forecastAccountBalance(
      body['accountId'] as int,
      DateTime.parse(body['targetDate'] as String),
    );
    return Response.ok(jsonEncode({'balance': balance}));
  });
  rpcRouter.post('/forecastNegativeDate', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final date = repo.forecastNegativeDate(
      body['accountId'] as int,
      horizonDays: body['horizonDays'] as int? ?? 365,
    );
    return Response.ok(jsonEncode(date?.toIso8601String()));
  });
  // ForecastChart (dans Tableau de bord) - dernier morceau de l'étape 4,
  // voir PLAN_ARCHITECTURE_CLIENT_SERVEUR.md.
  rpcRouter.post('/dailyNetTotals', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final totals = repo.dailyNetTotals(
      anchor: DateTime.parse(body['anchor'] as String),
      days: body['days'] as int,
      accountId: body['accountId'] as int?,
    );
    return Response.ok(jsonEncode(totals.map((k, v) => MapEntry(k.toIso8601String(), v))));
  });
  rpcRouter.post('/futureDailyNet', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final totals = repo.futureDailyNet(
      after: DateTime.parse(body['after'] as String),
      end: DateTime.parse(body['end'] as String),
      accountId: body['accountId'] as int?,
    );
    return Response.ok(jsonEncode(totals.map((k, v) => MapEntry(k.toIso8601String(), v))));
  });
  rpcRouter.post('/recurringDailyNet', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final totals = repo.recurringDailyNet(
      anchor: DateTime.parse(body['anchor'] as String),
      days: body['days'] as int,
      accountId: body['accountId'] as int?,
    );
    return Response.ok(jsonEncode(totals.map((k, v) => MapEntry(k.toIso8601String(), v))));
  });
  rpcRouter.post('/recurringOccurrencesInRange', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final occurrences = repo.recurringOccurrencesInRange(
      start: DateTime.parse(body['start'] as String),
      end: DateTime.parse(body['end'] as String),
      accountId: body['accountId'] as int?,
    );
    return Response.ok(jsonEncode([
      for (final o in occurrences)
        {'date': o.date.toIso8601String(), 'label': o.label, 'signedAmount': o.signedAmount},
    ]));
  });

  // Écritures (chantier, non branchées en production - voir
  // PLAN_ARCHITECTURE_CLIENT_SERVEUR.md, "Précision ajoutée le
  // 2026-09-10"). Une route par méthode d'écriture, même principe que les
  // lectures ci-dessus.

  // ---- Transactions ----
  rpcRouter.post('/insertTransaction', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final id = repo.insertTransaction(
      accountId: body['accountId'] as int,
      payeeId: body['payeeId'] as int,
      transCode: transCodeFromString(body['transCode'] as String),
      amount: (body['amount'] as num).toDouble(),
      date: DateTime.parse(body['date'] as String),
      categoryId: body['categoryId'] as int?,
      toAccountId: body['toAccountId'] as int?,
      toAmount: (body['toAmount'] as num?)?.toDouble(),
      notes: body['notes'] as String?,
      reconciled: body['reconciled'] as bool? ?? false,
    );
    return Response.ok(jsonEncode({'id': id}));
  });
  rpcRouter.post('/updateTransaction', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.updateTransaction(MoneyTransaction.fromJson(body));
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/deleteTransaction', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.deleteTransaction(body['transId'] as int);
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/restoreTransaction', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final id = repo.restoreTransaction(
      MoneyTransaction.fromJson(body['transaction'] as Map<String, dynamic>),
      billId: body['billId'] as int?,
      occurrenceIndex: body['occurrenceIndex'] as int?,
      occurrenceTotal: body['occurrenceTotal'] as int?,
      wasReconciledBeforePause: body['wasReconciledBeforePause'] as bool?,
    );
    return Response.ok(jsonEncode({'id': id}));
  });
  rpcRouter.post('/setReconciled', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.setReconciled(body['transId'] as int, body['reconciled'] as bool);
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/resolveOrCreatePayee', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final id = repo.resolveOrCreatePayee(
        name: body['name'] as String, categoryId: body['categoryId'] as int?);
    return Response.ok(jsonEncode({'id': id}));
  });
  rpcRouter.post('/syncPausedTracking', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.syncPausedTracking(body['transId'] as int,
        paused: body['paused'] as bool, reconciled: body['reconciled'] as bool);
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/billIdForTransaction', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final billId = repo.billIdForTransaction(body['transId'] as int);
    return Response.ok(jsonEncode({'billId': billId}));
  });
  rpcRouter.post('/wasReconciledBeforePause', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final result = repo.wasReconciledBeforePause(body['transId'] as int);
    return Response.ok(jsonEncode({'result': result}));
  });
  rpcRouter.post('/countTransactionsMatching', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final count = repo.countTransactionsMatching(
        payeeId: body['payeeId'] as int, categoryId: body['categoryId'] as int);
    return Response.ok(jsonEncode({'count': count}));
  });
  rpcRouter.post('/bulkReassignTransactionCategory', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.bulkReassignTransactionCategory(
      payeeId: body['payeeId'] as int,
      oldCategoryId: body['oldCategoryId'] as int,
      newCategoryId: body['newCategoryId'] as int,
    );
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/countTransfersMatching', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final count = repo.countTransfersMatching(
      accountId: body['accountId'] as int,
      toAccountId: body['toAccountId'] as int,
      categoryId: body['categoryId'] as int,
    );
    return Response.ok(jsonEncode({'count': count}));
  });
  rpcRouter.post('/bulkReassignTransferCategory', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.bulkReassignTransferCategory(
      accountId: body['accountId'] as int,
      toAccountId: body['toAccountId'] as int,
      oldCategoryId: body['oldCategoryId'] as int,
      newCategoryId: body['newCategoryId'] as int,
    );
    return Response.ok(jsonEncode({'ok': true}));
  });

  // ---- Comptes ----
  rpcRouter.post('/insertAccount', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final id = repo.insertAccount(
      name: body['name'] as String,
      type: body['type'] as String,
      initialBalance: (body['initialBalance'] as num).toDouble(),
      currencyId: body['currencyId'] as int,
    );
    return Response.ok(jsonEncode({'id': id}));
  });
  rpcRouter.post('/updateAccount', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.updateAccount(Account.fromJson(body));
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/deleteAccount', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.deleteAccount(body['accountId'] as int);
    return Response.ok(jsonEncode({'ok': true}));
  });

  // ---- Catégories ----
  rpcRouter.post('/insertCategory', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final id = repo.insertCategory(name: body['name'] as String, parentId: body['parentId'] as int?);
    return Response.ok(jsonEncode({'id': id}));
  });
  rpcRouter.post('/renameCategory', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.renameCategory(body['categoryId'] as int, body['newName'] as String);
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/setCategoryActive', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.setCategoryActive(body['categoryId'] as int, body['active'] as bool);
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/deleteCategory', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.deleteCategory(body['categoryId'] as int);
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/mergeCategories', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.mergeCategories(fromId: body['fromId'] as int, toId: body['toId'] as int);
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/moveCategory', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.moveCategory(body['categoryId'] as int, body['newParentId'] as int?);
    return Response.ok(jsonEncode({'ok': true}));
  });

  // ---- Tiers ----
  rpcRouter.post('/renamePayee', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.renamePayee(body['payeeId'] as int, body['newName'] as String);
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/deletePayee', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.deletePayee(body['payeeId'] as int);
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/mergePayees', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.mergePayees(fromId: body['fromId'] as int, toId: body['toId'] as int);
    return Response.ok(jsonEncode({'ok': true}));
  });

  // ---- Opérations récurrentes ----
  rpcRouter.post('/insertBillDeposit', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final id = repo.insertBillDeposit(
      accountId: body['accountId'] as int,
      payeeId: body['payeeId'] as int,
      transCode: transCodeFromString(body['transCode'] as String),
      amount: (body['amount'] as num).toDouble(),
      nextOccurrence: DateTime.parse(body['nextOccurrence'] as String),
      period: RecurrencePeriod.values.byName(body['period'] as String),
      autoExecute: RecurrenceAutoExecute.values.byName(body['autoExecute'] as String),
      categoryId: body['categoryId'] as int?,
      toAccountId: body['toAccountId'] as int?,
      toAmount: (body['toAmount'] as num?)?.toDouble(),
      notes: body['notes'] as String?,
      numOccurrences: body['numOccurrences'] as int? ?? -1,
    );
    return Response.ok(jsonEncode({'id': id}));
  });
  rpcRouter.post('/updateBillDeposit', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.updateBillDeposit(BillDeposit.fromJson(body));
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/deleteBillDeposit', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.deleteBillDeposit(body['bdId'] as int);
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/setBillPaused', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.setBillPaused(body['billId'] as int, body['paused'] as bool);
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/setBillAnnualIncrease', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.setBillAnnualIncrease(
      body['billId'] as int,
      percent: (body['percent'] as num).toDouble(),
      anchor: DateTime.parse(body['anchor'] as String),
    );
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/clearBillAnnualIncrease', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.clearBillAnnualIncrease(body['billId'] as int);
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/ensureBillOccurrenceTotal', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.ensureBillOccurrenceTotal(body['billId'] as int, body['total'] as int);
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/recordBillOccurrence', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final transId = repo.recordBillOccurrence(
      BillDeposit.fromJson(body['bill'] as Map<String, dynamic>),
      date: DateTime.parse(body['date'] as String),
      reconciled: body['reconciled'] as bool? ?? false,
      splitInto: body['splitInto'] as int? ?? 1,
    );
    return Response.ok(jsonEncode({'transId': transId}));
  });
  rpcRouter.post('/catchUpBillDeposit', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final ids = repo.catchUpBillDeposit(
      BillDeposit.fromJson(body['bill'] as Map<String, dynamic>),
      DateTime.parse(body['asOf'] as String),
      reconciled: body['reconciled'] as bool? ?? false,
    );
    return Response.ok(jsonEncode({'ids': ids}));
  });

  // ---- Budget (vue enveloppes uniquement - le simulateur reste local) ----
  rpcRouter.post('/upsertBudgetEnvelope', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final id = body['id'] as int?;
    final accountId = body['accountId'] as int;
    final categoryId = body['categoryId'] as int;
    final amount = (body['amount'] as num).toDouble();
    final hasName = body.containsKey('name');
    final hasManualOverride = body.containsKey('manualOverride');
    final name = body['name'] as String?;
    final manualOverride = body['manualOverride'] as bool?;
    // upsertBudgetEnvelope distingue "argument absent" (garde la valeur
    // existante) de "argument passé, même null" via une valeur sentinelle
    // par défaut sur ses propres paramètres - reproduit ici en n'incluant
    // l'argument nommé dans l'appel que lorsque la clé JSON était présente,
    // plutôt que de tenter de passer une sentinelle depuis l'extérieur (qui
    // ne serait de toute façon jamais identique à la sentinelle privée du
    // dépôt).
    if (hasName && hasManualOverride) {
      repo.upsertBudgetEnvelope(
          id: id,
          accountId: accountId,
          categoryId: categoryId,
          amount: amount,
          name: name,
          manualOverride: manualOverride);
    } else if (hasName) {
      repo.upsertBudgetEnvelope(
          id: id, accountId: accountId, categoryId: categoryId, amount: amount, name: name);
    } else if (hasManualOverride) {
      repo.upsertBudgetEnvelope(
          id: id,
          accountId: accountId,
          categoryId: categoryId,
          amount: amount,
          manualOverride: manualOverride);
    } else {
      repo.upsertBudgetEnvelope(id: id, accountId: accountId, categoryId: categoryId, amount: amount);
    }
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/deleteBudgetEnvelope', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.deleteBudgetEnvelope(body['id'] as int);
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/setIncomeTargetOverride', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.setIncomeTargetOverride(body['accountId'] as int, (body['amount'] as num).toDouble());
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/getIncomeTargetOverride', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final override = repo.getIncomeTargetOverride(body['accountId'] as int);
    return Response.ok(jsonEncode({'override': override}));
  });
  rpcRouter.post('/clearIncomeTargetOverride', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.clearIncomeTargetOverride(body['accountId'] as int);
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/monthlyRecurringIncome', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final income = repo.monthlyRecurringIncome(accountId: body['accountId'] as int?);
    return Response.ok(jsonEncode({'income': income}));
  });
  rpcRouter.post('/incomeCategoryTotalsForPeriod', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final totals = repo.incomeCategoryTotalsForPeriod(
      DateTime.parse(body['start'] as String),
      DateTime.parse(body['end'] as String),
      accountId: body['accountId'] as int?,
    );
    return Response.ok(jsonEncode({'totals': totals.map((k, v) => MapEntry('$k', v))}));
  });
  rpcRouter.post('/resetBudgetEnvelopes', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.resetBudgetEnvelopes(body['accountId'] as int);
    return Response.ok(jsonEncode({'ok': true}));
  });

  // ---- Simulation ("what if" scenarios de long terme) ----
  rpcRouter.post('/getSimScenarios', (Request request) async {
    final scenarios = repo.getSimScenarios();
    return Response.ok(jsonEncode([for (final s in scenarios) s.toJson()]));
  });
  rpcRouter.post('/createSimScenario', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final id = repo.createSimScenario(body['name'] as String);
    return Response.ok(jsonEncode({'id': id}));
  });
  rpcRouter.post('/renameSimScenario', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.renameSimScenario(body['scenarioId'] as int, body['name'] as String);
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/duplicateSimScenario', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final id = repo.duplicateSimScenario(
        body['sourceScenarioId'] as int, body['newName'] as String);
    return Response.ok(jsonEncode({'id': id}));
  });
  rpcRouter.post('/deleteSimScenario', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.deleteSimScenario(body['scenarioId'] as int);
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/getSimBillOverrides', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final overrides = repo.getSimBillOverrides(body['scenarioId'] as int);
    return Response.ok(jsonEncode([for (final o in overrides) o.toJson()]));
  });
  rpcRouter.post('/upsertSimBillOverride', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.upsertSimBillOverride(
      body['scenarioId'] as int,
      body['billId'] as int,
      disabledFrom: body['disabledFrom'] == null
          ? null
          : DateTime.parse(body['disabledFrom'] as String),
      amountOverride: (body['amountOverride'] as num?)?.toDouble(),
    );
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/deleteSimBillOverride', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.deleteSimBillOverride(body['scenarioId'] as int, body['billId'] as int);
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/getSimVirtualBills', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final bills = repo.getSimVirtualBills(body['scenarioId'] as int);
    return Response.ok(jsonEncode([for (final b in bills) b.toJson()]));
  });
  rpcRouter.post('/addSimVirtualBill', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final id = repo.addSimVirtualBill(
      scenarioId: body['scenarioId'] as int,
      accountId: body['accountId'] as int,
      label: body['label'] as String,
      transCode: transCodeFromString(body['transCode'] as String),
      amount: (body['amount'] as num).toDouble(),
      startDate: DateTime.parse(body['startDate'] as String),
      period: RecurrencePeriod.values.byName(body['period'] as String),
      numOccurrences: body['numOccurrences'] as int? ?? -1,
      variancePercent: (body['variancePercent'] as num?)?.toDouble() ?? 0,
      annualIncreasePercent: (body['annualIncreasePercent'] as num?)?.toDouble() ?? 0,
      annualIncreaseAnchor: body['annualIncreaseAnchor'] == null
          ? null
          : DateTime.parse(body['annualIncreaseAnchor'] as String),
    );
    return Response.ok(jsonEncode({'id': id}));
  });
  rpcRouter.post('/deleteSimVirtualBill', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.deleteSimVirtualBill(body['virtualBillId'] as int);
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/getSimOneOffEvents', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final events = repo.getSimOneOffEvents(body['scenarioId'] as int);
    return Response.ok(jsonEncode([for (final e in events) e.toJson()]));
  });
  rpcRouter.post('/addSimOneOffEvent', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final id = repo.addSimOneOffEvent(
      scenarioId: body['scenarioId'] as int,
      accountId: body['accountId'] as int,
      label: body['label'] as String,
      transCode: transCodeFromString(body['transCode'] as String),
      amount: (body['amount'] as num).toDouble(),
      date: DateTime.parse(body['date'] as String),
    );
    return Response.ok(jsonEncode({'id': id}));
  });
  rpcRouter.post('/deleteSimOneOffEvent', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.deleteSimOneOffEvent(body['eventId'] as int);
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/getSimMeanReversion', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final reversion =
        repo.getSimMeanReversion(body['scenarioId'] as int, body['accountId'] as int);
    return Response.ok(jsonEncode(reversion == null
        ? null
        : {
            'enabled': reversion.enabled,
            'equilibrium': reversion.equilibrium,
            'strength': reversion.strength,
            'noisePercent': reversion.noisePercent,
          }));
  });
  rpcRouter.post('/setSimMeanReversion', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.setSimMeanReversion(
      body['scenarioId'] as int,
      body['accountId'] as int,
      enabled: body['enabled'] as bool,
      equilibrium: (body['equilibrium'] as num?)?.toDouble(),
      strength: (body['strength'] as num).toDouble(),
      noisePercent: (body['noisePercent'] as num).toDouble(),
    );
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/setSimMeanReversionEnabled', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.setSimMeanReversionEnabled(
        body['scenarioId'] as int, body['accountId'] as int, body['enabled'] as bool);
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/deleteSimMeanReversion', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    repo.deleteSimMeanReversion(body['scenarioId'] as int, body['accountId'] as int);
    return Response.ok(jsonEncode({'ok': true}));
  });
  rpcRouter.post('/occurrencesForBill', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final bill = BillDeposit.fromJson(body['bill'] as Map<String, dynamic>);
    final occurrences = repo.occurrencesForBill(
      bill,
      DateTime.parse(body['start'] as String),
      DateTime.parse(body['end'] as String),
    );
    return Response.ok(jsonEncode([for (final d in occurrences) d.toIso8601String()]));
  });
  rpcRouter.post('/historicalDiscretionaryMonthlyAverage', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final average = repo.historicalDiscretionaryMonthlyAverage(
      accountId: body['accountId'] as int?,
      anchor: DateTime.parse(body['anchor'] as String),
      startDay: body['startDay'] as int,
      months: body['months'] as int? ?? 12,
    );
    return Response.ok(jsonEncode({'average': average}));
  });
  rpcRouter.post('/historicalDiscretionaryMonthlyStdev', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final stdev = repo.historicalDiscretionaryMonthlyStdev(
      accountId: body['accountId'] as int?,
      anchor: DateTime.parse(body['anchor'] as String),
      startDay: body['startDay'] as int,
      months: body['months'] as int? ?? 12,
    );
    return Response.ok(jsonEncode({'stdev': stdev}));
  });
  rpcRouter.post('/historicalEquilibriumBalance', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final balance = repo.historicalEquilibriumBalance(
      accountId: body['accountId'] as int,
      anchor: DateTime.parse(body['anchor'] as String),
      startDay: body['startDay'] as int,
      months: body['months'] as int? ?? 12,
    );
    return Response.ok(jsonEncode({'balance': balance}));
  });
  // Un seul aller-retour pour toute la courbe (référence + scénario) d'un
  // compte, plutôt que les ~6 appels séquentiels que ça prenait côté client
  // (voir _SimulationChartState._buildSeries dans simulation_screen.dart) -
  // reproduit exactement le même enchaînement, juste exécuté côté serveur.
  rpcRouter.post('/computeSimulationChart', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final scenarioId = body['scenarioId'] as int;
    final accountId = body['accountId'] as int;
    final anchor = DateTime.parse(body['anchor'] as String);
    final days = body['days'] as int;
    final startDay = body['startDay'] as int;
    final now = DateTime.now();

    final startingBalance = repo.accountBalance(accountId, asOf: now);
    final baselineNet = repo.recurringDailyNet(anchor: anchor, days: days, accountId: accountId);
    final reversion = repo.getSimMeanReversion(scenarioId, accountId);
    final equilibrium = reversion?.equilibrium ??
        repo.historicalEquilibriumBalance(
            accountId: accountId, anchor: now, startDay: startDay);
    final stdev = repo.historicalDiscretionaryMonthlyStdev(
        accountId: accountId, anchor: now, startDay: startDay);
    final scenarioResult = repo.simulatedDailyNetWithMeanReversion(
      scenarioId: scenarioId,
      accountId: accountId,
      enabled: reversion?.enabled ?? false,
      equilibrium: equilibrium,
      strength: reversion?.strength ?? 0.5,
      noiseAmount: stdev * (reversion?.noisePercent ?? 100) / 100,
      anchor: anchor,
      days: days,
      forecastDay: startDay,
    );

    return Response.ok(jsonEncode({
      'startingBalance': startingBalance,
      'baselineNet': baselineNet.map((k, v) => MapEntry(k.toIso8601String(), v)),
      'scenarioNet': scenarioResult.net.map((k, v) => MapEntry(k.toIso8601String(), v)),
      'appliedDates': [for (final d in scenarioResult.appliedDates) d.toIso8601String()],
      'equilibrium': equilibrium,
      'stdev': stdev,
      'meanReversion': reversion == null
          ? null
          : {
              'enabled': reversion.enabled,
              'equilibrium': reversion.equilibrium,
              'strength': reversion.strength,
              'noisePercent': reversion.noisePercent,
            },
    }));
  });

  router.mount(
      '/rpc', const Pipeline().addMiddleware(_bearerAuth(tokenStore)).addHandler(rpcRouter.call));

  return const Pipeline().addMiddleware(_cors()).addHandler(router.call);
}

/// Autorise l'appli web (servie sur une autre origine que le serveur API -
/// pas de routage par chemin possible avec le reverse-proxy DSM, voir
/// PLAN_ARCHITECTURE_CLIENT_SERVEUR.md) à appeler ce serveur - sans ça, le
/// navigateur bloque silencieusement chaque requête AVANT même qu'elle
/// n'atteigne le serveur (bloqué en local le 2026-09-10 en essayant de
/// vérifier l'écran Budget en direct : "Failed to fetch" côté appli,
/// "blocked by CORS policy" dans la console). `*` plutôt qu'une origine
/// précise - ce serveur n'est protégé que par le code PIN/jeton Bearer, pas
/// par l'origine de la requête, donc restreindre l'origine n'ajouterait pas
/// de sécurité réelle ici, seulement de la friction (URL du serveur
/// configurable côté appli, potentiellement différente en local/déployé/
/// tunnel).
Middleware _cors() {
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  };
  return (Handler innerHandler) {
    return (Request request) async {
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: headers);
      }
      final response = await innerHandler(request);
      return response.change(headers: headers);
    };
  };
}

/// Middleware qui vérifie `Authorization: Bearer <jeton>` sur toutes les
/// routes `/rpc/*` - voir PLAN_ARCHITECTURE_CLIENT_SERVEUR.md, section
/// "Sécurité de l'API".
Middleware _bearerAuth(TokenStore tokenStore) {
  return (Handler innerHandler) {
    return (Request request) {
      final header = request.headers['authorization'];
      if (header == null || !header.startsWith('Bearer ')) {
        return Response(401, body: jsonEncode({'error': 'jeton manquant'}));
      }
      final token = header.substring('Bearer '.length);
      if (!tokenStore.isValid(token)) {
        return Response(401, body: jsonEncode({'error': 'jeton invalide ou expiré'}));
      }
      return innerHandler(request.change(context: {'bearerToken': token}));
    };
  };
}
