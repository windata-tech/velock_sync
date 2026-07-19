import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_blob_cipher.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_key_deriver.dart';

void main() {
  group('GenericVaultBlobCipher', () {
    late GenericVaultBlobCipher cipher;

    setUp(() {
      cipher = GenericVaultBlobCipher(
        keyDeriver: GenericVaultKeyDeriver(
          Uint8List.fromList(List<int>.generate(32, (index) => index)),
        ),
        keyId: 'key-1',
        chunkSize: 3,
        secureBytes: (length) =>
            Uint8List.fromList(List<int>.filled(length, 7)),
      );
    });

    test(
      'round-trips chunked plaintext and reports exact artifact length',
      () async {
        final plaintext = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7]);
        final encrypted = Uint8List.fromList(
          await _collect(
            cipher.encrypt(
              vaultId: 'vault-1',
              blobId: 'blob-1',
              plaintextLength: plaintext.length,
              plaintext: Stream.fromIterable([
                plaintext.sublist(0, 2),
                plaintext.sublist(2),
              ]),
            ),
          ),
        );

        expect(encrypted.length, cipher.encryptedLengthFor(plaintext.length));
        expect(
          await cipher.decrypt(
            vaultId: 'vault-1',
            blobId: 'blob-1',
            encrypted: encrypted,
          ),
          plaintext,
        );
      },
    );

    test('rejects ciphertext and AAD identity tampering', () async {
      final encrypted = Uint8List.fromList(
        await _collect(
          cipher.encrypt(
            vaultId: 'vault-1',
            blobId: 'blob-1',
            plaintextLength: 3,
            plaintext: Stream.value([1, 2, 3]),
          ),
        ),
      );
      encrypted[encrypted.length - 1] ^= 1;

      await expectLater(
        cipher.decrypt(
          vaultId: 'vault-1',
          blobId: 'blob-1',
          encrypted: encrypted,
        ),
        throwsA(isA<GenericVaultBlobFormatException>()),
      );
    });
  });
}

Future<List<int>> _collect(Stream<List<int>> stream) async {
  final result = <int>[];
  await for (final part in stream) {
    result.addAll(part);
  }
  return result;
}
