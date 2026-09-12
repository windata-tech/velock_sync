import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_batch_preparer.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_dataset_adapter.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_incoming_applier.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_scanner.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/staging/batch_staging_store.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_acknowledgement.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_batch_envelope.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_blob_cipher.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_key_deriver.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_operations_cipher.dart';
import 'package:velock_sync/sync_core/engine/generic_vault_batch_compiler.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/engine/sync_download_engine.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';

void main() {
  test(
    'downloads a signed encrypted V1 file batch into Selected Folder',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'velock-download-root-',
      );
      final staging = await Directory.systemTemp.createTemp(
        'velock-download-stage-',
      );
      final database = await SyncStateDatabase.inMemory();
      addTearDown(() async {
        await database.close();
        await root.delete(recursive: true);
        await staging.delete(recursive: true);
      });
      final deriver = GenericVaultKeyDeriver(Uint8List(32));
      final blobCipher = GenericVaultBlobCipher(
        keyDeriver: deriver,
        keyId: 'key-1',
        chunkSize: 4,
        secureBytes: (_) => Uint8List(8),
      );
      final operationsCipher = GenericVaultOperationsCipher(
        keyDeriver: deriver,
      );
      final signer = GenericVaultBatchEnvelopeSigner();
      final sourceKeyPair = await Ed25519().newKeyPair();
      final sourcePublicKey = await sourceKeyPair.extractPublicKey();
      await database.trustDevice(
        vaultId: 'vault-1',
        deviceId: 'source-device',
        signingPublicKey: Uint8List.fromList(sourcePublicKey.bytes),
      );
      final encryptedBlob = await _encryptBlob(
        blobCipher,
        vaultId: 'vault-1',
        blobId: 'blob-1',
        text: 'downloaded content',
      );
      final compiler = GenericVaultBatchCompiler(
        operationsCipher: operationsCipher,
        envelopeSigner: signer,
        now: () => DateTime.utc(2026, 7, 15),
      );
      final batch = await compiler.compile(
        context: const OperationsCipherContext(
          vaultId: 'vault-1',
          batchId: 'batch-1',
          sourceDeviceId: 'source-device',
          sequence: 1,
          keyId: 'key-1',
        ),
        operations: [
          SyncOperation(
            operationId: 'operation-1',
            entityId: 'entity-1',
            entityKind: 'file',
            type: SyncOperationType.upsert,
            versionVector: VersionVector({'source-device': 1}),
            revisionId: 'revision-1',
            protectedPayload: Uint8List.fromList(
              utf8.encode(
                jsonEncode({
                  'entryType': 'file',
                  'relativePath': 'nested/note.txt',
                  'size': 18,
                  'modifiedAt': '2026-07-15T00:00:00.000Z',
                  'deletedAt': null,
                }),
              ),
            ),
            blobIds: const ['blob-1'],
            createdAt: DateTime.utc(2026, 7, 15),
          ),
        ],
        blobs: [
          PreparedBlob(
            descriptor: BlobDescriptor(
              blobId: 'blob-1',
              cipherSize: encryptedBlob.length,
              cipherSha256: sha256.convert(encryptedBlob).toString(),
              chunkSize: 4,
            ),
            content: ImmutableArtifact.fromBytes(encryptedBlob),
          ),
        ],
        signingKey: sourceKeyPair,
      );
      final remote = InMemoryObjectStore();
      await _put(
        remote,
        LogicalKeys.blob('vault-1', 'blob-1'),
        batch.blobs.single.content,
      );
      await _put(
        remote,
        LogicalKeys.batchOperations('vault-1', 'source-device', 1, 'batch-1'),
        batch.operations,
      );
      await _put(
        remote,
        LogicalKeys.batchEnvelope('vault-1', 'source-device', 1, 'batch-1'),
        batch.envelope,
      );
      await _put(
        remote,
        LogicalKeys.commit('vault-1', 'source-device', 1, 'batch-1'),
        batch.commit,
      );

      final adapter = SelectedFolderDatasetAdapter(
        datasetId: 'folder-1',
        profileId: 'profile-1',
        vaultId: 'vault-1',
        sourceDeviceId: 'target-device',
        displayName: 'Target Folder',
        root: root,
        keyId: 'key-1',
        signingKey: await Ed25519().newKeyPair(),
        database: database,
        scanner: SelectedFolderScanner(database),
        staging: BatchStagingStore(staging),
        batchPreparer: SelectedFolderBatchPreparer(
          blobCipher: blobCipher,
          compiler: compiler,
          staging: BatchStagingStore(staging),
        ),
        envelopeSigner: signer,
        acknowledgementSigner: GenericVaultAcknowledgementSigner(),
        operationsCipher: operationsCipher,
        incomingApplier: SelectedFolderIncomingApplier(
          root: root,
          datasetId: 'folder-1',
          profileId: 'profile-1',
          database: database,
          blobCipher: blobCipher,
        ),
      );

      final result = await SyncDownloadEngine(database).importAvailable(
        profileId: 'profile-1',
        vaultId: 'vault-1',
        consumerDeviceId: 'target-device',
        trustedProducerDeviceIds: const ['source-device'],
        dataset: adapter,
        remote: remote,
      );

      expect(result.importedBatchCount, 1);
      expect(
        await File('${root.path}/nested/note.txt').readAsString(),
        'downloaded content',
      );
      expect(
        await database.appliedSequence(
          profileId: 'profile-1',
          producerDeviceId: 'source-device',
        ),
        1,
      );
      final acknowledgementKey = LogicalKeys.acknowledgement(
        'vault-1',
        'target-device',
        'source-device',
        1,
      );
      final acknowledgement = await _read(remote, acknowledgementKey);
      expect(
        jsonDecode(utf8.decode(acknowledgement))['appliedThroughSequence'],
        1,
      );
    },
  );
}

Future<void> _put(
  InMemoryObjectStore store,
  String key,
  ImmutableArtifact artifact,
) async {
  await store.put(
    key,
    await artifact.openRead(),
    contentLength: artifact.length,
    ifAbsent: true,
  );
}

Future<Uint8List> _read(InMemoryObjectStore store, String key) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in store.read(key)) {
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

Future<Uint8List> _encryptBlob(
  GenericVaultBlobCipher cipher, {
  required String vaultId,
  required String blobId,
  required String text,
}) async {
  final bytes = utf8.encode(text);
  final output = BytesBuilder(copy: false);
  await for (final chunk in cipher.encrypt(
    vaultId: vaultId,
    blobId: blobId,
    plaintextLength: bytes.length,
    plaintext: Stream.value(bytes),
  )) {
    output.add(chunk);
  }
  return output.takeBytes();
}
