import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_batch_preparer.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_dataset_adapter.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_scanner.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_dataset_adapter.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_store.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_v1_contract.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/staging/batch_staging_store.dart';
import 'package:velock_sync/infrastructure/storage/available_space_probe.dart';
import 'package:velock_sync/infrastructure/storage/staging_disk_preflight.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_batch_envelope.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_blob_cipher.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_key_deriver.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_operations_cipher.dart';
import 'package:velock_sync/sync_core/engine/generic_vault_batch_compiler.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/engine/sync_download_engine.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';

import 'dataset_adapter_contract.dart';

void main() {
  defineDatasetAdapterContractSuite(
    DatasetAdapterContractFixture(
      name: 'Selected Folder sandbox',
      verifyDescriptor: () async {
        final fixture = await _SelectedFolderFixture.create();
        addTearDown(fixture.dispose);
        final descriptor = await fixture.adapter.describe();
        expect(descriptor.kind, DatasetKind.selectedFolder);
        expect(descriptor.accessState, DatasetAccessState.available);
      },
      verifications: {
        DatasetAdapterContract.baselinePagination: _selectedPagination,
        DatasetAdapterContract.add: () => _selectedMutation('add'),
        DatasetAdapterContract.modify: () => _selectedMutation('modify'),
        DatasetAdapterContract.move: () => _selectedMutation('move'),
        DatasetAdapterContract.rename: () => _selectedMutation('rename'),
        DatasetAdapterContract.deleteTombstone: () =>
            _selectedMutation('delete'),
        DatasetAdapterContract.duplicateBatch: _selectedDuplicate,
        DatasetAdapterContract.outOfOrderBatch: _commonOutOfOrderIsHeld,
        DatasetAdapterContract.conflict: _selectedConflictFailsClosed,
        DatasetAdapterContract.accessLossRegrant: _selectedAccessLossRegrant,
        DatasetAdapterContract.crashRecovery: _selectedCrashRecovery,
        DatasetAdapterContract.diskFull: _sharedDiskFull,
        DatasetAdapterContract.malformedArtifact: _selectedMalformedArtifact,
        DatasetAdapterContract.unsupportedVersion: _selectedUnsupportedVersion,
        DatasetAdapterContract.cursorAfterDurableApplyReceipt:
            _commonDurableCursor,
        DatasetAdapterContract.stagingCleanup: _selectedStagingCleanup,
      },
    ),
  );

  defineDatasetAdapterContractSuite(
    DatasetAdapterContractFixture(
      name: 'Velock fake Exchange',
      verifyDescriptor: () async {
        final fixture = await _VelockFixture.create();
        addTearDown(fixture.dispose);
        final descriptor = await fixture.adapter.describe();
        expect(descriptor.kind, DatasetKind.velockManaged);
        expect(descriptor.encryptionMode, EncryptionMode.velockManaged);
      },
      verifications: {
        DatasetAdapterContract.baselinePagination: _velockPagination,
        DatasetAdapterContract.add: () => _velockOpaqueOperation('add'),
        DatasetAdapterContract.modify: () => _velockOpaqueOperation('modify'),
        DatasetAdapterContract.move: () => _velockOpaqueOperation('move'),
        DatasetAdapterContract.rename: () => _velockOpaqueOperation('rename'),
        DatasetAdapterContract.deleteTombstone: () =>
            _velockOpaqueOperation('delete'),
        DatasetAdapterContract.duplicateBatch: _velockDuplicate,
        DatasetAdapterContract.outOfOrderBatch: _velockOutOfOrder,
        DatasetAdapterContract.conflict: _velockConflictIsDeferredOpaque,
        DatasetAdapterContract.accessLossRegrant: _velockAccessLossRegrant,
        DatasetAdapterContract.crashRecovery: _velockCrashRecovery,
        DatasetAdapterContract.diskFull: _sharedDiskFull,
        DatasetAdapterContract.malformedArtifact: _velockMalformedArtifact,
        DatasetAdapterContract.unsupportedVersion: _velockUnsupportedVersion,
        DatasetAdapterContract.cursorAfterDurableApplyReceipt:
            _velockDurableReceiptCursor,
        DatasetAdapterContract.stagingCleanup: _velockStagingCleanup,
      },
    ),
  );
}

