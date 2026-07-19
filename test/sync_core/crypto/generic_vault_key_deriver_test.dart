import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_key_deriver.dart';

void main() {
  group('GenericVaultKeyDeriver', () {
    test('matches RFC 5869 HKDF-SHA256 test vector 1', () {
      final key = GenericVaultKeyDeriver.hkdfSha256(
        inputKeyMaterial: List<int>.filled(22, 0x0b),
        salt: List<int>.generate(13, (index) => index),
        info: List<int>.generate(10, (index) => 0xf0 + index),
        length: 42,
      );

      expect(
        _hex(key),
        '3cb25f25faacd57a90434f64d0362f2a'
        '2d2d0a90cf1a5a4c5db02d56ecc4c5bf'
        '34007208d5b887185865',
      );
    });

    test('derives independent metadata, identifier, and blob keys', () {
      final deriver = GenericVaultKeyDeriver(
        Uint8List.fromList(List<int>.generate(32, (index) => index)),
      );

      final metadata = deriver.metadataKey('vault-1');
      final identifier = deriver.identifierKey('vault-1');
      final blobA = deriver.blobKey(vaultId: 'vault-1', blobId: 'blob-a');
      final blobB = deriver.blobKey(vaultId: 'vault-1', blobId: 'blob-b');
      expect(metadata, hasLength(32));
      expect(identifier, hasLength(32));
      expect(blobA, hasLength(32));
      expect(_hex(metadata), isNot(_hex(identifier)));
      expect(_hex(blobA), isNot(_hex(blobB)));
    });

    test('rejects malformed root keys', () {
      expect(() => GenericVaultKeyDeriver(Uint8List(31)), throwsArgumentError);
    });
  });
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
