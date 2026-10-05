import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'package:velock_sync/infrastructure/database/sync_state_migrations.dart';
export 'package:velock_sync/infrastructure/database/sync_state_records.dart';
import 'package:velock_sync/infrastructure/database/sync_state_records.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

import 'package:velock_sync/infrastructure/database/sync_state_connections.dart';
import 'package:velock_sync/infrastructure/database/sync_state_profiles.dart';
import 'package:velock_sync/infrastructure/database/sync_state_runs.dart';
import 'package:velock_sync/infrastructure/database/sync_state_activity.dart';
import 'package:velock_sync/infrastructure/database/sync_state_transfers.dart';
import 'package:velock_sync/infrastructure/database/sync_state_locks.dart';
import 'package:velock_sync/infrastructure/database/sync_state_batches.dart';
import 'package:velock_sync/infrastructure/database/sync_state_folder_scan.dart';
import 'package:velock_sync/infrastructure/database/sync_state_mirror.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/mirror_models.dart';
import 'package:velock_sync/infrastructure/database/sync_state_conflicts.dart';
import 'package:velock_sync/infrastructure/database/sync_state_devices.dart';

/// Persistent state owned by the sync engine. Secrets deliberately never
/// enter this database: rows retain only secure-storage references.
///
/// This class is a thin facade over per-domain query modules
/// (`sync_state_*.dart`); every public method keeps its original signature
/// so callers are unaffected by the split.
class SyncStateDatabase {
  SyncStateDatabase._(
    this._database, {
    Object? executionScopeKey,
    String? processToken,
  }) : executionScopeKey = executionScopeKey ?? Object(),
       processToken = processToken ?? 'pid-$pid',
       _connections = ConnectionQueries(_database),
       _profiles = ProfileQueries(_database),
       _runs = RunQueries(_database),
       _transfers = TransferQueries(_database),
       _locks = LockQueries(
         _database,
         processToken: processToken ?? 'pid-$pid',
       ),
       _batches = BatchQueries(_database),
       _folderScan = FolderScanQueries(_database),
       _conflicts = ConflictQueries(_database),
       _devices = DeviceQueries(_database),
       _mirror = MirrorQueries(_database);
  static late SyncStateDatabase _instance;

  final Database _database;

  /// Same on-disk DB => same in-isolate dispatch scope. In-memory DBs stay
  /// isolated, even if tests or profiles happen to reuse the same IDs.
  final Object executionScopeKey;

  /// The process that owns this connection's locks (see [LockQueries]).
  /// Every isolate of one process shares it; tests inject one per "process".
  final String processToken;

  final ConnectionQueries _connections;
  final ProfileQueries _profiles;
  final RunQueries _runs;
  final TransferQueries _transfers;
  final LockQueries _locks;
  final BatchQueries _batches;
  final FolderScanQueries _folderScan;
  final ConflictQueries _conflicts;
  final DeviceQueries _devices;
  final MirrorQueries _mirror;

  static SyncStateDatabase get instance => _instance;

  static Future<void> initialize() async {
    final directory = await getApplicationSupportDirectory();
    final file = File(p.join(directory.path, 'velock-sync', 'state.db'));
    _instance = await open(file);
  }

  static Future<SyncStateDatabase> open(
    File file, {
    @visibleForTesting String? processToken,
  }) async {
    await file.parent.create(recursive: true);
    final database = sqlite3.open(file.path);
    final state = SyncStateDatabase._(
      database,
      executionScopeKey: p.normalize(file.absolute.path),
      processToken: processToken,
    );
    state._migrate();
    return state;
  }

  static Future<SyncStateDatabase> inMemory() async {
    final state = SyncStateDatabase._(sqlite3.openInMemory());
    state._migrate();
    return state;
  }

  Future<int> get schemaVersion async =>
      _database.select('PRAGMA user_version').single.values.single as int;

  Future<List<String>> readConnectionPayloads() async =>
      _connections.readConnectionPayloads();

  Future<void> replaceConnectionPayloads(Map<String, String> payloads) async =>
      _connections.replaceConnectionPayloads(payloads);

