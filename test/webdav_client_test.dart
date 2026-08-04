import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:money_manager/services/webdav/webdav_client.dart';

WebDavConfig _config({String remotePath = 'MoneyManager/MyMoney.mmb'}) => WebDavConfig(
      serverUrl: 'https://nuage.example.com',
      username: 'bruno',
      appPassword: 'app-pass-123',
      remotePath: remotePath,
    );

void main() {
  group('WebDavConfig.fileUri', () {
    test('builds the Nextcloud per-user WebDAV path', () {
      final uri = _config().fileUri;
      expect(uri.toString(),
          'https://nuage.example.com/remote.php/dav/files/bruno/MoneyManager/MyMoney.mmb');
    });

    test('percent-encodes accented/spaced segments correctly', () {
      final uri = _config(remotePath: 'Mes Comptes/Année 2026.mmb').fileUri;
      expect(uri.pathSegments.last, 'Année 2026.mmb');
      // A raw space or accent must never appear unescaped in the serialized
      // URL string, even though Uri keeps them readable in pathSegments.
      expect(uri.toString().contains(' '), isFalse);
    });

    test('strips leading/trailing slashes from remotePath', () {
      final uri = _config(remotePath: '/MoneyManager/MyMoney.mmb/').fileUri;
      expect(uri.pathSegments.last, 'MyMoney.mmb');
    });
  });

  group('WebDavClient.headFileInfo', () {
    test('sends HTTP Basic Auth with the app password', () async {
      String? authHeader;
      final client = WebDavClient(
        _config(),
        httpClient: MockClient((request) async {
          authHeader = request.headers['authorization'];
          return http.Response('', 200);
        }),
      );
      await client.headFileInfo();
      expect(authHeader, 'Basic ${base64Encode(utf8.encode('bruno:app-pass-123'))}');
    });

    test('404 means the remote file does not exist - returns null, not an '
        'error', () async {
      final client = WebDavClient(
        _config(),
        httpClient: MockClient((request) async => http.Response('', 404)),
      );
      expect(await client.headFileInfo(), isNull);
    });

    test('200 populates WebDavFileInfo from lowercase-keyed headers',
        () async {
      final client = WebDavClient(
        _config(),
        httpClient: MockClient((request) async => http.Response('', 200, headers: {
              'etag': '"abc123"',
              'last-modified': 'Tue, 04 Aug 2026 12:00:00 GMT',
              'content-length': '1700000',
            })),
      );
      final info = await client.headFileInfo();
      expect(info, isNotNull);
      expect(info!.etag, '"abc123"');
      expect(info.lastModifiedRaw, 'Tue, 04 Aug 2026 12:00:00 GMT');
      expect(info.contentLength, 1700000);
      expect(info.identity, '"abc123"');
    });

    test('missing ETag falls back to Last-Modified+length for identity',
        () async {
      final client = WebDavClient(
        _config(),
        httpClient: MockClient((request) async => http.Response('', 200, headers: {
              'last-modified': 'Tue, 04 Aug 2026 12:00:00 GMT',
              'content-length': '1700000',
            })),
      );
      final info = await client.headFileInfo();
      expect(info!.etag, isNull);
      expect(info.identity, contains('Tue, 04 Aug 2026 12:00:00 GMT'));
      expect(info.identity, contains('1700000'));
    });

    test('401/403 throws WebDavAuthException', () async {
      final client = WebDavClient(
        _config(),
        httpClient: MockClient((request) async => http.Response('', 401)),
      );
      expect(client.headFileInfo(), throwsA(isA<WebDavAuthException>()));
    });

    test('other non-2xx throws WebDavServerException', () async {
      final client = WebDavClient(
        _config(),
        httpClient: MockClient((request) async => http.Response('', 500)),
      );
      expect(client.headFileInfo(), throwsA(isA<WebDavServerException>()));
    });
  });

  group('WebDavClient.uploadBytes', () {
    for (final code in [200, 201, 204]) {
      test('$code is accepted as a successful upload', () async {
        final client = WebDavClient(
          _config(),
          httpClient: MockClient((request) async => http.Response('', code)),
        );
        await client.uploadBytes([1, 2, 3]); // must not throw
      });
    }

    test('sends the raw bytes as the request body', () async {
      List<int>? sentBody;
      final client = WebDavClient(
        _config(),
        httpClient: MockClient((request) async {
          sentBody = request.bodyBytes;
          return http.Response('', 201);
        }),
      );
      await client.uploadBytes([9, 8, 7]);
      expect(sentBody, [9, 8, 7]);
    });
  });

  group('WebDavClient.downloadBytes', () {
    test('returns the response body bytes', () async {
      final client = WebDavClient(
        _config(),
        httpClient: MockClient((request) async => http.Response.bytes([4, 5, 6], 200)),
      );
      expect(await client.downloadBytes(), [4, 5, 6]);
    });
  });

  group('WebDavClient.testConnection', () {
    test('200 reports ok with file info', () async {
      final client = WebDavClient(
        _config(),
        httpClient: MockClient((request) async =>
            http.Response('', 200, headers: {'content-length': '100'})),
      );
      final result = await client.testConnection();
      expect(result.ok, isTrue);
      expect(result.info?.contentLength, 100);
    });

    test('404 still reports ok (connection/auth confirmed, just no file '
        'yet)', () async {
      final client = WebDavClient(
        _config(),
        httpClient: MockClient((request) async => http.Response('', 404)),
      );
      final result = await client.testConnection();
      expect(result.ok, isTrue);
      expect(result.info, isNull);
    });

    test('401 reports a specific auth failure message', () async {
      final client = WebDavClient(
        _config(),
        httpClient: MockClient((request) async => http.Response('', 401)),
      );
      final result = await client.testConnection();
      expect(result.ok, isFalse);
      expect(result.errorMessage, contains('Identifiants refusés'));
    });
  });
}
