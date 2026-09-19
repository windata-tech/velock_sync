/// Record types returned by the sync state database.
///
/// Plain data holders shared by the query modules and the rest of the app.
/// They contain no credentials: paths stay opaque and secret-bearing columns
/// are secure-storage references.
library;

import 'package:velock_sync/sync_core/model/sync_models.dart';

class OutgoingBatchReservation {
  const OutgoingBatchReservation({
    required this.sequence,
    required this.batchId,
    required this.isRecovered,
  });

  final int sequence;
  final String batchId;
  final bool isRecovered;
}

class PublishedOutgoingBatchReference {
  const PublishedOutgoingBatchReference({
    required this.batchId,
    required this.sequence,
  });

  final String batchId;
  final int sequence;
}

class SyncRunRecord {
  const SyncRunRecord({
    required this.runId,
    required this.profileId,
    required this.state,
    required this.startedAt,
    required this.completedAt,
    required this.errorCode,
    required this.errorCategory,
    required this.retryable,
    required this.retryAfter,
    required this.suggestedAction,
    required this.providerStatusCode,
  });

  final String runId;
  final String profileId;
  final String state;
  final DateTime startedAt;
  final DateTime? completedAt;
  final String? errorCode;
  final String? errorCategory;
  final bool? retryable;
  final Duration? retryAfter;
  final String? suggestedAction;
  final int? providerStatusCode;
}

class GarbageCollectionDiagnostics {
  const GarbageCollectionDiagnostics({
    required this.runId,
    required this.profileId,
    required this.vaultId,
    required this.state,
    required this.startedAt,
    required this.completedAt,
    required this.checkpointId,
    required this.retentionCutoff,
    required this.activeDeviceCount,
    required this.unackedDeviceCount,
    required this.candidateCount,
    required this.eligibleCandidateCount,
    required this.deletedObjectCount,
    required this.retentionManifestComplete,
    required this.planId,
    required this.skipReason,
  });

  final String runId;
  final String profileId;
  final String vaultId;
  final String state;
  final DateTime startedAt;
  final DateTime? completedAt;
  final String? checkpointId;
  final DateTime? retentionCutoff;
  final int activeDeviceCount;
  final int unackedDeviceCount;
  final int candidateCount;
  final int eligibleCandidateCount;
  final int deletedObjectCount;
  final bool? retentionManifestComplete;
  final String? planId;
  final String? skipReason;
}

class SyncProfileActivitySummary {
  const SyncProfileActivitySummary({
    required this.latestRun,
    required this.pendingUploadCount,
    required this.pendingDownloadCount,
    required this.transferredBytes,
    required this.unresolvedConflictCount,
  });

  final SyncRunRecord? latestRun;
  final int pendingUploadCount;
  final int pendingDownloadCount;
  final int transferredBytes;
  final int unresolvedConflictCount;
}

class SyncProfilePayloadRecord {
  const SyncProfilePayloadRecord({
    required this.profileId,
    required this.state,
    required this.payload,
  });

  final String profileId;
  final String state;
  final String payload;
}

enum TransferJobDirection { upload, download }

enum TransferJobState {
  queued,
  running,
  paused,
  retryWaiting,
  completed,
  failed,
  cancelled,
}

class TransferJobRecord {
  const TransferJobRecord({
    required this.transferId,
    required this.profileId,
    required this.direction,
    required this.state,
    required this.logicalKey,
    required this.expectedSize,
    required this.completedBytes,
    required this.expectedHash,
    required this.retryCount,
    required this.nextRetryAt,
    required this.providerCheckpoint,
    required this.errorCode,
    this.createdAt,
    this.completedAt,
  });

  final String transferId;
  final String profileId;
  final TransferJobDirection direction;
  final TransferJobState state;
  final String logicalKey;
  final int? expectedSize;
  final int completedBytes;
  final String? expectedHash;
  final int retryCount;
  final DateTime? nextRetryAt;
  final String? providerCheckpoint;
  final String? errorCode;
  final DateTime? createdAt;
  final DateTime? completedAt;
}

class SyncConflictRecord {
  const SyncConflictRecord({
    required this.conflictId,
    required this.profileId,
    required this.entityId,
    required this.sourceDeviceId,
    required this.type,
    required this.protectedDetails,
    required this.createdAt,
  });

  final String conflictId;
  final String profileId;
  final String entityId;
  final String? sourceDeviceId;
  final String type;

