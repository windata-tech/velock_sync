import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';

class SyncRunBusyException implements SyncFailureException {
  const SyncRunBusyException(this.profileId);

  final String profileId;

  @override
  String toString() => 'A sync run is already active for this profile.';

  @override
  SyncFailure get syncFailure => const SyncFailure(
    errorCode: 'sync.run_busy',
    category: SyncErrorCategory.transientNetwork,
    retryable: true,
    suggestedAction: '等待当前同步完成后自动重试。',
  );
}

class ImmutableRemoteObjectMismatchException implements SyncFailureException {
  const ImmutableRemoteObjectMismatchException(this.logicalKey);

  final String logicalKey;

  @override
  String toString() =>
      'An existing immutable remote object has a different size.';

  @override
  SyncFailure get syncFailure => const SyncFailure(
    errorCode: 'remote.immutable_object_mismatch',
    category: SyncErrorCategory.remoteConflict,
    retryable: false,
    suggestedAction: '请使用新的同步空间，或联系支持人员检查远端数据。',
  );
}

class UploadRunResult {
  const UploadRunResult.idle()
    : batchId = null,
      uploadedBlobCount = 0,
      publishedBatchCount = 0;

  const UploadRunResult.published({
    required this.batchId,
    required this.uploadedBlobCount,
  }) : publishedBatchCount = 1;

  const UploadRunResult.summary({
    required this.batchId,
    required this.uploadedBlobCount,
    required this.publishedBatchCount,
  });

  final String? batchId;
  final int uploadedBlobCount;
  final int publishedBatchCount;

  bool get didPublish => publishedBatchCount > 0;
}

/// Provider-neutral V1 upload half of the sync state machine.
///
/// It treats dataset output as opaque, writes blobs and batch bodies first,
/// then makes the batch visible by publishing its commit marker last.
class SyncUploadEngine {
  SyncUploadEngine(
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

  Future<UploadRunResult> publishNext({
    required String profileId,
    required SyncDatasetAdapter dataset,
    required RemoteObjectStore remote,
    required ExportCursor cursor,
    required BatchLimits limits,
  }) async {
    final owner = _uuid.v4();
    final acquired = await _database.tryAcquireProfileLock(
      profileId: profileId,
      owner: owner,
      now: _now(),
      staleAfter: lockLease,
    );
    if (!acquired) throw SyncRunBusyException(profileId);

    try {
      final batch = await dataset.prepareNextBatch(
        cursor: cursor,
        limits: limits,
      );
      if (batch == null) return const UploadRunResult.idle();

      await _database.recordOutgoingBatch(
        profileId: profileId,
        batchId: batch.batchId,
        sequence: batch.sequence,
        state: 'uploading',
      );

      var uploadedBlobCount = 0;
      for (final blob in batch.blobs) {
        if (blob.content.length != blob.descriptor.cipherSize) {
          throw ArgumentError.value(
            blob.content.length,
            'blob.content.length',
            'must match BlobDescriptor.cipherSize',
          );
        }
        final key = LogicalKeys.blob(batch.vaultId, blob.descriptor.blobId);
        if (await _putImmutable(
          profileId: profileId,
          remote: remote,
          logicalKey: key,
          artifact: blob.content,
          expectedHash: blob.descriptor.cipherSha256,
        )) {
          uploadedBlobCount++;
        }
      }

      await _putImmutable(
        profileId: profileId,
        remote: remote,
        logicalKey: LogicalKeys.batchOperations(
          batch.vaultId,
          batch.sourceDeviceId,
          batch.sequence,
          batch.batchId,
        ),
        artifact: batch.operations,
      );
      await _putImmutable(
        profileId: profileId,
        remote: remote,
        logicalKey: LogicalKeys.batchEnvelope(
          batch.vaultId,
          batch.sourceDeviceId,
          batch.sequence,
          batch.batchId,
        ),
        artifact: batch.envelope,
      );
      // This final write is the sole visibility transition for a batch.
      await _putImmutable(
        profileId: profileId,
        remote: remote,
        logicalKey: LogicalKeys.commit(
          batch.vaultId,
          batch.sourceDeviceId,
          batch.sequence,
          batch.batchId,
        ),
        artifact: batch.commit,
      );

      await _database.markOutgoingBatchPublished(
        profileId: profileId,
        batchId: batch.batchId,
        publishedAt: _now(),
      );
      await dataset.acknowledgePublishedBatch(
        batchId: batch.batchId,
        sequence: batch.sequence,
      );
      return UploadRunResult.published(
        batchId: batch.batchId,
        uploadedBlobCount: uploadedBlobCount,
      );
    } finally {
      await _database.releaseProfileLock(profileId: profileId, owner: owner);
    }
  }

  Future<bool> _putImmutable({
    required String profileId,
    required RemoteObjectStore remote,
    required String logicalKey,
    required ImmutableArtifact artifact,
    String? expectedHash,
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
      expectedHash: expectedHash,
    );

    try {
      final existing = await remote.stat(logicalKey);
      if (existing != null) {
        if (existing.size != artifact.length) {
          throw ImmutableRemoteObjectMismatchException(logicalKey);
        }
        await _database.completeTransferJob(
          transferId: transferId,
          completedBytes: artifact.length,
        );
        return false;
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
      return true;
    } on RemoteObjectAlreadyExistsException {
      final concurrentlyCreated = await remote.stat(logicalKey);
      if (concurrentlyCreated == null ||
          concurrentlyCreated.size != artifact.length) {
        throw ImmutableRemoteObjectMismatchException(logicalKey);
      }
      await _database.completeTransferJob(
        transferId: transferId,
        completedBytes: artifact.length,
      );
      return false;
    } on Object catch (error) {
      await _database.failTransferJob(
        transferId: transferId,
        errorCode: SyncFailureClassifier.classify(error).errorCode,
      );
      rethrow;
    }
  }

  String _transferId({
    required String profileId,
    required TransferJobDirection direction,
    required String logicalKey,
  }) => sha256
      .convert(
        utf8.encode('$profileId\u0000${direction.name}\u0000$logicalKey'),
      )
      .toString();
}
