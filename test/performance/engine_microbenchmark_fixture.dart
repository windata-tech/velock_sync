// Lightweight patterns adapted from test/sync_core/{sync_profile_runner,
// sync_upload_engine,sync_download_engine}_test.dart. No real adapter/network.
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';

const vaultId = 'perf-vault';
const producerId = 'producer-1';
const consumerId = 'consumer-1';
const profileId = 'perf-profile';

/// Counts external store API calls, not delegate internals or HTTP requests.
/// Bytes count consumed PUT stream chunks, not declared length or DB progress.
class Workload {
  final requests = <String, int>{
    'stat': 0,
    'list': 0,
    'read': 0,
    'put': 0,
    'delete': 0,
  };
  final putKeys = <String>[];
  final readKeys = <String>[];
  final uploadedBytesByKey = <String, int>{};
  int listedItems = 0;
  int duplicateItems = 0;

  void count(String method) => requests[method] = requests[method]! + 1;
  int get totalRequests => requests.values.fold(0, (a, b) => a + b);
  int get businessPutCount => putKeys.where(isBusinessObject).length;
  int get businessUploadBytes => bytesWhere(isBusinessObject);
  int get blobUploadBytes => bytesWhere((key) => key.contains('/blobs/'));
  int bytesWhere(bool Function(String) include) => uploadedBytesByKey.entries
      .where((entry) => include(entry.key))
      .fold(0, (total, entry) => total + entry.value);

  Map<String, Object> toJson() => {
    'requests': requests,
    'totalRequests': totalRequests,
    'businessPutCount': businessPutCount,
    'businessUploadBytes': businessUploadBytes,
    'blobUploadBytes': blobUploadBytes,
    'totalUploadBytes': bytesWhere((_) => true),
    'listedItems': listedItems,
    'duplicateItems': duplicateItems,
    'putKeys': putKeys,
    'readKeys': readKeys,
    'uploadedBytesByKey': uploadedBytesByKey,
  };
}

// All batch bodies and commits are business objects; protocol and ACKs are not.
bool isBusinessObject(String key) =>
    key.startsWith(LogicalKeys.vaultPrefix(vaultId)) &&
    (key.contains('/blobs/') || key.contains('/devices/'));

class MeteredStore implements RemoteObjectStore {
  final InMemoryObjectStore _delegate = InMemoryObjectStore();
  Workload workload = Workload();
  bool duplicateListEntries = false;

  @override
  RemoteCapabilities get capabilities => _delegate.capabilities;

  @override
  Future<RemoteObjectMetadata?> stat(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) {
    workload.count('stat');
    return _delegate.stat(logicalKey, cancellation: cancellation);
  }

  @override
  Future<RemoteObjectPage> list({
    String prefix = '',
    String? cursor,
    int limit = 100,
    RemoteOperationCancellation? cancellation,
  }) async {
    final sample = workload;
    sample.count('list');
    final page = await _delegate.list(
      prefix: prefix,
      cursor: cursor,
      limit: limit,
      cancellation: cancellation,
    );
    sample.listedItems += page.items.length;
    if (!duplicateListEntries) return page;
    sample.duplicateItems += page.items.length;
    return RemoteObjectPage(
      items: [...page.items, ...page.items],
      nextCursor: page.nextCursor,
    );
  }

  @override
  Stream<List<int>> read(
    String logicalKey, {
    int? start,
    int? endInclusive,
    RemoteOperationCancellation? cancellation,
  }) {
    workload.count('read');
    workload.readKeys.add(logicalKey);
    return _delegate.read(
      logicalKey,
      start: start,
      endInclusive: endInclusive,
      cancellation: cancellation,
    );
  }

  @override
  Future<RemoteObjectMetadata> put(
    String logicalKey,
    Stream<List<int>> content, {
    required int contentLength,
    bool ifAbsent = false,
    RemoteOperationCancellation? cancellation,
  }) {
    final sample = workload;
    sample.count('put');
    sample.putKeys.add(logicalKey);
    return _delegate.put(
      logicalKey,
      () async* {
        await for (final chunk in content) {
          sample.uploadedBytesByKey.update(
            logicalKey,
            (bytes) => bytes + chunk.length,
            ifAbsent: () => chunk.length,
          );
          yield chunk;
        }
      }(),
      contentLength: contentLength,
      ifAbsent: ifAbsent,
      cancellation: cancellation,
    );
  }

