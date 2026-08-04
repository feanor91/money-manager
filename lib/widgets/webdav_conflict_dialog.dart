import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/webdav/webdav_sync_service.dart';
import '../state/database_provider.dart';

/// What tapping the dashboard's sync icon or HomeShell's sync banner
/// actually does - shared between both, since [SyncStatus] can be reached
/// from either surface and the handling must stay identical: a plain sync
/// when idle/after a previous error, fetching what's needed then opening
/// the conflict dialog when one was detected, or a lighter confirm when the
/// remote file has gone missing. Never auto-resolves a conflict/
/// remoteMissing - both always require this explicit tap.
Future<void> handleWebDavSyncTap(BuildContext context) async {
  final dbProvider = context.read<DatabaseProvider>();
  switch (dbProvider.syncStatus) {
    case SyncStatus.idle:
    case SyncStatus.error:
      await dbProvider.syncNow();
    case SyncStatus.syncing:
      break;
    case SyncStatus.conflictPending:
      final info = await dbProvider.prepareConflictResolution();
      if (info == null || !context.mounted) return;
      final choice = await showWebDavConflictDialog(context, info: info);
      if (choice == null || !context.mounted) return;
      await dbProvider.resolveConflict(choice);
    case SyncStatus.remoteMissing:
      final reupload = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Fichier introuvable sur le serveur'),
          content: const Text(
            'Le fichier distant a disparu (supprimé ou déplacé) depuis la dernière '
            'synchronisation. Le renvoyer depuis ce téléphone ?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Ignorer pour l\'instant'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Renvoyer'),
            ),
          ],
        ),
      );
      if (reupload == null || !context.mounted) return;
      await dbProvider.resolveWebDavRemoteMissing(reupload: reupload);
  }
}

/// Shown when WebDAV sync detects the .mmb changed on both sides since the
/// last successful sync (see DatabaseProvider.prepareConflictResolution) -
/// never guesses, always asks. `barrierDismissible: false`: dismissing via
/// outside-tap/back would leave the conflict silently unresolved rather
/// than genuinely cancelled, and there's no safe default to fall back to.
Future<ConflictChoice?> showWebDavConflictDialog(
  BuildContext context, {
  required SyncConflictInfo info,
}) {
  return showDialog<ConflictChoice>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('Conflit de synchronisation'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'La base a été modifiée à la fois sur ce téléphone et sur le '
            'serveur depuis la dernière synchronisation. Laquelle voulez-vous '
            'garder ?',
          ),
          const SizedBox(height: 16),
          _VersionSummary(label: 'Ce téléphone', sizeBytes: info.localBytes.length),
          const SizedBox(height: 8),
          _VersionSummary(
            label: 'Serveur',
            sizeBytes: info.remoteBytes.length,
            lastModifiedRaw: info.remoteInfo?.lastModifiedRaw,
          ),
          const SizedBox(height: 12),
          Text(
            'La version que vous ne choisirez pas sera d\'abord sauvegardée '
            'dans le dossier "backup", au cas où.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(ConflictChoice.keepLocal),
          child: const Text('Garder ce téléphone'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(ConflictChoice.keepRemote),
          child: const Text('Garder le serveur'),
        ),
      ],
    ),
  );
}

class _VersionSummary extends StatelessWidget {
  final String label;
  final int sizeBytes;
  final String? lastModifiedRaw;

  const _VersionSummary({
    required this.label,
    required this.sizeBytes,
    this.lastModifiedRaw,
  });

  @override
  Widget build(BuildContext context) {
    final sizeKb = (sizeBytes / 1024).toStringAsFixed(0);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.circle, size: 8, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelLarge),
              Text(
                '$sizeKb Ko${lastModifiedRaw != null ? ' - $lastModifiedRaw' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
