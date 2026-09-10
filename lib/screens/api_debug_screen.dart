import 'package:flutter/material.dart';
import 'package:money_manager_core/models/account.dart';
import 'package:provider/provider.dart';

import '../state/api_session_provider.dart';

/// Écran de connexion au serveur API du chantier client/serveur (voir
/// PLAN_ARCHITECTURE_CLIENT_SERVEUR.md) - se connecte au [ApiSessionProvider]
/// partagé par toute l'appli (pas un client jetable propre à cet écran),
/// donc une fois connecté ici, l'écran Comptes (étape 4) peut utiliser la
/// même session. Reste un écran de développement, à retirer avant tout
/// déploiement réel de l'appli elle-même (pas le serveur, l'appli).
class ApiDebugScreen extends StatefulWidget {
  const ApiDebugScreen({super.key});

  @override
  State<ApiDebugScreen> createState() => _ApiDebugScreenState();
}

class _ApiDebugScreenState extends State<ApiDebugScreen> {
  // Adresse locale (réseau domestique) d'Excelsior par défaut - HTTPS sur
  // bteuile.ddns.net:8444 ne marche que depuis l'extérieur (certificat
  // valable pour ce nom, pas pour l'IP - voir PLAN_ARCHITECTURE_CLIENT_SERVEUR.md).
  final _urlController = TextEditingController(text: 'http://192.168.1.44:8899');
  final _pinController = TextEditingController();
  List<Account>? _accounts;
  String? _loadError;
  bool _loadingAccounts = false;

  @override
  void dispose() {
    _urlController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _loadAccounts(ApiSessionProvider session) async {
    setState(() {
      _loadingAccounts = true;
      _loadError = null;
    });
    try {
      final accounts = await session.getAccounts();
      setState(() => _accounts = accounts);
    } catch (e) {
      setState(() => _loadError = '$e');
    } finally {
      setState(() => _loadingAccounts = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<ApiSessionProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('Connexion au serveur API (chantier)')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              session.isConnected
                  ? 'Connecté à ${session.serverUrl} - la session est partagée '
                      'par toute l\'appli (voir Paramètres → Comptes via API).'
                  : 'Connexion au serveur API du chantier client/serveur (voir '
                      'PLAN_ARCHITECTURE_CLIENT_SERVEUR.md).',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(labelText: 'URL du serveur'),
              enabled: !session.isConnected,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _pinController,
              decoration: const InputDecoration(labelText: 'Code PIN'),
              obscureText: true,
              enabled: !session.isConnected,
              onSubmitted: (_) => session.login(_urlController.text.trim(), _pinController.text.trim()),
            ),
            const SizedBox(height: 12),
            if (!session.isConnected)
              FilledButton(
                onPressed: session.isBusy
                    ? null
                    : () => session.login(_urlController.text.trim(), _pinController.text.trim()),
                child: Text(session.isBusy ? 'Connexion...' : 'Se connecter'),
              )
            else ...[
              FilledButton(
                onPressed: _loadingAccounts ? null : () => _loadAccounts(session),
                child: Text(_loadingAccounts ? 'Chargement...' : 'Charger les comptes'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () {
                  session.logout();
                  setState(() {
                    _accounts = null;
                    _loadError = null;
                  });
                },
                child: const Text('Se déconnecter (révoque le jeton)'),
              ),
            ],
            if (session.error != null) ...[
              const SizedBox(height: 12),
              Text(session.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            if (_loadError != null) ...[
              const SizedBox(height: 12),
              Text(_loadError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            if (_accounts != null) ...[
              const SizedBox(height: 16),
              Text('${_accounts!.length} compte(s) reçu(s) du serveur :',
                  style: Theme.of(context).textTheme.titleMedium),
              Expanded(
                child: ListView(
                  children: [
                    for (final a in _accounts!)
                      ListTile(
                        title: Text(a.name),
                        subtitle: Text('${a.type} · ${a.status}'),
                        trailing: Text(a.initialBalance.toStringAsFixed(2)),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