  @override
  Future<void> delete(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) {
    workload.count('delete');
    return _delegate.delete(logicalKey, cancellation: cancellation);
  }
}

/// Intentionally does NOT deduplicate acceptIncomingBatch: duplicate engine
/// delivery must be observable rather than hidden by the fixture.
class QueueDataset implements SyncDatasetAdapter {
  final pending = Queue<PreparedOutgoingBatch>();
  final acknowledged = <String>[];
  final imported = <IncomingBatch>[];
  int failAcknowledgements = 0;

  @override
  Future<PreparedOutgoingBatch?> prepareNextBatch({
    required ExportCursor cursor,
    required BatchLimits limits,
  }) async => pending.isEmpty ? null : pending.first;

  @override
  Future<void> acknowledgePublishedBatch({
    required String batchId,
    required int sequence,
  }) async {
    if (failAcknowledgements > 0) {
      failAcknowledgements--;
      throw StateError('injected local cursor failure');
    }
    final batch = pending.removeFirst();
    if (batch.batchId != batchId || batch.sequence != sequence) {
      throw StateError('wrong outgoing acknowledgement');
    }
    acknowledged.add('$batchId:$sequence');
  }

  @override
  Future<ImportResult> acceptIncomingBatch(IncomingBatch batch) async {
    imported.add(batch);
    return ImportResult(
      acknowledgementArtifact: ImmutableArtifact.fromBytes(
        Uint8List.fromList([7]),
      ),
    );
  }

  @override
  Future<DatasetAccessState> checkAccess() async =>
      DatasetAccessState.available;

  @override
  Future<DatasetDescriptor> describe() async => const DatasetDescriptor(
    datasetId: 'perf-dataset',
    vaultId: vaultId,
    kind: DatasetKind.velockManaged,
    displayName: 'Synthetic engine microbenchmark',
    accessState: DatasetAccessState.available,
    encryptionMode: EncryptionMode.velockManaged,
  );
}

PreparedBlob makeBlob(int index, int size) {
  final bytes = Uint8List.fromList(
    List.generate(size, (i) => (i + index) % 251),
  );
  return PreparedBlob(
    descriptor: BlobDescriptor(
      blobId: 'blob-$index',
      cipherSize: size,
      cipherSha256: sha256.convert(bytes).toString(),
    ),
    content: ImmutableArtifact.fromBytes(bytes),
  );
}

PreparedOutgoingBatch makeBatch(int sequence, List<PreparedBlob> blobs) {
  final identity = <String, Object>{
    'vaultId': vaultId,
    'sourceDeviceId': producerId,
    'sequence': sequence,
    'batchId': 'batch-$sequence',
  };
  final operations = Uint8List.fromList([sequence, 2, 3]);
  Uint8List encode(Object value) =>
      Uint8List.fromList(utf8.encode(jsonEncode(value)));
  final envelope = encode({
    ...identity,
    'operations': {
      'cipherSize': operations.length,
      'cipherSha256': sha256.convert(operations).toString(),
    },
    'blobs': [
      for (final blob in blobs)
        {
          'blobId': blob.descriptor.blobId,
          'logicalKey': LogicalKeys.blob(vaultId, blob.descriptor.blobId),
          'cipherSize': blob.descriptor.cipherSize,
          'cipherSha256': blob.descriptor.cipherSha256,
        },
    ],
  });
  final commit = encode({
    ...identity,
    'envelopeSha256': sha256.convert(envelope).toString(),
  });
  return PreparedOutgoingBatch(
    vaultId: vaultId,
    sourceDeviceId: producerId,
    sequence: sequence,
    batchId: 'batch-$sequence',
    operations: ImmutableArtifact.fromBytes(operations),
    envelope: ImmutableArtifact.fromBytes(envelope),
    commit: ImmutableArtifact.fromBytes(commit),
    blobs: blobs,
  );
}

int batchBodyBytes(PreparedOutgoingBatch batch) =>
    batch.operations.length + batch.envelope.length + batch.commit.length;
