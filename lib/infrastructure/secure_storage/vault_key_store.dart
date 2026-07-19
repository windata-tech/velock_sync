import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

/// Keeps Generic Vault root keys out of preferences, SQLite, and sync payloads.
/// Callers persist only the returned opaque reference in local profile state.
abstract interface class VaultKeyStore {
  Future<String> writeRootKey(Uint8List rootKey);

  Future<Uint8List?> readRootKey(String keyRef);

  Future<void> delete(String keyRef);
}

class SecureVaultKeyStore implements VaultKeyStore {
  SecureVaultKeyStore({FlutterSecureStorage? storage, Uuid? uuid})
    : _storage = storage ?? const FlutterSecureStorage(),
      _uuid = uuid ?? const Uuid();

  static const _prefix = 'velock-sync/vault-root/';

  final FlutterSecureStorage _storage;
  final Uuid _uuid;

  @override
  Future<String> writeRootKey(Uint8List rootKey) async {
    _validateRootKey(rootKey);
    final keyRef = '$_prefix${_uuid.v4()}';
    await _storage.write(
      key: keyRef,
      value: base64UrlEncode(rootKey).replaceAll('=', ''),
    );
    return keyRef;
  }

  @override
  Future<Uint8List?> readRootKey(String keyRef) async {
    if (!keyRef.startsWith(_prefix)) return null;
    final encoded = await _storage.read(key: keyRef);
    if (encoded == null) return null;
    try {
      final padding = '=' * ((4 - encoded.length % 4) % 4);
      final rootKey = Uint8List.fromList(base64Url.decode('$encoded$padding'));
      _validateRootKey(rootKey);
      return rootKey;
    } on FormatException {
      throw StateError('Stored vault root key has an invalid encoding.');
    }
  }

  @override
  Future<void> delete(String keyRef) => _storage.delete(key: keyRef);
}

void _validateRootKey(Uint8List rootKey) {
  if (rootKey.length != 32) {
    throw ArgumentError.value(rootKey.length, 'rootKey.length', 'must be 32');
  }
}
