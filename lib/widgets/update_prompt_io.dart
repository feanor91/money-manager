import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../services/update_checker.dart';

/// Only used from _downloadAndInstall's Android branch, to hand a
/// downloaded APK to MainActivity.kt's platform-channel handler - see that
/// file's doc comment for why this one step needs native code at all
/// (FileProvider.getUriForFile() has no Dart-callable equivalent).
const _apkInstallChannel =
    MethodChannel('com.bteuile.moneymanager.money_manager/apk_installer');

/// Desktop and Android both compile this file (dart.library.io covers
/// both) and, as of 2026-08-04, both get a real check-and-install flow -
/// see _downloadAndInstall for how the final step differs: a silent
/// installer run + app exit on desktop, versus handing the APK to
/// Android's system package installer (which - unlike desktop - always
/// requires an explicit user tap to confirm; Android has no fully-silent
/// equivalent, by design, for an app installing another package).
Future<void> checkForUpdatesAndPrompt(BuildContext context) async {
  if (!Platform.isWindows && !Platform.isAndroid) return;

  final info = await PackageInfo.fromPlatform();
  final release = await fetchLatestRelease();
  if (release == null) return;
  if (!isNewerVersion(release.version, info.version)) return;
  final assetUrl =
      Platform.isWindows ? release.windowsInstallerUrl : release.androidApkUrl;
  if (assetUrl == null) return;
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

  await _downloadAndInstall(context, assetUrl);
}

/// Downloads the update (an installer .exe on Windows, an .apk on Android)
/// into the temp dir, then hands it to whatever actually installs it - a
/// detached process launch + app exit on Windows (Inno Setup's installer
/// handles replacing the running app's files itself once it's the only
/// thing still holding them open), or the system package installer via
/// MainActivity.kt's platform channel on Android (which shows its own UI
/// on top rather than anything this app controls further - no reason to
/// exit this app first, unlike Windows). A failed download/install shows
/// an error and leaves the app running rather than exiting into nothing.
Future<void> _downloadAndInstall(BuildContext context, String assetUrl) async {
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
        .get(Uri.parse(assetUrl))
        .timeout(const Duration(minutes: 5));
    final tempDir = await getTemporaryDirectory();
    final fileName =
        Platform.isWindows ? 'MoneyManagerSetup.exe' : 'money-manager-update.apk';
    final file = File('${tempDir.path}/$fileName');
    await file.writeAsBytes(response.bodyBytes, flush: true);
    if (Platform.isWindows) {
      await Process.start(file.path, [], mode: ProcessStartMode.detached);
      exit(0);
    } else {
      await _apkInstallChannel
          .invokeMethod<void>('installApk', {'path': file.path});
      if (context.mounted) Navigator.of(context).pop(); // close the progress dialog
    }
  } catch (e) {
    if (context.mounted) {
      Navigator.of(context).pop(); // close the download progress dialog
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Échec du téléchargement : $e')),
      );
    }
  }
}
