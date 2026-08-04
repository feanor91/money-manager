import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// True on Android specifically - see database_provider.dart's `_isAndroid`
/// for why this check (not dart:io's Platform.isAndroid) is required in a
/// file that also compiles for web.
bool get _isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Local (device-only) notification shown when a WebDAV sync happens while
/// the app isn't in the foreground - see app.dart's `paused` handling. The
/// in-app banner (DatabaseProvider.syncMessage) is useless for that case:
/// nobody is looking at the screen when a background sync completes, which
/// is exactly the scenario the user asked about 2026-08-04 ("est-ce que ça
/// synchronise dans l'autre sens, et peut-on être prévenu ?").
///
/// Android only, by design - same scope as the WebDAV feature itself.
/// Fully best-effort: nothing here may ever throw into the fire-and-forget
/// lifecycle callback that triggers it, since the sync it's confirming has
/// already succeeded regardless of whether this notification makes it to
/// the screen.
class SyncNotificationService {
  SyncNotificationService._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static bool _permissionRequested = false;

  static Future<void> _ensureInitialized() async {
    if (_initialized) return;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await _plugin.initialize(settings: settings);
    _initialized = true;
  }

  static Future<void> showSyncMessage(String message) async {
    if (!_isAndroid) return;
    try {
      await _ensureInitialized();
      if (!_permissionRequested) {
        // Android 13+ only prompts once per install either way - safe to
        // call on every notification attempt, but gated here so we don't
        // even try the platform channel call repeatedly once it's settled.
        _permissionRequested = true;
        await _plugin
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      }
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          'webdav_sync',
          'Synchronisation',
          channelDescription:
              'Confirmation quand une synchronisation WebDAV a eu lieu en arrière-plan',
          importance: Importance.low,
          priority: Priority.low,
        ),
      );
      // Fixed id: a new sync confirmation replaces the previous one rather
      // than piling up in the notification shade every time the app closes.
      await _plugin.show(
        id: 0,
        title: 'Money Manager',
        body: message,
        notificationDetails: details,
      );
    } catch (_) {
      // Best-effort, see class doc comment.
    }
  }
}
