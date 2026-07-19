import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/infrastructure/secure_storage/device_signing_key_store.dart';

/// Test-only implementation; production callers use secure platform storage.
class InMemoryDeviceSigningKeyStore implements DeviceSigningKeyStore {
  InMemoryDeviceSigningKeyStore({Uuid? uuid, Ed25519? algorithm})
    : _uuid = uuid ?? const Uuid(),
      _algorithm = algorithm ?? Ed25519();

  final Uuid _uuid;
  final Ed25519 _algorithm;
  final Map<String, Uint8List> _seeds = {};

  @override
  Future<String> writeEd25519Key(SimpleKeyPair keyPair) async {
    final seed = await keyPair.extractPrivateKeyBytes();
    if (seed.length != 32) {
      throw ArgumentError.value(seed.length, 'seed.length', 'must be 32');
    }
    final ref = 'velock-sync/device-signing/${_uuid.v4()}';
    _seeds[ref] = Uint8List.fromList(seed);
    return ref;
  }

  @override
  Future<SimpleKeyPair?> readEd25519Key(String keyRef) async {
    final seed = _seeds[keyRef];
    return seed == null ? null : _algorithm.newKeyPairFromSeed(seed);
  }

  @override
  Future<void> delete(String keyRef) async {
    _seeds.remove(keyRef);
  }
}
