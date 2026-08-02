import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../services/update_checker.dart';

/// Android also compiles this file (dart.library.io covers both), but only
/// has an APK download URL to offer, not an install trigger yet - Android
/// requires REQUEST_INSTALL_PACKAGES + a FileProvider to launch the system
/// installer, deliberately left for a separate change (see ROADMAP.md)
/// rather than half-building it alongside the desktop path.
Future<void> checkForUpdatesAndPrompt(BuildContext context) async {
  if (!Platform.isWindows) return;

  final info = await PackageInfo.fromPlatform();
  final release = await fetchLatestRelease();
  if (release == null) return;
  if (!isNewerVersion(release.version, info.version)) return;
  final installerUrl = release.windowsInstallerUrl;
  if (installerUrl == null) return;
  if (!context.mounted) return;

  final shouldInstall = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Mise à jour disponible'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Version ${release.version} disponible '
                '(vous avez ${info.version}).'),
            if (release.notes != null &&
                release.notes!.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(release.notes!.trim()),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Plus tard'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Installer'),
        ),
      ],
    ),
  );
  if (shouldInstall != true || !context.mounted) return;

  await _downloadAndRunInstaller(context, installerUrl);
}

/// Downloads the installer, launches it detached (so it survives after this
/// process exits), then closes this app - Inno Setup's installer handles
/// replacing the running app's files itself once it's the only thing still
/// holding them open. A failed download/launch shows an error and leaves
/// the app running rather than exiting into nothing.
Future<void> _downloadAndRunInstaller(
    BuildContext context, String installerUrl) async {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 16),
          Text('Téléchargement de la mise à jour...'),
        ],
      ),
    ),
  );

  try {
    final response = await http
        .get(Uri.parse(installerUrl))
        .timeout(const Duration(minutes: 5));
    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/MoneyManagerSetup.exe');
    await file.writeAsBytes(response.bodyBytes, flush: true);
    await Process.start(file.path, [], mode: ProcessStartMode.detached);
    exit(0);
  } catch (e) {
    if (context.mounted) {
      Navigator.of(context).pop(); // close the download progress dialog
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Échec du téléchargement : $e')),
      );
    }
  }
}
