import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/engine/sync_upload_engine.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';

void main() {
  group('SyncUploadEngine', () {
    late SyncStateDatabase database;

    setUp(() async {
      database = await SyncStateDatabase.inMemory();
    });

    tearDown(() => database.close());

    test(
      'deduplicates blobs and makes a batch visible only at commit',
      () async {
        final remote = _RecordingStore();
        final batch = _batch();
        final blobKey = LogicalKeys.blob(
          batch.vaultId,
          batch.blobs.single.descriptor.blobId,
        );
        await remote.put(
          blobKey,
          Stream.value(<int>[1, 2, 3]),
          contentLength: 3,
          ifAbsent: true,
        );
        remote.putKeys.clear();
        final dataset = _Dataset(batch);

        final result = await SyncUploadEngine(database).publishNext(
          profileId: 'profile-1',
          dataset: dataset,
          remote: remote,
          cursor: ExportCursor.empty,
          limits: const BatchLimits(),
        );

        final commitKey = LogicalKeys.commit(
          batch.vaultId,
          batch.sourceDeviceId,
          batch.sequence,
          batch.batchId,
        );
        expect(result.didPublish, isTrue);
        expect(result.publishedBatchCount, 1);
        expect(result.uploadedBlobCount, 0);
        expect(dataset.acknowledged, ['batch-1:1']);
        expect(remote.putKeys.last, commitKey);
        expect(await remote.stat(commitKey), isNotNull);

        final transfers = await database.listTransferJobs(
          profileId: 'profile-1',
          includeCompleted: true,
        );
        expect(transfers, hasLength(4));
        expect(
          transfers.every(
            (transfer) =>
                transfer.direction == TransferJobDirection.upload &&
                transfer.state == TransferJobState.completed,
          ),
          isTrue,
        );
        final blobTransfer = transfers.singleWhere(
          (transfer) => transfer.logicalKey == blobKey,
        );
        expect(blobTransfer.completedBytes, 3);
        expect(blobTransfer.expectedHash, 'hash');
      },
    );

    test(
      'does not publish a commit when a prior immutable object fails',
      () async {
        final batch = _batch();
        final operationsKey = LogicalKeys.batchOperations(
          batch.vaultId,
          batch.sourceDeviceId,
          batch.sequence,
          batch.batchId,
        );
        final remote = _RecordingStore(failPutFor: {operationsKey});
        final dataset = _Dataset(batch);

        await expectLater(
          SyncUploadEngine(database).publishNext(
            profileId: 'profile-1',
            dataset: dataset,
            remote: remote,
            cursor: ExportCursor.empty,
            limits: const BatchLimits(),
          ),
          throwsStateError,
        );

        final commitKey = LogicalKeys.commit(
          batch.vaultId,
          batch.sourceDeviceId,
          batch.sequence,
          batch.batchId,
        );
        expect(await remote.stat(commitKey), isNull);
        expect(dataset.acknowledged, isEmpty);
        final failed = (await database.listTransferJobs(
          profileId: 'profile-1',
        )).singleWhere((transfer) => transfer.logicalKey == operationsKey);
        expect(failed.state, TransferJobState.failed);
        expect(failed.errorCode, 'sync.unexpected');
      },
    );

    test(
      'replays safely after the blob succeeded but the batch body failed',
      () async {
        final batch = _batch();
        final blobKey = LogicalKeys.blob(
          batch.vaultId,
          batch.blobs.single.descriptor.blobId,
        );
        final operationsKey = LogicalKeys.batchOperations(
          batch.vaultId,
          batch.sourceDeviceId,
          batch.sequence,
          batch.batchId,
        );
        final remote = _RecordingStore(failPutFor: {operationsKey});
        final dataset = _Dataset(batch);
        final engine = SyncUploadEngine(database);

        await expectLater(
          engine.publishNext(
            profileId: 'profile-1',
            dataset: dataset,
            remote: remote,
            cursor: ExportCursor.empty,
            limits: const BatchLimits(),
          ),
          throwsStateError,
        );
        expect(await remote.stat(blobKey), isNotNull);
        expect(
          await remote.stat(
            LogicalKeys.commit(
              batch.vaultId,
              batch.sourceDeviceId,
              batch.sequence,
              batch.batchId,
            ),
          ),
          isNull,
        );

        remote.failPutFor.remove(operationsKey);
        final replay = await engine.publishNext(
          profileId: 'profile-1',
          dataset: dataset,
          remote: remote,
          cursor: ExportCursor.empty,
          limits: const BatchLimits(),
        );

        expect(replay.didPublish, isTrue);
        expect(remote.putAttempts.where((key) => key == blobKey), hasLength(1));
        expect(dataset.acknowledged, ['batch-1:1']);
      },
    );

    test(
      'keeps a completed batch invisible when commit upload fails',
      () async {
        final batch = _batch();
        final commitKey = LogicalKeys.commit(
          batch.vaultId,
          batch.sourceDeviceId,
          batch.sequence,
          batch.batchId,
        );
        final remote = _RecordingStore(failPutFor: {commitKey});
        final dataset = _Dataset(batch);
        final engine = SyncUploadEngine(database);

        await expectLater(
          engine.publishNext(
            profileId: 'profile-1',
            dataset: dataset,
            remote: remote,
            cursor: ExportCursor.empty,
            limits: const BatchLimits(),
          ),
          throwsStateError,
        );
        expect(await remote.stat(commitKey), isNull);
        expect(dataset.acknowledged, isEmpty);

        remote.failPutFor.remove(commitKey);
        final replay = await engine.publishNext(
          profileId: 'profile-1',
          dataset: dataset,
          remote: remote,
          cursor: ExportCursor.empty,
          limits: const BatchLimits(),
        );

        expect(replay.didPublish, isTrue);
        expect(await remote.stat(commitKey), isNotNull);
        expect(dataset.acknowledged, ['batch-1:1']);
      },
    );

    test(
      'restarts an interrupted blob upload from an immutable source',
      () async {
        final batch = _chunkedBatch();
        final blobKey = LogicalKeys.blob(
          batch.vaultId,
          batch.blobs.single.descriptor.blobId,
        );
        final remote = _InterruptingStore(interruptKey: blobKey);
        final dataset = _Dataset(batch);
        final engine = SyncUploadEngine(database);

        await expectLater(
          engine.publishNext(
            profileId: 'profile-1',
            dataset: dataset,
            remote: remote,
            cursor: ExportCursor.empty,
            limits: const BatchLimits(),
          ),
          throwsStateError,
        );
        expect(remote.interruptedBytes, 3);
        expect(await remote.stat(blobKey), isNull);
        final failed = (await database.listTransferJobs(
          profileId: 'profile-1',
        )).singleWhere((transfer) => transfer.logicalKey == blobKey);
        expect(failed.state, TransferJobState.failed);

        remote.interrupt = false;
        final replay = await engine.publishNext(
          profileId: 'profile-1',
          dataset: dataset,
          remote: remote,
          cursor: ExportCursor.empty,
          limits: const BatchLimits(),
        );

        expect(replay.didPublish, isTrue);
        expect((await remote.stat(blobKey))?.size, 10);
        expect(dataset.acknowledged, ['batch-1:1']);
      },
    );

    test(
      'reconciles a remote commit after the local dataset cursor write failed',
      () async {
        final batch = _batch();
        final remote = _RecordingStore();
        final dataset = _Dataset(batch, failAcknowledgements: 1);
        final engine = SyncUploadEngine(database);
        final commitKey = LogicalKeys.commit(
          batch.vaultId,
          batch.sourceDeviceId,
          batch.sequence,
          batch.batchId,
        );

        await expectLater(
          engine.publishNext(
            profileId: 'profile-1',
            dataset: dataset,
            remote: remote,
            cursor: ExportCursor.empty,
            limits: const BatchLimits(),
          ),
          throwsStateError,
        );
        expect(await remote.stat(commitKey), isNotNull);
        expect(dataset.acknowledged, isEmpty);
        final firstAttemptCount = remote.putAttempts.length;

        final replay = await engine.publishNext(
          profileId: 'profile-1',
          dataset: dataset,
          remote: remote,
          cursor: ExportCursor.empty,
          limits: const BatchLimits(),
        );

        expect(replay.didPublish, isTrue);
        expect(dataset.acknowledged, ['batch-1:1']);
        expect(remote.putAttempts, hasLength(firstAttemptCount));
      },
    );
  });
}

