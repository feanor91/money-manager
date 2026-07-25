import 'mmex_database.dart';

Future<MmexDatabase> openFromPath(String path) =>
    throw UnsupportedError('No MmexDatabase implementation for this platform.');

Future<MmexDatabase> openFromBytes(List<int> bytes, {String? label}) =>
    throw UnsupportedError('No MmexDatabase implementation for this platform.');
