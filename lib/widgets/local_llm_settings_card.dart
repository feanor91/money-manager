import 'dart:async';

import 'package:flutter/material.dart';

import '../services/nl_query/local_llm/local_llm_manager.dart';
import '../services/nl_query/local_llm/local_llm_support.dart';
import '../services/nl_query/local_llm/model_catalog.dart';
import '../services/nl_query/local_llm/sql_query_engine.dart' show defaultSqlSystemPrompt;

/// Settings card for the optional, Windows-only local-AI layer behind
/// "Poser une question" - hidden entirely (returns nothing) on any other
/// platform. Two separate readiness steps, shown explicitly rather than
/// collapsed into one toggle, because they really are independent and a
/// user stuck on one needs to see which: downloading the model (automatic,
/// this card does it) and placing a compatible native runtime (manual -
/// see local_llm_manager_io.dart's doc comment for why that step can't be
/// automated today).
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
    super.dispose();
  }

  LocalLlmModel get _selectedModel => localLlmModelById(_selectedModelId) ?? localLlmModels.first;

  Future<void> _load() async {
    final enabled = await isLocalLlmEnabled();
    final modelId = await selectedLocalLlmModelId() ?? localLlmModels.first.id;
    final downloaded = await isLocalLlmModelDownloaded(localLlmModelById(modelId) ?? localLlmModels.first);
    final runtimeAvailable = await isLocalLlmRuntimeAvailable();
    final runtimePath = await localLlmRuntimeFolderPath();
    final host = await localLlmServerHost();
    final port = await localLlmServerPort();
    final contextSize = await localLlmContextSize();
    final gpuLayers = await localLlmGpuLayers();
    final sqlPrompt = await localLlmSqlSystemPrompt();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
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

  Future<void> _toggleEnabled(bool value) async {
    await setLocalLlmEnabled(value);
    if (!mounted) return;
    setState(() => _enabled = value);
  }

  Future<void> _selectModel(String id) async {
    await setSelectedLocalLlmModelId(id);
    final downloaded = await isLocalLlmModelDownloaded(localLlmModelById(id) ?? localLlmModels.first);
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

  /// Validates and saves all four server launch settings together, rather
  /// than as each field changes - a half-typed port number is not a value
  /// worth persisting (or restarting the running server over) on every
  /// keystroke.
  Future<void> _applyServerSettings() async {
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    final contextSize = int.tryParse(_contextSizeController.text.trim());
    final gpuLayers = int.tryParse(_gpuLayersController.text.trim());
    if (host.isEmpty ||
        port == null || port <= 0 || port > 65535 ||
        contextSize == null || contextSize <= 0 ||
        gpuLayers == null || gpuLayers < 0) {
      setState(() {
        _serverSettingsError = 'Vérifie les valeurs : hôte non vide, port entre 1 et 65535, '
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
      const SnackBar(content: Text('Réglages enregistrés - appliqués à la prochaine question.')),
    );
  }

  Future<void> _saveSqlSystemPrompt() async {
    await setLocalLlmSqlSystemPrompt(_sqlPromptController.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Prompt enregistré - appliqué à la prochaine question.')),
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
        child: Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('IA locale pour "Poser une question"'),
              subtitle: const Text(
                'Comprend des formulations plus libres que l\'analyseur intégré. '
                'Tourne entièrement sur cet ordinateur - rien n\'est jamais envoyé en ligne.',
              ),
              value: _enabled,
              onChanged: _toggleEnabled,
            ),
            const SizedBox(height: 8),
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
              LinearProgressIndicator(value: _downloadProgress == 0 ? null : _downloadProgress),
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
                label: Text('Télécharger (~${_approxSizeLabel(_selectedModel.approxSizeBytes)})'),
              ),
            const Divider(height: 32),
            Text('Serveur llama.cpp', style: Theme.of(context).textTheme.labelLarge),
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
              SelectableText(_runtimePath, style: const TextStyle(fontFamily: 'monospace')),
            ],
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _recheckRuntime,
              icon: const Icon(Icons.refresh),
              label: const Text('Vérifier à nouveau'),
            ),
            const Divider(height: 32),
            Text('Paramètres du serveur', style: Theme.of(context).textTheme.labelLarge),
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
                    decoration: const InputDecoration(labelText: 'Hôte', isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _portController,
                    decoration: const InputDecoration(labelText: 'Port', isDense: true),
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
                    decoration:
                        const InputDecoration(labelText: 'Taille de contexte', isDense: true),
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
            const Divider(height: 32),
            Text('Prompt IA (accès complet aux données)', style: Theme.of(context).textTheme.labelLarge),
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

String _approxSizeLabel(int bytes) {
  final gb = bytes / (1024 * 1024 * 1024);
  return '${gb.toStringAsFixed(1)} Go';
}
