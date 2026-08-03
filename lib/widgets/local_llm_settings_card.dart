import 'dart:async';

import 'package:flutter/material.dart';

import '../services/nl_query/local_llm/local_llm_manager.dart';
import '../services/nl_query/local_llm/local_llm_support.dart';
import '../services/nl_query/local_llm/model_catalog.dart';

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

  @override
  void initState() {
    super.initState();
    if (isLocalLlmSupported) _load();
  }

  @override
  void dispose() {
    _downloadSub?.cancel();
    super.dispose();
  }

  LocalLlmModel get _selectedModel => localLlmModelById(_selectedModelId) ?? localLlmModels.first;

  Future<void> _load() async {
    final enabled = await isLocalLlmEnabled();
    final modelId = await selectedLocalLlmModelId() ?? localLlmModels.first.id;
    final downloaded = await isLocalLlmModelDownloaded(localLlmModelById(modelId) ?? localLlmModels.first);
    final runtimeAvailable = await isLocalLlmRuntimeAvailable();
    final runtimePath = await localLlmRuntimeFolderPath();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _selectedModelId = modelId;
      _modelDownloaded = downloaded;
      _runtimeAvailable = runtimeAvailable;
      _runtimePath = runtimePath;
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
