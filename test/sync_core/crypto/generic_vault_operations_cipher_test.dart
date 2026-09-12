import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_key_deriver.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_operations_cipher.dart';

void main() {
  group('GenericVaultOperationsCipher', () {
    final context = OperationsCipherContext(
      vaultId: 'vault-1',
      batchId: 'batch-1',
      sourceDeviceId: 'device-1',
      sequence: 1,
      keyId: 'key-1',
    );
    final cipher = GenericVaultOperationsCipher(
      keyDeriver: GenericVaultKeyDeriver(
        Uint8List.fromList(List<int>.generate(32, (index) => index)),
      ),
      secureBytes: (length) => List<int>.filled(length, 9),
    );

    test(
      'round-trips operations with a canonical authenticated header',
      () async {
        final plaintext = Uint8List.fromList([1, 2, 3, 4]);
        final encrypted = await cipher.encrypt(
          context: context,
          plaintext: plaintext,
        );

        expect(String.fromCharCodes(encrypted.sublist(0, 4)), 'VLSO');
        expect(
          await cipher.decrypt(context: context, encrypted: encrypted),
          plaintext,
        );
      },
    );

    test('rejects a mismatched context or ciphertext', () async {
      final encrypted = await cipher.encrypt(
        context: context,
        plaintext: Uint8List.fromList([1, 2, 3]),
      );
      await expectLater(
        cipher.decrypt(
          context: OperationsCipherContext(
            vaultId: 'vault-1',
            batchId: 'batch-other',
            sourceDeviceId: 'device-1',
            sequence: 1,
            keyId: 'key-1',
          ),
          encrypted: encrypted,
        ),
        throwsA(isA<GenericVaultOperationsFormatException>()),
      );
      encrypted[encrypted.length - 1] ^= 1;
      await expectLater(
        cipher.decrypt(context: context, encrypted: encrypted),
        throwsA(isA<GenericVaultOperationsFormatException>()),
      );
    });
  });
}