Future<void> _selectedPagination() async {
  final fixture = await _SelectedFolderFixture.create();
  addTearDown(fixture.dispose);
  for (final name in ['one.txt', 'two.txt', 'three.txt']) {
    await File('${fixture.root.path}/$name').writeAsString(name);
  }
  final first = await fixture.prepare(maxOperations: 1);
  await fixture.adapter.acknowledgePublishedBatch(
    batchId: first.batchId,
    sequence: first.sequence,
  );
  final second = await fixture.prepare(maxOperations: 1);
  expect(second.batchId, isNot(first.batchId));
  expect(second.sequence, first.sequence + 1);
}

Future<void> _selectedMutation(String kind) async {
  final fixture = await _SelectedFolderFixture.create();
  addTearDown(fixture.dispose);
  final source = File('${fixture.root.path}/original.txt');
  if (kind == 'add') {
    await source.writeAsString('new');
  } else {
    await source.writeAsString('before');
    final initial = await fixture.prepare();
    await fixture.adapter.acknowledgePublishedBatch(
      batchId: initial.batchId,
      sequence: initial.sequence,
    );
    switch (kind) {
      case 'modify':
        await source.writeAsString('after');
      case 'move':
        final destination = Directory('${fixture.root.path}/nested');
        await destination.create();
        await source.rename('${destination.path}/original.txt');
      case 'rename':
        await source.rename('${fixture.root.path}/renamed.txt');
      case 'delete':
        await source.delete();
      default:
        throw ArgumentError.value(kind, 'kind');
    }
  }
  final change = await fixture.prepare();
  expect(change.sequence, greaterThan(0));
  expect(change.envelope.length, greaterThan(0));
}

Future<void> _selectedDuplicate() async {
  final fixture = await _SelectedFolderFixture.create();
  addTearDown(fixture.dispose);
  await File('${fixture.root.path}/note.txt').writeAsString('content');
  final first = await fixture.prepare();
  final replay = await fixture.prepare();
  expect(replay.batchId, first.batchId);
  expect(replay.sequence, first.sequence);
  expect(
    await _readArtifact(replay.operations),
    await _readArtifact(first.operations),
  );
}

Future<void> _commonOutOfOrderIsHeld() async {
  final database = await SyncStateDatabase.inMemory();
  addTearDown(database.close);
  final remote = InMemoryObjectStore();
  final dataset = _RecordingDataset();
  await _publishRemoteBatch(remote, sequence: 2, batchId: 'batch-2');

  final result = await SyncDownloadEngine(database).importAvailable(
    profileId: 'profile-1',
    vaultId: 'vault-1',
    consumerDeviceId: 'consumer-1',
    trustedProducerDeviceIds: const ['producer-1'],
    dataset: dataset,
    remote: remote,
  );

  expect(result.importedBatchCount, 0);
  expect(dataset.imported, isEmpty);
  expect(
    await database.appliedSequence(
      profileId: 'profile-1',
      producerDeviceId: 'producer-1',
    ),
    0,
  );
}

Future<void> _selectedConflictFailsClosed() async {
  final fixture = await _SelectedFolderFixture.create();
  addTearDown(fixture.dispose);
  await expectLater(
    fixture.adapter.acceptIncomingBatch(_incomingBatch()),
    throwsA(isA<StateError>()),
  );
}

Future<void> _selectedAccessLossRegrant() async {
  final fixture = await _SelectedFolderFixture.create();
  addTearDown(fixture.dispose);
  await fixture.root.delete(recursive: true);
  expect(await fixture.adapter.checkAccess(), DatasetAccessState.unavailable);
  await fixture.root.create(recursive: true);
  expect(await fixture.adapter.checkAccess(), DatasetAccessState.available);
}

Future<void> _selectedCrashRecovery() async {
  final fixture = await _SelectedFolderFixture.create();
  addTearDown(fixture.dispose);
  await File('${fixture.root.path}/resume.txt').writeAsString('resume');
  final first = await fixture.prepare();
  final restarted = fixture.restartedAdapter();
  final replay = await restarted.prepareNextBatch(
    cursor: ExportCursor.empty,
    limits: const BatchLimits(),
  );
  expect(replay, isNotNull);
  expect(replay!.batchId, first.batchId);
  expect(replay.sequence, first.sequence);
}

