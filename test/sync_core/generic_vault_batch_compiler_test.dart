import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_batch_envelope.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_key_deriver.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_operations_cipher.dart';
import 'package:velock_sync/sync_core/engine/generic_vault_batch_compiler.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

void main() {
  test(
    'compiles encrypted operations, signed envelope, and final commit',
    () async {
      final context = OperationsCipherContext(
        vaultId: 'vault-1',
        batchId: 'batch-1',
        sourceDeviceId: 'device-1',
        sequence: 1,
        keyId: 'key-1',
      );
      final cipher = GenericVaultOperationsCipher(
        keyDeriver: GenericVaultKeyDeriver(Uint8List(32)),
        secureBytes: (length) => List<int>.filled(length, 5),
      );
      final compiler = GenericVaultBatchCompiler(
        operationsCipher: cipher,
        envelopeSigner: GenericVaultBatchEnvelopeSigner(),
        now: () => DateTime.utc(2026, 7, 15),
      );
      final blobBytes = Uint8List.fromList([9, 8, 7]);
      final blob = PreparedBlob(
        descriptor: BlobDescriptor(
          blobId: 'blob-1',
          cipherSize: blobBytes.length,
          cipherSha256: sha256.convert(blobBytes).toString(),
          chunkSize: 4,
        ),
        content: ImmutableArtifact.fromBytes(blobBytes),
      );
      final batch = await compiler.compile(
        context: context,
        operations: [
          SyncOperation(
            operationId: 'op-1',
            entityId: 'entity-1',
            entityKind: 'file',
            type: SyncOperationType.upsert,
            versionVector: VersionVector({'device-1': 1}),
            revisionId: 'revision-1',
            protectedPayload: Uint8List.fromList(utf8.encode('private name')),
            blobIds: const ['blob-1'],
            createdAt: DateTime.utc(2026, 7, 15),
          ),
        ],
        blobs: [blob],
        signingKey: await Ed25519().newKeyPair(),
      );

      final envelope = utf8.decode(
        await _collect(await batch.envelope.openRead()),
      );
      final operations = Uint8List.fromList(
        await _collect(await batch.operations.openRead()),
      );
      final commit =
          jsonDecode(utf8.decode(await _collect(await batch.commit.openRead())))
              as Map<String, dynamic>;
      expect(envelope, isNot(contains('private name')));
      expect(
        utf8.decode(
          await cipher.decrypt(context: context, encrypted: operations),
        ),
        contains('cHJpdmF0ZSBuYW1l'),
      );
      expect(commit['batchId'], 'batch-1');
      expect(
        commit['envelopeSha256'],
        sha256.convert(utf8.encode(envelope)).toString(),
      );
    },
  );
}

Future<List<int>> _collect(Stream<List<int>> stream) async {
  final bytes = <int>[];
  await for (final part in stream) {
    bytes.addAll(part);
  }
  return bytes;
}
