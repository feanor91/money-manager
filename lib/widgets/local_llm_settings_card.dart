import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../services/nl_query/local_llm/cloud_llm_client.dart';
import '../services/nl_query/local_llm/local_llm_manager.dart';
import '../services/nl_query/local_llm/local_llm_support.dart';
import '../services/nl_query/local_llm/model_catalog.dart';
import '../services/nl_query/local_llm/sql_query_engine.dart'
    show defaultSqlSystemPrompt;
import 'searchable_select_field.dart';

/// The desktop build's own runtime/model folders (model_downloader.dart's
/// `getApplicationSupportDirectory()` + "local_llm_models"/"local_llm_runtime"
/// - both siblings under the same app-support base), spelled out with the
/// PowerShell `$env:APPDATA` variable rather than a real absolute path.
/// Backs the web settings card's copyable launch commands (2026-08-24 user
/// request): a literal path baked in here would embed *this machine's*
/// Windows username - `$env:APPDATA` resolves per-user at the moment the
/// command actually runs, so the exact same string is correct on anyone's
/// PC, not just the one this was written on. Only meaningful if the model
/// was already downloaded once through the desktop build (or the .gguf was
/// placed there by hand) - the web build itself never downloads anything
/// (see [LocalLlmSettingsCard]'s own doc comment).
const _appSupportBase = r'$env:APPDATA\com.bteuile.moneymanager\money_manager';

/// The exact PowerShell command to start `llama-server.exe` for [model],
/// matching local_llm_manager_io.dart's own `Process.start` arguments
/// (`-c 32768 -ngl 999`, i.e. the desktop build's own defaults) so a model
/// launched this way for the web build behaves identically to how the
/// desktop build would have launched it itself. `--host 0.0.0.0` (not
/// 127.0.0.1) so the server is reachable from another device on the same
/// network too (e.g. testing the web app from a phone) - still reachable
/// via 127.0.0.1 from the same PC.
String _launchCommandFor(LocalLlmModel model) =>
    '& "$_appSupportBase\\local_llm_runtime\\llama-server.exe" '
    '-m "$_appSupportBase\\local_llm_models\\${model.fileName}" '
    '--host 0.0.0.0 --port 8792 -c 32768 -ngl 999';

/// Settings card for the optional AI layer behind "Poser une question".
/// Three platform variants:
///
/// - Desktop (Windows): defaults to the full local-model setup (download,
///   runtime placement, spawned-server launch parameters) - a
///   [SegmentedButton] ("Sur cet ordinateur" / "Service cloud") lets the
///   user opt into the cloud backend below instead (2026-08-31).
/// - Web: defaults to pointing at a llama.cpp server the user runs
///   themselves on their PC (host/port + copyable PowerShell launch
///   commands) - the same [SegmentedButton] choice as desktop.
/// - Android: cloud only, no toggle - a phone can neither download a
///   model nor spawn a process (see [_buildAndroidCard]).
///
/// The cloud backend itself ([_buildCloudFields]) is identical everywhere
/// it appears: an OpenAI-compatible endpoint address, model name (with an
/// optional "Charger la liste des modèles" fetch), and API key - see
/// cloud_llm_client.dart.
class LocalLlmSettingsCard extends StatefulWidget {
  const LocalLlmSettingsCard({super.key});

  @override
  State<LocalLlmSettingsCard> createState() => _LocalLlmSettingsCardState();
}

class _LocalLlmSettingsCardState extends State<LocalLlmSettingsCard> {
  bool _loading = true;
  bool _enabled = false;
  String _selectedModelId = localLlmModels.first.id;
  bool _modelDownloaded = false;
  bool _runtimeAvailable = false;
  String _runtimePath = '';
  double? _downloadProgress;
  String? _downloadError;
  StreamSubscription<double?>? _downloadSub;

  final _hostController = TextEditingController();
  final _portController = TextEditingController();
  final _contextSizeController = TextEditingController();
  final _gpuLayersController = TextEditingController();
  String? _serverSettingsError;

  final _sqlPromptController = TextEditingController();

  bool _testingConnection = false;
  bool? _connectionOk;

