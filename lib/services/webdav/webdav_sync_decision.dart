import 'package:crypto/crypto.dart';

/// SHA-256 of [bytes] as a lowercase hex string - the "did the local file
/// really change" signal [decideSyncAction] compares against a stored
/// marker. Deliberately content-based rather than a file modification
/// timestamp: SAF-backed files don't reliably expose a trustworthy mtime,
/// and a hash has no clock-skew risk between the phone and the server.
String contentHashOf(List<int> bytes) => sha256.convert(bytes).toString();

/// What [decideSyncAction] concluded should happen. Purely descriptive -
/// callers (see WebDavSyncService) decide how to actually carry each one
/// out (network calls, writing local bytes, asking the user).
enum SyncAction {
  /// Neither side changed since the last successful sync - nothing to do.
  noop,

  /// Only the local file changed - push it to the server automatically.
  pushLocal,

  /// Only the remote file changed - pull it down automatically.
  pullRemote,

  /// Both sides changed since the last successful sync - never guess,
  /// resolving this always requires asking the user.
  conflict,

  /// A remote file was synced successfully before, but is gone now (a 404
  /// where one previously existed) - never silently recreate it, since a
  /// server-side deletion could easily be intentional.
  remoteMissing,
}

/// The core two-way-sync decision, kept entirely pure (no I/O, no
/// Flutter/http/SAF dependency) so every branch is trivially unit-testable.
///
/// A conflict is only ever reported when *both* sides changed since the
/// last successful sync - not merely "the remote looks newer than the
/// local copy" by some timestamp. On financial data, blindly trusting
/// whichever side has the later timestamp risks silently discarding real
/// edits on the *other* side without ever asking - unacceptable here, so
/// this instead tracks what was true as of the last successful sync
/// ([lastSyncedContentHash]/[lastSyncedRemoteIdentity]) and only escalates
/// to the user when it genuinely can't be resolved without a decision.
///
/// [remoteIdentity]/[lastSyncedRemoteIdentity] are opaque strings from
/// [WebDavFileInfo.identity] (an ETag, or a Last-Modified+length fallback) -
/// this function never interprets them beyond equality.
SyncAction decideSyncAction({
  required String localContentHash,
  required String? lastSyncedContentHash,
  required String? remoteIdentity,
  required String? lastSyncedRemoteIdentity,
}) {
  final localChanged =
      lastSyncedContentHash == null || localContentHash != lastSyncedContentHash;

  if (remoteIdentity == null) {
    return lastSyncedRemoteIdentity == null
        ? SyncAction.pushLocal
        : SyncAction.remoteMissing;
  }
  final remoteChanged =
      lastSyncedRemoteIdentity == null || remoteIdentity != lastSyncedRemoteIdentity;

  if (!localChanged && !remoteChanged) return SyncAction.noop;
  if (localChanged && !remoteChanged) return SyncAction.pushLocal;
  if (!localChanged && remoteChanged) return SyncAction.pullRemote;
  return SyncAction.conflict;
}
