import 'dart:convert';

import 'package:http/http.dart' as http;

const _releasesUrl =
    'https://api.github.com/repos/feanor91/money-manager/releases/latest';

/// The latest published GitHub release, parsed from the public releases API.
class LatestRelease {
  final String version;
  final String? notes;
  final String? windowsInstallerUrl;
  final String? androidApkUrl;

  const LatestRelease({
    required this.version,
    this.notes,
    this.windowsInstallerUrl,
    this.androidApkUrl,
  });
}

/// Fetches the latest release - null on any failure (offline, rate-limited,
/// unexpected shape...), since a failed update check must never block or
/// interrupt normal app startup. No auth: the repo is public, and one check
/// per launch for a single user is nowhere near GitHub's unauthenticated
/// rate limit.
Future<LatestRelease?> fetchLatestRelease() async {
  try {
    final response = await http
        .get(Uri.parse(_releasesUrl),
            headers: {'Accept': 'application/vnd.github+json'})
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) return null;
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final tag = json['tag_name'] as String?;
    if (tag == null) return null;
    final version = tag.startsWith('v') ? tag.substring(1) : tag;
    final assets =
        (json['assets'] as List?)?.cast<Map<String, dynamic>>() ?? const [];

    String? findAssetUrl(bool Function(String name) matches) {
      for (final asset in assets) {
        final name = asset['name'] as String?;
        if (name != null && matches(name)) {
          return asset['browser_download_url'] as String?;
        }
      }
      return null;
    }

    return LatestRelease(
      version: version,
      notes: json['body'] as String?,
      windowsInstallerUrl: findAssetUrl((n) => n.endsWith('-setup-win64.exe')),
      androidApkUrl: findAssetUrl((n) => n == 'app-release.apk'),
    );
  } catch (_) {
    return null;
  }
}

/// True if [latest] is a newer version than [current] - both expected as
/// dot-separated numeric versions (e.g. "1.0.32"); a trailing "+buildNumber"
/// is ignored if present (pubspec.yaml's own version field carries one).
/// Malformed input fails closed (returns false) - never nag about an update
/// this can't confidently confirm is real.
bool isNewerVersion(String latest, String current) {
  List<int>? parse(String v) {
    final numbers = v.split('+').first.split('.').map(int.tryParse).toList();
    if (numbers.any((n) => n == null)) return null;
    return numbers.cast<int>();
  }

  final latestParts = parse(latest);
  final currentParts = parse(current);
  if (latestParts == null || currentParts == null) return false;

  final length = latestParts.length > currentParts.length
      ? latestParts.length
      : currentParts.length;
  for (var i = 0; i < length; i++) {
    final l = i < latestParts.length ? latestParts[i] : 0;
    final c = i < currentParts.length ? currentParts[i] : 0;
    if (l != c) return l > c;
  }
  return false;
}
