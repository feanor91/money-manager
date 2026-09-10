import 'package:flutter/material.dart';
import 'package:money_manager_core/models/account.dart';

import '../services/api/api_client.dart';

/// Écran de développement pour prouver que l'appli Flutter peut réellement
/// parler au serveur API construit à l'étape 2/3 (voir
/// PLAN_ARCHITECTURE_CLIENT_SERVEUR.md) - pas un écran destiné à rester
/// dans l'appli finale, juste la preuve de bout en bout demandée par le
/// plan avant de s'attaquer à l'étape 4 (basculer chaque écran réel un
/// par un, un chantier bien plus large).
class ApiDebugScreen extends StatefulWidget {
  const ApiDebugScreen({super.key});

  @override
  State<ApiDebugScreen> createState() => _ApiDebugScreenState();
}

class _ApiDebugScreenState extends State<ApiDebugScreen> {
  final _urlController = TextEditingController(text: 'http://localhost:8899');
  final _pinController = TextEditingController();
  ApiClient? _client;
  List<Account>? _accounts;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _urlController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final client = ApiClient(baseUrl: _urlController.text.trim());
    try {
      await client.login(_pinController.text.trim());
      setState(() {
        _client = client;
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  Future<void> _loadAccounts() async {
    final client = _client;
    if (client == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final accounts = await client.getAccounts();
      setState(() {
        _accounts = accounts;
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final client = _client;
    return Scaffold(
      appBar: AppBar(title: const Text('Test API serveur (chantier)')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Preuve de bout en bout - se connecte au serveur API du chantier '
              'client/serveur (voir PLAN_ARCHITECTURE_CLIENT_SERVEUR.md) et '
              'récupère la vraie liste des comptes via /rpc/getAccounts.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(labelText: 'URL du serveur'),
              enabled: client == null,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _pinController,
              decoration: const InputDecoration(labelText: 'Code PIN'),
              obscureText: true,
              enabled: client == null,
              onSubmitted: (_) => _login(),
            ),
            const SizedBox(height: 12),
            if (client == null)
              FilledButton(
                onPressed: _busy ? null : _login,
                child: Text(_busy ? 'Connexion...' : 'Se connecter'),
              )
            else ...[
              FilledButton(
                onPressed: _busy ? null : _loadAccounts,
                child: Text(_busy ? 'Chargement...' : 'Charger les comptes'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => setState(() {
                  _client = null;
                  _accounts = null;
                  _error = null;
                }),
                child: const Text('Se déconnecter'),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
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