PreparedOutgoingBatch _batch() => PreparedOutgoingBatch(
  vaultId: 'vault-1',
  sourceDeviceId: 'device-1',
  sequence: 1,
  batchId: 'batch-1',
  envelope: _artifact(<int>[4]),
  operations: _artifact(<int>[5, 6]),
  commit: _artifact(<int>[7]),
  blobs: [
    PreparedBlob(
      descriptor: const BlobDescriptor(
        blobId: 'abc-blob',
        cipherSize: 3,
        cipherSha256: 'hash',
      ),
      content: _artifact(<int>[1, 2, 3]),
    ),
  ],
);

ImmutableArtifact _artifact(List<int> bytes) =>
    ImmutableArtifact.fromBytes(Uint8List.fromList(bytes));

PreparedOutgoingBatch _chunkedBatch() {
  final original = _batch();
  return PreparedOutgoingBatch(
    vaultId: original.vaultId,
    sourceDeviceId: original.sourceDeviceId,
    sequence: original.sequence,
    batchId: original.batchId,
    envelope: original.envelope,
    operations: original.operations,
    commit: original.commit,
    blobs: [
      PreparedBlob(
        descriptor: const BlobDescriptor(
          blobId: 'abc-blob',
          cipherSize: 10,
          cipherSha256: 'hash',
        ),
        content: ImmutableArtifact(
          length: 10,
          openRead: () async => Stream.fromIterable([
            <int>[1, 2, 3],
            <int>[4, 5, 6, 7, 8, 9, 10],
          ]),
        ),
      ),
    ],
  );
}

