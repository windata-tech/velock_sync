import 'dart:typed_data';

import 'package:velock_sync/sync_core/model/sync_models.dart';

typedef ArtifactStreamOpener = Future<Stream<List<int>>> Function();

/// A replayable stream source. Retrying a batch always asks the dataset for a
/// fresh stream instead of retaining a full blob in memory.
class ImmutableArtifact {
  const ImmutableArtifact({required this.length, required this.openRead});

  factory ImmutableArtifact.fromBytes(Uint8List bytes) => ImmutableArtifact(
    length: bytes.length,
    openRead: () async => Stream.value(bytes),
  );

  final int length;
  final ArtifactStreamOpener openRead;
}

class PreparedBlob {
  const PreparedBlob({required this.descriptor, required this.content});

  final BlobDescriptor descriptor;
  final ImmutableArtifact content;
}

class BatchLimits {
  const BatchLimits({
    this.maxOperations = 500,
    this.maxCipherBytes = 256 * 1024 * 1024,
    this.enforceMaxCipherBytes = false,
  });

  final int maxOperations;
  final int maxCipherBytes;

  /// The default preserves V1's streaming guarantee for a single oversized
  /// file. Metered-network policies set this to defer oversized work instead.
  final bool enforceMaxCipherBytes;
}

class ExportCursor {
  const ExportCursor(this.value);

  static const empty = ExportCursor(null);

  final String? value;
}

/// A dataset-created V1 batch. In Velock mode every artifact is already
/// encrypted and authenticated before this type reaches the sync process.
class PreparedOutgoingBatch {
  const PreparedOutgoingBatch({
    required this.vaultId,
    required this.sourceDeviceId,
    required this.sequence,
    required this.batchId,
    required this.envelope,
    required this.operations,
    required this.commit,
    required this.blobs,
  });

  final String vaultId;
  final String sourceDeviceId;
  final int sequence;
  final String batchId;
  final ImmutableArtifact envelope;
  final ImmutableArtifact operations;
  final ImmutableArtifact commit;
  final List<PreparedBlob> blobs;
}

/// An integrity-checked batch that is ready for a dataset to authenticate,
/// decrypt if appropriate, and apply idempotently.
class IncomingBatch {
  const IncomingBatch({
    required this.vaultId,
    required this.sourceDeviceId,
    required this.sequence,
    required this.batchId,
    required this.envelope,
    required this.operations,
    required this.blobs,
  });

  final String vaultId;
  final String sourceDeviceId;
  final int sequence;
  final String batchId;
  final Uint8List envelope;
  final Uint8List operations;
  final Map<String, Uint8List> blobs;
}

/// An integrity-checked incoming batch whose potentially large blobs remain
/// replayable streams. The sync engine validates each blob's declared length
/// and hash while the adapter consumes it.
class IncomingArtifactBatch {
  const IncomingArtifactBatch({
    required this.vaultId,
    required this.sourceDeviceId,
    required this.sequence,
    required this.batchId,
    required this.envelope,
    required this.operations,
    required this.blobs,
  });

  final String vaultId;
  final String sourceDeviceId;
  final int sequence;
  final String batchId;
  final Uint8List envelope;
  final Uint8List operations;
  final Map<String, ImmutableArtifact> blobs;
}

class ImportResult {
  const ImportResult({this.acknowledgementArtifact, this.isApplied = true});

  /// In Velock mode this is created and signed by the trusted Velock app. The
  /// sync core only stores it as an opaque immutable object.
  final ImmutableArtifact? acknowledgementArtifact;

  /// False means the dataset has durably accepted delivery but its trusted
  /// owner (for example the Velock App Group peer) has not applied it yet.
  final bool isApplied;
}

class IncomingBatchReference {
  const IncomingBatchReference({
    required this.vaultId,
    required this.sourceDeviceId,
    required this.sequence,
    required this.batchId,
  });

  final String vaultId;
  final String sourceDeviceId;
  final int sequence;
  final String batchId;
}

/// A checkpoint is an opaque, trusted-owner-validated snapshot. The sync core
/// only exposes it after finding its final commit marker and bounding every
/// transfer; the dataset validates the envelope, signatures, hashes and
/// cursor semantics before accepting it.
class IncomingCheckpoint {
  const IncomingCheckpoint({
    required this.vaultId,
    required this.checkpointId,
    required this.commit,
    required this.envelope,
    required this.parts,
  });

  final String vaultId;
  final String checkpointId;
  final Uint8List commit;
  final Uint8List envelope;
  final List<IncomingCheckpointPart> parts;
}

class IncomingCheckpointPart {
  const IncomingCheckpointPart({
    required this.partNumber,
    required this.content,
  });

  final int partNumber;
  final Uint8List content;
}

enum CheckpointImportDisposition { applied, alreadyApplied, rejected }

class CheckpointImportResult {
  const CheckpointImportResult({
    required this.disposition,
    this.coveredSequences = const {},
  });

  const CheckpointImportResult.applied({
    required Map<String, int> coveredSequences,
  }) : this(
         disposition: CheckpointImportDisposition.applied,
         coveredSequences: coveredSequences,
       );

  const CheckpointImportResult.alreadyApplied({
    required Map<String, int> coveredSequences,
  }) : this(
         disposition: CheckpointImportDisposition.alreadyApplied,
         coveredSequences: coveredSequences,
       );

  const CheckpointImportResult.rejected()
    : this(disposition: CheckpointImportDisposition.rejected);

  final CheckpointImportDisposition disposition;

  /// Producer cursors covered by the authenticated checkpoint. Sync Core only
  /// persists these after the dataset has durably applied the checkpoint.
  final Map<String, int> coveredSequences;

  bool get isAccepted => disposition != CheckpointImportDisposition.rejected;
}

/// Optional capability for datasets that support checkpoint-based recovery.
/// Returning [CheckpointImportDisposition.rejected] asks the engine to try an older
/// committed checkpoint; malformed or unsigned data must never be accepted.
abstract interface class CheckpointRecoveringDatasetAdapter {
  Future<CheckpointImportResult> acceptIncomingCheckpoint(
    IncomingCheckpoint checkpoint,
  );
}

/// Optional two-phase import contract for a trusted peer that applies inboxes
/// asynchronously. The sync engine does not advance its cursor until a later
/// receipt returns an applied result.
abstract interface class DeferredIncomingBatchAdapter {
  Future<ImportResult?> reconcileIncomingBatch(IncomingBatchReference batch);
}

/// Optional Dataset capability used when opaque blobs must never be
/// materialized in the sync process. Adapters must consume every referenced
/// stream before returning so transport integrity failures occur before apply.
abstract interface class StreamingIncomingBatchAdapter {
  Future<ImportResult> acceptIncomingArtifactBatch(IncomingArtifactBatch batch);
}

abstract interface class SyncDatasetAdapter {
  Future<DatasetDescriptor> describe();

  Future<DatasetAccessState> checkAccess();

  Future<PreparedOutgoingBatch?> prepareNextBatch({
    required ExportCursor cursor,
    required BatchLimits limits,
  });

  /// Must only advance its durable export cursor after the remote commit is
  /// visible. Calling this again for an already committed batch is required to
  /// be safe after a crash between commit and local acknowledgement.
  Future<void> acknowledgePublishedBatch({
    required String batchId,
    required int sequence,
  });

  /// Must reject untrusted or malformed batches and be idempotent for the
  /// same batch/operation IDs. Velock adapters perform signature and AEAD
  /// validation inside the trusted Velock application.
  Future<ImportResult> acceptIncomingBatch(IncomingBatch batch);
}
