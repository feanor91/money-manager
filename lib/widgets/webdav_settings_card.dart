import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../services/webdav/webdav_sync_store.dart' show WebDavCredentials;
import '../state/database_provider.dart';
import 'confirm_delete.dart';

bool get _isAndroidPlatform =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Settings card for the Android-only built-in WebDAV sync - hidden
/// entirely (returns nothing) on any other platform, same convention as
/// LocalLlmSettingsCard's Windows-only self-gating. Replaces the
/// third-party sync app this project previously relied on (cost + repeated
/// unexplained conflicts, including once on the .mmb itself) with a flow
/// under this app's own control: credentials configured here, reconciled
/// automatically at launch and on a manual "Synchroniser maintenant" here,
/// genuine conflicts resolved through the dialog reachable from the
/// dashboard's sync icon/HomeShell's banner (not from this card) - see
/// DatabaseProvider's WebDAV section for the full flow this configures.
class WebDavSettingsCard extends StatefulWidget {
  const WebDavSettingsCard({super.key});

  @override
  State<WebDavSettingsCard> createState() => _WebDavSettingsCardState();
}

class _WebDavSettingsCardState extends State<WebDavSettingsCard> {
  bool _loading = true;
  bool _enabled = false;

  final _serverUrlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _appPasswordController = TextEditingController();
  final _remotePathController = TextEditingController();
  String? _credentialsError;

  bool _testing = false;
  bool? _testOk;
  String? _testMessage;

  @override
  void initState() {
    super.initState();
    if (_isAndroidPlatform) _load();
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _usernameController.dispose();
    _appPasswordController.dispose();
    _remotePathController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final dbProvider = context.read<DatabaseProvider>();
    final enabled = await dbProvider.webDavEnabled();
    final creds = await dbProvider.webDavCredentials();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _serverUrlController.text = creds.serverUrl;
      _usernameController.text = creds.username;
      _appPasswordController.text = creds.appPassword;
      _remotePathController.text = creds.remotePath;
      _loading = false;
    });
  }

  Future<void> _toggleEnabled(bool value) async {
    await context.read<DatabaseProvider>().setWebDavEnabled(value);
    if (!mounted) return;
    setState(() => _enabled = value);
  }

  WebDavCredentials get _fieldCredentials => WebDavCredentials(
        serverUrl: _serverUrlController.text.trim(),
        username: _usernameController.text.trim(),
        appPassword: _appPasswordController.text,
        remotePath: _remotePathController.text.trim(),
      );

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _testOk = null;
      _testMessage = null;
    });
    final result = await context.read<DatabaseProvider>().testWebDavConnection(_fieldCredentials);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testOk = result.ok;
      _testMessage = result.ok
          ? (result.info == null
              ? "Connexion réussie - aucun fichier à cet emplacement pour l'instant "
                  '(normal avant le tout premier envoi).'
              : 'Connexion réussie - fichier trouvé '
                  '(${((result.info!.contentLength ?? 0) / 1024).toStringAsFixed(0)} Ko).')
          : result.errorMessage;
    });
  }

  Future<void> _saveCredentials() async {
    final creds = _fieldCredentials;
    if (!creds.isComplete) {
      setState(() => _credentialsError = 'Tous les champs sont obligatoires.');
      return;
    }
    await context.read<DatabaseProvider>().saveWebDavCredentials(creds);
    if (!mounted) return;
    setState(() => _credentialsError = null);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Identifiants enregistrés.')),
    );
  }

  Future<void> _forget() async {
    final confirmed = await confirmDelete(
      context,
      title: 'Oublier les identifiants WebDAV',
      message: 'Retire les identifiants enregistrés sur cet appareil et désactive la '
          'synchronisation. Rien n\'est supprimé sur le serveur ni sur ce téléphone.',
    );
    if (!confirmed || !mounted) return;
    await context.read<DatabaseProvider>().forgetWebDavCredentials();
    if (!mounted) return;
    setState(() {
      _enabled = false;
      _serverUrlController.clear();
      _usernameController.clear();
      _appPasswordController.clear();
      _remotePathController.clear();
      _testOk = null;
      _testMessage = null;
    });
  }

  String _statusLabel(SyncStatus status, DateTime? lastSyncedAt) {
    switch (status) {
      case SyncStatus.idle:
        return lastSyncedAt == null
            ? 'Jamais synchronisé'
            : 'Dernière synchronisation : '
                '${DateFormat('dd/MM/yyyy HH:mm').format(lastSyncedAt)}';
      case SyncStatus.syncing:
        return 'Synchronisation en cours...';
      case SyncStatus.conflictPending:
        return 'Conflit détecté - à résoudre depuis l\'icône de synchro du tableau de bord.';
      case SyncStatus.remoteMissing:
        return 'Le fichier n\'est plus trouvé sur le serveur.';
      case SyncStatus.error:
        return 'Échec de la dernière synchronisation.';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isAndroidPlatform) return const SizedBox.shrink();
    if (_loading) {
      return const Card(
        child: Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
      );
    }

    final dbProvider = context.watch<DatabaseProvider>();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Synchronisation WebDAV'),
              subtitle: const Text(
                'Garde la base synchronisée avec un serveur Nextcloud (ou tout serveur '
                'WebDAV), sans dépendre d\'une appli tierce.',
              ),
              value: _enabled,
              onChanged: _toggleEnabled,
            ),
            if (_enabled) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _serverUrlController,
                decoration: const InputDecoration(
                  labelText: 'Serveur',
                  hintText: 'https://mon-nextcloud.example.com',
                  isDense: true,
                ),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _usernameController,
                decoration: const InputDecoration(labelText: "Nom d'utilisateur", isDense: true),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _appPasswordController,
                decoration:
                    const InputDecoration(labelText: "Mot de passe d'application", isDense: true),
                obscureText: true,
                autofillHints: const [],
                enableSuggestions: false,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _remotePathController,
                decoration: const InputDecoration(
                  labelText: 'Chemin du fichier distant',
                  hintText: 'MoneyManager/MyMoney.mmb',
                  isDense: true,
                ),
              ),
              if (_credentialsError != null) ...[
                const SizedBox(height: 8),
                Text(_credentialsError!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              if (_testMessage != null) ...[
                const SizedBox(height: 8),
                Text(
                  _testMessage!,
                  style: TextStyle(
                    color: _testOk == true
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton(
                    onPressed: _testing ? null : _testConnection,
                    child: _testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Tester la connexion'),
                  ),
                  const Spacer(),
                  FilledButton(onPressed: _saveCredentials, child: const Text('Enregistrer')),
                ],
              ),
              const Divider(height: 32),
              Text('État', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              Text(_statusLabel(dbProvider.syncStatus, dbProvider.webDavLastSyncedAt)),
              if (dbProvider.syncStatus == SyncStatus.error && dbProvider.syncError != null) ...[
                const SizedBox(height: 4),
                Text(dbProvider.syncError!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: dbProvider.syncStatus == SyncStatus.syncing
                    ? null
                    : () => dbProvider.syncNow(),
                icon: dbProvider.syncStatus == SyncStatus.syncing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.sync),
                label: const Text('Synchroniser maintenant'),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _forget,
                  child: const Text('Oublier les identifiants'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
