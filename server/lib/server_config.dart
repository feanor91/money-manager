import 'dart:io';

/// Configuration de démarrage du serveur - lue depuis l'environnement,
/// jamais codée en dur (voir PLAN_ARCHITECTURE_CLIENT_SERVEUR.md, section
/// "Configuration du serveur - deux niveaux distincts"). C'est le niveau 1
/// (config de démarrage) : le strict nécessaire avant que le serveur
/// puisse répondre à quoi que ce soit d'authentifié. Tout le reste
/// (modèle IA, politique PIN...) vivra dans le niveau 2, réglable depuis
/// l'appli une fois le stockage de réglages côté serveur implémenté.
class ServerConfig {
  /// Chemin du fichier .mmb - jamais une valeur par défaut pointant vers un
  /// vrai fichier, pour ne jamais risquer d'ouvrir la vraie base par
  /// accident en développement (voir la même prudence dans CLAUDE.md,
  /// "Never commit either path").
  final String dbPath;

  final int port;

  /// Code PIN de démarrage, pour l'authentification (voir pin_auth.dart).
  /// En développement seulement - le stockage définitif (salt/hash
  /// persistés, compteur de tentatives, blocage) reste à porter depuis
  /// PinLockProvider dans une étape ultérieure ; voir pin_auth.dart pour
  /// le détail de ce qui est déjà couvert ici et ce qui ne l'est pas.
  final String devPin;

  const ServerConfig({
    required this.dbPath,
    required this.port,
    required this.devPin,
  });

  /// Lève une [StateError] avec un message clair si une variable requise
  /// manque - jamais de valeur par défaut pointant vers un vrai chemin.
  factory ServerConfig.fromEnvironment() {
    final dbPath = Platform.environment['MM_DB_PATH'];
    if (dbPath == null || dbPath.isEmpty) {
      throw StateError(
        'MM_DB_PATH manquant - chemin du fichier .mmb à ouvrir. '
        'En développement, utilise une copie jetable, jamais le vrai '
        'fichier Nextcloud (voir dev_db.dart pour en créer une).',
      );
    }
    final devPin = Platform.environment['MM_DEV_PIN'];
    if (devPin == null || devPin.isEmpty) {
      throw StateError('MM_DEV_PIN manquant - code PIN de développement.');
    }
    final portStr = Platform.environment['MM_PORT'];
    final port = portStr == null ? 8080 : int.parse(portStr);
    return ServerConfig(dbPath: dbPath, port: port, devPin: devPin);
  }
}
