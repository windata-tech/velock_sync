import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/engine/sync_profile_runner.dart';
import 'package:velock_sync/sync_core/engine/vault_protocol.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';

void main() {
  test(
    'bootstraps protocol before an idle profile upload/download run',
    () async {
      final database = await SyncStateDatabase.inMemory();
      addTearDown(database.close);
      final result = await SyncProfileRunner(database).run(
        profileId: 'profile-1',
        vaultId: 'vault-1',
        deviceId: 'device-1',
        protocol: VaultProtocolDocument(
          vaultId: 'vault-1',
          createdAt: DateTime.utc(2026, 7, 15),
        ),
        dataset: const _IdleDataset(),
        remote: InMemoryObjectStore(),
      );
      expect(result.upload.didPublish, isFalse);
      expect(result.upload.publishedBatchCount, 0);
      expect(result.download.importedBatchCount, 0);
      expect((await database.latestSyncRun('profile-1'))!.state, 'completed');
    },
  );

  test('drains consecutive local batches during one profile run', () async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    final dataset = _BatchingDataset(2);

    final result = await SyncProfileRunner(database).run(
      profileId: 'profile-1',
      vaultId: 'vault-1',
      deviceId: 'device-1',
      protocol: VaultProtocolDocument(
        vaultId: 'vault-1',
        createdAt: DateTime.utc(2026, 7, 15),
      ),
      dataset: dataset,
      remote: InMemoryObjectStore(),
    );

    expect(result.upload.publishedBatchCount, 2);
    expect(dataset.acknowledged, ['batch-1:1', 'batch-2:2']);
  });

  test('accepts a paired producer without generic vault membership', () async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    final remote = InMemoryObjectStore();
    await _publishIncomingFixture(
      remote,
      producerId: 'paired-producer',
      batchId: 'paired-batch',
    );
    final dataset = _RecordingDataset();

    final result = await SyncProfileRunner(database).run(
      profileId: 'profile-1',
      vaultId: 'vault-1',
      deviceId: 'consumer-1',
      protocol: VaultProtocolDocument(
        vaultId: 'vault-1',
        createdAt: DateTime.utc(2026, 7, 15),
      ),
      dataset: dataset,
      remote: remote,
      trustedProducerDeviceIds: const ['paired-producer'],
    );

    expect(result.download.importedBatchCount, 1);
    expect(dataset.imported, hasLength(1));
    expect(
      await database.appliedSequence(
        profileId: 'profile-1',
        producerDeviceId: 'paired-producer',
      ),
      1,
    );
    expect(
      await database.readTrustedDevicePublicKeys(vaultId: 'vault-1'),
      isEmpty,
    );
  });

  test(
    'fails before remote access when the dataset authorization is unavailable',
    () async {
      final database = await SyncStateDatabase.inMemory();
      addTearDown(database.close);

      await expectLater(
        SyncProfileRunner(database).run(
          profileId: 'profile-1',
          vaultId: 'vault-1',
          deviceId: 'device-1',
          protocol: VaultProtocolDocument(
            vaultId: 'vault-1',
            createdAt: DateTime.utc(2026, 7, 15),
          ),
          dataset: const _UnavailableDataset(),
          remote: InMemoryObjectStore(),
        ),
        throwsA(isA<SyncDatasetAccessException>()),
      );

      final run = await database.latestSyncRun('profile-1');
      expect(run!.state, 'failed');
      expect(run.errorCode, 'dataset.access.needsAuthorization');
    },
  );

  test('records a preflight failure in the same sync run history', () async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);

    await expectLater(
      SyncProfileRunner(database).run(
        profileId: 'profile-1',
        vaultId: 'vault-1',
        deviceId: 'device-1',
        protocol: VaultProtocolDocument(
          vaultId: 'vault-1',
          createdAt: DateTime.utc(2026, 7, 15),
        ),
        dataset: const _IdleDataset(),
        remote: InMemoryObjectStore(),
        preflight: () async =>
            throw const RemoteObjectNotFoundException('opaque-member-key'),
      ),
      throwsA(isA<RemoteObjectNotFoundException>()),
    );

    expect(
      (await database.latestSyncRun('profile-1'))!.errorCode,
      'remote.object_not_found',
    );
  });

  test(
    'runs post-protocol preflight only after the vault protocol is available remotely',
    () async {
      final database = await SyncStateDatabase.inMemory();
      addTearDown(database.close);
      final remote = InMemoryObjectStore();

      await SyncProfileRunner(database).run(
        profileId: 'profile-1',
        vaultId: 'vault-1',
        deviceId: 'device-1',
        protocol: VaultProtocolDocument(
          vaultId: 'vault-1',
          createdAt: DateTime.utc(2026, 7, 15),
        ),
        dataset: const _IdleDataset(),
        remote: remote,
        postProtocolPreflight: () async {
          expect(await remote.stat(LogicalKeys.protocol('vault-1')), isNotNull);
        },
      );
    },
  );

  test('runs preflight before any remote protocol access', () async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    final remote = InMemoryObjectStore();

    await expectLater(
      SyncProfileRunner(database).run(
        profileId: 'profile-1',
        vaultId: 'vault-1',
        deviceId: 'device-1',
        protocol: VaultProtocolDocument(
          vaultId: 'vault-1',
          createdAt: DateTime.utc(2026, 7, 15),
        ),
        dataset: const _IdleDataset(),
        remote: remote,
        preflight: () async => throw const SyncDatasetAccessException(
          DatasetAccessState.unavailable,
        ),
      ),
      throwsA(isA<SyncDatasetAccessException>()),
    );

    expect(await remote.stat(LogicalKeys.protocol('vault-1')), isNull);
  });

  test('seeds download cursors after a dataset accepts a checkpoint', () async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    final remote = InMemoryObjectStore();
    await _putCheckpoint(remote, 'checkpoint-1');
    final dataset = _CheckpointDataset();

    final result = await SyncProfileRunner(database).run(
      profileId: 'profile-1',
      vaultId: 'vault-1',
      deviceId: 'device-1',
      protocol: VaultProtocolDocument(
        vaultId: 'vault-1',
        createdAt: DateTime.utc(2026, 7, 15),
      ),
      dataset: dataset,
      remote: remote,
    );

    expect(result.checkpointRecovery!.didRecover, isTrue);
    expect(dataset.checkpoints, ['checkpoint-1']);
    expect(
      await database.appliedSequence(
        profileId: 'profile-1',
        producerDeviceId: 'producer-1',
      ),
      7,
    );
  });
}

