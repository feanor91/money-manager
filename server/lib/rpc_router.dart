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

  final rpcRouter = Router();
  rpcRouter.post('/getAccounts', (Request request) async {
    final onlyOpen = request.url.queryParameters['onlyOpen'] == 'true';
    final accounts = repo.getAccounts(onlyOpen: onlyOpen);
    return Response.ok(jsonEncode([for (final a in accounts) a.toJson()]));
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
      return innerHandler(request);
    };
  };
}
