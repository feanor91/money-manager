Future<void> save({
  required String label,
  required List<int> bytes,
  required int retentionWeeks,
}) async {
  throw UnsupportedError('DbBackup is not supported on this platform.');
}
