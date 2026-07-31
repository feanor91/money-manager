import 'dart:convert';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;

/// Shared AES-256-CBC codec for this app's small local settings files (see
/// [EncryptedFilePreferences] in state/app_preferences.dart, and
/// DatabaseCompanionSettings) - "encrypted" here means resistant to
/// casually being opened in a text editor, not real security: the key is
/// embedded in the app itself, so anyone with the app's source/binary can
/// derive it too. Acceptable since these files only ever hold app
/// preferences/PIN hash+salt, never the actual financial data (which stays
/// in the plain .mmb SQLite file, as MMEX itself always has it).
final _key = enc.Key.fromUtf8('Mn8rF2kLpX9qT4wZaC7uJ6yH1sE3bV0d');

Map<String, Object?> decryptSettingsBytes(Uint8List raw) {
  if (raw.length <= 16) return {};
  final iv = enc.IV(raw.sublist(0, 16));
  final encrypter = enc.Encrypter(enc.AES(_key, mode: enc.AESMode.cbc));
  final plain = encrypter.decrypt(enc.Encrypted(raw.sublist(16)), iv: iv);
  return (jsonDecode(plain) as Map).cast<String, Object?>();
}

Uint8List encryptSettingsBytes(Map<String, Object?> data) {
  final iv = enc.IV.fromSecureRandom(16);
  final encrypter = enc.Encrypter(enc.AES(_key, mode: enc.AESMode.cbc));
  final cipher = encrypter.encrypt(jsonEncode(data), iv: iv);
  return Uint8List.fromList([...iv.bytes, ...cipher.bytes]);
}
