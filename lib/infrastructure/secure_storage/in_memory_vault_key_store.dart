import 'dart:typed_data';

import 'package:uuid/uuid.dart';
import 'package:velock_sync/infrastructure/secure_storage/vault_key_store.dart';

/// Test-only vault key store. Production code must use [SecureVaultKeyStore].
class InMemoryVaultKeyStore implements VaultKeyStore {
  InMemoryVaultKeyStore({Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final Uuid _uuid;
  final Map<String, Uint8List> _values = {};

  @override
  Future<void> delete(String keyRef) async {
    _values.remove(keyRef);
  }

  @override
  Future<Uint8List?> readRootKey(String keyRef) async => _values[keyRef];

  @override
  Future<String> writeRootKey(Uint8List rootKey) async {
    if (rootKey.length != 32) {
      throw ArgumentError.value(rootKey.length, 'rootKey.length', 'must be 32');
    }
    final keyRef = 'velock-sync/vault-root/${_uuid.v4()}';
    _values[keyRef] = Uint8List.fromList(rootKey);
    return keyRef;
  }
}
