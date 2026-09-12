import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_batch_preparer.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_dataset_adapter.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_scanner.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/staging/batch_staging_store.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_batch_envelope.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_blob_cipher.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_key_deriver.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_operations_cipher.dart';
import 'package:velock_sync/sync_core/engine/generic_vault_batch_compiler.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/engine/sync_upload_engine.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';

void main() {
  test(
    'defers an oversized metered batch then replays and advances folder changes',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'velock-folder-adapter-',
      );
      addTearDown(() => root.delete(recursive: true));
      final stagingRoot = await Directory.systemTemp.createTemp(
        'velock-folder-staging-',
      );
      addTearDown(() => stagingRoot.delete(recursive: true));
      final file = File('${root.path}${Platform.pathSeparator}note.txt');
      await file.writeAsString('first version');
      final database = await SyncStateDatabase.inMemory();
      addTearDown(database.close);
      final deriver = GenericVaultKeyDeriver(Uint8List(32));
      final staging = BatchStagingStore(stagingRoot);
      final adapter = SelectedFolderDatasetAdapter(
        datasetId: 'folder-1',
        profileId: 'profile-1',
        vaultId: 'vault-1',
        sourceDeviceId: 'device-1',
        displayName: 'Folder',
        root: root,
        keyId: 'key-1',
        signingKey: await Ed25519().newKeyPair(),
        database: database,
        scanner: SelectedFolderScanner(database),
        staging: staging,
        batchPreparer: SelectedFolderBatchPreparer(
          blobCipher: GenericVaultBlobCipher(
            keyDeriver: deriver,
            keyId: 'key-1',
            chunkSize: 4,
          ),
          compiler: GenericVaultBatchCompiler(
            operationsCipher: GenericVaultOperationsCipher(keyDeriver: deriver),
            envelopeSigner: GenericVaultBatchEnvelopeSigner(),
          ),
          staging: staging,
        ),
      );

      expect(
        await adapter.prepareNextBatch(
          cursor: ExportCursor.empty,
          limits: const BatchLimits(
            maxCipherBytes: 1,
            enforceMaxCipherBytes: true,
          ),
        ),
        isNull,
      );

      final first = await adapter.prepareNextBatch(
        cursor: ExportCursor.empty,
        limits: const BatchLimits(maxCipherBytes: 1024 * 1024),
      );
      final replayed = await adapter.prepareNextBatch(
        cursor: ExportCursor.empty,
        limits: const BatchLimits(maxCipherBytes: 1024 * 1024),
      );
      expect(first, isNotNull);
      expect(replayed, isNotNull);
      expect(replayed!.batchId, first!.batchId);
      expect(replayed.sequence, first.sequence);

      final remote = InMemoryObjectStore();
      final published = await SyncUploadEngine(database).publishNext(
        profileId: 'profile-1',
        dataset: adapter,
        remote: remote,
        cursor: ExportCursor.empty,
        limits: const BatchLimits(maxCipherBytes: 1024 * 1024),
      );
      expect(published.didPublish, isTrue);
      expect(
        await remote.stat(
          LogicalKeys.commit(
            first.vaultId,
            first.sourceDeviceId,
            first.sequence,
            first.batchId,
          ),
        ),
        isNotNull,
      );
      expect(
        await adapter.prepareNextBatch(
          cursor: ExportCursor.empty,
          limits: const BatchLimits(maxCipherBytes: 1024 * 1024),
        ),
        isNull,
      );
      await File(
        '${root.path}${Platform.pathSeparator}later-a.txt',
      ).writeAsString('later A');
      await File(
        '${root.path}${Platform.pathSeparator}later-b.txt',
      ).writeAsString('later B');
      final second = await adapter.prepareNextBatch(
        cursor: ExportCursor.empty,
        limits: const BatchLimits(
          maxOperations: 1,
          maxCipherBytes: 1024 * 1024,
        ),
      );
      expect(second, isNotNull);
      expect(second!.sequence, 2);
      expect(second.batchId, isNot(first.batchId));
      await adapter.acknowledgePublishedBatch(
        batchId: second.batchId,
        sequence: second.sequence,
      );
      final third = await adapter.prepareNextBatch(
        cursor: ExportCursor.empty,
        limits: const BatchLimits(
          maxOperations: 1,
          maxCipherBytes: 1024 * 1024,
        ),
      );
      expect(third, isNotNull);
      expect(third!.sequence, 3);
      await adapter.acknowledgePublishedBatch(
        batchId: third.batchId,
        sequence: third.sequence,
      );
      final entityId = (await database.readFolderScanEntries(
        datasetId: 'folder-1',
      )).first.entityId;
      expect(
        (await database.readFolderEntitySyncState(
          datasetId: 'folder-1',
          entityId: entityId,
        ))!.versionVector,
        VersionVector({'device-1': 1}),
      );
    },
  );
}