Future<void> _sharedDiskFull() async {
  final root = await Directory.systemTemp.createTemp('velock-contract-space-');
  addTearDown(() => root.delete(recursive: true));
  await expectLater(
    StagingDiskPreflight(
      _FixedSpaceProbe(0),
      minimumFreeBytes: 1,
    ).ensureAvailable(Directory('${root.path}/staging')),
    throwsA(isA<StagingDiskSpaceException>()),
  );
}

Future<void> _selectedMalformedArtifact() async {
  final root = await Directory.systemTemp.createTemp('velock-contract-stage-');
  addTearDown(() => root.delete(recursive: true));
  final staging = BatchStagingStore(root);
  await staging.stage(
    batchId: 'batch-1',
    artifactName: 'manifest.json',
    content: Stream.value(utf8.encode('{not-json')),
    contentLength: utf8.encode('{not-json').length,
  );
  final fixture = await _SelectedFolderFixture.create(staging: staging);
  addTearDown(fixture.disposeWithoutStaging);
  await expectLater(
    fixture.batchPreparer.recover('batch-1'),
    throwsFormatException,
  );
}

Future<void> _selectedUnsupportedVersion() async {
  final root = await Directory.systemTemp.createTemp('velock-contract-stage-');
  addTearDown(() => root.delete(recursive: true));
  final staging = BatchStagingStore(root);
  final bytes = utf8.encode(jsonEncode({'version': 2, 'batchId': 'batch-1'}));
  await staging.stage(
    batchId: 'batch-1',
    artifactName: 'manifest.json',
    content: Stream.value(bytes),
    contentLength: bytes.length,
  );
  final fixture = await _SelectedFolderFixture.create(staging: staging);
  addTearDown(fixture.disposeWithoutStaging);
  await expectLater(
    fixture.batchPreparer.recover('batch-1'),
    throwsFormatException,
  );
}

Future<void> _commonDurableCursor() async {
  final database = await SyncStateDatabase.inMemory();
  addTearDown(database.close);
  final remote = InMemoryObjectStore();
  final dataset = _DeferredRecordingDataset();
  await _publishRemoteBatch(remote, sequence: 1, batchId: 'batch-1');
  final engine = SyncDownloadEngine(database);

  expect(
    (await engine.importAvailable(
      profileId: 'profile-1',
      vaultId: 'vault-1',
      consumerDeviceId: 'consumer-1',
      trustedProducerDeviceIds: const ['producer-1'],
      dataset: dataset,
      remote: remote,
    )).importedBatchCount,
    0,
  );
  expect(
    await database.appliedSequence(
      profileId: 'profile-1',
      producerDeviceId: 'producer-1',
    ),
    0,
  );
  dataset.receiptReady = true;
  expect(
    (await engine.importAvailable(
      profileId: 'profile-1',
      vaultId: 'vault-1',
      consumerDeviceId: 'consumer-1',
      trustedProducerDeviceIds: const ['producer-1'],
      dataset: dataset,
      remote: remote,
    )).importedBatchCount,
    1,
  );
  expect(
    await database.appliedSequence(
      profileId: 'profile-1',
      producerDeviceId: 'producer-1',
    ),
    1,
  );
}

Future<void> _selectedStagingCleanup() async {
  final fixture = await _SelectedFolderFixture.create();
  addTearDown(fixture.dispose);
  await File('${fixture.root.path}/cleanup.txt').writeAsString('cleanup');
  final batch = await fixture.prepare();
  await fixture.adapter.acknowledgePublishedBatch(
    batchId: batch.batchId,
    sequence: batch.sequence,
  );
  expect(
    await fixture.staging.read(
      batchId: batch.batchId,
      artifactName: 'manifest.json',
    ),
    isNull,
  );
}

Future<void> _velockPagination() async {
  final fixture = await _VelockFixture.create();
  addTearDown(fixture.dispose);
  await fixture.writeReady(batchId: 'batch-1', sequence: 1, payload: [1]);
  await fixture.writeReady(batchId: 'batch-2', sequence: 2, payload: [2]);
  final first = await fixture.prepare();
  await fixture.adapter.acknowledgePublishedBatch(
    batchId: first.batchId,
    sequence: first.sequence,
  );
  final second = await fixture.prepare();
  expect([first.sequence, second.sequence], [1, 2]);
}

Future<void> _velockOpaqueOperation(String operation) async {
  final fixture = await _VelockFixture.create();
  addTearDown(fixture.dispose);
  final opaque = Uint8List.fromList(utf8.encode('opaque-$operation\u0000\xff'));
  await fixture.writeReady(batchId: 'batch-1', sequence: 1, payload: opaque);
  final batch = await fixture.prepare();
  expect(await _readArtifact(batch.operations), opaque);
  expect(utf8.decode(await _readArtifact(batch.envelope)), contains('batch-1'));
}

