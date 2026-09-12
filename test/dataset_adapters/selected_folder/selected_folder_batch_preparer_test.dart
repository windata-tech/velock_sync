import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_batch_preparer.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_change_planner.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_storage.dart';
import 'package:velock_sync/infrastructure/staging/batch_staging_store.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_batch_envelope.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_blob_cipher.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_key_deriver.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_operations_cipher.dart';
import 'package:velock_sync/sync_core/engine/generic_vault_batch_compiler.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

void main() {
  test(
    'stages a selected-folder file as encrypted blob and operation batch',
    () async {
      final root = await Directory.systemTemp.createTemp('velock-preparer-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}${Platform.pathSeparator}note.txt');
      await file.writeAsString('local file body');
      final deriver = GenericVaultKeyDeriver(Uint8List(32));
      final context = OperationsCipherContext(
        vaultId: 'vault-1',
        batchId: 'batch-1',
        sourceDeviceId: 'device-1',
        sequence: 1,
        keyId: 'key-1',
      );
      final preparer = SelectedFolderBatchPreparer(
        blobCipher: GenericVaultBlobCipher(
          keyDeriver: deriver,
          keyId: 'key-1',
          chunkSize: 4,
        ),
        compiler: GenericVaultBatchCompiler(
          operationsCipher: GenericVaultOperationsCipher(keyDeriver: deriver),
          envelopeSigner: GenericVaultBatchEnvelopeSigner(),
        ),
        staging: BatchStagingStore(Directory('${root.path}/staging')),
      );
      final batch = await preparer.prepare(
        context: context,
        signingKey: await Ed25519().newKeyPair(),
        scanGeneration: 1,
        baseVersionVectors: const {},
        plan: SelectedFolderChangePlan([
          SelectedFolderChange(
            type: SelectedFolderChangeType.upsert,
            entry: FolderScanEntry(
              entityId: 'entity-1',
              relativePath: 'note.txt',
              type: FolderEntryType.file,
              size: await file.length(),
              scanGeneration: 1,
            ),
            blobSource: LocalSelectedFolderStorage(root).file('note.txt'),
          ),
        ]),
      );

      expect(batch, isNotNull);
      expect(batch!.blobs, hasLength(1));
      expect(await batch.operations.openRead(), isA<Stream<List<int>>>());
      expect(batch.envelope.length, greaterThan(0));
      expect(batch.commit.length, greaterThan(0));

      final recovered = await preparer.recover('batch-1');
      expect(recovered, isNotNull);
      expect(recovered!.batch.sequence, batch.sequence);
      expect(
        recovered.batch.blobs.single.descriptor.cipherSha256,
        batch.blobs.single.descriptor.cipherSha256,
      );
    },
  );
}
