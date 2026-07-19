import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_batch_envelope.dart';

void main() {
  group('GenericVaultBatchEnvelopeSigner', () {
    late GenericVaultBatchEnvelopeSigner signer;
    late KeyPair keyPair;

    setUp(() async {
      signer = GenericVaultBatchEnvelopeSigner();
      keyPair = await Ed25519().newKeyPair();
    });

    test(
      'signs an envelope without exposing path-like payload fields',
      () async {
        final signed = await signer.sign(draft: _draft(), keyPair: keyPair);
        final decoded =
            jsonDecode(utf8.decode(signed.bytes)) as Map<String, dynamic>;

        expect(await signer.verify(signed), isTrue);
        expect(decoded['protocol'], 'velock-sync');
        expect(decoded['signatureAlgorithm'], 'Ed25519');
        expect(decoded['signature'], isNotEmpty);
        expect(
          utf8.decode(signed.bytes),
          isNot(contains('Documents/secret.txt')),
        );
      },
    );

    test('commit marker binds the exact envelope hash', () async {
      final draft = _draft();
      final signed = await signer.sign(draft: draft, keyPair: keyPair);
      final marker =
          jsonDecode(
                utf8.decode(
                  signer.commitMarker(
                    draft: draft,
                    envelope: signed.bytes,
                    committedAt: DateTime.utc(2026, 7, 15),
                  ),
                ),
              )
              as Map<String, dynamic>;

      expect(marker['batchId'], 'batch-1');
      expect(marker['envelopeSha256'], hasLength(64));
    });

    test(
      'accepts only a canonical envelope signed by a trusted device',
      () async {
        final signed = await signer.sign(draft: _draft(), keyPair: keyPair);
        final verified = await signer.parseAndVerify(
          envelope: signed.bytes,
          trustedPublicKey: await keyPair.extractPublicKey(),
        );
        expect(verified.draft.batchId, 'batch-1');

        final reordered = utf8.encode(
          utf8.decode(signed.bytes).replaceFirst('{', '{ '),
        );
        await expectLater(
          signer.parseAndVerify(
            envelope: Uint8List.fromList(reordered),
            trustedPublicKey: await keyPair.extractPublicKey(),
          ),
          throwsFormatException,
        );
      },
    );
  });
}

GenericVaultBatchEnvelopeDraft _draft() => GenericVaultBatchEnvelopeDraft(
  vaultId: 'vault-1',
  sourceDeviceId: 'device-1',
  sequence: 1,
  batchId: 'batch-1',
  keyId: 'key-1',
  createdAt: DateTime.utc(2026, 7, 15),
  operationsCipherSize: 12,
  operationsCipherSha256:
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  operationCount: 1,
  blobs: const [
    BatchBlobReference(
      blobId: 'blob-1',
      logicalKey: 'velock-sync/v1/vault-1/blobs/bl/blob-1.blob',
      cipherSize: 100,
      cipherSha256:
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      chunkSize: 4194304,
    ),
  ],
);