  /// Local-only metadata for a dataset resolver. UI must never render it.
  final String? protectedDetails;
  final DateTime createdAt;
}

enum ConflictResolutionIntentState { running, retryable, completed }

class ConflictResolutionIntentAcquisition {
  const ConflictResolutionIntentAcquisition._(this.status);

  const ConflictResolutionIntentAcquisition.acquired()
    : this._(ConflictResolutionIntentAcquisitionStatus.acquired);
  const ConflictResolutionIntentAcquisition.completed()
    : this._(ConflictResolutionIntentAcquisitionStatus.completed);
  const ConflictResolutionIntentAcquisition.inProgress()
    : this._(ConflictResolutionIntentAcquisitionStatus.inProgress);
  const ConflictResolutionIntentAcquisition.strategyMismatch()
    : this._(ConflictResolutionIntentAcquisitionStatus.strategyMismatch);
  const ConflictResolutionIntentAcquisition.missing()
    : this._(ConflictResolutionIntentAcquisitionStatus.missing);

  final ConflictResolutionIntentAcquisitionStatus status;
}

enum ConflictResolutionIntentAcquisitionStatus {
  acquired,
  completed,
  inProgress,
  strategyMismatch,
  missing,
}

class ConflictResolutionIntentRecord {
  const ConflictResolutionIntentRecord({
    required this.conflictId,
    required this.strategy,
    required this.state,
    required this.createdAt,
    required this.updatedAt,
    required this.leaseOwner,
    required this.leaseExpiresAt,
    required this.errorCode,
    required this.receiptArtifact,
  });

  final String conflictId;
  final String strategy;
  final ConflictResolutionIntentState state;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? leaseOwner;
  final DateTime? leaseExpiresAt;
  final String? errorCode;
  final String? receiptArtifact;
}

class FolderEntitySyncState {
  const FolderEntitySyncState({
    required this.entityId,
    required this.revisionId,
    required this.versionVector,
    required this.isTombstone,
  });

  final String entityId;
  final String revisionId;
  final VersionVector versionVector;
  final bool isTombstone;
}

class SyncedDataKind {
  const SyncedDataKind({
    required this.kind,
    required this.count,
    required this.bytes,
  });

  /// Stable bucket id: blobs, batches, commits, checkpoints, protocol …
  final String kind;
  final int count;
  final int bytes;
}

/// How far one remote producer's increments have been applied locally.
class SyncedDataDevice {
  const SyncedDataDevice({
    required this.deviceId,
    required this.appliedSequence,
  });

  final String deviceId;
  final int appliedSequence;
}

/// Everything the detail page needs to show *what* has been synced.
class SyncedDataSnapshot {
  const SyncedDataSnapshot({
    required this.uploadedKinds,
    required this.uploadedCount,
    required this.uploadedBytes,
    required this.downloadedKinds,
    required this.downloadedCount,
    required this.downloadedBytes,
    required this.pendingUploadCount,
    required this.pendingDownloadCount,
    required this.appliedIncomingCount,
    required this.pendingIncomingCount,
    required this.publishedOutgoingCount,
    required this.pendingOutgoingCount,
    required this.devices,
    this.incomingLastReceivedAt,
    this.outgoingLastPublishedAt,
  });

  final List<SyncedDataKind> uploadedKinds;
  final int uploadedCount;
  final int uploadedBytes;
  final List<SyncedDataKind> downloadedKinds;
  final int downloadedCount;
  final int downloadedBytes;
  final int pendingUploadCount;
  final int pendingDownloadCount;
  final int appliedIncomingCount;
  final int pendingIncomingCount;
  final int publishedOutgoingCount;
  final int pendingOutgoingCount;
  final List<SyncedDataDevice> devices;
  final DateTime? incomingLastReceivedAt;
  final DateTime? outgoingLastPublishedAt;

  int get totalBytes => uploadedBytes + downloadedBytes;

  bool get isEmpty =>
      uploadedCount == 0 &&
      downloadedCount == 0 &&
      appliedIncomingCount == 0 &&
      publishedOutgoingCount == 0 &&
      devices.isEmpty;

  DateTime? get lastActivityAt {
    final incoming = incomingLastReceivedAt;
    final outgoing = outgoingLastPublishedAt;
    if (incoming == null) return outgoing;
    if (outgoing == null) return incoming;
    return incoming.isAfter(outgoing) ? incoming : outgoing;
  }
}