Future<void> _velockDuplicate() async {
  final fixture = await _VelockFixture.create();
  addTearDown(fixture.dispose);
  await fixture.writeReady(batchId: 'batch-1', sequence: 1, payload: [7]);
  final first = await fixture.prepare();
  await fixture.adapter.acknowledgePublishedBatch(
    batchId: first.batchId,
    sequence: first.sequence,
  );
  expect(
    await fixture.adapter.prepareNextBatch(
      cursor: ExportCursor.empty,
      limits: const BatchLimits(),
    ),
    isNull,
  );
}

Future<void> _velockOutOfOrder() async {
  final fixture = await _VelockFixture.create();
  addTearDown(fixture.dispose);
  await fixture.writeReady(batchId: 'batch-2', sequence: 2, payload: [2]);
  await fixture.writeReady(batchId: 'batch-1', sequence: 1, payload: [1]);
  final first = await fixture.prepare();
  await fixture.adapter.acknowledgePublishedBatch(
    batchId: first.batchId,
    sequence: first.sequence,
  );
  final second = await fixture.prepare();
  expect([first.sequence, second.sequence], [1, 2]);
}

Future<void> _velockConflictIsDeferredOpaque() async {
  final fixture = await _VelockFixture.create();
  addTearDown(fixture.dispose);
  final result = await fixture.adapter.acceptIncomingBatch(
    _incomingBatch(operations: Uint8List.fromList([0, 255, 19])),
  );
  expect(result.isApplied, isFalse);
  expect(
    await File(
      '${fixture.root.path}/Inbox/Ready/batch-1/operations.enc',
    ).readAsBytes(),
    [0, 255, 19],
  );
}

Future<void> _velockAccessLossRegrant() async {
  final fixture = await _VelockFixture.create();
  addTearDown(fixture.dispose);
  await fixture.root.delete(recursive: true);
  // The exchange root is explicitly re-created only by a fresh authorized
  // discovery/pairing lifecycle. A disposed root is therefore unavailable.
  expect(await fixture.root.exists(), isFalse);
  await fixture.root.create(recursive: true);
  expect(await fixture.adapter.checkAccess(), DatasetAccessState.available);
}

Future<void> _velockCrashRecovery() async {
  final root = await Directory.systemTemp.createTemp(
    'velock-contract-exchange-',
  );
  addTearDown(() => root.delete(recursive: true));
  var now = DateTime.utc(2026, 7, 17, 1);
  final fixture = await _VelockFixture.create(root: root, now: () => now);
  await fixture.writeReady(batchId: 'batch-1', sequence: 1, payload: [1]);
  await fixture.store.claimNextOutbox(leaseId: 'crashed-process');
  now = now.add(const Duration(minutes: 11));
  final restarted = VelockExchangeDatasetAdapter(
    datasetId: 'velock-1',
    vaultId: 'vault-1',
    deviceId: 'device-1',
    displayName: 'Velock',
    exchange: fixture.store,
  );
  final recovered = await restarted.prepareNextBatch(
    cursor: ExportCursor.empty,
    limits: const BatchLimits(),
  );
  expect(recovered!.batchId, 'batch-1');
}

Future<void> _velockMalformedArtifact() async {
  final fixture = await _VelockFixture.create();
  addTearDown(fixture.dispose);
  await fixture.writeReady(
    batchId: 'batch-1',
    sequence: 1,
    payload: [1],
    corruptReadyHash: true,
  );
  await expectLater(
    fixture.adapter.prepareNextBatch(
      cursor: ExportCursor.empty,
      limits: const BatchLimits(),
    ),
    throwsFormatException,
  );
}

Future<void> _velockUnsupportedVersion() async {
  final fixture = await _VelockFixture.create();
  addTearDown(fixture.dispose);
  await fixture.adapter.acceptIncomingBatch(_incomingBatch());
  final ack = File('${fixture.root.path}/Inbox/Ready/batch-1/ack/a.ack');
  await ack.parent.create(recursive: true);
  await ack.writeAsBytes([9]);
  await fixture.store.writeInboxReceipt(
    batchId: 'batch-1',
    receipt: Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'protocolVersion': 2,
          'batchId': 'batch-1',
          'sourceDeviceId': 'producer-1',
          'sequence': 1,
          'status': 'imported',
          'ackArtifactRelativePath': 'ack/a.ack',
        }),
      ),
    ),
  );
  await expectLater(
    fixture.adapter.reconcileIncomingBatch(_incomingReference()),
    throwsFormatException,
  );
}

