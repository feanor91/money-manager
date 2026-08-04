import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:money_manager/services/webdav/webdav_client.dart';
import 'package:money_manager/services/webdav/webdav_sync_decision.dart';
import 'package:money_manager/services/webdav/webdav_sync_service.dart';
import 'package:money_manager/services/webdav/webdav_sync_store.dart';

const _creds = WebDavCredentials(
  serverUrl: 'https://nuage.example.com',
  username: 'bruno',
  appPassword: 'app-pass',
  remotePath: 'MoneyManager/MyMoney.mmb',
);

void main() {
  late Directory tempDir;
  late WebDavSyncStore store;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('webdav_sync_service_test_');
    store = await WebDavSyncStore.forTestingAtPath(
        '${tempDir.path}${Platform.pathSeparator}webdav_sync.dat');
    await store.saveCredentials(_creds);
    await store.setEnabled(true);
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  /// [remoteBytes] backs both HEAD (derives headers from it) and GET
  /// (returns it directly) - keeps a single source of truth for "what's on
  /// the server" per test instead of two handlers that could drift apart.
  WebDavSyncService serviceWith({
    List<int>? remoteBytes,
    String? etag,
    List<int>? uploadedBytesSink,
    void Function(http.Request request)? onRequest,
  }) {
    final client = MockClient((request) async {
      onRequest?.call(request);
      if (request.method == 'HEAD') {
        if (remoteBytes == null) return http.Response('', 404);
        return http.Response('', 200, headers: {
          if (etag != null) 'etag': etag,
          'content-length': '${remoteBytes.length}',
        });
      }
      if (request.method == 'GET') {
        return http.Response.bytes(remoteBytes ?? [], 200);
      }
      if (request.method == 'PUT') {
        uploadedBytesSink?.addAll(request.bodyBytes);
        return http.Response('', 201);
      }
      throw StateError('Unexpected method ${request.method}');
    });
    return WebDavSyncService(store, httpClient: client);
  }

  group('isConfiguredAndEnabled', () {
    test('false when disabled even with complete credentials', () async {
      await store.setEnabled(false);
      final service = serviceWith();
      expect(service.isConfiguredAndEnabled, isFalse);
    });

    test('false when enabled but credentials incomplete', () async {
      await store.saveCredentials(const WebDavCredentials(serverUrl: 'https://x'));
      await store.setEnabled(true);
      final service = serviceWith();
      expect(service.isConfiguredAndEnabled, isFalse);
    });

    test('reconcile short-circuits to noop with zero HTTP calls when not '
        'configured', () async {
      await store.setEnabled(false);
      var called = false;
      final service = serviceWith(onRequest: (_) => called = true);
      final result =
          await service.reconcile(localBytes: [1, 2, 3], allowAutoPush: true);
      expect(result.action, SyncAction.noop);
      expect(called, isFalse);
    });
  });

  group('reconcile', () {
    test('neither side changed - noop, no upload/download', () async {
      final localBytes = utf8.encode('same content');
      await store.saveMarker(
        contentHash: contentHashOf(localBytes),
        remoteIdentity: '"etag-1"',
        syncedAt: DateTime.now(),
      );
      final service = serviceWith(remoteBytes: localBytes, etag: '"etag-1"');
      final result = await service.reconcile(localBytes: localBytes, allowAutoPush: true);
      expect(result.action, SyncAction.noop);
    });

    test('only local changed - pushes and updates the marker', () async {
      final oldBytes = utf8.encode('old content');
      final newBytes = utf8.encode('new content');
      await store.saveMarker(
        contentHash: contentHashOf(oldBytes),
        remoteIdentity: '"etag-1"',
        syncedAt: DateTime.now(),
      );
      final uploaded = <int>[];
      final service = serviceWith(
        remoteBytes: oldBytes,
        etag: '"etag-1"',
        uploadedBytesSink: uploaded,
      );
      final result = await service.reconcile(localBytes: newBytes, allowAutoPush: true);
      expect(result.action, SyncAction.pushLocal);
      expect(uploaded, newBytes);
      expect(store.marker.lastSyncedContentHash, contentHashOf(newBytes));
    });

    test('only remote changed - pulls and returns the new bytes', () async {
      final oldBytes = utf8.encode('old content');
      final newRemoteBytes = utf8.encode('new remote content');
      await store.saveMarker(
        contentHash: contentHashOf(oldBytes),
        remoteIdentity: '"etag-1"',
        syncedAt: DateTime.now(),
      );
      final service = serviceWith(remoteBytes: newRemoteBytes, etag: '"etag-2"');
      final result = await service.reconcile(localBytes: oldBytes, allowAutoPush: true);
      expect(result.action, SyncAction.pullRemote);
      expect(result.pulledBytes, newRemoteBytes);
      expect(store.marker.lastSyncedRemoteIdentity, '"etag-2"');
    });

    test('both sides changed - conflict, no upload/download attempted', () async {
      final oldBytes = utf8.encode('old content');
      final newLocalBytes = utf8.encode('new local content');
      final newRemoteBytes = utf8.encode('new remote content');
      await store.saveMarker(
        contentHash: contentHashOf(oldBytes),
        remoteIdentity: '"etag-1"',
        syncedAt: DateTime.now(),
      );
      var putCalled = false;
      var getCalled = false;
      final service = serviceWith(
        remoteBytes: newRemoteBytes,
        etag: '"etag-2"',
        onRequest: (r) {
          if (r.method == 'PUT') putCalled = true;
          if (r.method == 'GET') getCalled = true;
        },
      );
      final result = await service.reconcile(localBytes: newLocalBytes, allowAutoPush: true);
      expect(result.action, SyncAction.conflict);
      expect(putCalled, isFalse);
      expect(getCalled, isFalse);
    });

    test('allowAutoPush: false degrades a would-be push to a conflict '
        '(pickDatabaseFile picking an unrelated file)', () async {
      final oldBytes = utf8.encode('old content');
      final unrelatedLocalBytes = utf8.encode('completely different file');
      await store.saveMarker(
        contentHash: contentHashOf(oldBytes),
        remoteIdentity: '"etag-1"',
        syncedAt: DateTime.now(),
      );
      final service = serviceWith(remoteBytes: oldBytes, etag: '"etag-1"');
      final result =
          await service.reconcile(localBytes: unrelatedLocalBytes, allowAutoPush: false);
      expect(result.action, SyncAction.conflict);
    });

    test('a network failure surfaces as errorMessage, never throws', () async {
      final client = MockClient((request) async => throw const SocketException('no network'));
      final service = WebDavSyncService(store, httpClient: client);
      final result = await service.reconcile(localBytes: [1, 2, 3], allowAutoPush: true);
      expect(result.errorMessage, isNotNull);
    });
  });

  group('prepareConflictResolution', () {
    test('byte-identical remote resolves silently and returns null', () async {
      final bytes = utf8.encode('identical content');
      final service = serviceWith(remoteBytes: bytes, etag: '"etag-1"');
      final info = await service.prepareConflictResolution(localBytes: bytes);
      expect(info, isNull);
      expect(store.marker.lastSyncedContentHash, contentHashOf(bytes));
    });

    test('genuinely different content returns both byte buffers', () async {
      final localBytes = utf8.encode('local content');
      final remoteBytes = utf8.encode('remote content');
      final service = serviceWith(remoteBytes: remoteBytes, etag: '"etag-1"');
      final info = await service.prepareConflictResolution(localBytes: localBytes);
      expect(info, isNotNull);
      expect(info!.localBytes, localBytes);
      expect(info.remoteBytes, remoteBytes);
    });
  });

  group('resolveConflict', () {
    test('keepLocal uploads the local bytes and reports it as the winner',
        () async {
      final localBytes = utf8.encode('local content');
      final remoteBytes = utf8.encode('remote content');
      final uploaded = <int>[];
      final service = serviceWith(
        remoteBytes: remoteBytes,
        etag: '"etag-1"',
        uploadedBytesSink: uploaded,
      );
      final info = SyncConflictInfo(
        localBytes: localBytes,
        remoteBytes: remoteBytes,
        remoteInfo: const WebDavFileInfo(etag: '"etag-1"'),
      );
      final resolution =
          await service.resolveConflict(choice: ConflictChoice.keepLocal, info: info);
      expect(resolution.localWon, isTrue);
      expect(resolution.winningBytes, localBytes);
      expect(resolution.losingBytes, remoteBytes);
      expect(uploaded, localBytes);
      expect(store.marker.lastSyncedContentHash, contentHashOf(localBytes));
    });

    test('keepRemote never uploads and reports remote as the winner', () async {
      final localBytes = utf8.encode('local content');
      final remoteBytes = utf8.encode('remote content');
      var putCalled = false;
      final service = serviceWith(
        remoteBytes: remoteBytes,
        etag: '"etag-1"',
        onRequest: (r) {
          if (r.method == 'PUT') putCalled = true;
        },
      );
      final info = SyncConflictInfo(
        localBytes: localBytes,
        remoteBytes: remoteBytes,
        remoteInfo: const WebDavFileInfo(etag: '"etag-1"'),
      );
      final resolution =
          await service.resolveConflict(choice: ConflictChoice.keepRemote, info: info);
      expect(resolution.localWon, isFalse);
      expect(resolution.winningBytes, remoteBytes);
      expect(resolution.losingBytes, localBytes);
      expect(putCalled, isFalse);
      expect(store.marker.lastSyncedContentHash, contentHashOf(remoteBytes));
    });
  });

  group('resolveRemoteMissing', () {
    test('reupload: true pushes the current local bytes and re-establishes '
        'a marker', () async {
      final localBytes = utf8.encode('local content');
      final uploaded = <int>[];
      final service = serviceWith(
        remoteBytes: localBytes,
        etag: '"etag-new"',
        uploadedBytesSink: uploaded,
      );
      await service.resolveRemoteMissing(localBytes: localBytes, reupload: true);
      expect(uploaded, localBytes);
      expect(store.marker.lastSyncedContentHash, contentHashOf(localBytes));
    });

    test('reupload: false just clears the marker, no network call', () async {
      await store.saveMarker(
        contentHash: 'abc', remoteIdentity: 'etag', syncedAt: DateTime.now());
      var called = false;
      final service = serviceWith(onRequest: (_) => called = true);
      await service.resolveRemoteMissing(localBytes: [1, 2, 3], reupload: false);
      expect(called, isFalse);
      expect(store.marker.lastSyncedContentHash, isNull);
    });
  });
}
