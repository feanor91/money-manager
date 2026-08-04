import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:money_manager/services/webdav/webdav_sync_store.dart';

void main() {
  late Directory tempDir;
  late String path;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('webdav_sync_store_test_');
    path = '${tempDir.path}${Platform.pathSeparator}webdav_sync.dat';
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('starts disabled with empty credentials and no marker', () async {
    final store = await WebDavSyncStore.forTestingAtPath(path);
    expect(store.enabled, isFalse);
    expect(store.credentials.isComplete, isFalse);
    expect(store.marker.lastSyncedContentHash, isNull);
    expect(store.marker.lastSyncedRemoteIdentity, isNull);
    expect(store.marker.lastSyncedAt, isNull);
  });

  test('WebDavCredentials.isComplete requires every field non-empty', () {
    expect(
      const WebDavCredentials(
        serverUrl: 'https://x', username: 'u', appPassword: 'p', remotePath: 'r',
      ).isComplete,
      isTrue,
    );
    expect(
      const WebDavCredentials(serverUrl: 'https://x', username: 'u', appPassword: 'p')
          .isComplete,
      isFalse,
    );
  });

  test('setEnabled round-trips through a fresh instance loaded from the '
      'same path', () async {
    var store = await WebDavSyncStore.forTestingAtPath(path);
    await store.setEnabled(true);

    store = await WebDavSyncStore.forTestingAtPath(path);
    expect(store.enabled, isTrue);
  });

  test('saveCredentials round-trips through a fresh instance', () async {
    var store = await WebDavSyncStore.forTestingAtPath(path);
    const creds = WebDavCredentials(
      serverUrl: 'https://nuage.example.com',
      username: 'bruno',
      appPassword: 'secret',
      remotePath: 'MoneyManager/MyMoney.mmb',
    );
    await store.saveCredentials(creds);

    store = await WebDavSyncStore.forTestingAtPath(path);
    expect(store.credentials.serverUrl, creds.serverUrl);
    expect(store.credentials.username, creds.username);
    expect(store.credentials.appPassword, creds.appPassword);
    expect(store.credentials.remotePath, creds.remotePath);
  });

  test('the on-disk file is not plain-text - same encryption guarantee as '
      'the PIN hash/companion settings', () async {
    final store = await WebDavSyncStore.forTestingAtPath(path);
    await store.saveCredentials(const WebDavCredentials(
      serverUrl: 'https://nuage.example.com',
      username: 'bruno',
      appPassword: 'super-secret-app-password',
      remotePath: 'MoneyManager/MyMoney.mmb',
    ));

    final raw = latin1.decode(File(path).readAsBytesSync());
    expect(raw.contains('super-secret-app-password'), isFalse);
  });

  test('saveMarker round-trips content hash, remote identity and '
      'timestamp', () async {
    var store = await WebDavSyncStore.forTestingAtPath(path);
    final now = DateTime.utc(2026, 8, 4, 12, 30);
    await store.saveMarker(
      contentHash: 'abc123',
      remoteIdentity: '"etag-1"',
      syncedAt: now,
    );

    store = await WebDavSyncStore.forTestingAtPath(path);
    expect(store.marker.lastSyncedContentHash, 'abc123');
    expect(store.marker.lastSyncedRemoteIdentity, '"etag-1"');
    expect(store.marker.lastSyncedAt, now);
  });

  test('saveMarker with a null remoteIdentity clears any previously stored '
      'one (first push against a remote with no ETag support)', () async {
    final store = await WebDavSyncStore.forTestingAtPath(path);
    await store.saveMarker(
      contentHash: 'abc123',
      remoteIdentity: '"etag-1"',
      syncedAt: DateTime.now(),
    );
    await store.saveMarker(
      contentHash: 'def456',
      remoteIdentity: null,
      syncedAt: DateTime.now(),
    );
    expect(store.marker.lastSyncedRemoteIdentity, isNull);
  });

  test('clearMarker resets to no marker without touching credentials',
      () async {
    final store = await WebDavSyncStore.forTestingAtPath(path);
    await store.saveCredentials(const WebDavCredentials(
      serverUrl: 'https://x', username: 'u', appPassword: 'p', remotePath: 'r',
    ));
    await store.saveMarker(
        contentHash: 'abc', remoteIdentity: 'etag', syncedAt: DateTime.now());

    await store.clearMarker();

    expect(store.marker.lastSyncedContentHash, isNull);
    expect(store.credentials.serverUrl, 'https://x');
  });

  test('saveCredentials clears the marker when server/username/remotePath '
      'actually change - a marker only means something relative to one '
      'specific remote file', () async {
    final store = await WebDavSyncStore.forTestingAtPath(path);
    await store.saveCredentials(const WebDavCredentials(
      serverUrl: 'https://a.example.com', username: 'u', appPassword: 'p', remotePath: 'r',
    ));
    await store.saveMarker(
        contentHash: 'abc', remoteIdentity: 'etag', syncedAt: DateTime.now());

    await store.saveCredentials(const WebDavCredentials(
      serverUrl: 'https://b.example.com', username: 'u', appPassword: 'p', remotePath: 'r',
    ));

    expect(store.marker.lastSyncedContentHash, isNull);
  });

  test('saveCredentials keeps the marker when only the app password '
      'changed - same server/user/path, the marker is still meaningful',
      () async {
    final store = await WebDavSyncStore.forTestingAtPath(path);
    await store.saveCredentials(const WebDavCredentials(
      serverUrl: 'https://a.example.com', username: 'u', appPassword: 'old-pass', remotePath: 'r',
    ));
    await store.saveMarker(
        contentHash: 'abc', remoteIdentity: 'etag', syncedAt: DateTime.now());

    await store.saveCredentials(const WebDavCredentials(
      serverUrl: 'https://a.example.com', username: 'u', appPassword: 'new-pass', remotePath: 'r',
    ));

    expect(store.marker.lastSyncedContentHash, 'abc');
  });

  test('forgetCredentials clears credentials, disables, and clears the '
      'marker', () async {
    final store = await WebDavSyncStore.forTestingAtPath(path);
    await store.saveCredentials(const WebDavCredentials(
      serverUrl: 'https://a.example.com', username: 'u', appPassword: 'p', remotePath: 'r',
    ));
    await store.setEnabled(true);
    await store.saveMarker(
        contentHash: 'abc', remoteIdentity: 'etag', syncedAt: DateTime.now());

    await store.forgetCredentials();

    expect(store.enabled, isFalse);
    expect(store.credentials.isComplete, isFalse);
    expect(store.marker.lastSyncedContentHash, isNull);
  });
}
