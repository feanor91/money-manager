import 'package:money_manager_server/auth/token_store.dart';
import 'package:test/test.dart';

void main() {
  test('an issued token is valid', () {
    final store = TokenStore();
    final token = store.issue();
    expect(store.isValid(token), isTrue);
  });

  test('an unknown token is invalid', () {
    final store = TokenStore();
    expect(store.isValid('n-importe-quoi'), isFalse);
  });

  test('a revoked token is no longer valid', () {
    final store = TokenStore();
    final token = store.issue();
    store.revoke(token);
    expect(store.isValid(token), isFalse);
  });

  test('an expired token is no longer valid', () {
    final store = TokenStore(ttl: const Duration(seconds: -1));
    final token = store.issue();
    expect(store.isValid(token), isFalse);
  });

  test('two issued tokens are different', () {
    final store = TokenStore();
    expect(store.issue(), isNot(equals(store.issue())));
  });
}
