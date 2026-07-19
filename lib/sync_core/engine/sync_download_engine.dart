import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/engine/sync_upload_engine.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';

class BatchIntegrityException implements SyncFailureException {
  const BatchIntegrityException(this.code);

  final String code;

  @override
  String toString() => 'Incoming batch integrity verification failed: $code';

  @override
  SyncFailure get syncFailure => SyncFailure(
    errorCode: 'integrity.$code',
    category: SyncErrorCategory.integrityFailure,
    retryable: false,
    suggestedAction: '请勿导入该远端批次，并检查同步空间完整性。',
  );
}

class DownloadLimits {
  const DownloadLimits({
    this.maxEnvelopeBytes = 4 * 1024 * 1024,
    this.maxOperationsBytes = 64 * 1024 * 1024,
    this.maxBlobBytes = 512 * 1024 * 1024,
    this.maxStreamedBlobBytes,
  });

  final int maxEnvelopeBytes;
  final int maxOperationsBytes;

  /// Protects adapters that still materialize a blob before applying it.
  final int maxBlobBytes;

  /// Optional policy cap for adapters that consume replayable blob streams.
  /// Null preserves the Exchange V1 rule that the protocol has no blob-size
  /// ceiling; transfer length and hash are still verified incrementally.
  final int? maxStreamedBlobBytes;
}

class DownloadRunResult {
  const DownloadRunResult(this.importedBatchCount);

  final int importedBatchCount;
}

/// Provider-neutral V1 download half of the sync state machine.
///
/// It consumes only batches from locally trusted devices. Dataset adapters own
/// signature/AEAD validation and idempotent business import; this layer checks
/// transport identity, sequence continuity, size and ciphertext hashes.
class SyncDownloadEngine {
  SyncDownloadEngine(
    this._database, {
    Uuid? uuid,
    DateTime Function()? now,
    this.lockLease = const Duration(minutes: 10),
  }) : _uuid = uuid ?? const Uuid(),
       _now = now ?? DateTime.now;

  final SyncStateDatabase _database;
  final Uuid _uuid;
  final DateTime Function() _now;
  final Duration lockLease;

  Future<DownloadRunResult> importAvailable({
    required String profileId,
    required String vaultId,
    required String consumerDeviceId,
    required Iterable<String> trustedProducerDeviceIds,
    required SyncDatasetAdapter dataset,
    required RemoteObjectStore remote,
    DownloadLimits limits = const DownloadLimits(),
    int maxBatches = 100,
  }) async {
    if (maxBatches < 1) throw ArgumentError.value(maxBatches, 'maxBatches');
    final owner = _uuid.v4();
    final acquired = await _database.tryAcquireProfileLock(
      profileId: profileId,
      owner: owner,
      now: _now(),
      staleAfter: lockLease,
    );
    if (!acquired) throw SyncRunBusyException(profileId);

    try {
      var imported = 0;
      final producers =
          trustedProducerDeviceIds
              .where((id) => id != consumerDeviceId)
              .toSet()
              .toList()
            ..sort();
      for (final producer in producers) {
        var expected =
            await _database.appliedSequence(
              profileId: profileId,
              producerDeviceId: producer,
            ) +
            1;
        final commits = await _listCommits(remote, vaultId, producer);
        while (imported < maxBatches) {
          final batchId = commits[expected];
          if (batchId == null) break; // Preserve same-device ordering on a gap.
          final applied = await _importOne(
            profileId: profileId,
            vaultId: vaultId,
            consumerDeviceId: consumerDeviceId,
            sourceDeviceId: producer,
            sequence: expected,
            batchId: batchId,
            dataset: dataset,
            remote: remote,
            limits: limits,
          );
          if (!applied) break;
          imported++;
          expected++;
        }
        if (imported >= maxBatches) break;
      }
      return DownloadRunResult(imported);
    } finally {
      await _database.releaseProfileLock(profileId: profileId, owner: owner);
    }
  }

  Future<Map<int, String>> _listCommits(
    RemoteObjectStore remote,
    String vaultId,
    String producerDeviceId,
  ) async {
    final prefix = LogicalKeys.deviceCommitsPrefix(vaultId, producerDeviceId);
    final commits = <int, String>{};
    String? cursor;
    do {
      final page = await remote.list(
        prefix: prefix,
        cursor: cursor,
        limit: 100,
      );
      for (final item in page.items) {
        final suffix = item.logicalKey.startsWith(prefix)
            ? item.logicalKey.substring(prefix.length)
            : '';
        final match = RegExp(r'^(\d{20})-([^/]+)\.commit$').firstMatch(suffix);
        if (match != null) {
          commits[int.parse(match.group(1)!)] = match.group(2)!;
        }
      }
      cursor = page.nextCursor;
    } while (cursor != null);
    return commits;
  }