Future<void> _velockDurableReceiptCursor() async {
  final fixture = await _VelockFixture.create();
  addTearDown(fixture.dispose);
  final database = await SyncStateDatabase.inMemory();
  addTearDown(database.close);
  final remote = InMemoryObjectStore();
  await _publishRemoteBatch(remote, sequence: 1, batchId: 'batch-1');
  final engine = SyncDownloadEngine(database);

  expect(
    (await engine.importAvailable(
      profileId: 'profile-1',
      vaultId: 'vault-1',
      consumerDeviceId: 'device-1',
      trustedProducerDeviceIds: const ['producer-1'],
      dataset: fixture.adapter,
      remote: remote,
    )).importedBatchCount,
    0,
  );
  expect(
    await database.appliedSequence(
      profileId: 'profile-1',
      producerDeviceId: 'producer-1',
    ),
    0,
  );
  final ack = File(
    '${fixture.root.path}/Inbox/Ready/batch-1/ack/producer-1.ack',
  );
  await ack.parent.create(recursive: true);
  await ack.writeAsBytes([9]);
  await fixture.store.writeInboxReceipt(
    batchId: 'batch-1',
    receipt: Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'protocolVersion': 1,
          'batchId': 'batch-1',
          'sourceDeviceId': 'producer-1',
          'sequence': 1,
          'status': 'imported',
          'ackArtifactRelativePath': 'ack/producer-1.ack',
        }),
      ),
    ),
  );
  expect(
    (await engine.importAvailable(
      profileId: 'profile-1',
      vaultId: 'vault-1',
      consumerDeviceId: 'device-1',
      trustedProducerDeviceIds: const ['producer-1'],
      dataset: fixture.adapter,
      remote: remote,
    )).importedBatchCount,
    1,
  );
  expect(
    await database.appliedSequence(
      profileId: 'profile-1',
      producerDeviceId: 'producer-1',
    ),
    1,
  );
}

Future<void> _velockStagingCleanup() async {
  final fixture = await _VelockFixture.create();
  addTearDown(fixture.dispose);
  await fixture.adapter.acceptIncomingBatch(_incomingBatch());
  expect(
    await Directory('${fixture.root.path}/Inbox/Staging/batch-1').exists(),
    isFalse,
  );
  expect(
    await Directory('${fixture.root.path}/Inbox/Ready/batch-1').exists(),
    isTrue,
  );
}

class _SelectedFolderFixture {
  _SelectedFolderFixture._({
    required this.root,
    required this.stagingRoot,
    required this.database,
    required this.staging,
    required this.batchPreparer,
    required this.adapter,
    required this.signingKey,
  });

  final Directory root;
  final Directory stagingRoot;
  final SyncStateDatabase database;
  final BatchStagingStore staging;
  final SelectedFolderBatchPreparer batchPreparer;
  final SelectedFolderDatasetAdapter adapter;
  final KeyPair signingKey;

  static Future<_SelectedFolderFixture> create({
    BatchStagingStore? staging,
  }) async {
    final root = await Directory.systemTemp.createTemp(
      'velock-contract-folder-',
    );
    final stagingRoot = staging == null
        ? await Directory.systemTemp.createTemp('velock-contract-staging-')
        : stagingRootFor(staging);
    final database = await SyncStateDatabase.inMemory();
    final key = await Ed25519().newKeyPair();
    final resolvedStaging = staging ?? BatchStagingStore(stagingRoot);
    final deriver = GenericVaultKeyDeriver(Uint8List(32));
    final preparer = SelectedFolderBatchPreparer(
      blobCipher: GenericVaultBlobCipher(
        keyDeriver: deriver,
        keyId: 'key-1',
        chunkSize: 16,
      ),
      compiler: GenericVaultBatchCompiler(
        operationsCipher: GenericVaultOperationsCipher(keyDeriver: deriver),
        envelopeSigner: GenericVaultBatchEnvelopeSigner(),
      ),
      staging: resolvedStaging,
    );
    return _SelectedFolderFixture._(
      root: root,
      stagingRoot: stagingRoot,
      database: database,
      staging: resolvedStaging,
      batchPreparer: preparer,
      signingKey: key,
      adapter: SelectedFolderDatasetAdapter(
        datasetId: 'folder-1',
        profileId: 'profile-1',
        vaultId: 'vault-1',
        sourceDeviceId: 'device-1',
        displayName: 'Folder',
        root: root,
        keyId: 'key-1',
        signingKey: key,
        database: database,
        scanner: SelectedFolderScanner(
          database,
          deletionPolicy: const DeletionProtectionPolicy(maxDeletedFraction: 1),
        ),
        batchPreparer: preparer,
        staging: resolvedStaging,
      ),
    );
  }

