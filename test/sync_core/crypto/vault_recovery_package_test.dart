import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/secure_storage/in_memory_vault_key_store.dart';
import 'package:velock_sync/sync_core/crypto/vault_recovery_package.dart';

void main() {
  final rootKey = Uint8List.fromList(List<int>.generate(32, (index) => index));

  test(
    'round-trips a Generic Vault root key through an opaque package',
    () async {
      final codec = VaultRecoveryPackageCodec(
        iterations: 100000,
        randomBytes: (length) => Uint8List.fromList(
          List<int>.generate(length, (index) => index + length),
        ),
      );

      final recoveryPackage = await codec.create(
        rootKey: rootKey,
        passphrase: 'correct horse battery staple',
      );

      expect(recoveryPackage, startsWith('VLSR1.'));
      expect(recoveryPackage, isNot(contains('AAECAwQFBgcICQoLDA0ODw')));
      expect(
        await codec.restore(
          recoveryPackage: recoveryPackage,
          passphrase: 'correct horse battery staple',
        ),
        rootKey,
      );
    },
  );

  test(
    'rejects a wrong passphrase or malformed package without returning a key',
    () async {
      final codec = VaultRecoveryPackageCodec(iterations: 100000);
      final recoveryPackage = await codec.create(
        rootKey: rootKey,
        passphrase: 'passphrase',
      );

      await expectLater(
        codec.restore(recoveryPackage: recoveryPackage, passphrase: 'wrong'),
        throwsA(isA<VaultRecoveryPackageException>()),
      );
      await expectLater(
        codec.restore(
          recoveryPackage: 'VLSR1.not-base64!',
          passphrase: 'passphrase',
        ),
        throwsA(isA<VaultRecoveryPackageException>()),
      );
    },
  );

  test(
    'imports a recovered root key into secure-storage abstraction',
    () async {
      final store = InMemoryVaultKeyStore();
      final codec = VaultRecoveryPackageCodec(iterations: 100000);
      final sourceRef = await store.writeRootKey(rootKey);
      final service = GenericVaultRecoveryService(store, codec: codec);

      final recoveryPackage = await service.export(
        rootKeyRef: sourceRef,
        passphrase: 'passphrase',
      );
      await store.delete(sourceRef);
      final restoredRef = await service.import(
        recoveryPackage: recoveryPackage,
        passphrase: 'passphrase',
      );

      expect(restoredRef, isNot(sourceRef));
      expect(await store.readRootKey(restoredRef), rootKey);
    },
  );

  test('round-trips authenticated recovery trust anchors', () async {
    final store = InMemoryVaultKeyStore();
    final codec = VaultRecoveryPackageCodec(iterations: 100000);
    final sourceRef = await store.writeRootKey(rootKey);
    final service = GenericVaultRecoveryService(store, codec: codec);
    final signingKey = Uint8List.fromList(List<int>.filled(32, 9));

    final recoveryPackage = await service.exportBundle(
      rootKeyRef: sourceRef,
      vaultId: 'vault-1',
      trustedDevices: {'source-device': signingKey},
      passphrase: 'passphrase',
    );
    final recovered = await service.importBundle(
      recoveryPackage: recoveryPackage,
      passphrase: 'passphrase',
      expectedVaultId: 'vault-1',
    );

    expect(await store.readRootKey(recovered.rootKeyRef), rootKey);
    expect(recovered.vaultId, 'vault-1');
    expect(recovered.trustedDevices['source-device'], signingKey);
    await expectLater(
      service.importBundle(
        recoveryPackage: recoveryPackage,
        passphrase: 'passphrase',
        expectedVaultId: 'different-vault',
      ),
      throwsA(isA<VaultRecoveryPackageException>()),
    );
  });
}