Future<void> _putCheckpoint(
  RemoteObjectStore remote,
  String checkpointId,
) async {
  const vaultId = 'vault-1';
  final artifact = Uint8List.fromList([1]);
  Future<void> put(String key) async {
    await remote.put(
      key,
      Stream.value(artifact),
      contentLength: artifact.length,
      ifAbsent: true,
    );
  }

  await put(LogicalKeys.checkpointEnvelope(vaultId, checkpointId));
  await put(LogicalKeys.checkpointPart(vaultId, checkpointId, 1));
  await put(LogicalKeys.checkpointCommit(vaultId, checkpointId));
}

class _IdleDataset implements SyncDatasetAdapter {
  const _IdleDataset();

  @override
  Future<void> acknowledgePublishedBatch({
    required String batchId,
    required int sequence,
  }) async {}
  @override
  Future<ImportResult> acceptIncomingBatch(IncomingBatch batch) async =>
      const ImportResult();
  @override
  Future<DatasetAccessState> checkAccess() async =>
      DatasetAccessState.available;
  @override
  Future<DatasetDescriptor> describe() async => const DatasetDescriptor(
    datasetId: 'd',
    vaultId: 'vault-1',
    kind: DatasetKind.velockManaged,
    displayName: 'd',
    accessState: DatasetAccessState.available,
    encryptionMode: EncryptionMode.velockManaged,
  );
  @override
  Future<PreparedOutgoingBatch?> prepareNextBatch({
    required ExportCursor cursor,
    required BatchLimits limits,
  }) async => null;
}

class _BatchingDataset extends _IdleDataset {
  _BatchingDataset(this.remaining);

  int remaining;
  final List<String> acknowledged = [];

  @override
  Future<PreparedOutgoingBatch?> prepareNextBatch({
    required ExportCursor cursor,
    required BatchLimits limits,
  }) async {
    if (remaining == 0) return null;
    final sequence = 3 - remaining--;
    final artifact = ImmutableArtifact.fromBytes(
      Uint8List.fromList([sequence]),
    );
    return PreparedOutgoingBatch(
      vaultId: 'vault-1',
      sourceDeviceId: 'device-1',
      sequence: sequence,
      batchId: 'batch-$sequence',
      envelope: artifact,
      operations: artifact,
      commit: artifact,
      blobs: const [],
    );
  }

  @override
  Future<void> acknowledgePublishedBatch({
    required String batchId,
    required int sequence,
  }) async {
    acknowledged.add('$batchId:$sequence');
  }
}

class _UnavailableDataset extends _IdleDataset {
  const _UnavailableDataset();

  @override
  Future<DatasetAccessState> checkAccess() async =>
      DatasetAccessState.needsAuthorization;
}

class _CheckpointDataset extends _IdleDataset
    implements CheckpointRecoveringDatasetAdapter {
  final checkpoints = <String>[];

  @override
  Future<CheckpointImportResult> acceptIncomingCheckpoint(
    IncomingCheckpoint checkpoint,
  ) async {
    checkpoints.add(checkpoint.checkpointId);
    return const CheckpointImportResult.applied(
      coveredSequences: {'producer-1': 7},
    );
  }
}

Future<void> _publishIncomingFixture(
  InMemoryObjectStore remote, {
  required String producerId,
  required String batchId,
}) async {
  const vaultId = 'vault-1';
  final operations = Uint8List.fromList(<int>[1, 2, 3]);
  final envelope = Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'vaultId': vaultId,
        'sourceDeviceId': producerId,
        'sequence': 1,
        'batchId': batchId,
        'operations': {
          'cipherSize': operations.length,
          'cipherSha256': sha256.convert(operations).toString(),
        },
        'blobs': const [],
      }),
    ),
  );
  final commit = Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'vaultId': vaultId,
        'sourceDeviceId': producerId,
        'sequence': 1,
        'batchId': batchId,
        'envelopeSha256': sha256.convert(envelope).toString(),
      }),
    ),
  );
  Future<void> put(String key, Uint8List value) => remote.put(
    key,
    Stream.value(value),
    contentLength: value.length,
    ifAbsent: true,
  );

  await put(
    LogicalKeys.batchOperations(vaultId, producerId, 1, batchId),
    operations,
  );
  await put(
    LogicalKeys.batchEnvelope(vaultId, producerId, 1, batchId),
    envelope,
  );
  await put(LogicalKeys.commit(vaultId, producerId, 1, batchId), commit);
}

class _RecordingDataset extends _IdleDataset {
  final List<IncomingBatch> imported = [];

  @override
  Future<ImportResult> acceptIncomingBatch(IncomingBatch batch) async {
    imported.add(batch);
    return const ImportResult();
  }
}
