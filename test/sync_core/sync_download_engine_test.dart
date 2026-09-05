import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/engine/sync_download_engine.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';

void main() {
  group('SyncDownloadEngine', () {
    late SyncStateDatabase database;
    late InMemoryObjectStore remote;
    late _ImportingDataset dataset;

    setUp(() async {
      database = await SyncStateDatabase.inMemory();
      remote = InMemoryObjectStore();
      dataset = _ImportingDataset();
    });

    tearDown(() => database.close());

    test(
      'imports the next trusted sequence, verifies hashes, and publishes the dataset ack',
      () async {
        await _publishFixture(remote, sequence: 1, batchId: 'batch-1');

        final result = await SyncDownloadEngine(database).importAvailable(
          profileId: 'profile-1',
          vaultId: 'vault-1',
          consumerDeviceId: 'consumer-1',
          trustedProducerDeviceIds: const ['producer-1'],
          dataset: dataset,
          remote: remote,
        );

        expect(result.importedBatchCount, 1);
        expect(
          dataset.imported.single.blobs['blob-1'],
          Uint8List.fromList(<int>[8, 9]),
        );
        expect(
          await database.appliedSequence(
            profileId: 'profile-1',
            producerDeviceId: 'producer-1',
          ),
          1,
        );
        expect(
          await remote.stat(
            LogicalKeys.acknowledgement(
              'vault-1',
              'consumer-1',
              'producer-1',
              1,
            ),
          ),
          isNotNull,
        );
        expect(
          await database.listTransferJobs(profileId: 'profile-1'),
          isEmpty,
        );
        final transfers = await database.listTransferJobs(
          profileId: 'profile-1',
          includeCompleted: true,
        );
        expect(transfers, hasLength(5));
        expect(
          transfers.where(
            (transfer) => transfer.direction == TransferJobDirection.download,
          ),
          hasLength(4),
        );
        final blobTransfer = transfers.singleWhere(
          (transfer) =>
              transfer.logicalKey == LogicalKeys.blob('vault-1', 'blob-1'),
        );
        expect(blobTransfer.expectedSize, 2);
        expect(blobTransfer.completedBytes, 2);
        expect(
          blobTransfer.expectedHash,
          sha256.convert(<int>[8, 9]).toString(),
        );
      },
    );

    test('streams replayable blobs to capable datasets', () async {
      final streaming = _StreamingDataset();
      await _publishFixture(remote, sequence: 1, batchId: 'batch-1');

      final result = await SyncDownloadEngine(database).importAvailable(
        profileId: 'profile-1',
        vaultId: 'vault-1',
        consumerDeviceId: 'consumer-1',
        trustedProducerDeviceIds: const ['producer-1'],
        dataset: streaming,
        remote: remote,
      );

      expect(result.importedBatchCount, 1);
      expect(streaming.blobs['blob-1'], [8, 9]);
      final blobTransfer =
          (await database.listTransferJobs(
            profileId: 'profile-1',
            includeCompleted: true,
          )).singleWhere(
            (transfer) =>
                transfer.logicalKey == LogicalKeys.blob('vault-1', 'blob-1'),
          );
      expect(blobTransfer.state, TransferJobState.completed);
      expect(blobTransfer.completedBytes, 2);
    });

    test('rejects a streamed blob whose signed hash is wrong', () async {
      final streaming = _StreamingDataset();
      await _publishFixture(
        remote,
        sequence: 1,
        batchId: 'batch-1',
        corruptBlobHash: true,
      );

      await expectLater(
        SyncDownloadEngine(database).importAvailable(
          profileId: 'profile-1',
          vaultId: 'vault-1',
          consumerDeviceId: 'consumer-1',
          trustedProducerDeviceIds: const ['producer-1'],
          dataset: streaming,
          remote: remote,
        ),
        throwsA(isA<BatchIntegrityException>()),
      );
      expect(
        await database.appliedSequence(
          profileId: 'profile-1',
          producerDeviceId: 'producer-1',
        ),
        0,
      );
    });

    test('does not skip a missing sequence from the same producer', () async {
      await _publishFixture(remote, sequence: 2, batchId: 'batch-2');

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
    });

    test('deduplicates repeated provider list entries before import', () async {
      await _publishFixture(remote, sequence: 1, batchId: 'batch-1');
      final duplicated = _DuplicateListStore(remote);

      final result = await SyncDownloadEngine(database).importAvailable(
        profileId: 'profile-1',
        vaultId: 'vault-1',
        consumerDeviceId: 'consumer-1',
        trustedProducerDeviceIds: const ['producer-1'],
        dataset: dataset,
        remote: duplicated,
      );

      expect(result.importedBatchCount, 1);
      expect(dataset.imported, hasLength(1));
      expect(duplicated.injectedDuplicateCount, greaterThan(0));
    });

    test('rejects a bad operations hash before the dataset import', () async {
      await _publishFixture(
        remote,
        sequence: 1,
        batchId: 'batch-1',
        corruptOperationsHash: true,
      );

      await expectLater(
        SyncDownloadEngine(database).importAvailable(
          profileId: 'profile-1',
          vaultId: 'vault-1',
          consumerDeviceId: 'consumer-1',
          trustedProducerDeviceIds: const ['producer-1'],
          dataset: dataset,
          remote: remote,
        ),
        throwsA(isA<BatchIntegrityException>()),
      );
      expect(dataset.imported, isEmpty);
      expect(
        await database.appliedSequence(
          profileId: 'profile-1',
          producerDeviceId: 'producer-1',
        ),
        0,
      );
    });

    test(
      'records a failed transfer when a remote object cannot be read',
      () async {
        await _publishFixture(remote, sequence: 1, batchId: 'batch-1');
        final operationsKey = LogicalKeys.batchOperations(
          'vault-1',
          'producer-1',
          1,
          'batch-1',
        );
        await remote.delete(operationsKey);

        await expectLater(
          SyncDownloadEngine(database).importAvailable(
            profileId: 'profile-1',
            vaultId: 'vault-1',
            consumerDeviceId: 'consumer-1',
            trustedProducerDeviceIds: const ['producer-1'],
            dataset: dataset,
            remote: remote,
          ),
          throwsA(isA<RemoteObjectNotFoundException>()),
        );

        final failed = (await database.listTransferJobs(
          profileId: 'profile-1',
        )).singleWhere((transfer) => transfer.logicalKey == operationsKey);
        expect(failed.state, TransferJobState.failed);
        expect(failed.errorCode, 'remote.object_not_found');
      },
    );

    test(
      'waits for a deferred trusted-peer receipt before advancing cursor',
      () async {
        final deferred = _DeferredDataset();
        await _publishFixture(remote, sequence: 1, batchId: 'batch-1');
        final engine = SyncDownloadEngine(database);

        expect(
          (await engine.importAvailable(
            profileId: 'profile-1',
            vaultId: 'vault-1',
            consumerDeviceId: 'consumer-1',
            trustedProducerDeviceIds: const ['producer-1'],
            dataset: deferred,
            remote: remote,
          )).importedBatchCount,
          0,
        );
        expect(deferred.imported, hasLength(1));
        expect(
          await database.appliedSequence(
            profileId: 'profile-1',
            producerDeviceId: 'producer-1',
          ),
          0,
        );

        await engine.importAvailable(
          profileId: 'profile-1',
          vaultId: 'vault-1',
          consumerDeviceId: 'consumer-1',
          trustedProducerDeviceIds: const ['producer-1'],
          dataset: deferred,
          remote: remote,
        );
        expect(deferred.imported, hasLength(1));

        deferred.receiptReady = true;
        expect(
          (await engine.importAvailable(
            profileId: 'profile-1',
            vaultId: 'vault-1',
            consumerDeviceId: 'consumer-1',
            trustedProducerDeviceIds: const ['producer-1'],
            dataset: deferred,
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
      },
    );
  });
}

Future<void> _publishFixture(
  InMemoryObjectStore remote, {
  required int sequence,
  required String batchId,
  bool corruptOperationsHash = false,
  bool corruptBlobHash = false,
}) async {
  const vault = 'vault-1';
  const producer = 'producer-1';
  final operations = Uint8List.fromList(<int>[1, 2, 3]);
  final blob = Uint8List.fromList(<int>[8, 9]);
  final blobKey = LogicalKeys.blob(vault, 'blob-1');
  final envelope = Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'vaultId': vault,
        'sourceDeviceId': producer,
        'sequence': sequence,
        'batchId': batchId,
        'operations': {
          'cipherSize': operations.length,
          'cipherSha256': corruptOperationsHash
              ? '00'
              : sha256.convert(operations).toString(),
        },
        'blobs': [
          {
            'blobId': 'blob-1',
            'logicalKey': blobKey,
            'cipherSize': blob.length,
            'cipherSha256': corruptBlobHash
                ? '00'
                : sha256.convert(blob).toString(),
          },
        ],
      }),
    ),
  );
  final commit = Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'vaultId': vault,
        'sourceDeviceId': producer,
        'sequence': sequence,
        'batchId': batchId,
        'envelopeSha256': sha256.convert(envelope).toString(),
      }),
    ),
  );

  await _put(remote, blobKey, blob);
  await _put(
    remote,
    LogicalKeys.batchOperations(vault, producer, sequence, batchId),
    operations,
  );
  await _put(
    remote,
    LogicalKeys.batchEnvelope(vault, producer, sequence, batchId),
    envelope,
  );
  await _put(
    remote,
    LogicalKeys.commit(vault, producer, sequence, batchId),
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

class _ImportingDataset implements SyncDatasetAdapter {
  final List<IncomingBatch> imported = [];

  @override
  Future<ImportResult> acceptIncomingBatch(IncomingBatch batch) async {
    imported.add(batch);
    return ImportResult(
      acknowledgementArtifact: ImmutableArtifact.fromBytes(
        Uint8List.fromList(<int>[7]),
      ),
    );
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
    datasetId: 'dataset-1',
    vaultId: 'vault-1',
    kind: DatasetKind.velockManaged,
    displayName: 'Test',
    accessState: DatasetAccessState.available,
    encryptionMode: EncryptionMode.velockManaged,
  );

  @override
  Future<PreparedOutgoingBatch?> prepareNextBatch({
    required ExportCursor cursor,
    required BatchLimits limits,
  }) async => null;
}

class _DeferredDataset extends _ImportingDataset
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
  ) async => receiptReady
      ? ImportResult(
          acknowledgementArtifact: ImmutableArtifact.fromBytes(
            Uint8List.fromList(<int>[7]),
          ),
        )
      : null;
}

