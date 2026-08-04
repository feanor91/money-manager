import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../state/app_preferences.dart';

/// WebDAV connection details for this device. Deliberately never synced
/// anywhere (not in the .mmb's companion settings file, not via this
/// feature) - each device configures its own, same as the SAF folder grant
/// it pairs with.
class WebDavCredentials {
  final String serverUrl;
  final String username;
  final String appPassword;
  final String remotePath;

  const WebDavCredentials({
    this.serverUrl = '',
    this.username = '',
    this.appPassword = '',
    this.remotePath = '',
  });

  bool get isComplete =>
      serverUrl.isNotEmpty &&
      username.isNotEmpty &&
      appPassword.isNotEmpty &&
      remotePath.isNotEmpty;
}

/// What was true as of the last successful sync - the whole basis for
/// [decideSyncAction] telling "genuinely changed" apart from "just looks
/// different because we've never compared before". See
/// webdav_sync_decision.dart for how this gets used.
class WebDavSyncMarker {
  final String? lastSyncedContentHash;
  final String? lastSyncedRemoteIdentity;
  final DateTime? lastSyncedAt;

  const WebDavSyncMarker({
    this.lastSyncedContentHash,
    this.lastSyncedRemoteIdentity,
    this.lastSyncedAt,
  });

  static const empty = WebDavSyncMarker();
}

const _keyEnabled = 'webdav_enabled';
const _keyServerUrl = 'webdav_server_url';
const _keyUsername = 'webdav_username';
const _keyAppPassword = 'webdav_app_password';
const _keyRemotePath = 'webdav_remote_path';
const _keyLastSyncedContentHash = 'webdav_last_synced_content_hash';
const _keyLastSyncedRemoteIdentity = 'webdav_last_synced_remote_identity';
const _keyLastSyncedAt = 'webdav_last_synced_at';

/// Device-local, encrypted-at-rest storage for WebDAV credentials and the
/// sync marker - reuses [EncryptedFilePreferences] (same AES codec already
/// used for the PIN hash and the .mmb's own companion settings file)
/// against a brand new file in this app's own support directory, entirely
/// separate from the SAF-granted folder the .mmb and its companion settings
/// file live in. That separation is what makes "app settings never sync"
/// true by construction: this store is never reached through
/// AndroidFileLink at all, only through path_provider's
/// getApplicationSupportDirectory() - the same directory
/// local_llm/model_downloader.dart already uses for its own unrelated
/// per-device asset (see that file's doc comment for the same reasoning).
class WebDavSyncStore {
  final AppPreferences _prefs;

  WebDavSyncStore._(this._prefs);

  static Future<WebDavSyncStore> load() async {
    final base = await getApplicationSupportDirectory();
    if (!await base.exists()) await base.create(recursive: true);
    final path = '${base.path}${Platform.pathSeparator}webdav_sync.dat';
    return forTestingAtPath(path);
  }

  /// Bypasses getApplicationSupportDirectory() (a path_provider platform
  /// channel call unavailable in a plain `flutter_test` run, same reasoning
  /// as AppPreferences.forTestingAtPath) to load directly from an arbitrary
  /// path - despite the name, [load] itself is just a thin wrapper around
  /// this with a real device path, not a separate implementation.
  @visibleForTesting
  static Future<WebDavSyncStore> forTestingAtPath(String path) async {
    final prefs = await EncryptedFilePreferences.load(path);
    return WebDavSyncStore._(prefs);
  }

  bool get enabled => _prefs.getInt(_keyEnabled) == 1;
  Future<void> setEnabled(bool value) => _prefs.setInt(_keyEnabled, value ? 1 : 0);

  WebDavCredentials get credentials => WebDavCredentials(
        serverUrl: _prefs.getString(_keyServerUrl) ?? '',
        username: _prefs.getString(_keyUsername) ?? '',
        appPassword: _prefs.getString(_keyAppPassword) ?? '',
        remotePath: _prefs.getString(_keyRemotePath) ?? '',
      );

  /// Clears the stored sync marker whenever the server/username/remotePath
  /// actually changed (an unchanged app password alone doesn't need this) -
  /// a marker only means something relative to one specific remote file, so
  /// reusing it against a newly-pointed-at remote would let a stale
  /// identity comparison silently mistrigger an automatic push/pull against
  /// completely unrelated content.
  Future<void> saveCredentials(WebDavCredentials creds) async {
    final previous = credentials;
    final pointsElsewhere = previous.serverUrl != creds.serverUrl ||
        previous.username != creds.username ||
        previous.remotePath != creds.remotePath;
    await _prefs.setString(_keyServerUrl, creds.serverUrl);
    await _prefs.setString(_keyUsername, creds.username);
    await _prefs.setString(_keyAppPassword, creds.appPassword);
    await _prefs.setString(_keyRemotePath, creds.remotePath);
    if (pointsElsewhere) await clearMarker();
  }

  Future<void> forgetCredentials() async {
    await _prefs.remove(_keyServerUrl);
    await _prefs.remove(_keyUsername);
    await _prefs.remove(_keyAppPassword);
    await _prefs.remove(_keyRemotePath);
    await setEnabled(false);
    await clearMarker();
  }

  WebDavSyncMarker get marker {
    final rawDate = _prefs.getString(_keyLastSyncedAt);
    return WebDavSyncMarker(
      lastSyncedContentHash: _prefs.getString(_keyLastSyncedContentHash),
      lastSyncedRemoteIdentity: _prefs.getString(_keyLastSyncedRemoteIdentity),
      lastSyncedAt: rawDate == null ? null : DateTime.tryParse(rawDate),
    );
  }

  Future<void> saveMarker({
    required String contentHash,
    required String? remoteIdentity,
    required DateTime syncedAt,
  }) async {
    await _prefs.setString(_keyLastSyncedContentHash, contentHash);
    if (remoteIdentity == null) {
      await _prefs.remove(_keyLastSyncedRemoteIdentity);
    } else {
      await _prefs.setString(_keyLastSyncedRemoteIdentity, remoteIdentity);
    }
    await _prefs.setString(_keyLastSyncedAt, syncedAt.toIso8601String());
  }

  Future<void> clearMarker() async {
    await _prefs.remove(_keyLastSyncedContentHash);
    await _prefs.remove(_keyLastSyncedRemoteIdentity);
    await _prefs.remove(_keyLastSyncedAt);
  }
}
