import 'package:flutter_test/flutter_test.dart';
import 'package:money_manager/services/update_checker.dart';

void main() {
  group('isNewerVersion', () {
    test('a higher patch/minor/major is newer', () {
      expect(isNewerVersion('1.0.32', '1.0.31'), isTrue);
      expect(isNewerVersion('1.1.0', '1.0.31'), isTrue);
      expect(isNewerVersion('2.0.0', '1.9.9'), isTrue);
    });

    test('an equal or lower version is not newer', () {
      expect(isNewerVersion('1.0.31', '1.0.31'), isFalse);
      expect(isNewerVersion('1.0.30', '1.0.31'), isFalse);
      expect(isNewerVersion('0.9.9', '1.0.0'), isFalse);
    });

    test('ignores a trailing build number', () {
      expect(isNewerVersion('1.0.32', '1.0.31+34'), isTrue);
      expect(isNewerVersion('1.0.31+40', '1.0.31+34'), isFalse);
    });

    test('handles uneven segment counts by padding with zero', () {
      expect(isNewerVersion('1.0.1', '1.0'), isTrue);
      expect(isNewerVersion('1.0', '1.0.0'), isFalse);
    });

    test('fails closed on malformed input', () {
      expect(isNewerVersion('not-a-version', '1.0.31'), isFalse);
      expect(isNewerVersion('1.0.32', 'not-a-version'), isFalse);
    });
  });
}