  Future<bool> _importOne({
    required String profileId,
    required String vaultId,
    required String consumerDeviceId,
    required String sourceDeviceId,
    required int sequence,
    required String batchId,
    required SyncDatasetAdapter dataset,
    required RemoteObjectStore remote,
    required DownloadLimits limits,
  }) async {
    final reference = IncomingBatchReference(
      vaultId: vaultId,
      sourceDeviceId: sourceDeviceId,
      sequence: sequence,
      batchId: batchId,
    );
    if (dataset case final DeferredIncomingBatchAdapter deferred) {
      final reconciled = await deferred.reconcileIncomingBatch(reference);
      if (reconciled != null) {
        if (!reconciled.isApplied) {
          throw StateError('Deferred import reconciliation must be applied.');
        }
        await _completeImport(
          result: reconciled,
          profileId: profileId,
          vaultId: vaultId,
          consumerDeviceId: consumerDeviceId,
          sourceDeviceId: sourceDeviceId,
          sequence: sequence,
          batchId: batchId,
          remote: remote,
        );
        return true;
      }
      if (await _database.incomingBatchState(
            profileId: profileId,
            sourceDeviceId: sourceDeviceId,
            sequence: sequence,
            batchId: batchId,
          ) ==
          'delivered') {
        return false;
      }
    }
    final commitKey = LogicalKeys.commit(
      vaultId,
      sourceDeviceId,
      sequence,
      batchId,
    );
    final commit = _Commit.parse(
      await _readLimited(
        profileId: profileId,
        remote: remote,
        logicalKey: commitKey,
        maximumBytes: limits.maxEnvelopeBytes,
      ),
    );
    if (commit.vaultId != vaultId ||
        commit.sourceDeviceId != sourceDeviceId ||
        commit.sequence != sequence ||
        commit.batchId != batchId) {
      throw const BatchIntegrityException('commit-identity');
    }

    await _database.recordIncomingBatch(
      profileId: profileId,
      sourceDeviceId: sourceDeviceId,
      sequence: sequence,
      batchId: batchId,
      state: 'downloading',
    );
    final envelopeKey = LogicalKeys.batchEnvelope(
      vaultId,
      sourceDeviceId,
      sequence,
      batchId,
    );
    final envelope = await _readLimited(
      profileId: profileId,
      remote: remote,
      logicalKey: envelopeKey,
      maximumBytes: limits.maxEnvelopeBytes,
      expectedHash: commit.envelopeSha256,
    );
    if (_sha256(envelope) != commit.envelopeSha256) {
      throw const BatchIntegrityException('envelope-hash');
    }
    final manifest = _Envelope.parse(envelope);
    if (manifest.vaultId != vaultId ||
        manifest.sourceDeviceId != sourceDeviceId ||
        manifest.sequence != sequence ||
        manifest.batchId != batchId) {
      throw const BatchIntegrityException('envelope-identity');
    }

    final operations = await _readLimited(
      profileId: profileId,
      remote: remote,
      logicalKey: LogicalKeys.batchOperations(
        vaultId,
        sourceDeviceId,
        sequence,
        batchId,
      ),
      maximumBytes: limits.maxOperationsBytes,
      expectedSize: manifest.operationsSize,
      expectedHash: manifest.operationsSha256,
    );
    if (operations.length != manifest.operationsSize ||
        _sha256(operations) != manifest.operationsSha256) {
      throw const BatchIntegrityException('operations-hash');
    }

    final streamedBlobs = <String, ImmutableArtifact>{};
    final bufferedBlobs = <String, Uint8List>{};
    final supportsStreaming = dataset is StreamingIncomingBatchAdapter;
    for (final blob in manifest.blobs) {
      final maximumBlobBytes = supportsStreaming
          ? limits.maxStreamedBlobBytes
          : limits.maxBlobBytes;
      if (maximumBlobBytes != null && blob.size > maximumBlobBytes) {
        throw const BatchIntegrityException('blob-limit');
      }
      final expectedKey = LogicalKeys.blob(vaultId, blob.blobId);
      if (blob.logicalKey != expectedKey) {
        throw const BatchIntegrityException('blob-key');
      }
      if (supportsStreaming) {
        streamedBlobs[blob.blobId] = _remoteArtifact(
          profileId: profileId,
          remote: remote,
          logicalKey: expectedKey,
          maximumBytes: maximumBlobBytes,
          expectedSize: blob.size,
          expectedHash: blob.sha256,
        );
        continue;
      }
      final content = await _readLimited(
        profileId: profileId,
        remote: remote,
        logicalKey: expectedKey,
        maximumBytes: limits.maxBlobBytes,
        expectedSize: blob.size,
        expectedHash: blob.sha256,
      );
      if (content.length != blob.size || _sha256(content) != blob.sha256) {
        throw const BatchIntegrityException('blob-hash');
      }
      bufferedBlobs[blob.blobId] = content;
    }

    final result = supportsStreaming
        ? await (dataset as StreamingIncomingBatchAdapter)
              .acceptIncomingArtifactBatch(
                IncomingArtifactBatch(
                  vaultId: vaultId,
                  sourceDeviceId: sourceDeviceId,
                  sequence: sequence,
                  batchId: batchId,
                  envelope: envelope,
                  operations: operations,
                  blobs: Map.unmodifiable(streamedBlobs),
                ),
              )
        : await dataset.acceptIncomingBatch(
            IncomingBatch(
              vaultId: vaultId,
              sourceDeviceId: sourceDeviceId,
              sequence: sequence,
              batchId: batchId,
              envelope: envelope,
              operations: operations,
              blobs: bufferedBlobs,
            ),
          );
    if (!result.isApplied) {
      await _database.recordIncomingBatch(
        profileId: profileId,
        sourceDeviceId: sourceDeviceId,
        sequence: sequence,
        batchId: batchId,
        state: 'delivered',
      );
      return false;
    }
    await _completeImport(
      result: result,
      profileId: profileId,
      vaultId: vaultId,
      consumerDeviceId: consumerDeviceId,
      sourceDeviceId: sourceDeviceId,
      sequence: sequence,
      batchId: batchId,
      remote: remote,
    );
    return true;
  }

