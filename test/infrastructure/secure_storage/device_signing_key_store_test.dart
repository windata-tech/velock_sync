import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/secure_storage/in_memory_device_signing_key_store.dart';

void main() {
  test(
    'restores the same Ed25519 signing identity behind an opaque reference',
    () async {
      final algorithm = Ed25519();
      final store = InMemoryDeviceSigningKeyStore(algorithm: algorithm);
      final original = await algorithm.newKeyPair();
      final ref = await store.writeEd25519Key(original);
      final restored = await store.readEd25519Key(ref);
      final message = utf8.encode('batch signing payload');

      expect(ref, startsWith('velock-sync/device-signing/'));
      expect(restored, isNotNull);
      expect(
        await algorithm.verify(
          message,
          signature: await algorithm.sign(message, keyPair: restored!),
        ),
        isTrue,
      );
      expect(
        (await original.extractPublicKey()).bytes,
        (await restored.extractPublicKey()).bytes,
      );

      await store.delete(ref);
      expect(await store.readEd25519Key(ref), isNull);
    },
  );
}
