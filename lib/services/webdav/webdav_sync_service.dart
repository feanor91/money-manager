import 'package:http/http.dart' as http;

import 'webdav_client.dart';
import 'webdav_sync_decision.dart';
import 'webdav_sync_store.dart';

/// What a reconciliation attempt concluded, phrased for DatabaseProvider's
/// hook points: whether/how to adjust the bytes about to be opened (or just
/// synced), and what status to surface once the app is up. [errorMessage]
/// non-null means the attempt itself failed (network/server) - callers
/// should check that *before* trusting [action], which defaults to
/// [SyncAction.noop] in that case simply as an inert placeholder, not a
/// real "nothing to do" verdict.
class ReconcileResult {
  final SyncAction action;
  final List<int>? pulledBytes;
  final String? errorMessage;

  const ReconcileResult(this.action, {this.pulledBytes, this.errorMessage});
}

/// Both full byte buffers behind a detected conflict, so resolving it never
/// needs a second download regardless of which side wins.
class SyncConflictInfo {
  final List<int> localBytes;
  final List<int> remoteBytes;
  final WebDavFileInfo? remoteInfo;

  const SyncConflictInfo({
    required this.localBytes,
    required this.remoteBytes,
    this.remoteInfo,
  });
}

enum ConflictChoice { keepLocal, keepRemote }

/// Which bytes won and which lost after a conflict is resolved -
/// DatabaseProvider (via AndroidFileLink, which this service never touches)
/// owns actually writing the winner locally and backing up the loser.
class ConflictResolution {
  final List<int> winningBytes;
  final List<int> losingBytes;
  final bool localWon;

  const ConflictResolution({
    required this.winningBytes,
    required this.losingBytes,
    required this.localWon,
  });
}

/// Orchestrates WebDAV two-way sync for the Android .mmb - owns the HTTP
/// client and the credential/marker store, and knows how to carry out a
/// [SyncAction], but never touches MmexDatabase/AndroidFileLink directly,
/// never calls notifyListeners(), never shows UI. DatabaseProvider is the
/// sole caller, and owns turning these results into actual local file
/// writes, a database reload, and UI state.
class WebDavSyncService {
  final WebDavSyncStore store;

  /// Injectable for tests (see webdav_sync_service_test.dart) - a real
  /// http.Client() in production when omitted. Every WebDavClient this
  /// service constructs is built with this same underlying client, so a
  /// test can hand in one MockClient and observe/stub every HTTP call this
  /// service makes.
  final http.Client? _httpClient;

  WebDavClient? _client;

  WebDavSyncService(this.store, {http.Client? httpClient}) : _httpClient = httpClient;

  bool get isConfiguredAndEnabled => store.enabled && store.credentials.isComplete;

  WebDavClient _buildClient(WebDavCredentials creds) => WebDavClient(
        WebDavConfig(
          serverUrl: creds.serverUrl,
          username: creds.username,
          appPassword: creds.appPassword,
          remotePath: creds.remotePath,
        ),
        httpClient: _httpClient,
      );

  WebDavClient _clientFor(WebDavCredentials creds) {
    final existing = _client;
    if (existing != null &&
        existing.config.serverUrl == creds.serverUrl &&
        existing.config.username == creds.username &&
        existing.config.appPassword == creds.appPassword &&
        existing.config.remotePath == creds.remotePath) {
      return existing;
    }
    existing?.close();
    final client = _buildClient(creds);
    _client = client;
    return client;
  }

  /// Drops the cached client so the next call rebuilds one from whatever
  /// credentials are current - call after credentials are saved/forgotten.
  void invalidateClient() {
    _client?.close();
    _client = null;
  }

  Future<WebDavTestResult> testConnection(WebDavCredentials creds) =>
      _buildClient(creds).testConnection();

