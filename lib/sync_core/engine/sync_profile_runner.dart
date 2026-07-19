import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/engine/sync_download_engine.dart';
import 'package:velock_sync/sync_core/engine/sync_checkpoint_recovery.dart';
import 'package:velock_sync/sync_core/engine/sync_upload_engine.dart';
import 'package:velock_sync/sync_core/engine/vault_protocol.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';

class SyncDatasetAccessException implements SyncFailureException {
  const SyncDatasetAccessException(this.accessState);

  final DatasetAccessState accessState;

  @override
  String toString() => 'Dataset access is not available: ${accessState.name}.';

  @override
  SyncFailure get syncFailure => SyncFailure(
    errorCode: 'dataset.access.${accessState.name}',
    category: accessState == DatasetAccessState.needsAuthorization
        ? SyncErrorCategory.userActionRequired
        : SyncErrorCategory.localAccessLost,
    retryable: accessState == DatasetAccessState.unavailable,
    suggestedAction: accessState == DatasetAccessState.needsAuthorization
        ? '请重新授权数据源。'
        : '请确认数据源目录仍可访问。',
  );
}

class SyncProfileRunResult {
  const SyncProfileRunResult({
    required this.runId,
    required this.upload,
    required this.download,
    this.checkpointRecovery,
  });

  final String runId;
  final UploadRunResult upload;
  final DownloadRunResult download;
  final CheckpointRecoveryResult? checkpointRecovery;
}

/// The application-facing V1 run sequence. It keeps trust local: remote member
/// descriptions never enter the download allow-list without a local record.
class SyncProfileRunner {
  SyncProfileRunner(
    this._database, {
    SyncUploadEngine? uploadEngine,
    SyncDownloadEngine? downloadEngine,
    SyncCheckpointRecovery? checkpointRecovery,
    VaultProtocolBootstrapper? protocolBootstrapper,
    Uuid? uuid,
    DateTime Function()? now,
  }) : _uploadEngine = uploadEngine ?? SyncUploadEngine(_database),
       _downloadEngine = downloadEngine ?? SyncDownloadEngine(_database),
       _checkpointRecovery =
           checkpointRecovery ?? const SyncCheckpointRecovery(),
       _protocolBootstrapper =
           protocolBootstrapper ?? VaultProtocolBootstrapper(),
       _uuid = uuid ?? const Uuid(),
       _now = now ?? DateTime.now;

  final SyncStateDatabase _database;
  final SyncUploadEngine _uploadEngine;
  final SyncDownloadEngine _downloadEngine;
  final SyncCheckpointRecovery _checkpointRecovery;
  final VaultProtocolBootstrapper _protocolBootstrapper;
  final Uuid _uuid;
  final DateTime Function() _now;

  Future<SyncProfileRunResult> run({
    required String profileId,
    required String vaultId,
    required String deviceId,
    required VaultProtocolDocument protocol,
    required SyncDatasetAdapter dataset,
    required RemoteObjectStore remote,
    ExportCursor cursor = ExportCursor.empty,
    BatchLimits uploadLimits = const BatchLimits(),
    DownloadLimits downloadLimits = const DownloadLimits(),
    int maxUploadBatches = 100,

    /// Runs after dataset access but before any remote operation.
    Future<void> Function()? preflight,

    /// Runs after the immutable protocol document is known to be available.
    Future<void> Function()? postProtocolPreflight,

    /// Optional locally-established producer identities for datasets whose
    /// trust is maintained outside the generic device membership table.
    ///
    /// This never accepts producer IDs from the remote. Omit it for Generic
    /// Vault profiles to retain the database-backed device allow-list.
    Iterable<String>? trustedProducerDeviceIds,
  }) async {
    if (protocol.vaultId != vaultId) {
      throw ArgumentError.value(protocol.vaultId, 'protocol.vaultId');
    }
    final runId = _uuid.v4();
    await _database.startSyncRun(
      runId: runId,
      profileId: profileId,
      startedAt: _now(),
    );
    try {
      final access = await dataset.checkAccess();
      if (access != DatasetAccessState.available) {
        throw SyncDatasetAccessException(access);
      }
      await preflight?.call();
      await _protocolBootstrapper.ensure(remote: remote, expected: protocol);
      await postProtocolPreflight?.call();
      CheckpointRecoveryResult? checkpointRecovery;
      if (dataset
          case final CheckpointRecoveringDatasetAdapter checkpointDataset) {
        checkpointRecovery = await _checkpointRecovery.recoverLatest(
          vaultId: vaultId,
          dataset: checkpointDataset,
          remote: remote,
        );
        if (checkpointRecovery.didRestoreCursor) {
          await _database.advanceAppliedSequencesFromCheckpoint(
            profileId: profileId,
            coveredSequences: checkpointRecovery.coveredSequences,
          );
        }
      }
      if (maxUploadBatches < 1) {
        throw ArgumentError.value(maxUploadBatches, 'maxUploadBatches');
      }
      var publishedBatchCount = 0;
      var uploadedBlobCount = 0;
      String? lastBatchId;
      while (publishedBatchCount < maxUploadBatches) {
        final next = await _uploadEngine.publishNext(
          profileId: profileId,
          dataset: dataset,
          remote: remote,
          cursor: cursor,
          limits: uploadLimits,
        );
        if (!next.didPublish) break;
        publishedBatchCount += next.publishedBatchCount;
        uploadedBlobCount += next.uploadedBlobCount;
        lastBatchId = next.batchId;
      }
      final upload = publishedBatchCount == 0
          ? const UploadRunResult.idle()
          : UploadRunResult.summary(
              batchId: lastBatchId,
              uploadedBlobCount: uploadedBlobCount,
              publishedBatchCount: publishedBatchCount,
            );
      final trustedProducerIds =
          trustedProducerDeviceIds ??
          (await _database.readTrustedDevicePublicKeys(vaultId: vaultId)).keys;
      final download = await _downloadEngine.importAvailable(
        profileId: profileId,
        vaultId: vaultId,
        consumerDeviceId: deviceId,
        trustedProducerDeviceIds: trustedProducerIds,
        dataset: dataset,
        remote: remote,
        limits: downloadLimits,
      );
      await _database.finishSyncRun(
        runId: runId,
        state: 'completed',
        completedAt: _now(),
      );
      return SyncProfileRunResult(
        runId: runId,
        upload: upload,
        download: download,
        checkpointRecovery: checkpointRecovery,
      );
    } on Object catch (error) {
      final failure = SyncFailureClassifier.classify(error);
      await _database.finishSyncRun(
        runId: runId,
        state: 'failed',
        completedAt: _now(),
        failure: failure,
      );
      rethrow;
    }
  }
}
