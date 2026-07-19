import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_blob_cipher.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_key_deriver.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_operations_cipher.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_operations_codec.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/engine/vault_protocol.dart';

void main() {
  const root = 'test_vectors/protocol_v1';

  test('accepts the canonical V1 protocol vector', () {
    final document = VaultProtocolDocument.parse(
      _utf8Vector('$root/valid/protocol.utf8.json'),
    );

    expect(document.vaultId, 'vault-vector-1');
    expect(document.createdAt, DateTime.utc(2026, 7, 15));
  });

  test('rejects the unsupported-version protocol vector', () {
    expect(
      () => VaultProtocolDocument.parse(
        _bytes('$root/unsupported_version/protocol.json'),
      ),
      throwsFormatException,
    );
  });

  test('rejects path-traversal identifier vector', () {
    final value = _json('$root/path_traversal/identifiers.json');

    expect(
      () => LogicalKeys.protocol(value['vaultId']! as String),
      throwsArgumentError,
    );
    expect(
      () => LogicalKeys.blob('vault-vector-1', value['blobId']! as String),
      throwsArgumentError,
    );
  });

  test('rejects the replayed operation vector before import', () {
    const context = OperationsCipherContext(
      vaultId: 'vault-vector-1',
      batchId: 'batch-vector-1',
      sourceDeviceId: 'device-vector-1',
      sequence: 1,
      keyId: 'key-1',
    );

    expect(
      () => const GenericVaultOperationsCodec().decode(
        context: context,
        plaintext: _bytes('$root/replay/operations.json'),
      ),
      throwsFormatException,
    );
  });

  test('rejects forged and truncated blob vectors', () async {
    final cipher = GenericVaultBlobCipher(
      keyDeriver: GenericVaultKeyDeriver(Uint8List(32)),
      keyId: 'key-1',
    );
    for (final path in [
      '$root/invalid_authentication/blob.hex',
      '$root/corrupted_blob/blob.hex',
    ]) {
      await expectLater(
        cipher.decrypt(
          vaultId: 'vault-vector-1',
          blobId: 'blob-vector-1',
          encrypted: _hex(path),
        ),
        throwsA(isA<GenericVaultBlobFormatException>()),
      );
    }
  });

  test('accepts the RFC 8032 Ed25519 signature vector', () async {
    final vector = _json('$root/valid/ed25519_signature.json');
    final verified = await Ed25519().verify(
      _hexFromString(vector['messageHex']! as String),
      signature: Signature(
        _hexFromString(vector['signatureHex']! as String),
        publicKey: SimplePublicKey(
          _hexFromString(vector['publicKeyHex']! as String),
          type: KeyPairType.ed25519,
        ),
      ),
    );
    expect(verified, isTrue);
  });

  test('rejects a tampered RFC 8032 Ed25519 signature', () async {
    final vector = _json('$root/valid/ed25519_signature.json');
    final signature = _hexFromString(vector['signatureHex']! as String);
    signature[0] ^= 1;
    final verified = await Ed25519().verify(
      _hexFromString(vector['messageHex']! as String),
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(
          _hexFromString(vector['publicKeyHex']! as String),
          type: KeyPairType.ed25519,
        ),
      ),
    );
    expect(verified, isFalse);
  });
}

Uint8List _bytes(String path) =>
    Uint8List.fromList(File(path).readAsBytesSync());

Uint8List _utf8Vector(String path) {
  final value = _json(path)['value'];
  if (value is! String) throw FormatException('Invalid UTF-8 vector: $path');
  return Uint8List.fromList(utf8.encode(value));
}

Map<String, Object?> _json(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

Uint8List _hex(String path) {
  return _hexFromString(File(path).readAsStringSync().trim());
}

Uint8List _hexFromString(String source) {
  if (source.length.isOdd) throw FormatException('Invalid hex');
  return Uint8List.fromList([
    for (var index = 0; index < source.length; index += 2)
      int.parse(source.substring(index, index + 2), radix: 16),
  ]);
}
