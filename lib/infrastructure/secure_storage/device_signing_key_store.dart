import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

/// Stores only an Ed25519 seed in platform secure storage. Sync state and
/// preferences retain the returned opaque reference, never signing material.
abstract interface class DeviceSigningKeyStore {
  Future<String> writeEd25519Key(SimpleKeyPair keyPair);

  Future<SimpleKeyPair?> readEd25519Key(String keyRef);

  Future<void> delete(String keyRef);
}

class SecureDeviceSigningKeyStore implements DeviceSigningKeyStore {
  SecureDeviceSigningKeyStore({
    FlutterSecureStorage? storage,
    Uuid? uuid,
    Ed25519? algorithm,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _uuid = uuid ?? const Uuid(),
       _algorithm = algorithm ?? Ed25519();

  static const _prefix = 'velock-sync/device-signing/';

  final FlutterSecureStorage _storage;
  final Uuid _uuid;
  final Ed25519 _algorithm;

  @override
  Future<String> writeEd25519Key(SimpleKeyPair keyPair) async {
    final seed = await keyPair.extractPrivateKeyBytes();
    _validateSeed(seed);
    final keyRef = '$_prefix${_uuid.v4()}';
    await _storage.write(key: keyRef, value: _encode(seed));
    return keyRef;
  }

  @override
  Future<SimpleKeyPair?> readEd25519Key(String keyRef) async {
    if (!keyRef.startsWith(_prefix)) return null;
    final encoded = await _storage.read(key: keyRef);
    if (encoded == null) return null;
    try {
      final seed = _decode(encoded);
      _validateSeed(seed);
      return _algorithm.newKeyPairFromSeed(seed);
    } on FormatException {
      throw StateError('Stored device signing key has an invalid encoding.');
    }
  }

  @override
  Future<void> delete(String keyRef) => _storage.delete(key: keyRef);
}

String _encode(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');

Uint8List _decode(String value) {
  final padding = '=' * ((4 - value.length % 4) % 4);
  return Uint8List.fromList(base64Url.decode('$value$padding'));
}

void _validateSeed(List<int> seed) {
  if (seed.length != 32) {
    throw ArgumentError.value(seed.length, 'seed.length', 'must be 32');
  }
}
