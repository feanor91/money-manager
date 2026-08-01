import 'android_file_link.dart';

// Used on web only (see android_file_link.dart's conditional import) -
// never actually reached, since DatabaseProvider gates every Android code
// path behind `_isAndroid` first. Exists purely so android_file_link_io.dart
// (which imports package:saf_stream, and therefore transitively dart:ffi -
// unavailable on web) never ends up in the web compilation graph at all.

Future<AndroidFileLink?> pickAndRemember() =>
    throw UnsupportedError('Android-only.');

Future<AndroidFileLink?> tryRestore() async => null;