  Future<void> _completeImport({
    required ImportResult result,
    required String profileId,
    required String vaultId,
    required String consumerDeviceId,
    required String sourceDeviceId,
    required int sequence,
    required String batchId,
    required RemoteObjectStore remote,
  }) async {
    if (result.acknowledgementArtifact case final acknowledgement?) {
      await _putImmutable(
        profileId: profileId,
        remote: remote,
        logicalKey: LogicalKeys.acknowledgement(
          vaultId,
          consumerDeviceId,
          sourceDeviceId,
          sequence,
        ),
        artifact: acknowledgement,
      );
    }
    await _database.advanceAppliedSequence(
      profileId: profileId,
      producerDeviceId: sourceDeviceId,
      sequence: sequence,
    );
    await _database.recordIncomingBatch(
      profileId: profileId,
      sourceDeviceId: sourceDeviceId,
      sequence: sequence,
      batchId: batchId,
      state: 'imported',
    );
  }

  Future<Uint8List> _readLimited({
    required String profileId,
    required RemoteObjectStore remote,
    required String logicalKey,
    required int maximumBytes,
    int? expectedSize,
    String? expectedHash,
  }) async {
    final transferId = _transferId(
      profileId: profileId,
      direction: TransferJobDirection.download,
      logicalKey: logicalKey,
    );
    await _database.beginTransferJob(
      transferId: transferId,
      profileId: profileId,
      direction: TransferJobDirection.download,
      logicalKey: logicalKey,
      expectedSize: expectedSize,
      expectedHash: expectedHash,
    );
    try {
      final bytes = BytesBuilder(copy: false);
      var lastPersistedBytes = 0;
      await for (final chunk in remote.read(logicalKey)) {
        bytes.add(chunk);
        if (bytes.length > maximumBytes) {
          throw const BatchIntegrityException('size-limit');
        }
        if (bytes.length - lastPersistedBytes >= 1024 * 1024) {
          await _database.updateTransferProgress(
            transferId: transferId,
            completedBytes: bytes.length,
          );
          lastPersistedBytes = bytes.length;
        }
      }
      await _database.completeTransferJob(
        transferId: transferId,
        completedBytes: bytes.length,
      );
      return bytes.takeBytes();
    } on Object catch (error) {
      await _database.failTransferJob(
        transferId: transferId,
        errorCode: SyncFailureClassifier.classify(error).errorCode,
      );
      rethrow;
    }
  }

