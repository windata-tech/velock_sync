import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/engine/sync_download_engine.dart';
import 'package:velock_sync/sync_core/engine/sync_checkpoint_recovery.dart';
import 'package:velock_sync/sync_core/engine/sync_checkpoint_publisher.dart';
import 'package:velock_sync/sync_core/engine/sync_upload_engine.dart';
import 'package:velock_sync/sync_core/engine/garbage_collection_evidence_builder.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/engine/remote_retention_manifest_service.dart';
import 'package:velock_sync/sync_core/engine/sync_garbage_collector.dart';
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
    this.garbageCollection,
  });

  final String runId;
  final UploadRunResult upload;
  final DownloadRunResult download;
  final CheckpointRecoveryResult? checkpointRecovery;
  final GarbageCollectionResult? garbageCollection;

  bool get didTransfer => upload.didPublish || download.importedBatchCount > 0;
}

/// The application-facing V1 run sequence. It keeps trust local: remote member
/// descriptions never enter the download allow-list without a local record.
class SyncProfileRunner {
  SyncProfileRunner(
    this._database, {
    SyncUploadEngine? uploadEngine,
    SyncDownloadEngine? downloadEngine,
    SyncCheckpointRecovery? checkpointRecovery,
    SyncGarbageCollector? garbageCollector,
    GarbageCollectionEvidenceBuilder? garbageCollectionEvidenceBuilder,
    VaultProtocolBootstrapper? protocolBootstrapper,
    Uuid? uuid,
    DateTime Function()? now,
  }) : _uploadEngine = uploadEngine ?? SyncUploadEngine(_database),
       _downloadEngine = downloadEngine ?? SyncDownloadEngine(_database),
       _checkpointRecovery =
           checkpointRecovery ?? const SyncCheckpointRecovery(),
       _garbageCollector = garbageCollector ?? SyncGarbageCollector(),
       _garbageCollectionEvidenceBuilder =
           garbageCollectionEvidenceBuilder ??
           const GarbageCollectionEvidenceBuilder(),
       _protocolBootstrapper =
           protocolBootstrapper ?? VaultProtocolBootstrapper(),
       _uuid = uuid ?? const Uuid(),
       _now = now ?? DateTime.now;

