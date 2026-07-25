import 'web_file_link.dart';

bool get isSupported => false;

Future<WebFileLink?> pickAndRemember() => throw UnsupportedError('Web-only.');

Future<WebFileRestoreResult> tryRestore() async =>
    const WebFileRestoreResult(WebFileRestoreStatus.none);

Future<WebFileLink?> requestPermissionAndRestore() => throw UnsupportedError('Web-only.');