class _Dataset implements SyncDatasetAdapter {
  _Dataset(this.batch, {this.failAcknowledgements = 0});

  final PreparedOutgoingBatch batch;
  final List<String> acknowledged = [];
  int failAcknowledgements;

  @override
  Future<void> acknowledgePublishedBatch({
    required String batchId,
    required int sequence,
  }) async {
    if (failAcknowledgements > 0) {
      failAcknowledgements--;
      throw StateError('injected local cursor failure');
    }
    acknowledged.add('$batchId:$sequence');
  }

  @override
  Future<ImportResult> acceptIncomingBatch(IncomingBatch batch) async =>
      const ImportResult();

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
  }) async => batch;
}

class _RecordingStore implements RemoteObjectStore {
  _RecordingStore({Set<String>? failPutFor}) : _failPutFor = failPutFor ?? {};

  final InMemoryObjectStore _delegate = InMemoryObjectStore();
  final Set<String> _failPutFor;
  final List<String> putKeys = [];
  final List<String> putAttempts = [];

  Set<String> get failPutFor => _failPutFor;

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
  }) => _delegate.list(
    prefix: prefix,
    cursor: cursor,
    limit: limit,
    cancellation: cancellation,
  );

  @override
  Future<RemoteObjectMetadata> put(
    String logicalKey,
    Stream<List<int>> content, {
    required int contentLength,
    bool ifAbsent = false,
    RemoteOperationCancellation? cancellation,
  }) async {
    putAttempts.add(logicalKey);
    if (_failPutFor.contains(logicalKey)) {
      throw StateError('injected upload failure');
    }
    putKeys.add(logicalKey);
    return _delegate.put(
      logicalKey,
      content,
      contentLength: contentLength,
      ifAbsent: ifAbsent,
      cancellation: cancellation,
    );
  }

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

class _InterruptingStore implements RemoteObjectStore {
  _InterruptingStore({required this.interruptKey});

  final String interruptKey;
  final InMemoryObjectStore _delegate = InMemoryObjectStore();
  bool interrupt = true;
  int interruptedBytes = 0;

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
  }) => _delegate.list(
    prefix: prefix,
    cursor: cursor,
    limit: limit,
    cancellation: cancellation,
  );

  @override
  Future<RemoteObjectMetadata> put(
    String logicalKey,
    Stream<List<int>> content, {
    required int contentLength,
    bool ifAbsent = false,
    RemoteOperationCancellation? cancellation,
  }) async {
    if (interrupt && logicalKey == interruptKey) {
      await for (final chunk in content) {
        interruptedBytes += chunk.length;
        throw StateError('injected network loss at 30 percent');
      }
    }
    return _delegate.put(
      logicalKey,
      content,
      contentLength: contentLength,
      ifAbsent: ifAbsent,
      cancellation: cancellation,
    );
  }

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