  ImmutableArtifact _remoteArtifact({
    required String profileId,
    required RemoteObjectStore remote,
    required String logicalKey,
    required int? maximumBytes,
    required int expectedSize,
    required String expectedHash,
  }) => ImmutableArtifact(
    length: expectedSize,
    openRead: () async => _verifiedRemoteStream(
      profileId: profileId,
      remote: remote,
      logicalKey: logicalKey,
      maximumBytes: maximumBytes,
      expectedSize: expectedSize,
      expectedHash: expectedHash,
    ),
  );

  Stream<List<int>> _verifiedRemoteStream({
    required String profileId,
    required RemoteObjectStore remote,
    required String logicalKey,
    required int? maximumBytes,
    required int expectedSize,
    required String expectedHash,
  }) async* {
    final transferId = _transferId(
      profileId: profileId,
      direction: TransferJobDirection.download,
      logicalKey: logicalKey,
    );
    await _database.beginTransferJob(
      transferId: transferId,
      profileId: profileId,
      direction: TransferJobDirection.download,
      logicalKey: logicalKey,
      expectedSize: expectedSize,
      expectedHash: expectedHash,
    );
    var transferred = 0;
    var lastPersisted = 0;
    final digestOutput = _DigestSink();
    final digestInput = sha256.startChunkedConversion(digestOutput);
    var digestClosed = false;
    var transferCompleted = false;
    var failureRecorded = false;
    try {
      await for (final chunk in remote.read(logicalKey)) {
        transferred += chunk.length;
        if ((maximumBytes != null && transferred > maximumBytes) ||
            transferred > expectedSize) {
          throw const BatchIntegrityException('blob-limit');
        }
        digestInput.add(chunk);
        if (transferred - lastPersisted >= 1024 * 1024) {
          await _database.updateTransferProgress(
            transferId: transferId,
            completedBytes: transferred,
          );
          lastPersisted = transferred;
        }
        yield chunk;
      }
      digestInput.close();
      digestClosed = true;
      if (transferred != expectedSize ||
          digestOutput.value.toString() != expectedHash) {
        throw const BatchIntegrityException('blob-hash');
      }
      await _database.completeTransferJob(
        transferId: transferId,
        completedBytes: transferred,
      );
      transferCompleted = true;
    } on Object catch (error) {
      await _database.failTransferJob(
        transferId: transferId,
        errorCode: SyncFailureClassifier.classify(error).errorCode,
      );
      failureRecorded = true;
      rethrow;
    } finally {
      if (!digestClosed) {
        digestInput.close();
      }
      if (!transferCompleted && !failureRecorded) {
        await _database.failTransferJob(
          transferId: transferId,
          errorCode: 'remote.operation_cancelled',
        );
      }
    }
  }

  Future<void> _putImmutable({
    required String profileId,
    required RemoteObjectStore remote,
    required String logicalKey,
    required ImmutableArtifact artifact,
  }) async {
    final transferId = _transferId(
      profileId: profileId,
      direction: TransferJobDirection.upload,
      logicalKey: logicalKey,
    );
    await _database.beginTransferJob(
      transferId: transferId,
      profileId: profileId,
      direction: TransferJobDirection.upload,
      logicalKey: logicalKey,
      expectedSize: artifact.length,
    );
    try {
      final existing = await remote.stat(logicalKey);
      if (existing != null) {
        if (existing.size != artifact.length) {
          throw const BatchIntegrityException('ack-mismatch');
        }
        await _database.completeTransferJob(
          transferId: transferId,
          completedBytes: artifact.length,
        );
        return;
      }

      var transferredBytes = 0;
      var lastPersistedBytes = 0;
      final source = await artifact.openRead();
      await remote.put(
        logicalKey,
        () async* {
          await for (final chunk in source) {
            transferredBytes += chunk.length;
            if (transferredBytes == artifact.length ||
                transferredBytes - lastPersistedBytes >= 1024 * 1024) {
              await _database.updateTransferProgress(
                transferId: transferId,
                completedBytes: transferredBytes,
              );
              lastPersistedBytes = transferredBytes;
            }
            yield chunk;
          }
        }(),
        contentLength: artifact.length,
        ifAbsent: true,
      );
      await _database.completeTransferJob(
        transferId: transferId,
        completedBytes: transferredBytes,
      );
    } on RemoteObjectAlreadyExistsException {
      final concurrent = await remote.stat(logicalKey);
      if (concurrent == null || concurrent.size != artifact.length) {
        throw const BatchIntegrityException('ack-mismatch');
      }
      await _database.completeTransferJob(
        transferId: transferId,
        completedBytes: artifact.length,
      );
    } on Object catch (error) {
      await _database.failTransferJob(
        transferId: transferId,
        errorCode: SyncFailureClassifier.classify(error).errorCode,
      );
      rethrow;
    }
  }