  static Directory stagingRootFor(BatchStagingStore staging) =>
      // The store intentionally hides its root; this independent temporary
      // directory is only a lifecycle marker and is never deleted by this
      // fixture when an externally supplied staging store is under test.
      Directory.systemTemp;

  SelectedFolderDatasetAdapter restartedAdapter() =>
      SelectedFolderDatasetAdapter(
        datasetId: 'folder-1',
        profileId: 'profile-1',
        vaultId: 'vault-1',
        sourceDeviceId: 'device-1',
        displayName: 'Folder',
        root: root,
        keyId: 'key-1',
        signingKey: signingKey,
        database: database,
        scanner: SelectedFolderScanner(
          database,
          deletionPolicy: const DeletionProtectionPolicy(maxDeletedFraction: 1),
        ),
        batchPreparer: batchPreparer,
        staging: staging,
      );

  Future<PreparedOutgoingBatch> prepare({int maxOperations = 500}) async =>
      (await adapter.prepareNextBatch(
        cursor: ExportCursor.empty,
        limits: BatchLimits(maxOperations: maxOperations),
      ))!;

  Future<void> dispose() async {
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
    if (stagingRoot.path != Directory.systemTemp.path &&
        await stagingRoot.exists()) {
      await stagingRoot.delete(recursive: true);
    }
  }

  Future<void> disposeWithoutStaging() async {
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  }
}

class _VelockFixture {
  _VelockFixture._({
    required this.root,
    required this.store,
    required this.adapter,
  });

  final Directory root;
  final VelockExchangeStore store;
  final VelockExchangeDatasetAdapter adapter;

  static Future<_VelockFixture> create({
    Directory? root,
    DateTime Function()? now,
  }) async {
    final resolvedRoot =
        root ??
        await Directory.systemTemp.createTemp('velock-contract-exchange-');
    final store = VelockExchangeStore(
      resolvedRoot,
      now: now,
      leaseDuration: const Duration(minutes: 10),
    );
    await store.initialize();
    return _VelockFixture._(
      root: resolvedRoot,
      store: store,
      adapter: VelockExchangeDatasetAdapter(
        datasetId: 'velock-1',
        vaultId: 'vault-1',
        deviceId: 'device-1',
        displayName: 'Velock',
        exchange: store,
      ),
    );
  }

  Future<void> writeReady({
    required String batchId,
    required int sequence,
    required List<int> payload,
    bool corruptReadyHash = false,
  }) async {
    final package = Directory('${root.path}/Outbox/Ready/$batchId');
    await package.create(recursive: true);
    final envelope = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'batchId': batchId,
          'batchKind': 'incremental',
          'blobs': [],
          'createdAt': '2026-07-17T00:00:00.000Z',
          'keyId': 'key-1',
          'operations': {
            'cipherSha256': sha256.convert(payload).toString(),
            'cipherSize': payload.length,
            'compression': 'none',
            'logicalName': 'operations.enc',
            'operationCount': 1,
          },
          'previousBatchId': sequence == 1 ? null : 'batch-${sequence - 1}',
          'previousSequence': sequence == 1 ? null : sequence - 1,
          'protocol': 'velock-sync',
          'protocolVersion': 1,
          'sequence': sequence,
          'signature': 'fixture-signature',
          'signatureAlgorithm': 'Ed25519',
          'sourceDeviceId': 'device-1',
          'vaultId': 'vault-1',
        }),
      ),
    );
    await File('${package.path}/envelope.json').writeAsBytes(envelope);
    await File('${package.path}/operations.enc').writeAsBytes(payload);
    await File('${package.path}/READY').writeAsString(
      jsonEncode({
        'batchId': batchId,
        'envelopeSha256': corruptReadyHash
            ? '00'
            : sha256.convert(envelope).toString(),
        'exchangeVersion': VelockExchangeV1Contract.exchangeVersion,
        'publishedAt': '2026-07-17T00:00:00.000Z',
      }),
    );
  }

  Future<PreparedOutgoingBatch> prepare() async =>
      (await adapter.prepareNextBatch(
        cursor: ExportCursor.empty,
        limits: const BatchLimits(),
      ))!;

  Future<void> dispose() async {
    if (await root.exists()) await root.delete(recursive: true);
  }
}