  final SyncStateDatabase _database;
  final SyncUploadEngine _uploadEngine;
  final SyncDownloadEngine _downloadEngine;
  final SyncCheckpointRecovery _checkpointRecovery;
  final SyncGarbageCollector _garbageCollector;
  final GarbageCollectionEvidenceBuilder _garbageCollectionEvidenceBuilder;
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
    bool enableGarbageCollection = false,

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
      await _publishCheckpoint(dataset: dataset, remote: remote);
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
      final garbageCollection = await _runGarbageCollection(
        enabled: enableGarbageCollection,
        profileId: profileId,
        vaultId: vaultId,
        dataset: dataset,
        remote: remote,
        checkpointRecovery: checkpointRecovery,
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
        garbageCollection: garbageCollection,
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

  Future<void> _publishCheckpoint({
    required SyncDatasetAdapter dataset,
    required RemoteObjectStore remote,
  }) async {
    final preparing = dataset is CheckpointPreparingDatasetAdapter
        ? dataset as CheckpointPreparingDatasetAdapter
        : null;
    if (preparing == null) return;
    try {
      final checkpoint = await preparing.prepareCheckpoint();
      if (checkpoint == null) return;
      await const SyncCheckpointPublisher().publish(
        checkpoint: checkpoint,
        remote: remote,
      );
    } on Object {
      // Checkpoint publication is a GC safety input, not business data. A
      // malformed or temporarily unavailable local checkpoint must not fail a
      // transfer; GC remains disabled until a later run publishes one.
    }
  }

  Future<GarbageCollectionResult?> _runGarbageCollection({
    required bool enabled,
    required String profileId,
    required String vaultId,
    required SyncDatasetAdapter dataset,
    required RemoteObjectStore remote,
    required CheckpointRecoveryResult? checkpointRecovery,
  }) async {
    if (!enabled) return null;
    final runId = _uuid.v4();
    try {
      await _database.startGarbageCollectionRun(
        runId: runId,
        profileId: profileId,
        vaultId: vaultId,
        startedAt: _now(),
      );
    } on Object {
      // Diagnostics must never block or fail a sync run.
      return null;
    }

    var checkpointId = checkpointRecovery?.checkpointId;
    DateTime? retentionCutoff;
    var activeDeviceCount = 0;
    var unackedDeviceCount = 0;
    var candidateCount = 0;
    var eligibleCandidateCount = 0;
    var deletedObjectCount = 0;
    bool? retentionManifestComplete;
    String? planId;
    var finished = false;

    Future<void> finish({required String state, String? skipReason}) async {
      if (finished) return;
      finished = true;
      try {
        await _database.finishGarbageCollectionRun(
          runId: runId,
          state: state,
          completedAt: _now(),
          checkpointId: checkpointId,
          retentionCutoff: retentionCutoff,
          activeDeviceCount: activeDeviceCount,
          unackedDeviceCount: unackedDeviceCount,
          candidateCount: candidateCount,
          eligibleCandidateCount: eligibleCandidateCount,
          deletedObjectCount: deletedObjectCount,
          retentionManifestComplete: retentionManifestComplete,
          planId: planId,
          skipReason: skipReason,
        );
        final event = state == 'completed'
            ? 'gc_completed'
            : state == 'skipped'
            ? 'gc_skipped'
            : 'gc_failed';
        debugPrint(
          'VELOCK_SYNC_EVENT {"event":"$event","candidates":$candidateCount,'
          '"eligible":$eligibleCandidateCount,"deleted":$deletedObjectCount,'
          '"unacked":$unackedDeviceCount,"reason":"${skipReason ?? 'none'}"}',
        );
      } on Object {
        // Diagnostics are best-effort.
      }
    }

    if (checkpointId == null) {
      await finish(state: 'skipped', skipReason: 'checkpoint-missing');
      return null;
    }
    if (dataset is! GarbageCollectionCandidateProvider) {
      await finish(state: 'skipped', skipReason: 'dataset-unsupported');
      return null;
    }

    try {
      final rawTrustedKeys = await _database.readTrustedDevicePublicKeys(
        vaultId: vaultId,
      );
      final trustedKeys = <String, PublicKey>{
        for (final entry in rawTrustedKeys.entries)
          entry.key: SimplePublicKey(entry.value, type: KeyPairType.ed25519),
      };
      activeDeviceCount = trustedKeys.length;
      if (trustedKeys.isEmpty) {
        await finish(state: 'skipped', skipReason: 'trusted-members-empty');
        return null;
      }
      final evidence = await _garbageCollectionEvidenceBuilder.build(
        vaultId: vaultId,
        checkpointId: checkpointId,
        checkpointCoveredSequences: checkpointRecovery!.coveredSequences,
        remote: remote,
        trustedDeviceKeys: trustedKeys,
      );
      retentionCutoff = evidence.tombstoneRetentionCutoff;
      activeDeviceCount = evidence.activeDeviceIds.length;
      final candidates = await (dataset as GarbageCollectionCandidateProvider)
          .garbageCollectionCandidates(
            vaultId: vaultId,
            evidence: evidence,
            trustedDeviceKeys: trustedKeys,
          );
      candidateCount = candidates.length;
      unackedDeviceCount = _countUnackedDevices(evidence, candidates);
      if (candidates.isEmpty) {
        retentionManifestComplete = null;
        await finish(state: 'skipped', skipReason: 'no-candidates');
        return null;
      }

      final validation = await _validateRetentionManifests(
        vaultId: vaultId,
        candidates: candidates,
        remote: remote,
        trustedDeviceKeys: trustedKeys,
      );
      retentionManifestComplete = validation.invalidCount == 0;
      if (validation.candidates.isEmpty) {
        await finish(
          state: 'skipped',
          skipReason: validation.invalidCount == candidates.length
              ? 'retention-manifest-invalid'
              : 'no-valid-retention-manifest',
        );
        return null;
      }

      final plan = _garbageCollector.plan(
        vaultId: vaultId,
        evidence: evidence,
        candidates: validation.candidates,
      );
      eligibleCandidateCount = plan.candidates.length;
      final result = await _garbageCollector.publishAndExecute(
        plan: plan,
        remote: remote,
        dryRun: false,
      );
      planId = result.plan.planId;
      deletedObjectCount = result.deletedObjectCount;
      await finish(state: 'completed');
      return result;
    } on Object {
      // GC is an optimization. Missing/invalid ACKs, manifests, members or
      // candidate evidence must block deletion, never fail a completed sync.
      await finish(state: 'failed', skipReason: 'gc-error');
      return null;
    }
  }

  Future<({List<GarbageCollectionCandidate> candidates, int invalidCount})>
  _validateRetentionManifests({
    required String vaultId,
    required List<GarbageCollectionCandidate> candidates,
    required RemoteObjectStore remote,
    required Map<String, PublicKey> trustedDeviceKeys,
  }) async {
    final validated = <GarbageCollectionCandidate>[];
    var invalidCount = 0;
    for (final candidate in candidates) {
      final manifestKey = candidate.retentionManifestKey;
      if (manifestKey == null) {
        validated.add(candidate);
        continue;
      }
      try {
        final key = trustedDeviceKeys[candidate.producerDeviceId];
        if (key == null) {
          invalidCount++;
          continue;
        }
        final prefix = '${LogicalKeys.vaultPrefix(vaultId)}retention/';
        if (!manifestKey.startsWith(prefix) || !manifestKey.endsWith('.json')) {
          invalidCount++;
          continue;
        }
        final trashBatchId = manifestKey.substring(
          prefix.length,
          manifestKey.length - '.json'.length,
        );
        if (LogicalKeys.retentionManifest(vaultId, trashBatchId) !=
            manifestKey) {
          invalidCount++;
          continue;
        }
        final manifest = await const RemoteRetentionManifestService().read(
          vaultId: vaultId,
          trashBatchId: trashBatchId,
          remote: remote,
          trustedSigningKey: key,
        );
        if (manifest == null ||
            manifest.producerDeviceId != candidate.producerDeviceId) {
          invalidCount++;
          continue;
        }
        final blobPrefix = '${LogicalKeys.vaultPrefix(vaultId)}blobs/';
        final candidateBlobIds = <String>{};
        for (final logicalKey in candidate.logicalKeys) {
          if (!logicalKey.startsWith(blobPrefix) ||
              !logicalKey.endsWith('.blob')) {
            continue;
          }
          final fileName = logicalKey.split('/').last;
          candidateBlobIds.add(
            fileName.substring(0, fileName.length - '.blob'.length),
          );
        }
        if (!manifest.blobRefs.toSet().containsAll(candidateBlobIds)) {
          invalidCount++;
          continue;
        }
        final holdUntil = candidate.retentionHoldUntil;
        validated.add(
          GarbageCollectionCandidate(
            candidateId: candidate.candidateId,
            logicalKeys: candidate.logicalKeys,
            producerDeviceId: candidate.producerDeviceId,
            sequence: candidate.sequence,
            tombstoneAt: candidate.tombstoneAt,
            isReferencedByActiveRevision:
                candidate.isReferencedByActiveRevision,
            isReferencedByCheckpoint: candidate.isReferencedByCheckpoint,
            retentionManifestKey: candidate.retentionManifestKey,
            isReferencedByRetentionHold: candidate.isReferencedByRetentionHold,
            retentionHoldUntil: holdUntil == null
                ? manifest.retainUntil
                : (holdUntil.isAfter(manifest.retainUntil)
                      ? holdUntil
                      : manifest.retainUntil),
          ),
        );
      } on Object {
        // Missing, malformed, unsigned or mismatched retention metadata must
        // skip that candidate, never delete its objects.
        invalidCount++;
      }
    }
    return (candidates: validated, invalidCount: invalidCount);
  }

  int _countUnackedDevices(
    GarbageCollectionEvidence evidence,
    Iterable<GarbageCollectionCandidate> candidates,
  ) {
    final requiredThrough = <String, int>{};
    for (final candidate in candidates) {
      final current = requiredThrough[candidate.producerDeviceId] ?? 0;
      if (candidate.sequence > current) {
        requiredThrough[candidate.producerDeviceId] = candidate.sequence;
      }
    }
    var unacked = 0;
    for (final consumer in evidence.activeDeviceIds) {
      final acknowledged = evidence.acknowledgedSequences[consumer] ?? const {};
      final missing = requiredThrough.entries.any(
        (entry) =>
            entry.key != consumer &&
            (acknowledged[entry.key] ?? 0) < entry.value,
      );
      if (missing) unacked++;
    }
    return unacked;
  }
}