  bool get _isWeb => kIsWeb;
  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Desktop/web only - whether "Poser une question" uses the cloud
  /// backend below instead of each platform's own default (desktop: its
  /// spawned local model; web: a remote llama.cpp server via host/port).
  /// Always true on Android without a toggle to flip - see
  /// [_buildAndroidCard]/[useCloudLlm]'s own doc comment.
  bool _useCloud = false;

  final _cloudEndpointController = TextEditingController();
  final _cloudModelController = TextEditingController();
  final _cloudApiKeyController = TextEditingController();
  bool _cloudApiKeyVisible = false;
  bool _applyingCloudSettings = false;

  /// Fetched via [_loadCloudModels] ("Charger la liste des modèles") -
  /// null until the user asks for it, so the field starts as a plain free-
  /// text entry (still usable without ever fetching anything, e.g. if the
  /// provider doesn't implement `/v1/models`) and only switches to a
  /// searchable dropdown once a real list is in hand.
  List<CloudLlmModelInfo>? _cloudModelOptions;
  bool _loadingModels = false;
  String? _modelsError;

  @override
  void initState() {
    super.initState();
    if (isLocalLlmSupported) _load();
  }

  @override
  void dispose() {
    _downloadSub?.cancel();
    _hostController.dispose();
    _portController.dispose();
    _contextSizeController.dispose();
    _gpuLayersController.dispose();
    _sqlPromptController.dispose();
    _cloudEndpointController.dispose();
    _cloudModelController.dispose();
    _cloudApiKeyController.dispose();
    super.dispose();
  }

  LocalLlmModel get _selectedModel =>
      localLlmModelById(_selectedModelId) ?? localLlmModels.first;

