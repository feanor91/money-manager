import 'dart:convert';
import 'dart:math';

/// Jetons Bearer opaques (chaîne aléatoire, pas un JWT signé) - choix
/// délibéré : pas de bibliothèque de signature à ajouter, la révocation
/// est triviale (retirer l'entrée de la map), et le serveur est de toute
/// façon la seule partie qui a besoin de vérifier un jeton (contrairement
/// à un JWT, pensé pour être vérifié par plusieurs services sans aller-
/// retour réseau - pas le cas ici, un seul serveur).
///
/// En mémoire seulement pour l'instant - un redémarrage du serveur
/// déconnecte tout le monde (limitation connue, comme pour
/// [PinAuthenticator] - à persister plus tard si besoin).
class TokenStore {
  final Duration ttl;
  final Map<String, DateTime> _issuedAt = {};

  // 7 jours par défaut (réduit de 30 - voir PLAN_ARCHITECTURE_CLIENT_SERVEUR.md,
  // discussion sur la fenêtre d'exposition d'un jeton qui fuiterait) - un
  // compromis entre reconnexion fréquente et exposition prolongée, pas une
  // valeur figée à ne jamais revoir.
  TokenStore({this.ttl = const Duration(days: 7)});

  String issue() {
    final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    final token = base64UrlEncode(bytes);
    _issuedAt[token] = DateTime.now();
    return token;
  }

  bool isValid(String token) {
    final issuedAt = _issuedAt[token];
    if (issuedAt == null) return false;
    if (DateTime.now().difference(issuedAt) > ttl) {
      _issuedAt.remove(token);
      return false;
    }
    return true;
  }

  void revoke(String token) => _issuedAt.remove(token);
}