  Future<bool> replaceSyncProfilePayloadIfCurrent({
    BackupRebuildCompletion? rebuild,
    required String profileId,
    required String expectedPayload,
    required String datasetId,
    required String targetId,
    required String vaultId,
    required String state,
    required String payload,
  }) => _profiles.replaceSyncProfilePayloadIfCurrent(
    rebuild: rebuild,
    profileId: profileId,
    expectedPayload: expectedPayload,
    datasetId: datasetId,
    targetId: targetId,
    vaultId: vaultId,
    state: state,
    payload: payload,
  );

  Future<bool> retireSyncProfileAndInsertReplacement({
    required String retiredProfileId,
    required String expectedRetiredPayload,
    required String profileId,
    required String datasetId,
    required String targetId,
    required String vaultId,
    required String state,
    required String payload,
  }) => _profiles.retireSyncProfileAndInsertReplacement(
    retiredProfileId: retiredProfileId,
    expectedRetiredPayload: expectedRetiredPayload,
    profileId: profileId,
    datasetId: datasetId,
    targetId: targetId,
    vaultId: vaultId,
    state: state,
    payload: payload,
  );

  Future<void> upsertSyncProfilePayload({
    required String profileId,
    required String datasetId,
    required String targetId,
    required String vaultId,
    required String state,
    required String payload,
  }) async => _profiles.upsertSyncProfilePayload(
    profileId: profileId,
    datasetId: datasetId,
    targetId: targetId,
    vaultId: vaultId,
    state: state,
    payload: payload,
  );

  /// Atomically consumes a hash of a pairing challenge.
  ///
  /// Only a SHA-256 digest is persisted; the original challenge never enters
  /// the database, profile JSON, preferences, or logs. A duplicate digest is
  /// a replay and is rejected before the caller sends a pairing request.
  Future<bool> consumeVelockPairingChallenge({
    required String challengeDigest,
    required DateTime consumedAt,
  }) async => _profiles.consumeVelockPairingChallenge(
    challengeDigest: challengeDigest,
    consumedAt: consumedAt,
  );

  Future<String?> readSyncProfilePayload(String profileId) async =>
      _profiles.readSyncProfilePayload(profileId);

  /// Returns every locally visible profile. Removed profiles retain their
  /// durable history but can no longer be reconstructed or scheduled.
  Future<List<SyncProfilePayloadRecord>>
  readVisibleSyncProfilePayloads() async =>
      _profiles.readVisibleSyncProfilePayloads();

  Future<SyncProfilePayloadRecord?> readVisibleSyncProfilePayload(
    String profileId,
  ) async => _profiles.readVisibleSyncProfilePayload(profileId);

  Future<void> setSyncProfileState({
    required String profileId,
    required String state,
  }) async => _profiles.setSyncProfileState(profileId: profileId, state: state);

  Future<List<String>> readActiveSyncProfilePayloads() async =>
      _profiles.readActiveSyncProfilePayloads();

  Future<bool> hasSyncRun(String runId) async => _database.select(
    'SELECT 1 FROM sync_runs WHERE run_id = ? LIMIT 1',
    [runId],
  ).isNotEmpty;

  Future<void> startSyncRun({
    required String runId,
    required String profileId,
    required DateTime startedAt,
  }) async => _runs.startSyncRun(
    runId: runId,
    profileId: profileId,
    startedAt: startedAt,
  );

  Future<void> finishSyncRun({
    required String runId,
    required String state,
    required DateTime completedAt,
    String? errorCode,
    SyncFailure? failure,
  }) async => _runs.finishSyncRun(
    runId: runId,
    state: state,
    completedAt: completedAt,
    errorCode: errorCode,
    failure: failure,
  );

  Future<void> startGarbageCollectionRun({
    required String runId,
    required String profileId,
    required String vaultId,
    required DateTime startedAt,
  }) async => _runs.startGarbageCollectionRun(
    runId: runId,
    profileId: profileId,
    vaultId: vaultId,
    startedAt: startedAt,
  );

