import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Everything needed to reach one specific file on a Nextcloud (or any
/// standard WebDAV) server. [remotePath] is relative to the user's own
/// WebDAV root, e.g. "MoneyManager/MyMoney.mmb".
class WebDavConfig {
  final String serverUrl;
  final String username;
  final String appPassword;
  final String remotePath;

  const WebDavConfig({
    required this.serverUrl,
    required this.username,
    required this.appPassword,
    required this.remotePath,
  });

  /// https://<server>/remote.php/dav/files/<username>/<remotePath segments>
  /// - Nextcloud's standard per-user WebDAV root. Built via
  /// `Uri.replace(pathSegments:)` rather than string concatenation so each
  /// segment (including the username and any accented/spaced folder names
  /// in remotePath) gets percent-encoded correctly on its own.
  Uri get fileUri {
    final base = Uri.parse(serverUrl);
    final cleanedRemotePath = remotePath.replaceAll(RegExp(r'^/+|/+$'), '');
    return base.replace(pathSegments: [
      ...base.pathSegments.where((s) => s.isNotEmpty),
      'remote.php',
      'dav',
      'files',
      username,
      ...cleanedRemotePath.split('/').where((s) => s.isNotEmpty),
    ]);
  }
}

/// The subset of a WebDAV `HEAD` response needed to tell "has this file
/// changed" without downloading it.
class WebDavFileInfo {
  final String? etag;
  final String? lastModifiedRaw;
  final int? contentLength;

  const WebDavFileInfo({this.etag, this.lastModifiedRaw, this.contentLength});

  /// A stable opaque identity to compare against a previously-stored one -
  /// prefers the content-derived ETag (most reliable), falling back to
  /// Last-Modified+length so a server/proxy that omits ETag still works,
  /// just less rigorously (two different byte sequences could in theory
  /// share both, though that's exceedingly unlikely for a database file
  /// that changes size or content on almost every real edit).
  String get identity => etag ?? 'lm:$lastModifiedRaw:len:$contentLength';
}

sealed class WebDavException implements Exception {
  final String message;
  WebDavException(this.message);
  @override
  String toString() => message;
}

class WebDavAuthException extends WebDavException {
  WebDavAuthException(super.message);
}

class WebDavNetworkException extends WebDavException {
  WebDavNetworkException(super.message);
}

class WebDavServerException extends WebDavException {
  WebDavServerException(super.message);
}

/// Result of [WebDavClient.testConnection] - a 404 still counts as a
/// successful *connection* (auth + reachability both confirmed), it just
/// means the file doesn't exist yet at that path.
class WebDavTestResult {
  final bool ok;
  final WebDavFileInfo? info;
  final String? errorMessage;

  const WebDavTestResult._(this.ok, this.info, this.errorMessage);
  factory WebDavTestResult.ok(WebDavFileInfo? info) =>
      WebDavTestResult._(true, info, null);
  factory WebDavTestResult.failed(String message) =>
      WebDavTestResult._(false, null, message);
}

/// Minimal WebDAV-over-HTTP for exactly one known file - no PROPFIND/XML,
/// no directory listing, just HEAD/GET/PUT with HTTP Basic Auth against a
/// Nextcloud app password. Deliberately this narrow: the app only ever
/// needs to read/write one specific remote path, never browse a folder.
class WebDavClient {
  final WebDavConfig config;
  final http.Client _http;

  WebDavClient(this.config, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  Map<String, String> get _authHeader => {
        'Authorization':
            'Basic ${base64Encode(utf8.encode('${config.username}:${config.appPassword}'))}',
      };

  /// Null means the remote file doesn't exist (404) - a real, expected
  /// outcome (e.g. before the very first sync), not an error condition.
  Future<WebDavFileInfo?> headFileInfo() async {
    final resp = await _run(
        () => _http.head(config.fileUri, headers: _authHeader).timeout(_shortTimeout));
    if (resp.statusCode == 404) return null;
    _checkStatus(resp, okCodes: {200});
    return WebDavFileInfo(
      etag: resp.headers['etag'],
      lastModifiedRaw: resp.headers['last-modified'],
      contentLength: int.tryParse(resp.headers['content-length'] ?? ''),
    );
  }

  Future<List<int>> downloadBytes() async {
    final resp = await _run(
        () => _http.get(config.fileUri, headers: _authHeader).timeout(_longTimeout));
    _checkStatus(resp, okCodes: {200});
    return resp.bodyBytes;
  }

  /// Nextcloud returns 201 for a brand new file, 204 for an overwrite -
  /// both count as success.
  Future<void> uploadBytes(List<int> bytes) async {
    final resp = await _run(() => _http
        .put(config.fileUri,
            headers: {..._authHeader, 'Content-Type': 'application/octet-stream'},
            body: bytes)
        .timeout(_longTimeout));
    _checkStatus(resp, okCodes: {200, 201, 204});
  }

  /// For the settings card's "Tester la connexion" button - runs against
  /// whatever [config] is currently constructed with (typically not-yet-saved
  /// field values), never throws.
  Future<WebDavTestResult> testConnection() async {
    try {
      final info = await headFileInfo();
      return WebDavTestResult.ok(info);
    } on WebDavAuthException {
      return WebDavTestResult.failed(
          "Identifiants refusés - vérifiez le nom d'utilisateur et le mot de passe d'application.");
    } on WebDavNetworkException {
      return WebDavTestResult.failed(
          'Serveur injoignable - vérifiez l\'adresse et la connexion réseau.');
    } on WebDavException catch (e) {
      return WebDavTestResult.failed(e.message);
    } catch (e) {
      return WebDavTestResult.failed(e.toString());
    }
  }

  void close() => _http.close();

  static const _shortTimeout = Duration(seconds: 10);
  static const _longTimeout = Duration(seconds: 60);

  Future<http.Response> _run(Future<http.Response> Function() call) async {
    try {
      return await call();
    } on TimeoutException catch (e) {
      throw WebDavNetworkException('Délai dépassé : $e');
    } on SocketException catch (e) {
      throw WebDavNetworkException('Connexion impossible : $e');
    } on http.ClientException catch (e) {
      throw WebDavNetworkException(e.message);
    }
  }

  void _checkStatus(http.Response resp, {required Set<int> okCodes}) {
    if (okCodes.contains(resp.statusCode)) return;
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw WebDavAuthException('Authentification refusée (${resp.statusCode})');
    }
    throw WebDavServerException('Erreur serveur (${resp.statusCode})');
  }
}
