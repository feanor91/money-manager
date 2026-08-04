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
      if (!context.mounted) return;
      if (info == null) {
        // Two different reasons this can come back empty - tell them apart
        // rather than silently doing nothing either way, which is exactly
        // what looked like a bug (tap "Résoudre", nothing visibly happens):
        // either the fetch itself failed (dbProvider.syncError set), or -
        // the far more likely case on a first-ever sync - the phone and
        // server copies turned out to be genuinely byte-identical despite
        // looking different (e.g. two WebDAV identities for the same
        // content), so DatabaseProvider already resolved it and there was
        // never anything to actually choose between.
        final error = dbProvider.syncError;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error != null
                  ? 'Échec de la vérification du conflit : $error'
                  : 'Les deux versions étaient en fait identiques - rien à choisir, '
                      'synchronisation terminée.',
            ),
          ),
        );
        return;
      }
      final choice = await showWebDavConflictDialog(context, info: info);
      if (choice == null || !context.mounted) return;
      await dbProvider.resolveConflict(choice);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(dbProvider.syncError != null
              ? 'Échec de la résolution : ${dbProvider.syncError}'
              : choice == ConflictChoice.keepLocal
                  ? 'Version du téléphone envoyée sur le serveur.'
                  : 'Version du serveur récupérée.'),
        ),
      );
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
