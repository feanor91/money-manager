import 'package:flutter_test/flutter_test.dart';

import 'package:money_manager/services/webdav/webdav_sync_decision.dart';

void main() {
  group('contentHashOf', () {
    test('same bytes produce the same hash', () {
      expect(contentHashOf([1, 2, 3]), contentHashOf([1, 2, 3]));
    });

    test('different bytes produce different hashes', () {
      expect(contentHashOf([1, 2, 3]), isNot(contentHashOf([1, 2, 4])));
    });
  });

  group('decideSyncAction', () {
    test('no marker at all, remote already exists - both sides "changed" by '
        'definition - is a conflict, not a guess', () {
      final action = decideSyncAction(
        localContentHash: 'local-hash',
        lastSyncedContentHash: null,
        remoteIdentity: 'remote-etag',
        lastSyncedRemoteIdentity: null,
      );
      expect(action, SyncAction.conflict);
    });

    test('no marker at all, remote does not exist either - first push, not '
        'a conflict', () {
      final action = decideSyncAction(
        localContentHash: 'local-hash',
        lastSyncedContentHash: null,
        remoteIdentity: null,
        lastSyncedRemoteIdentity: null,
      );
      expect(action, SyncAction.pushLocal);
    });

    test('neither side changed since the last sync - nothing to do', () {
      final action = decideSyncAction(
        localContentHash: 'same-hash',
        lastSyncedContentHash: 'same-hash',
        remoteIdentity: 'same-etag',
        lastSyncedRemoteIdentity: 'same-etag',
      );
      expect(action, SyncAction.noop);
    });

    test('only local changed - pushes automatically, no conflict', () {
      final action = decideSyncAction(
        localContentHash: 'new-local-hash',
        lastSyncedContentHash: 'old-local-hash',
        remoteIdentity: 'same-etag',
        lastSyncedRemoteIdentity: 'same-etag',
      );
      expect(action, SyncAction.pushLocal);
    });

    test('only remote changed - pulls automatically, no conflict', () {
      final action = decideSyncAction(
        localContentHash: 'same-hash',
        lastSyncedContentHash: 'same-hash',
        remoteIdentity: 'new-etag',
        lastSyncedRemoteIdentity: 'old-etag',
      );
      expect(action, SyncAction.pullRemote);
    });

    test('both sides changed since the last sync - the one scenario that '
        'must ask the user, never silently pick a side (financial data: '
        'guessing wrong here means silently discarding real edits)', () {
      final action = decideSyncAction(
        localContentHash: 'new-local-hash',
        lastSyncedContentHash: 'old-local-hash',
        remoteIdentity: 'new-etag',
        lastSyncedRemoteIdentity: 'old-etag',
      );
      expect(action, SyncAction.conflict);
    });

    test('a marker exists but the remote 404s now - remoteMissing, never '
        'silently recreated', () {
      final action = decideSyncAction(
        localContentHash: 'same-hash',
        lastSyncedContentHash: 'same-hash',
        remoteIdentity: null,
        lastSyncedRemoteIdentity: 'old-etag',
      );
      expect(action, SyncAction.remoteMissing);
    });

    test('remoteMissing takes priority even if local also changed - a '
        'deleted remote is never silently overwritten by an automatic '
        'push, regardless of local state', () {
      final action = decideSyncAction(
        localContentHash: 'new-local-hash',
        lastSyncedContentHash: 'old-local-hash',
        remoteIdentity: null,
        lastSyncedRemoteIdentity: 'old-etag',
      );
      expect(action, SyncAction.remoteMissing);
    });
  });
}
