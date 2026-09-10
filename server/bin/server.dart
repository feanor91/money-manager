import 'dart:io';

import 'package:money_manager_core/data/mmex_database.dart';
import 'package:money_manager_core/data/mmex_repository.dart';
import 'package:money_manager_server/auth/pin_auth.dart';
import 'package:money_manager_server/auth/token_store.dart';
import 'package:money_manager_server/rpc_router.dart';
import 'package:money_manager_server/server_config.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

Future<void> main() async {
  final config = ServerConfig.fromEnvironment();

  // false explicite (jamais createIfMissing: true ici) - une base
  // manquante doit être une erreur claire, pas un fichier vide créé en
  // silence. Voir CLAUDE.md "Desktop: reopening a missing path must never
  // silently create an empty file" - même règle ici côté serveur.
  final db = await MmexDatabase.openFromPath(config.dbPath, createIfMissing: false);
  final repo = MmexRepository(db)..ensureAppSchema();

  final pinAuth = PinAuthenticator(pin: config.devPin);
  final tokenStore = TokenStore();
  final router = buildRouter(repo: repo, pinAuth: pinAuth, tokenStore: tokenStore);

  final server = await shelf_io.serve(router.call, InternetAddress.anyIPv4, config.port);
  // ignore: avoid_print
  print('Money Manager Server à l\'écoute sur le port ${server.port} '
      '(base : ${config.dbPath})');
}