  static String _transferId({
    required String profileId,
    required TransferJobDirection direction,
    required String logicalKey,
  }) => sha256
      .convert(
        utf8.encode('$profileId\u0000${direction.name}\u0000$logicalKey'),
      )
      .toString();

  static String _sha256(List<int> bytes) => sha256.convert(bytes).toString();
}

class _DigestSink implements Sink<Digest> {
  Digest? _value;

  Digest get value =>
      _value ?? (throw StateError('Digest stream did not produce a value.'));

  @override
  void add(Digest data) {
    if (_value != null) throw StateError('Digest stream produced twice.');
    _value = data;
  }

  @override
  void close() {}
}

class _Commit {
  const _Commit({
    required this.vaultId,
    required this.sourceDeviceId,
    required this.sequence,
    required this.batchId,
    required this.envelopeSha256,
  });

  final String vaultId;
  final String sourceDeviceId;
  final int sequence;
  final String batchId;
  final String envelopeSha256;

  factory _Commit.parse(Uint8List bytes) {
    final json = _jsonObject(bytes, 'commit-json');
    return _Commit(
      vaultId: _string(json, 'vaultId'),
      sourceDeviceId: _string(json, 'sourceDeviceId'),
      sequence: _int(json, 'sequence'),
      batchId: _string(json, 'batchId'),
      envelopeSha256: _string(json, 'envelopeSha256'),
    );
  }
}

class _Envelope {
  const _Envelope({
    required this.vaultId,
    required this.sourceDeviceId,
    required this.sequence,
    required this.batchId,
    required this.operationsSize,
    required this.operationsSha256,
    required this.blobs,
  });

  final String vaultId;
  final String sourceDeviceId;
  final int sequence;
  final String batchId;
  final int operationsSize;
  final String operationsSha256;
  final List<_Blob> blobs;

  factory _Envelope.parse(Uint8List bytes) {
    final json = _jsonObject(bytes, 'envelope-json');
    final operations = json['operations'];
    if (operations is! Map<String, dynamic>) {
      throw const BatchIntegrityException('operations-schema');
    }
    final blobs = json['blobs'];
    if (blobs is! List) {
      throw const BatchIntegrityException('blobs-schema');
    }
    return _Envelope(
      vaultId: _string(json, 'vaultId'),
      sourceDeviceId: _string(json, 'sourceDeviceId'),
      sequence: _int(json, 'sequence'),
      batchId: _string(json, 'batchId'),
      operationsSize: _int(operations, 'cipherSize'),
      operationsSha256: _string(operations, 'cipherSha256'),
      blobs: blobs.map((blob) => _Blob.parse(blob)).toList(),
    );
  }
}

class _Blob {
  const _Blob({
    required this.blobId,
    required this.logicalKey,
    required this.size,
    required this.sha256,
  });

  final String blobId;
  final String logicalKey;
  final int size;
  final String sha256;

  factory _Blob.parse(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const BatchIntegrityException('blob-schema');
    }
    return _Blob(
      blobId: _string(value, 'blobId'),
      logicalKey: _string(value, 'logicalKey'),
      size: _int(value, 'cipherSize'),
      sha256: _string(value, 'cipherSha256'),
    );
  }
}

Map<String, dynamic> _jsonObject(Uint8List bytes, String code) {
  try {
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic>) {
      throw const BatchIntegrityException('json-object');
    }
    return value;
  } on FormatException {
    throw BatchIntegrityException(code);
  }
}

String _string(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is! String || value.isEmpty) {
    throw BatchIntegrityException('$field-schema');
  }
  return value;
}

int _int(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is! int || value < 0) {
    throw BatchIntegrityException('$field-schema');
  }
  return value;
}