class _StreamingDataset extends _ImportingDataset
    implements StreamingIncomingBatchAdapter {
  final Map<String, Uint8List> blobs = {};

  @override
  Future<ImportResult> acceptIncomingArtifactBatch(
    IncomingArtifactBatch batch,
  ) async {
    for (final entry in batch.blobs.entries) {
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in await entry.value.openRead()) {
        bytes.add(chunk);
      }
      blobs[entry.key] = bytes.takeBytes();
    }
    return ImportResult(
      acknowledgementArtifact: ImmutableArtifact.fromBytes(
        Uint8List.fromList(<int>[7]),
      ),
    );
  }
}

class _DuplicateListStore implements RemoteObjectStore {
  _DuplicateListStore(this._delegate);

  final RemoteObjectStore _delegate;
  int injectedDuplicateCount = 0;

  @override
  RemoteCapabilities get capabilities => _delegate.capabilities;

  @override
  Future<void> delete(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) => _delegate.delete(logicalKey, cancellation: cancellation);

  @override
  Future<RemoteObjectPage> list({
    String prefix = '',
    String? cursor,
    int limit = 100,
    RemoteOperationCancellation? cancellation,
  }) async {
    final page = await _delegate.list(
      prefix: prefix,
      cursor: cursor,
      limit: limit,
      cancellation: cancellation,
    );
    if (page.items.isEmpty) return page;
    injectedDuplicateCount += page.items.length;
    return RemoteObjectPage(
      items: [...page.items, ...page.items],
      nextCursor: page.nextCursor,
    );
  }

  @override
  Future<RemoteObjectMetadata> put(
    String logicalKey,
    Stream<List<int>> content, {
    required int contentLength,
    bool ifAbsent = false,
    RemoteOperationCancellation? cancellation,
  }) => _delegate.put(
    logicalKey,
    content,
    contentLength: contentLength,
    ifAbsent: ifAbsent,
    cancellation: cancellation,
  );

  @override
  Stream<List<int>> read(
    String logicalKey, {
    int? start,
    int? endInclusive,
    RemoteOperationCancellation? cancellation,
  }) => _delegate.read(
    logicalKey,
    start: start,
    endInclusive: endInclusive,
    cancellation: cancellation,
  );

  @override
  Future<RemoteObjectMetadata?> stat(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) => _delegate.stat(logicalKey, cancellation: cancellation);
}