  Future<void> _load() async {
    final enabled = await isLocalLlmEnabled();
    final sqlPrompt = await localLlmSqlSystemPrompt();
    // Loaded unconditionally on every supported platform (not just when
    // _useCloud is already on) so the cloud fields are pre-filled and
    // ready the instant the user flips the mode toggle, rather than
    // needing a fresh fetch first.
    final cloudEndpoint = await cloudLlmEndpoint();
    final cloudModel = await cloudLlmModel();
    final cloudApiKey = await cloudLlmApiKey();

    if (_isAndroid) {
      if (!mounted) return;
      setState(() {
        _enabled = enabled;
        _cloudEndpointController.text = cloudEndpoint;
        _cloudModelController.text = cloudModel;
        _cloudApiKeyController.text = cloudApiKey;
        _sqlPromptController.text = sqlPrompt;
        _loading = false;
      });
      return;
    }

    final useCloud = await useCloudLlm();
    final host = await localLlmServerHost();
    final port = await localLlmServerPort();
    if (_isWeb) {
      if (!mounted) return;
      setState(() {
        _enabled = enabled;
        _useCloud = useCloud;
        _cloudEndpointController.text = cloudEndpoint;
        _cloudModelController.text = cloudModel;
        _cloudApiKeyController.text = cloudApiKey;
        _hostController.text = host;
        _portController.text = '$port';
        _sqlPromptController.text = sqlPrompt;
        _loading = false;
      });
      return;
    }
    final modelId = await selectedLocalLlmModelId() ?? localLlmModels.first.id;
    final downloaded = await isLocalLlmModelDownloaded(
        localLlmModelById(modelId) ?? localLlmModels.first);
    final runtimeAvailable = await isLocalLlmRuntimeAvailable();
    final runtimePath = await localLlmRuntimeFolderPath();
    final contextSize = await localLlmContextSize();
    final gpuLayers = await localLlmGpuLayers();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _useCloud = useCloud;
      _cloudEndpointController.text = cloudEndpoint;
      _cloudModelController.text = cloudModel;
      _cloudApiKeyController.text = cloudApiKey;
      _selectedModelId = modelId;
      _modelDownloaded = downloaded;
      _runtimeAvailable = runtimeAvailable;
      _runtimePath = runtimePath;
      _hostController.text = host;
      _portController.text = '$port';
      _contextSizeController.text = '$contextSize';
      _gpuLayersController.text = '$gpuLayers';
      _sqlPromptController.text = sqlPrompt;
      _loading = false;
    });
  }

  /// Flips [_useCloud] and persists it - see [useCloudLlm]/[setUseCloudLlm].
  /// Clears transient per-mode UI state (a stale "connexion réussie" from
  /// the mode just left over, a leftover model-list-fetch error) so
  /// switching modes never shows feedback that belonged to the other one.
  Future<void> _setUseCloud(bool value) async {
    await setUseCloudLlm(value);
    if (!mounted) return;
    setState(() {
      _useCloud = value;
      _connectionOk = null;
      _serverSettingsError = null;
      _modelsError = null;
    });
  }

  Future<void> _toggleEnabled(bool value) async {
    await setLocalLlmEnabled(value);
    if (!mounted) return;
    setState(() => _enabled = value);
  }

  Future<void> _selectModel(String id) async {
    await setSelectedLocalLlmModelId(id);
    final downloaded = await isLocalLlmModelDownloaded(
        localLlmModelById(id) ?? localLlmModels.first);
    if (!mounted) return;
    setState(() {
      _selectedModelId = id;
      _modelDownloaded = downloaded;
    });
  }

  void _startDownload() {
    setState(() {
      _downloadProgress = 0;
      _downloadError = null;
    });
    _downloadSub?.cancel();
    _downloadSub = downloadLocalLlmModel(_selectedModel).listen(
      (progress) {
        if (!mounted) return;
        setState(() => _downloadProgress = progress);
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _downloadProgress = null;
          _downloadError = e.toString();
        });
      },
      onDone: () async {
        final downloaded = await isLocalLlmModelDownloaded(_selectedModel);
        if (!mounted) return;
        setState(() {
          _downloadProgress = null;
          _modelDownloaded = downloaded;
        });
      },
    );
  }

  Future<void> _deleteModel() async {
    await deleteLocalLlmModel(_selectedModel);
    if (!mounted) return;
    setState(() => _modelDownloaded = false);
  }

  Future<void> _recheckRuntime() async {
    final available = await isLocalLlmRuntimeAvailable();
    if (!mounted) return;
    setState(() => _runtimeAvailable = available);
  }

  /// [_buildCloudFields]'s own "Tester la connexion" - deliberately built
  /// from whatever is currently typed (like [_loadCloudModels]), NOT the
  /// saved settings [_testConnection]/[isLocalLlmServerReachable] check.
  /// Found 2026-08-31 confusing a real user: after picking a model from
  /// "Charger la liste des modèles" (which does use live field values) and
  /// testing without pressing "Appliquer" first, the test failed even
  /// though everything on screen was correct - it was silently checking
  /// the *previous* saved endpoint/model/key instead.
  Future<void> _testCloudConnection() async {
    setState(() {
      _testingConnection = true;
      _connectionOk = null;
    });
    final client = CloudLlmClient(
      baseUrl: _cloudEndpointController.text.trim(),
      apiKey: _cloudApiKeyController.text.trim(),
      model: _cloudModelController.text.trim(),
    );
    try {
      final ok = await client.healthCheck();
      if (!mounted) return;
      setState(() {
        _testingConnection = false;
        _connectionOk = ok;
      });
    } finally {
      client.close();
    }
  }

  Future<void> _testConnection() async {
    setState(() {
      _testingConnection = true;
      _connectionOk = null;
    });
    final ok = await isLocalLlmServerReachable();
    if (!mounted) return;
    setState(() {
      _testingConnection = false;
      _connectionOk = ok;
    });
  }

  /// Finds the fetched [CloudLlmModelInfo] matching the currently-held
  /// model id ([_cloudModelController]'s text), so [SearchableSelectField]'s
  /// starting display text shows "(gratuit)" too when applicable, instead
  /// of just the bare id. Falls back to a synthetic non-free entry (rather
  /// than null) when the current id isn't in the freshly fetched list -
  /// e.g. a previously-saved model that this provider no longer lists, or
  /// one entered by hand - so that value is never silently lost from the
  /// field just because it fetched a model list afterward.
  CloudLlmModelInfo? _currentModelOption() {
    final currentId = _cloudModelController.text;
    if (currentId.isEmpty) return null;
    final options = _cloudModelOptions;
    if (options == null) return null;
    for (final m in options) {
      if (m.id == currentId) return m;
    }
    return CloudLlmModelInfo(id: currentId, isFree: false);
  }

  /// [SearchableSelectField.onTextChanged] fires with whatever the field
  /// currently *displays* - which, right after picking an option, is
  /// [CloudLlmModelInfo.displayLabel] ("id (gratuit)"), not the bare model
  /// id [_cloudModelController] must actually hold (it's sent to the API
  /// verbatim as the `model` field - see _applyCloudSettings/CloudLlmClient).
  /// This maps a label back to its real id when it exactly matches a known
  /// option, and passes anything else through unchanged (genuine free
  /// typing, or a provider-less manual entry).
  String _resolveModelId(String displayedText) {
    final options = _cloudModelOptions;
    if (options == null) return displayedText;
    for (final m in options) {
      if (m.displayLabel == displayedText) return m.id;
    }
    return displayedText;
  }

  /// Builds a throwaway [CloudLlmClient] from whatever is currently typed
  /// in the fields (not necessarily saved yet via "Appliquer") and asks it
  /// to list available models - see CloudLlmClient.fetchAvailableModels.
  /// Deliberately independent of "Appliquer": trying a model list is part
  /// of *filling in* the form, so it shouldn't require saving first.
  Future<void> _loadCloudModels() async {
    final endpoint = _cloudEndpointController.text.trim();
    if (endpoint.isEmpty) {
      setState(() =>
          _modelsError = "Renseigne d'abord l'adresse du service ci-dessus.");
      return;
    }
    setState(() {
      _loadingModels = true;
      _modelsError = null;
    });
    final client = CloudLlmClient(
      baseUrl: endpoint,
      apiKey: _cloudApiKeyController.text.trim(),
      model: '',
    );
    try {
      final models = await client.fetchAvailableModels();
      if (!mounted) return;
      setState(() {
        _loadingModels = false;
        _cloudModelOptions = models;
        if (models.isEmpty) {
          _modelsError = 'Ce service n\'a retourné aucun modèle.';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingModels = false;
        _modelsError =
            'Impossible de charger la liste - vérifie l\'adresse et la clé API.';
      });
    } finally {
      client.close();
    }
  }

  Future<void> _applyCloudSettings() async {
    final endpoint = _cloudEndpointController.text.trim();
    final model = _cloudModelController.text.trim();
    if (endpoint.isEmpty || model.isEmpty) {
      setState(() {
        _serverSettingsError =
            "Vérifie les valeurs : adresse et nom de modèle non vides.";
      });
      return;
    }
    setState(() => _applyingCloudSettings = true);
    await setCloudLlmEndpoint(endpoint);
    await setCloudLlmModel(model);
    await setCloudLlmApiKey(_cloudApiKeyController.text.trim());
    if (!mounted) return;
    setState(() {
      _applyingCloudSettings = false;
      _serverSettingsError = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text(
              'Réglages enregistrés - appliqués à la prochaine question.')),
    );
  }

  Future<void> _applyServerSettings() async {
    if (_isWeb) {
      final host = _hostController.text.trim();
      final port = int.tryParse(_portController.text.trim());
      if (host.isEmpty || port == null || port <= 0 || port > 65535) {
        setState(() {
          _serverSettingsError =
              'Vérifie les valeurs : hôte non vide, port entre 1 et 65535.';
        });
        return;
      }
      await setLocalLlmServerHost(host);
      await setLocalLlmServerPort(port);
      if (!mounted) return;
      setState(() => _serverSettingsError = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Réglages enregistrés - appliqués à la prochaine question.')),
      );
      return;
    }
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    final contextSize = int.tryParse(_contextSizeController.text.trim());
    final gpuLayers = int.tryParse(_gpuLayersController.text.trim());
    if (host.isEmpty ||
        port == null ||
        port <= 0 ||
        port > 65535 ||
        contextSize == null ||
        contextSize <= 0 ||
        gpuLayers == null ||
        gpuLayers < 0) {
      setState(() {
        _serverSettingsError =
            'Vérifie les valeurs : hôte non vide, port entre 1 et 65535, '
            'taille de contexte et couches GPU positives.';
      });
      return;
    }
    await setLocalLlmServerHost(host);
    await setLocalLlmServerPort(port);
    await setLocalLlmContextSize(contextSize);
    await setLocalLlmGpuLayers(gpuLayers);
    if (!mounted) return;
    setState(() => _serverSettingsError = null);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text(
              'Réglages enregistrés - appliqués à la prochaine question.')),
    );
  }

  Future<void> _saveSqlSystemPrompt() async {
    await setLocalLlmSqlSystemPrompt(_sqlPromptController.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content:
              Text('Prompt enregistré - appliqué à la prochaine question.')),
    );
  }

  void _resetSqlSystemPrompt() {
    setState(() => _sqlPromptController.text = defaultSqlSystemPrompt);
  }

  @override
  Widget build(BuildContext context) {
    if (!isLocalLlmSupported) return const SizedBox.shrink();
    if (_loading) {
      return const Card(
        child: Padding(
            padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
      );
    }

    if (_isWeb) return _buildWebCard(context);
    if (_isAndroid) return _buildAndroidCard(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('IA pour "Poser une question"'),
              subtitle: Text(_useCloud
                  ? 'Comprend des formulations plus libres que l\'analyseur intégré. '
                      'Le calcul est fait par un service IA en ligne - tes questions et les '
                      'données financières concernées quittent cet ordinateur pour y être '
                      'envoyées.'
                  : 'Comprend des formulations plus libres que l\'analyseur intégré. '
                      'Tourne entièrement sur cet ordinateur - rien n\'est jamais envoyé en ligne.'),
              value: _enabled,
              onChanged: _toggleEnabled,
            ),
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  label: Text('Sur cet ordinateur'),
                  icon: Icon(Icons.computer_outlined),
                ),
                ButtonSegment(
                  value: true,
                  label: Text('Service cloud'),
                  icon: Icon(Icons.cloud_outlined),
                ),
              ],
              selected: {_useCloud},
              onSelectionChanged: (s) => _setUseCloud(s.first),
            ),
            const SizedBox(height: 8),
            if (_useCloud)
              _buildCloudFields(context)
            else ...[
              Text('Modèle', style: Theme.of(context).textTheme.labelLarge),
              for (final model in localLlmModels)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(
                    model.id == _selectedModelId
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  title: Text(model.label),
                  subtitle: Text(model.description),
                  onTap: () => _selectModel(model.id),
                ),
              const SizedBox(height: 8),
              if (_downloadProgress != null) ...[
                LinearProgressIndicator(
                    value: _downloadProgress == 0 ? null : _downloadProgress),
                const SizedBox(height: 8),
              ],
              if (_downloadError != null) ...[
                Text(
                  'Erreur : $_downloadError',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(height: 8),
              ],
              if (_modelDownloaded)
                OutlinedButton.icon(
                  onPressed: _deleteModel,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Supprimer le modèle téléchargé'),
                )
              else
                FilledButton.icon(
                  onPressed: _downloadProgress != null ? null : _startDownload,
                  icon: const Icon(Icons.download_outlined),
                  label: Text(
                      'Télécharger (~${_approxSizeLabel(_selectedModel.approxSizeBytes)})'),
                ),
              const Divider(height: 32),
              Text('Serveur llama.cpp',
                  style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Text(
                _runtimeAvailable
                    ? 'Détecté - l\'IA locale peut être utilisée dès qu\'un modèle est téléchargé. '
                        "L'appli démarre et arrête ce serveur elle-même, en arrière-plan."
                    : 'Non détecté - cette étape est manuelle : télécharge la dernière release '
                        'Windows de llama.cpp (voir github.com/ggml-org/llama.cpp/releases, un '
                        'fichier "llama-*-bin-win-*.zip" correspondant à ton processeur) et place '
                        'llama-server.exe, avec les .dll qui l\'accompagnent dans la même archive, '
                        'dans ce dossier :',
              ),
              if (!_runtimeAvailable) ...[
                const SizedBox(height: 8),
                SelectableText(_runtimePath,
                    style: const TextStyle(fontFamily: 'monospace')),
              ],
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _recheckRuntime,
                icon: const Icon(Icons.refresh),
                label: const Text('Vérifier à nouveau'),
              ),
              const Divider(height: 32),
              Text('Paramètres du serveur',
                  style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              Text(
                "Un changement redémarre le serveur local à la prochaine question, pas "
                'immédiatement.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _hostController,
                      decoration: const InputDecoration(
                          labelText: 'Hôte', isDense: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _portController,
                      decoration: const InputDecoration(
                          labelText: 'Port', isDense: true),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _contextSizeController,
                      decoration: const InputDecoration(
                          labelText: 'Taille de contexte', isDense: true),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _gpuLayersController,
                      decoration: const InputDecoration(
                        labelText: 'Couches sur GPU (0 = CPU seul)',
                        isDense: true,
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              if (_serverSettingsError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _serverSettingsError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _applyServerSettings,
                  child: const Text('Appliquer'),
                ),
              ),
            ],
            const Divider(height: 32),
            Text('Prompt IA (accès complet aux données)',
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            const Text(
              "Utilisé quand la question posée dans \"Poser une question\" ne correspond à aucun "
              "des cas déjà prévus (solde, revenus/dépenses, prévision...) : l'IA écrit elle-même "
              'une requête sur le schéma de la base, en lecture seule, puis formule la réponse à '
              'partir du résultat réel - jamais de chiffre inventé. Modifie ce texte seulement si '
              "tu comprends ce que tu fais : c'est ce qui empêche l'IA de dévier de ce cadre.",
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _sqlPromptController,
              maxLines: 14,
              minLines: 6,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _resetSqlSystemPrompt,
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Réinitialiser'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _saveSqlSystemPrompt,
                  child: const Text('Enregistrer'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The cloud-backend config block (endpoint/key/model + "Charger la liste
  /// des modèles" + "Appliquer"/"Tester la connexion") - shared verbatim by
  /// [_buildAndroidCard] (Android's *only* option, see its own doc comment)
  /// and, since 2026-08-31, an opt-in alternative on desktop/web too (see
  /// [_useCloud]/[useCloudLlm]) for exactly the same reason: a real hosted
  /// provider, or the user's own PC reached remotely (its llama-server
  /// started with `--api-key`, exposed the same way the web app itself
  /// already is - see CLAUDE.md's DDNS/port-forward note) look identical
  /// from here, both being an OpenAI-compatible HTTP endpoint
  /// (cloud_llm_client.dart).
  Widget _buildCloudFields(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Service IA', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        const Text(
          'Adresse du service (compatible API OpenAI), par exemple '
          '"https://api.openai.com/v1", "https://api.mistral.ai/v1", ou l\'adresse de '
          'ton propre PC si son serveur IA est accessible depuis l\'extérieur (ex : '
          '"https://tonadresse.ddns.net:8793/v1"). Nom du modèle et clé API fournis par '
          'le service choisi (ou par toi-même si c\'est ton PC).',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _cloudEndpointController,
          decoration: const InputDecoration(
              labelText: 'Adresse du service', isDense: true),
          keyboardType: TextInputType.url,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _cloudApiKeyController,
          decoration: InputDecoration(
            labelText: 'Clé API',
            isDense: true,
            suffixIcon: IconButton(
              icon: Icon(_cloudApiKeyVisible
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined),
              onPressed: () =>
                  setState(() => _cloudApiKeyVisible = !_cloudApiKeyVisible),
            ),
          ),
          obscureText: !_cloudApiKeyVisible,
          autofillHints: const [],
          enableSuggestions: false,
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _cloudModelOptions == null
                  ? TextField(
                      controller: _cloudModelController,
                      decoration: const InputDecoration(
                          labelText: 'Nom du modèle', isDense: true),
                    )
                  : SearchableSelectField<CloudLlmModelInfo>(
                      label: 'Nom du modèle',
                      options: _cloudModelOptions!,
                      labelOf: (m) => m.displayLabel,
                      initialValue: _currentModelOption(),
                      onSelected: (m) =>
                          _cloudModelController.text = m?.id ?? '',
                      onTextChanged: (text) => _cloudModelController.text =
                          _resolveModelId(text),
                    ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Charger la liste des modèles disponibles',
              onPressed: _loadingModels ? null : _loadCloudModels,
              icon: _loadingModels
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ],
        ),
        if (_modelsError != null) ...[
          const SizedBox(height: 4),
          Text(
            _modelsError!,
            style: TextStyle(
                color: Theme.of(context).colorScheme.error, fontSize: 12),
          ),
        ],
        if (_serverSettingsError != null) ...[
          const SizedBox(height: 8),
          Text(
            _serverSettingsError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton(
              onPressed: _applyingCloudSettings ? null : _applyCloudSettings,
              child: _applyingCloudSettings
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Appliquer'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _testingConnection ? null : _testCloudConnection,
              icon: _testingConnection
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.network_check),
              label: const Text('Tester la connexion'),
            ),
          ],
        ),
        if (_connectionOk != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                _connectionOk! ? Icons.check_circle : Icons.error,
                color: _connectionOk!
                    ? Colors.green
                    : Theme.of(context).colorScheme.error,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _connectionOk!
                      ? 'Connexion réussie - le service répond.'
                      : 'Connexion impossible - vérifie l\'adresse, le modèle et la clé API.',
                  style: TextStyle(
                    color: _connectionOk!
                        ? Colors.green
                        : Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// Android's whole "Poser une question" AI setup, in one card - unlike
  /// desktop/web there is no local model, no spawned process, and no
  /// "point at a remote llama.cpp server" native-protocol option: a phone
  /// only ever talks to an OpenAI-compatible HTTP endpoint, so there is no
  /// mode toggle here (see [_buildCloudFields]) - unlike desktop/web, which
  /// keep their own existing option alongside this one.
  Widget _buildAndroidCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('IA pour "Poser une question"'),
              subtitle: const Text(
                'Comprend des formulations plus libres que l\'analyseur intégré. '
                'Le calcul est fait par un service IA en ligne (un fournisseur cloud, ou ton '
                'propre PC accessible à distance) - contrairement aux autres versions de '
                'l\'appli, tes questions et les données financières concernées quittent cet '
                'appareil pour y être envoyées.',
              ),
              value: _enabled,
              onChanged: _toggleEnabled,
            ),
            const SizedBox(height: 8),
            _buildCloudFields(context),
            const Divider(height: 32),
            Text('Prompt IA (accès complet aux données)',
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            const Text(
              "Utilisé quand la question posée dans \"Poser une question\" ne correspond à aucun "
              "des cas déjà prévus (solde, revenus/dépenses, prévision...) : l'IA écrit elle-même "
              'une requête sur le schéma de la base, en lecture seule, puis formule la réponse à '
              'partir du résultat réel - jamais de chiffre inventé. Modifie ce texte seulement si '
              "tu comprends ce que tu fais : c'est ce qui empêche l'IA de dévier de ce cadre.",
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _sqlPromptController,
              maxLines: 14,
              minLines: 6,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _resetSqlSystemPrompt,
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Réinitialiser'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _saveSqlSystemPrompt,
                  child: const Text('Enregistrer'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWebCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('IA pour "Poser une question"'),
              subtitle: Text(_useCloud
                  ? 'Comprend des formulations plus libres que l\'analyseur intégré. '
                      'Le calcul est fait par un service IA en ligne - tes questions et les '
                      'données financières concernées quittent cet ordinateur pour y être '
                      'envoyées.'
                  : 'Comprend des formulations plus libres que l\'analyseur intégré. '
                      'Le calcul est fait par un serveur IA que tu lances sur ton ordinateur - '
                      'rien n\'est envoyé en ligne.'),
              value: _enabled,
              onChanged: _toggleEnabled,
            ),
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  label: Text('Mon PC'),
                  icon: Icon(Icons.computer_outlined),
                ),
                ButtonSegment(
                  value: true,
                  label: Text('Service cloud'),
                  icon: Icon(Icons.cloud_outlined),
                ),
              ],
              selected: {_useCloud},
              onSelectionChanged: (s) => _setUseCloud(s.first),
            ),
            const SizedBox(height: 8),
            if (_useCloud)
              _buildCloudFields(context)
            else ...[
              Text('Serveur IA', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              const Text(
                'Lance le serveur IA sur ton ordinateur (PowerShell) avec l\'une des '
                'commandes ci-dessous, selon le modèle voulu - copie-la puis colle-la '
                'dans une fenêtre PowerShell. Elles supposent que le modèle a déjà été '
                'téléchargé une fois via la version bureau (Paramètres IA > télécharger '
                'un modèle) ; si tu l\'as placé ailleurs toi-même, remplace le chemin '
                'après "-m".\n\n'
                'Puis renseigne l\'adresse ci-dessous. Si la page web est ouverte sur le '
                'même ordinateur que le serveur, « 127.0.0.1 » suffit. Si elle est ouverte '
                'depuis un autre appareil (téléphone, autre PC), utilise l\'adresse IP de '
                'cet ordinateur sur le réseau local.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              for (final model in localLlmModels) ...[
                _LaunchCommandBlock(model: model),
                const SizedBox(height: 8),
              ],
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _hostController,
                      decoration: const InputDecoration(
                          labelText: 'Hôte', isDense: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _portController,
                      decoration: const InputDecoration(
                          labelText: 'Port', isDense: true),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              if (_serverSettingsError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _serverSettingsError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  FilledButton(
                    onPressed: _applyServerSettings,
                    child: const Text('Appliquer'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _testingConnection ? null : _testConnection,
                    icon: _testingConnection
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.network_check),
                    label: const Text('Tester la connexion'),
                  ),
                ],
              ),
              if (_connectionOk != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      _connectionOk! ? Icons.check_circle : Icons.error,
                      color: _connectionOk!
                          ? Colors.green
                          : Theme.of(context).colorScheme.error,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _connectionOk!
                          ? 'Connexion réussie - le serveur IA répond.'
                          : 'Connexion impossible - vérifie que le serveur est bien lancé et que l\'adresse est correcte.',
                      style: TextStyle(
                        color: _connectionOk!
                            ? Colors.green
                            : Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ),
              ],
            ],
            const Divider(height: 32),
            Text('Prompt IA (accès complet aux données)',
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            const Text(
              "Utilisé quand la question posée dans \"Poser une question\" ne correspond à aucun "
              "des cas déjà prévus (solde, revenus/dépenses, prévision...) : l'IA écrit elle-même "
              'une requête sur le schéma de la base, en lecture seule, puis formule la réponse à '
              'partir du résultat réel - jamais de chiffre inventé. Modifie ce texte seulement si '
              "tu comprends ce que tu fais : c'est ce qui empêche l'IA de dévier de ce cadre.",
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _sqlPromptController,
              maxLines: 14,
              minLines: 6,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _resetSqlSystemPrompt,
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Réinitialiser'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _saveSqlSystemPrompt,
                  child: const Text('Enregistrer'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One model's launch command in a monospace, selectable box with a copy
/// button - so the web settings card's commands (see [_launchCommandFor])
/// can go straight from here into a PowerShell window without retyping.
class _LaunchCommandBlock extends StatelessWidget {
  final LocalLlmModel model;

  const _LaunchCommandBlock({required this.model});

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: _launchCommandFor(model)));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Commande copiée.'), duration: Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(model.label,
                    style: Theme.of(context).textTheme.labelMedium),
                const SizedBox(height: 4),
                SelectableText(
                  _launchCommandFor(model),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Copier la commande',
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () => _copy(context),
          ),
        ],
      ),
    );
  }
}

String _approxSizeLabel(int bytes) {
  final gb = bytes / (1024 * 1024 * 1024);
  return '${gb.toStringAsFixed(1)} Go';
}
