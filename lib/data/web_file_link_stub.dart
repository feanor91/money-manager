import 'web_file_link.dart';

bool get isSupported => false;

Future<WebFileLink?> pickAndRemember() => throw UnsupportedError('Web-only.');

Future<WebFileLink?> pickLocationForNewFile(String suggestedName) =>
    throw UnsupportedError('Web-only.');

Future<WebFileRestoreResult> tryRestore() async =>
    const WebFileRestoreResult(WebFileRestoreStatus.none);

Future<WebFileLink?> requestPermissionAndRestore() => throw UnsupportedError('Web-only.');

// hasDirectoryHandle/ensureDirectoryPermission/readCompanionFile/
// writeCompanionFile aren't top-level functions here because they're
// instance members of WebFileLink - this stub never actually produces an
// instance (pickAndRemember/requestPermissionAndRestore above always throw
// or return null), so there's nothing to implement.