class _FixedSpaceProbe implements AvailableSpaceProbe {
  const _FixedSpaceProbe(this.bytes);

  final int bytes;

  @override
  Future<int> availableBytes(Directory directory) async => bytes;
}

IncomingBatch _incomingBatch({Uint8List? operations}) => IncomingBatch(
  vaultId: 'vault-1',
  sourceDeviceId: 'producer-1',
  sequence: 1,
  batchId: 'batch-1',
  envelope: Uint8List.fromList([1]),
  operations: operations ?? Uint8List.fromList([2]),
  blobs: const {},
);

IncomingBatchReference _incomingReference() => const IncomingBatchReference(
  vaultId: 'vault-1',
  sourceDeviceId: 'producer-1',
  sequence: 1,
  batchId: 'batch-1',
);

Future<Uint8List> _readArtifact(ImmutableArtifact artifact) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in await artifact.openRead()) {
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

Future<void> _publishRemoteBatch(
  InMemoryObjectStore remote, {
  required int sequence,
  required String batchId,
}) async {
  final operations = Uint8List.fromList([1, 2, 3]);
  final envelope = Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'vaultId': 'vault-1',
        'sourceDeviceId': 'producer-1',
        'sequence': sequence,
        'batchId': batchId,
        'operations': {
          'cipherSize': operations.length,
          'cipherSha256': sha256.convert(operations).toString(),
        },
        'blobs': [],
      }),
    ),
  );
  final commit = Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'vaultId': 'vault-1',
        'sourceDeviceId': 'producer-1',
        'sequence': sequence,
        'batchId': batchId,
        'envelopeSha256': sha256.convert(envelope).toString(),
      }),
    ),
  );
  await _put(
    remote,
    LogicalKeys.batchOperations('vault-1', 'producer-1', sequence, batchId),
    operations,
  );
  await _put(
    remote,
    LogicalKeys.batchEnvelope('vault-1', 'producer-1', sequence, batchId),
    envelope,
  );
  await _put(
    remote,
    LogicalKeys.commit('vault-1', 'producer-1', sequence, batchId),
    commit,
  );
}

Future<void> _put(InMemoryObjectStore remote, String key, Uint8List bytes) =>
    remote.put(
      key,
      Stream.value(bytes),
      contentLength: bytes.length,
      ifAbsent: true,
    );

class _RecordingDataset implements SyncDatasetAdapter {
  final List<IncomingBatch> imported = [];

  @override
  Future<ImportResult> acceptIncomingBatch(IncomingBatch batch) async {
    imported.add(batch);
    return const ImportResult();
  }

  @override
  Future<void> acknowledgePublishedBatch({
    required String batchId,
    required int sequence,
  }) async {}

  @override
  Future<DatasetAccessState> checkAccess() async =>
      DatasetAccessState.available;

  @override
  Future<DatasetDescriptor> describe() async => const DatasetDescriptor(
    datasetId: 'recording',
    vaultId: 'vault-1',
    kind: DatasetKind.selectedFolder,
    displayName: 'Recording',
    accessState: DatasetAccessState.available,
    encryptionMode: EncryptionMode.endToEnd,
  );

  @override
  Future<PreparedOutgoingBatch?> prepareNextBatch({
    required ExportCursor cursor,
    required BatchLimits limits,
  }) async => null;
}

class _DeferredRecordingDataset extends _RecordingDataset
    implements DeferredIncomingBatchAdapter {
  bool receiptReady = false;

  @override
  Future<ImportResult> acceptIncomingBatch(IncomingBatch batch) async {
    imported.add(batch);
    return const ImportResult(isApplied: false);
  }

  @override
  Future<ImportResult?> reconcileIncomingBatch(
    IncomingBatchReference batch,
  ) async => receiptReady ? const ImportResult() : null;
}