  /// Pre-open reconciliation (see DatabaseProvider.restoreLastDatabase/
  /// pickDatabaseFile) and the manual "Synchroniser maintenant" trigger -
  /// same decision, different [allowAutoPush]. Only ever issues a HEAD
  /// request to decide - a genuine pull still downloads the full file (the
  /// whole point), but a detected conflict is left unresolved rather than
  /// downloaded speculatively, since this runs on every single launch and
  /// spending mobile data on a multi-MB download the user may not act on
  /// for hours isn't worth it. See [prepareConflictResolution] for the
  /// deferred download.
  ///
  /// [allowAutoPush] false degrades a would-be [SyncAction.pushLocal] down
  /// to [SyncAction.conflict] - used for pickDatabaseFile(), where the
  /// local bytes might be an unrelated freshly-picked file with no real
  /// relationship to the stored marker, so an apparent "push" verdict can't
  /// be trusted to mean "this device has new edits worth keeping" the way
  /// it can for restoreLastDatabase()'s continuously-used file.
  Future<ReconcileResult> reconcile({
    required List<int> localBytes,
    required bool allowAutoPush,
  }) async {
    if (!isConfiguredAndEnabled) return const ReconcileResult(SyncAction.noop);
    try {
      final creds = store.credentials;
      final client = _clientFor(creds);
      final marker = store.marker;
      final remoteInfo = await client.headFileInfo();
      var action = decideSyncAction(
        localContentHash: contentHashOf(localBytes),
        lastSyncedContentHash: marker.lastSyncedContentHash,
        remoteIdentity: remoteInfo?.identity,
        lastSyncedRemoteIdentity: marker.lastSyncedRemoteIdentity,
      );
      if (!allowAutoPush && action == SyncAction.pushLocal) {
        action = SyncAction.conflict;
      }
      switch (action) {
        case SyncAction.noop:
          return const ReconcileResult(SyncAction.noop);
        case SyncAction.pushLocal:
          await client.uploadBytes(localBytes);
          final newRemoteInfo = await client.headFileInfo();
          await store.saveMarker(
            contentHash: contentHashOf(localBytes),
            remoteIdentity: newRemoteInfo?.identity,
            syncedAt: DateTime.now(),
          );
          return const ReconcileResult(SyncAction.pushLocal);
        case SyncAction.pullRemote:
          final bytes = await client.downloadBytes();
          await store.saveMarker(
            contentHash: contentHashOf(bytes),
            remoteIdentity: remoteInfo?.identity,
            syncedAt: DateTime.now(),
          );
          return ReconcileResult(SyncAction.pullRemote, pulledBytes: bytes);
        case SyncAction.conflict:
          return const ReconcileResult(SyncAction.conflict);
        case SyncAction.remoteMissing:
          return const ReconcileResult(SyncAction.remoteMissing);
      }
    } on WebDavException catch (e) {
      return ReconcileResult(SyncAction.noop, errorMessage: e.message);
    } catch (e) {
      return ReconcileResult(SyncAction.noop, errorMessage: e.toString());
    }
  }

  /// Called only when the user actually opens the conflict dialog (never
  /// automatically) - downloads the remote bytes once and checks whether
  /// they're actually byte-identical to [localBytes] despite differing
  /// WebDAV identities. A real, likely scenario on the very first sync
  /// after switching away from a different sync tool that left both sides
  /// truly matching - when identical, resolves and saves the marker
  /// silently and returns null; the caller should treat null as "resolved,
  /// nothing more to do" and skip showing a dialog at all.
  ///
  /// Throws [WebDavException] on failure (network/server) - deliberately
  /// not caught here, so the caller can distinguish "no conflict, resolved"
  /// (null) from "couldn't even check" (needs a visible retry option)
  /// rather than conflating both into one falsy result.
  Future<SyncConflictInfo?> prepareConflictResolution({
    required List<int> localBytes,
  }) async {
    final client = _clientFor(store.credentials);
    final remoteInfo = await client.headFileInfo();
    final remoteBytes = await client.downloadBytes();
    if (contentHashOf(remoteBytes) == contentHashOf(localBytes)) {
      await store.saveMarker(
        contentHash: contentHashOf(localBytes),
        remoteIdentity: remoteInfo?.identity,
        syncedAt: DateTime.now(),
      );
      return null;
    }
    return SyncConflictInfo(
      localBytes: localBytes,
      remoteBytes: remoteBytes,
      remoteInfo: remoteInfo,
    );
  }

  /// Executes the user's choice from the conflict dialog and always updates
  /// the marker. Throws [WebDavException] on failure (only reachable on the
  /// keepLocal path, which uploads) - not caught here, same reasoning as
  /// [prepareConflictResolution].
  Future<ConflictResolution> resolveConflict({
    required ConflictChoice choice,
    required SyncConflictInfo info,
  }) async {
    final client = _clientFor(store.credentials);
    if (choice == ConflictChoice.keepLocal) {
      await client.uploadBytes(info.localBytes);
      final newRemoteInfo = await client.headFileInfo();
      await store.saveMarker(
        contentHash: contentHashOf(info.localBytes),
        remoteIdentity: newRemoteInfo?.identity,
        syncedAt: DateTime.now(),
      );
      return ConflictResolution(
        winningBytes: info.localBytes,
        losingBytes: info.remoteBytes,
        localWon: true,
      );
    }
    await store.saveMarker(
      contentHash: contentHashOf(info.remoteBytes),
      remoteIdentity: info.remoteInfo?.identity,
      syncedAt: DateTime.now(),
    );
    return ConflictResolution(
      winningBytes: info.remoteBytes,
      losingBytes: info.localBytes,
      localWon: false,
    );
  }

  /// remoteMissing: the marker says this device synced against a real
  /// remote file before, but it's gone now (deleted or moved server-side).
  /// Never auto-resolved - a server-side deletion could easily be
  /// intentional. [reupload] true recreates it from the phone's current
  /// state; false just stops flagging this same state every launch
  /// (clears the marker rather than guessing either way).
  Future<void> resolveRemoteMissing({
    required List<int> localBytes,
    required bool reupload,
  }) async {
    if (!reupload) {
      await store.clearMarker();
      return;
    }
    final client = _clientFor(store.credentials);
    await client.uploadBytes(localBytes);
    final newRemoteInfo = await client.headFileInfo();
    await store.saveMarker(
      contentHash: contentHashOf(localBytes),
      remoteIdentity: newRemoteInfo?.identity,
      syncedAt: DateTime.now(),
    );
  }
}