  Future<void> finishGarbageCollectionRun({
    required String runId,
    required String state,
    required DateTime completedAt,
    String? checkpointId,
    DateTime? retentionCutoff,
    int activeDeviceCount = 0,
    int unackedDeviceCount = 0,
    int candidateCount = 0,
    int eligibleCandidateCount = 0,
    int deletedObjectCount = 0,
    bool? retentionManifestComplete,
    String? planId,
    String? skipReason,
  }) async => _runs.finishGarbageCollectionRun(
    runId: runId,
    state: state,
    completedAt: completedAt,
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

  Future<GarbageCollectionDiagnostics?>
  latestGarbageCollectionDiagnostics() async =>
      _runs.latestGarbageCollectionDiagnostics();

  Future<SyncRunRecord?> latestSyncRun(String profileId) async =>
      _runs.latestSyncRun(profileId);

  /// Whether [profileId] already has backup history in its current folder:
  /// a batch it published there, or one it downloaded and applied. Such a
  /// backup cannot simply be pointed at an empty folder; the history check
  /// would then fail on every run.
  Future<bool> hasExchangedHistory(String profileId) async {
    final rows = _database.select(
      'SELECT EXISTS(SELECT 1 FROM outgoing_batches '
      'WHERE profile_id = ? AND published_at IS NOT NULL) '
      'OR EXISTS(SELECT 1 FROM sync_cursors '
      'WHERE profile_id = ? AND applied_sequence > 0) AS present',
      [profileId, profileId],
    );
    return rows.first['present'] == 1;
  }

  Future<bool> hasRunningSyncRun(String profileId) async =>
      _runs.hasRunningSyncRun(profileId);

  /// Closes runs that were interrupted by process termination before their
  /// normal completion callback ran. This is used only for an explicit local
  /// profile removal, so a removed profile cannot leave a permanent "running"
  /// record that blocks future cleanup.
  /// Closes runs and frees locks left by a process that is no longer alive.
  /// Runs of this process (any isolate) are untouched, so it is safe to call
  /// on startup, on a foreground resume and from a background task.
  Future<int> failInterruptedSyncRuns({
    String errorCode = 'sync.interrupted',
  }) => _runs.failInterruptedSyncRuns(
    liveOwnerPrefix: '$processToken$lockOwnerProcessSeparator',
    errorCode: errorCode,
  );

  Future<int> failRunningSyncRunsForProfile({
    required String profileId,
    required String errorCode,
    DateTime? completedAt,
  }) async => _runs.failRunningSyncRunsForProfile(
    profileId: profileId,
    errorCode: errorCode,
    completedAt: completedAt,
  );

  Future<List<SyncRunRecord>> listRecentSyncRuns({
    String? profileId,
    int limit = 50,
  }) async => _runs.listRecentSyncRuns(profileId: profileId, limit: limit);

  /// A privacy-safe status projection for the profile list. It intentionally
  /// contains counts and normalized run state only: neither paths, filenames,
  /// credentials, nor provider response bodies are queried for UI display.
  Future<SyncProfileActivitySummary> readSyncProfileActivity(
    String profileId,
  ) async => ActivityQueries(
    _database,
    _runs.latestSyncRun,
  ).readSyncProfileActivity(profileId);

  /// Privacy-safe inventory of what this profile has already moved.
  ///
  /// Only aggregate counts, sizes and opaque device ids leave this method —
  /// logical keys and provider paths never reach the UI.
  Future<SyncedDataSnapshot> readSyncedDataSnapshot(String profileId) async =>
      ActivityQueries(
        _database,
        _runs.latestSyncRun,
      ).readSyncedDataSnapshot(profileId);

  /// Starts or resumes one durable, provider-neutral object transfer. The
  /// logical key is opaque protocol metadata; credentials and provider payloads
  /// never enter this table.
  Future<void> beginTransferJob({
    required String transferId,
    required String profileId,
    required TransferJobDirection direction,
    required String logicalKey,
    int? expectedSize,
    String? expectedHash,
    String? providerCheckpoint,
  }) async => _transfers.beginTransferJob(
    transferId: transferId,
    profileId: profileId,
    direction: direction,
    logicalKey: logicalKey,
    expectedSize: expectedSize,
    expectedHash: expectedHash,
    providerCheckpoint: providerCheckpoint,
  );

  Future<void> updateTransferProgress({
    required String transferId,
    required int completedBytes,
    String? providerCheckpoint,
  }) async => _transfers.updateTransferProgress(
    transferId: transferId,
    completedBytes: completedBytes,
    providerCheckpoint: providerCheckpoint,
  );

  Future<void> completeTransferJob({
    required String transferId,
    required int completedBytes,
  }) async => _transfers.completeTransferJob(
    transferId: transferId,
    completedBytes: completedBytes,
  );

  Future<void> failTransferJob({
    required String transferId,
    required String errorCode,
  }) async =>
      _transfers.failTransferJob(transferId: transferId, errorCode: errorCode);

  /// Completed (or failed) transfers in reverse chronological order.
  ///
  /// Powers the itemised "what moved, and when" lists; logical keys stay
  /// opaque and are only mapped to a coarse content category by the caller.
  Future<List<TransferJobRecord>> listTransferHistory({
    required String profileId,
    DateTime? from,
    DateTime? to,
    int limit = 50,
  }) async => _transfers.listTransferHistory(
    profileId: profileId,
    from: from,
    to: to,
    limit: limit,
  );

  Future<int> transferredBytesSince({
    required String profileId,
    required DateTime since,
    required TransferJobDirection direction,
  }) async => _transfers.transferredBytesSince(
    profileId: profileId,
    since: since,
    direction: direction,
  );

  Future<List<TransferJobRecord>> listTransferJobs({
    String? profileId,
    bool includeCompleted = false,
    int limit = 50,
  }) async => _transfers.listTransferJobs(
    profileId: profileId,
    includeCompleted: includeCompleted,
    limit: limit,
  );

  /// Acquires the persistent, recoverable lock required for a single active
  /// run per sync profile. A stale lock may be claimed by a new owner.
  Future<bool> tryAcquireProfileLock({
    required String profileId,
    required String owner,
    required DateTime now,
    required Duration staleAfter,
  }) async => _locks.tryAcquireProfileLock(
    profileId: profileId,
    owner: owner,
    now: now,
    staleAfter: staleAfter,
  );

  Future<bool> heartbeatProfileLock({
    required String profileId,
    required String owner,
    required DateTime now,
  }) async =>
      _locks.heartbeatProfileLock(profileId: profileId, owner: owner, now: now);

  Future<void> releaseProfileLock({
    required String profileId,
    required String owner,
  }) async => _locks.releaseProfileLock(profileId: profileId, owner: owner);

  Future<void> recordOutgoingBatch({
    required String profileId,
    required String batchId,
    required int sequence,
    required String state,
  }) async => _batches.recordOutgoingBatch(
    profileId: profileId,
    batchId: batchId,
    sequence: sequence,
    state: state,
  );

  Future<void> markOutgoingBatchPublished({
    required String profileId,
    required String batchId,
    required DateTime publishedAt,
  }) async => _batches.markOutgoingBatchPublished(
    profileId: profileId,
    batchId: batchId,
    publishedAt: publishedAt,
  );

  /// Reserves one producer sequence durably. If a prior run crashed before its
  /// commit was acknowledged, that same reservation is returned so callers
  /// reuse the exact batch identity and staged ciphertext.
  Future<OutgoingBatchReservation> reserveOutgoingSequence({
    required String profileId,
    required String sourceDeviceId,
    required String newBatchId,
  }) async => _batches.reserveOutgoingSequence(
    profileId: profileId,
    sourceDeviceId: sourceDeviceId,
    newBatchId: newBatchId,
  );

  Future<void> markOutgoingSequencePublished({
    required String profileId,
    required String sourceDeviceId,
    required int sequence,
    required String batchId,
  }) async => _batches.markOutgoingSequencePublished(
    profileId: profileId,
    sourceDeviceId: sourceDeviceId,
    sequence: sequence,
    batchId: batchId,
  );

  /// Releases a reservation that never produced a staged batch. A caller must
  /// provide the exact reservation identity so a different active run cannot
  /// accidentally skip a producer sequence.
  Future<void> cancelOutgoingSequenceReservation({
    required String profileId,
    required String sourceDeviceId,
    required int sequence,
    required String batchId,
  }) async => _batches.cancelOutgoingSequenceReservation(
    profileId: profileId,
    sourceDeviceId: sourceDeviceId,
    sequence: sequence,
    batchId: batchId,
  );

  /// Returns the immediate predecessor needed to bind the next signed batch
  /// into this producer's append-only chain.
  Future<PublishedOutgoingBatchReference?> latestPublishedOutgoingBatch({
    required String profileId,
    required String sourceDeviceId,
  }) async => _batches.latestPublishedOutgoingBatch(
    profileId: profileId,
    sourceDeviceId: sourceDeviceId,
  );

  Future<int> appliedSequence({
    required String profileId,
    required String producerDeviceId,
  }) async => _batches.appliedSequence(
    profileId: profileId,
    producerDeviceId: producerDeviceId,
  );

  Future<void> recordIncomingBatch({
    required String profileId,
    required String sourceDeviceId,
    required int sequence,
    required String batchId,
    required String state,
  }) async => _batches.recordIncomingBatch(
    profileId: profileId,
    sourceDeviceId: sourceDeviceId,
    sequence: sequence,
    batchId: batchId,
    state: state,
  );

  Future<String?> incomingBatchState({
    required String profileId,
    required String sourceDeviceId,
    required int sequence,
    required String batchId,
  }) async => _batches.incomingBatchState(
    profileId: profileId,
    sourceDeviceId: sourceDeviceId,
    sequence: sequence,
    batchId: batchId,
  );

  /// The first durable receipt time is used in the signed ACK so retries emit
  /// byte-identical immutable artifacts rather than competing replacements.
  Future<DateTime?> incomingBatchReceivedAt({
    required String profileId,
    required String sourceDeviceId,
    required int sequence,
    required String batchId,
  }) async => _batches.incomingBatchReceivedAt(
    profileId: profileId,
    sourceDeviceId: sourceDeviceId,
    sequence: sequence,
    batchId: batchId,
  );

  Future<void> advanceAppliedSequence({
    required String profileId,
    required String producerDeviceId,
    required int sequence,
  }) async => _batches.advanceAppliedSequence(
    profileId: profileId,
    producerDeviceId: producerDeviceId,
    sequence: sequence,
  );

  /// Seeds contiguous-download cursors after a trusted checkpoint has been
  /// durably applied. Unlike individual batch import, a checkpoint may safely
  /// jump from any older cursor to its authenticated covered sequence.
  Future<void> advanceAppliedSequencesFromCheckpoint({
    required String profileId,
    required Map<String, int> coveredSequences,
  }) async => _batches.advanceAppliedSequencesFromCheckpoint(
    profileId: profileId,
    coveredSequences: coveredSequences,
  );

  /// Starts a new complete-scan attempt. Entries are only tombstoned by the
  /// caller after enumeration has completed without an error.
  Future<int> beginFolderScan({required String datasetId}) async =>
      _folderScan.beginFolderScan(datasetId: datasetId);

  Future<List<FolderScanEntry>> readFolderScanEntries({
    required String datasetId,
    bool includeDeleted = false,
  }) async => _folderScan.readFolderScanEntries(
    datasetId: datasetId,
    includeDeleted: includeDeleted,
  );

  Future<void> upsertFolderScanEntries({
    required String datasetId,
    required Iterable<FolderScanEntry> entries,
  }) async => _folderScan.upsertFolderScanEntries(
    datasetId: datasetId,
    entries: entries,
  );

  /// Marks only entries absent from a successfully completed generation as
  /// tombstones. The returned entries are the source for delete operations.
  Future<List<FolderScanEntry>> markMissingFolderEntriesDeleted({
    required String datasetId,
    required int completedGeneration,
    required DateTime deletedAt,
  }) async => _folderScan.markMissingFolderEntriesDeleted(
    datasetId: datasetId,
    completedGeneration: completedGeneration,
    deletedAt: deletedAt,
  );

  Future<List<FolderScanEntry>> readPendingFolderScanEntries({
    required String datasetId,
  }) async => _folderScan.readPendingFolderScanEntries(datasetId: datasetId);

  /// Acknowledging a batch clears only changes observed no later than its
  /// completed scan, preserving modifications that happened while it uploaded.
  Future<void> clearFolderPendingChangesThrough({
    required String datasetId,
    required int generation,
  }) async => _folderScan.clearFolderPendingChangesThrough(
    datasetId: datasetId,
    generation: generation,
  );

  /// Clears only the entries whose exact revisions were committed. A scan can
  /// contain more than one outgoing batch, so clearing a whole generation here
  /// would silently lose later changes after the first batch publishes.
  Future<void> clearFolderPendingChanges({
    required String datasetId,
    required Iterable<String> entityIds,
    required int generation,
  }) async => _folderScan.clearFolderPendingChanges(
    datasetId: datasetId,
    entityIds: entityIds,
    generation: generation,
  );

  Future<void> markFolderEntryImportedDeleted({
    required String datasetId,
    required String entityId,
    required DateTime deletedAt,
  }) async => _folderScan.markFolderEntryImportedDeleted(
    datasetId: datasetId,
    entityId: entityId,
    deletedAt: deletedAt,
  );

  Future<FolderEntitySyncState?> readFolderEntitySyncState({
    required String datasetId,
    required String entityId,
  }) async => _folderScan.readFolderEntitySyncState(
    datasetId: datasetId,
    entityId: entityId,
  );

  Future<bool> isFolderOperationApplied({
    required String datasetId,
    required String operationId,
  }) async => _folderScan.isFolderOperationApplied(
    datasetId: datasetId,
    operationId: operationId,
  );

  Future<void> recordFolderOperationApplied({
    required String datasetId,
    required String operationId,
    required String entityId,
    required String batchId,
  }) async => _folderScan.recordFolderOperationApplied(
    datasetId: datasetId,
    operationId: operationId,
    entityId: entityId,
    batchId: batchId,
  );

  Future<void> upsertFolderEntitySyncState({
    required String datasetId,
    required String entityId,
    required String revisionId,
    required VersionVector versionVector,
    required bool isTombstone,
  }) async => _folderScan.upsertFolderEntitySyncState(
    datasetId: datasetId,
    entityId: entityId,
    revisionId: revisionId,
    versionVector: versionVector,
    isTombstone: isTombstone,
  );

  /// Durably queues a conflict resolution for the normal
  /// scanner/batch pipeline. The stored vector is the component-wise merge of
  /// both conflicting revisions; the batch preparer will increment the local
  /// device component when it creates the resolution operation.
  ///
  /// This transaction deliberately does not mark the conflict resolved. The
  /// caller must run the normal Sync Core path and verify the published entity
  /// revision before completing the conflict-resolution intent.
  Future<void> queueFolderConflictResolution({
    required String datasetId,
    required String entityId,
    required String relativePath,
    required String expectedRevisionId,
    required VersionVector expectedVersionVector,
    required VersionVector mergedBaseVersionVector,
    required bool resolutionIsTombstone,
  }) async => _folderScan.queueFolderConflictResolution(
    datasetId: datasetId,
    entityId: entityId,
    relativePath: relativePath,
    expectedRevisionId: expectedRevisionId,
    expectedVersionVector: expectedVersionVector,
    mergedBaseVersionVector: mergedBaseVersionVector,
    resolutionIsTombstone: resolutionIsTombstone,
  );

  /// Removes a scanner row created only for an incoming conflict copy that was
  /// discarded before it ever acquired synchronised entity state. This avoids
  /// publishing a meaningless tombstone for a local-only temporary identity.
  Future<void> discardUnpublishedFolderScanEntry({
    required String datasetId,
    required String relativePath,
  }) async => _folderScan.discardUnpublishedFolderScanEntry(
    datasetId: datasetId,
    relativePath: relativePath,
  );

  Future<void> recordFolderConflict({
    required String conflictId,
    required String profileId,
    required String entityId,
    required String sourceDeviceId,
    required String localRevisionId,
    required String incomingRevisionId,
    required String type,
    String? protectedDetails,
  }) async => _conflicts.recordFolderConflict(
    conflictId: conflictId,
    profileId: profileId,
    entityId: entityId,
    sourceDeviceId: sourceDeviceId,
    localRevisionId: localRevisionId,
    incomingRevisionId: incomingRevisionId,
    type: type,
    protectedDetails: protectedDetails,
  );

  Future<SyncConflictRecord?> readUnresolvedConflict(String conflictId) async =>
      _conflicts.readUnresolvedConflict(conflictId);

  Future<List<SyncConflictRecord>> listUnresolvedConflicts({
    String? profileId,
  }) async => _conflicts.listUnresolvedConflicts(profileId: profileId);

  Future<ConflictResolutionIntentAcquisition> acquireConflictResolutionIntent({
    required String conflictId,
    required String strategy,
    required String owner,
    required DateTime now,
    required Duration lease,
  }) async => _conflicts.acquireConflictResolutionIntent(
    conflictId: conflictId,
    strategy: strategy,
    owner: owner,
    now: now,
    lease: lease,
  );

  Future<void> completeConflictResolution({
    required String conflictId,
    required String owner,
    String? completionArtifact,
  }) async => _conflicts.completeConflictResolution(
    conflictId: conflictId,
    owner: owner,
    completionArtifact: completionArtifact,
  );

  Future<void> failConflictResolutionIntent({
    required String conflictId,
    required String owner,
    required String errorCode,
  }) async => _conflicts.failConflictResolutionIntent(
    conflictId: conflictId,
    owner: owner,
    errorCode: errorCode,
  );

  Future<ConflictResolutionIntentRecord?> readConflictResolutionIntent(
    String conflictId,
  ) async => _conflicts.readConflictResolutionIntent(conflictId);

  /// Kept for legacy internal callers only. UI and domain code must use
  /// [completeConflictResolution] after a durable resolution action.
  Future<void> markConflictResolved(String conflictId) async =>
      _conflicts.markConflictResolved(conflictId);

  /// Records a device only after an explicit local pairing/approval flow. This
  /// API intentionally never reads a remote member object or auto-enrolls it.
  Future<void> trustDevice({
    required String vaultId,
    required String deviceId,
    required Uint8List signingPublicKey,
  }) async => _devices.trustDevice(
    vaultId: vaultId,
    deviceId: deviceId,
    signingPublicKey: signingPublicKey,
  );

  Future<void> revokeTrustedDevice({
    required String vaultId,
    required String deviceId,
  }) async =>
      _devices.revokeTrustedDevice(vaultId: vaultId, deviceId: deviceId);

  Future<Map<String, Uint8List>> readTrustedDevicePublicKeys({
    required String vaultId,
  }) async => _devices.readTrustedDevicePublicKeys(vaultId: vaultId);

  Future<void> close() async => _database.close();

  // --- Plain folder mirror (unencrypted) state -----------------------------

  Future<Map<String, MirrorBaselineEntry>> readMirrorEntries(
    String profileId,
  ) async => _mirror.readMirrorEntries(profileId);

  Future<void> upsertMirrorEntries(
    String profileId,
    Iterable<MirrorBaselineEntry> entries,
  ) async => _mirror.upsertMirrorEntries(profileId, entries);

  Future<void> deleteMirrorEntries(
    String profileId,
    Iterable<String> relativePaths,
  ) async => _mirror.deleteMirrorEntries(profileId, relativePaths);

  Future<void> clearMirrorEntries(String profileId) async =>
      _mirror.clearMirrorEntries(profileId);

  /// Saves a relocated plain folder location and drops the mirror state of the
  /// old binding in one transaction.
  Future<void> relocateMirrorProfile({
    required String profileId,
    required String datasetId,
    required String targetId,
    required String state,
    required String payload,
    bool resetBaseline = true,
  }) async => _mirror.relocateMirrorProfile(
    profileId: profileId,
    datasetId: datasetId,
    targetId: targetId,
    state: state,
    payload: payload,
    resetBaseline: resetBaseline,
  );

  Future<void> recordMirrorConflicts(
    String profileId,
    Iterable<MirrorPlannedConflict> conflicts, {
    DateTime? detectedAt,
  }) async => _mirror.recordMirrorConflicts(
    profileId,
    conflicts,
    detectedAt ?? DateTime.now().toUtc(),
  );

  Future<List<MirrorConflictRecord>> readMirrorConflicts(
    String profileId, {
    int limit = 50,
  }) async => _mirror.readMirrorConflicts(profileId, limit: limit);

  Future<int> countMirrorConflicts(String profileId) async =>
      _mirror.countMirrorConflicts(profileId);

  Future<void> clearMirrorConflicts(
    String profileId, {
    required DateTime through,
  }) async => _mirror.clearMirrorConflicts(profileId, through: through);

  /// Keeps the informational conflict log bounded for a long-lived location.
  Future<void> trimMirrorConflicts(String profileId, {int keep = 200}) async =>
      _mirror.trimMirrorConflicts(profileId, keep: keep);

  Future<void> saveMirrorRunStats(MirrorRunStats stats) async =>
      _mirror.saveMirrorRunStats(stats);

  Future<MirrorRunStats?> readLatestMirrorRunStats(String profileId) async =>
      _mirror.readLatestMirrorRunStats(profileId);

  void _migrate() => migrateSyncStateSchema(_database, kSyncStateSchemaVersion);
}
