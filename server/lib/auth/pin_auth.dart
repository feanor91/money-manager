import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Résultat d'une tentative de vérification du code PIN - même forme que
/// [PinVerifyResult] côté appli (lib/state/pin_lock_provider.dart), pas
/// encore partagée car ce fichier appli dépend de choses spécifiques au
/// client (Flutter). À unifier plus tard si utile.
class PinVerifyResult {
  final bool ok;
  final int? attemptsRemaining;
  final Duration? lockoutRemaining;

  const PinVerifyResult._(this.ok, this.attemptsRemaining, this.lockoutRemaining);

  static const success = PinVerifyResult._(true, null, null);
  static PinVerifyResult wrong(int attemptsRemaining) =>
      PinVerifyResult._(false, attemptsRemaining, null);
  static PinVerifyResult lockedOut(Duration remaining) =>
      PinVerifyResult._(false, null, remaining);
}

/// Vérifie un code PIN contre un salt+hash, avec compteur de tentatives et
/// blocage temporaire - même principe que PinLockProvider.verify côté
/// appli (lib/state/pin_lock_provider.dart), mais en mémoire seulement ici
/// (pas encore persisté sur disque entre deux redémarrages du serveur -
/// limitation connue, à corriger quand le stockage de réglages côté
/// serveur existera, voir PLAN_ARCHITECTURE_CLIENT_SERVEUR.md niveau 2).
class PinAuthenticator {
  static const int maxAttempts = 5;
  static const Duration lockoutDuration = Duration(minutes: 15);

  final String _salt;
  final String _expectedHash;
  int _failedAttempts = 0;
  DateTime? _lockedUntil;

  PinAuthenticator({required String pin, String? salt})
      : this._(salt ?? _randomSalt(), pin);

  PinAuthenticator._(String salt, String pin)
      : _salt = salt,
        _expectedHash = _hash(pin, salt);

  static String _randomSalt() =>
      List.generate(16, (_) => Random.secure().nextInt(256)).join(',');

  static String _hash(String pin, String salt) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();

  PinVerifyResult verify(String pin) {
    final lockedUntil = _lockedUntil;
    if (lockedUntil != null) {
      final remaining = lockedUntil.difference(DateTime.now());
      if (remaining > Duration.zero) {
        return PinVerifyResult.lockedOut(remaining);
      }
      _lockedUntil = null;
      _failedAttempts = 0;
    }

    if (_hash(pin, _salt) == _expectedHash) {
      _failedAttempts = 0;
      return PinVerifyResult.success;
    }

    _failedAttempts++;
    if (_failedAttempts >= maxAttempts) {
      _lockedUntil = DateTime.now().add(lockoutDuration);
      _failedAttempts = 0;
      return PinVerifyResult.lockedOut(lockoutDuration);
    }
    return PinVerifyResult.wrong(maxAttempts - _failedAttempts);
  }
}
