import 'dart:convert';

import 'package:money_manager_core/data/mmex_repository.dart';
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
Router buildRouter({
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

  router.mount(
      '/rpc', const Pipeline().addMiddleware(_bearerAuth(tokenStore)).addHandler(rpcRouter.call));

  return router;
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
