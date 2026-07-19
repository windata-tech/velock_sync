import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/engine/sync_upload_engine.dart';

/// Opaque checkpoint artifacts prepared and signed by a trusted dataset owner.
/// The transport layer does not decrypt, alter, or inspect their content.
class PreparedCheckpoint {
  const PreparedCheckpoint({
    required this.vaultId,
    required this.checkpointId,
    required this.envelope,
    required this.parts,
    required this.commit,
  });

  final String vaultId;
  final String checkpointId;
  final ImmutableArtifact envelope;
  final List<CheckpointPart> parts;
  final ImmutableArtifact commit;
}

class CheckpointPart {
  const CheckpointPart({required this.partNumber, required this.content});

  final int partNumber;
  final ImmutableArtifact content;
}

class CheckpointPublishResult {
  const CheckpointPublishResult({
    required this.uploadedPartCount,
    required this.didUploadEnvelope,
    required this.didPublishCommit,
  });

  final int uploadedPartCount;
  final bool didUploadEnvelope;
  final bool didPublishCommit;
}

/// Publishes a V1 checkpoint with `checkpoint.commit` as its sole visibility
/// transition. Re-running after a crash is safe because every artifact is
/// immutable and existing objects are accepted only when their sizes match.
class SyncCheckpointPublisher {
  const SyncCheckpointPublisher();

  Future<CheckpointPublishResult> publish({
    required PreparedCheckpoint checkpoint,
    required RemoteObjectStore remote,
  }) async {
    final numbers = <int>{};
    for (final part in checkpoint.parts) {
      if (!numbers.add(part.partNumber)) {
        throw ArgumentError.value(
          part.partNumber,
          'parts',
          'part numbers must be unique',
        );
      }
    }
    var uploadedPartCount = 0;
    for (final part in checkpoint.parts) {
      if (await _putImmutable(
        remote,
        LogicalKeys.checkpointPart(
          checkpoint.vaultId,
          checkpoint.checkpointId,
          part.partNumber,
        ),
        part.content,
      )) {
        uploadedPartCount++;
      }
    }
    final didUploadEnvelope = await _putImmutable(
      remote,
      LogicalKeys.checkpointEnvelope(
        checkpoint.vaultId,
        checkpoint.checkpointId,
      ),
      checkpoint.envelope,
    );
    // Do not move this final write: readers and GC must ignore an incomplete
    // checkpoint even if its parts and envelope are already present.
    final didPublishCommit = await _putImmutable(
      remote,
      LogicalKeys.checkpointCommit(checkpoint.vaultId, checkpoint.checkpointId),
      checkpoint.commit,
    );
    return CheckpointPublishResult(
      uploadedPartCount: uploadedPartCount,
      didUploadEnvelope: didUploadEnvelope,
      didPublishCommit: didPublishCommit,
    );
  }

  Future<bool> _putImmutable(
    RemoteObjectStore remote,
    String logicalKey,
    ImmutableArtifact artifact,
  ) async {
    final existing = await remote.stat(logicalKey);
    if (existing != null) {
      if (existing.size != artifact.length) {
        throw ImmutableRemoteObjectMismatchException(logicalKey);
      }
      return false;
    }
    try {
      await remote.put(
        logicalKey,
        await artifact.openRead(),
        contentLength: artifact.length,
        ifAbsent: true,
      );
      return true;
    } on RemoteObjectAlreadyExistsException {
      final concurrentlyCreated = await remote.stat(logicalKey);
      if (concurrentlyCreated == null ||
          concurrentlyCreated.size != artifact.length) {
        throw ImmutableRemoteObjectMismatchException(logicalKey);
      }
      return false;
    }
  }
}
