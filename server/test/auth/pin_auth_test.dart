import 'package:money_manager_server/auth/pin_auth.dart';
import 'package:test/test.dart';

void main() {
  test('correct pin succeeds', () {
    final auth = PinAuthenticator(pin: '1234');
    expect(auth.verify('1234').ok, isTrue);
  });

  test('wrong pin reports remaining attempts, never locks on its own', () {
    final auth = PinAuthenticator(pin: '1234');
    final result = auth.verify('0000');
    expect(result.ok, isFalse);
    expect(result.attemptsRemaining, PinAuthenticator.maxAttempts - 1);
    expect(result.lockoutRemaining, isNull);
  });

  test('locks out after maxAttempts consecutive wrong attempts', () {
    final auth = PinAuthenticator(pin: '1234');
    for (var i = 0; i < PinAuthenticator.maxAttempts - 1; i++) {
      auth.verify('0000');
    }
    final result = auth.verify('0000');
    expect(result.ok, isFalse);
    expect(result.lockoutRemaining, isNotNull);
    expect(result.lockoutRemaining!.inMinutes, PinAuthenticator.lockoutDuration.inMinutes);
  });

  test('a correct pin resets the failed-attempts counter', () {
    final auth = PinAuthenticator(pin: '1234');
    auth.verify('0000');
    auth.verify('0000');
    expect(auth.verify('1234').ok, isTrue);
    // Back to a fresh count of maxAttempts - 1 remaining, not exhausted.
    final result = auth.verify('0000');
    expect(result.attemptsRemaining, PinAuthenticator.maxAttempts - 1);
  });

  test('still locked out reports the same lockout while it lasts', () {
    final auth = PinAuthenticator(pin: '1234');
    for (var i = 0; i < PinAuthenticator.maxAttempts; i++) {
      auth.verify('0000');
    }
    // Even the *correct* pin is refused while locked out - matches
    // PinLockProvider's own behaviour client-side.
    final result = auth.verify('1234');
    expect(result.ok, isFalse);
    expect(result.lockoutRemaining, isNotNull);
  });
}
