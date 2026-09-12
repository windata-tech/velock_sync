import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_batch_preparer.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_change_planner.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_incoming_applier.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_scanner.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_storage.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/staging/batch_staging_store.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_acknowledgement.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_batch_envelope.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_operations_cipher.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_operations_codec.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// Upload-capable adapter for an already-authorized local folder. It reserves
/// producer sequence numbers before encrypting, then replays the exact staged
/// ciphertext after interruption until the remote commit is acknowledged.
class SelectedFolderDatasetAdapter implements SyncDatasetAdapter {
  SelectedFolderDatasetAdapter({
    required String datasetId,
    required String profileId,
    required String vaultId,
    required String sourceDeviceId,
    required String displayName,
    Directory? root,
    SelectedFolderStorage? storage,
    required String keyId,
    required KeyPair signingKey,
    required SyncStateDatabase database,
    required SelectedFolderScanner scanner,
    required SelectedFolderBatchPreparer batchPreparer,
    required BatchStagingStore staging,
    Map<String, PublicKey> trustedDeviceKeys = const {},
    GenericVaultBatchEnvelopeSigner? envelopeSigner,
    GenericVaultAcknowledgementSigner? acknowledgementSigner,
    GenericVaultOperationsCipher? operationsCipher,
    GenericVaultOperationsCodec operationsCodec =
        const GenericVaultOperationsCodec(),
    SelectedFolderIncomingApplier? incomingApplier,
    SelectedFolderChangePlanner planner = const SelectedFolderChangePlanner(),
    Uuid? uuid,
  }) : assert(root != null || storage != null),
       _datasetId = datasetId,
       _profileId = profileId,
       _vaultId = vaultId,
       _sourceDeviceId = sourceDeviceId,
       _displayName = displayName,
       _storage = storage ?? LocalSelectedFolderStorage(root!),
       _keyId = keyId,
       _signingKey = signingKey,
       _database = database,
       _scanner = scanner,
       _batchPreparer = batchPreparer,
       _staging = staging,
       _trustedDeviceKeys = Map.unmodifiable(trustedDeviceKeys),
       _envelopeSigner = envelopeSigner,
       _acknowledgementSigner =
           acknowledgementSigner ?? GenericVaultAcknowledgementSigner(),
       _operationsCipher = operationsCipher,
       _operationsCodec = operationsCodec,
       _incomingApplier = incomingApplier,
       _planner = planner,
       _uuid = uuid ?? const Uuid();

  final String _datasetId;
  final String _profileId;
  final String _vaultId;
  final String _sourceDeviceId;
  final String _displayName;
  final SelectedFolderStorage _storage;
  final String _keyId;
  final KeyPair _signingKey;
  final SyncStateDatabase _database;
  final SelectedFolderScanner _scanner;
  final SelectedFolderBatchPreparer _batchPreparer;
  final BatchStagingStore _staging;
  final Map<String, PublicKey> _trustedDeviceKeys;
  final GenericVaultBatchEnvelopeSigner? _envelopeSigner;
  final GenericVaultAcknowledgementSigner _acknowledgementSigner;
  final GenericVaultOperationsCipher? _operationsCipher;
  final GenericVaultOperationsCodec _operationsCodec;
  final SelectedFolderIncomingApplier? _incomingApplier;
  final SelectedFolderChangePlanner _planner;
  final Uuid _uuid;

  @override
  Future<DatasetDescriptor> describe() async => DatasetDescriptor(
    datasetId: _datasetId,
    vaultId: _vaultId,
    kind: DatasetKind.selectedFolder,
    displayName: _displayName,
    accessState: await checkAccess(),
    encryptionMode: EncryptionMode.endToEnd,
  );

  @override
  Future<DatasetAccessState> checkAccess() async => await _storage.checkAccess()
      ? DatasetAccessState.available
      : DatasetAccessState.unavailable;

  @override
  Future<PreparedOutgoingBatch?> prepareNextBatch({
    required ExportCursor cursor,
    required BatchLimits limits,
  }) async {
    if (await checkAccess() != DatasetAccessState.available) {
      throw FolderRootUnavailableException(_storage.rootReference);
    }
    final reservation = await _database.reserveOutgoingSequence(
      profileId: _profileId,
      sourceDeviceId: _sourceDeviceId,
      newBatchId: _uuid.v4(),
    );
    if (reservation.isRecovered) {
      final recovered = await _batchPreparer.recover(reservation.batchId);
      if (recovered != null) {
        _validateRecoveredBatch(recovered.batch, reservation);
        return recovered.batch;
      }
      // No manifest means the previous process stopped before returning any
      // batch to the upload engine; its temporary ciphertext is safe to drop.
      await _staging.discard(reservation.batchId);
    }

    final scan = await _scanner.scan(datasetId: _datasetId, storage: _storage);
    final plan = await _limitPlan(
      _planner.plan(storage: _storage, scan: scan),
      limits,
    );
    if (plan.isEmpty) {
      await _database.cancelOutgoingSequenceReservation(
        profileId: _profileId,
        sourceDeviceId: _sourceDeviceId,
        sequence: reservation.sequence,
        batchId: reservation.batchId,
      );
      return null;
    }
    final previous = await _database.latestPublishedOutgoingBatch(
      profileId: _profileId,
      sourceDeviceId: _sourceDeviceId,
    );
    if (reservation.sequence > 1 &&
        (previous == null || previous.sequence != reservation.sequence - 1)) {
      throw StateError('Outgoing batch chain has a missing predecessor.');
    }
    final baseVersionVectors = <String, VersionVector>{};
    for (final change in plan.changes) {
      final state = await _database.readFolderEntitySyncState(
        datasetId: _datasetId,
        entityId: change.entry.entityId,
      );
      if (state != null) {
        baseVersionVectors[change.entry.entityId] = state.versionVector;
      }
    }
    final batch = await _batchPreparer.prepare(
      plan: plan,
      context: OperationsCipherContext(
        vaultId: _vaultId,
        batchId: reservation.batchId,
        sourceDeviceId: _sourceDeviceId,
        sequence: reservation.sequence,
        keyId: _keyId,
      ),
      signingKey: _signingKey,
      scanGeneration: scan.generation,
      baseVersionVectors: baseVersionVectors,
      previousBatchId: previous?.batchId,
      previousSequence: previous?.sequence,
    );
    if (batch == null) {
      throw StateError(
        'Non-empty Selected Folder plan did not produce a batch.',
      );
    }
    final cipherBytes =
        batch.operations.length +
        batch.envelope.length +
        batch.commit.length +
        batch.blobs.fold<int>(0, (sum, blob) => sum + blob.content.length);
    if (cipherBytes > limits.maxCipherBytes && limits.enforceMaxCipherBytes) {
      await _staging.discard(reservation.batchId);
      await _database.cancelOutgoingSequenceReservation(
        profileId: _profileId,
        sourceDeviceId: _sourceDeviceId,
        sequence: reservation.sequence,
        batchId: reservation.batchId,
      );
      return null;
    }
    if (cipherBytes > limits.maxCipherBytes && plan.changes.length > 1) {
      await _staging.discard(reservation.batchId);
      throw StateError(
        'Selected Folder batch estimate exceeded the cipher-byte limit.',
      );
    }
    return batch;
  }

  @override
  Future<void> acknowledgePublishedBatch({
    required String batchId,
    required int sequence,
  }) async {
    final recovery = await _batchPreparer.recover(batchId);
    if (recovery == null || recovery.batch.sequence != sequence) {
      throw StateError(
        'Published batch is missing its staged recovery manifest.',
      );
    }
    await _database.clearFolderPendingChanges(
      datasetId: _datasetId,
      entityIds: recovery.entityRevisions.map((entity) => entity.entityId),
      generation: recovery.scanGeneration,
    );
    for (final entity in recovery.entityRevisions) {
      await _database.upsertFolderEntitySyncState(
        datasetId: _datasetId,
        entityId: entity.entityId,
        revisionId: entity.revisionId,
        versionVector: entity.versionVector,
        isTombstone: entity.isTombstone,
      );
    }
    await _database.recordOutgoingBatch(
      profileId: _profileId,
      batchId: batchId,
      sequence: sequence,
      state: 'published',
    );
    await _database.markOutgoingSequencePublished(
      profileId: _profileId,
      sourceDeviceId: _sourceDeviceId,
      sequence: sequence,
      batchId: batchId,
    );
    await _staging.discard(batchId);
  }

  @override
  Future<ImportResult> acceptIncomingBatch(IncomingBatch batch) async {
    final trustedKey =
        _trustedDeviceKeys[batch.sourceDeviceId] ??
        await _trustedKeyFromDatabase(batch.sourceDeviceId);
    final signer = _envelopeSigner;
    final cipher = _operationsCipher;
    final applier = _incomingApplier;
    if (trustedKey == null ||
        signer == null ||
        cipher == null ||
        applier == null) {
      throw StateError('Selected Folder inbound trust is not configured.');
    }
    final envelope = await signer.parseAndVerify(
      envelope: batch.envelope,
      trustedPublicKey: trustedKey,
    );
    final draft = envelope.draft;
    if (draft.vaultId != batch.vaultId ||
        draft.sourceDeviceId != batch.sourceDeviceId ||
        draft.sequence != batch.sequence ||
        draft.batchId != batch.batchId ||
        draft.keyId != _keyId) {
      throw const FormatException('Incoming envelope identity is invalid.');
    }
    final operations = _operationsCodec.decode(
      context: OperationsCipherContext(
        vaultId: batch.vaultId,
        batchId: batch.batchId,
        sourceDeviceId: batch.sourceDeviceId,
        sequence: batch.sequence,
        keyId: draft.keyId,
      ),
      plaintext: await cipher.decrypt(
        context: OperationsCipherContext(
          vaultId: batch.vaultId,
          batchId: batch.batchId,
          sourceDeviceId: batch.sourceDeviceId,
          sequence: batch.sequence,
          keyId: draft.keyId,
        ),
        encrypted: batch.operations,
      ),
    );
    if (operations.length != draft.operationCount) {
      throw const FormatException('Incoming operation count is invalid.');
    }
    final envelopeBlobIds = draft.blobs.map((blob) => blob.blobId).toSet();
    if (operations.any(
      (operation) => operation.blobIds.any(
        (blobId) =>
            !envelopeBlobIds.contains(blobId) ||
            !batch.blobs.containsKey(blobId),
      ),
    )) {
      throw const FormatException(
        'Incoming operation references an unknown blob.',
      );
    }
    await applier.apply(
      vaultId: batch.vaultId,
      sourceDeviceId: batch.sourceDeviceId,
      batchId: batch.batchId,
      operations: operations,
      blobs: batch.blobs,
    );
    final receivedAt = await _database.incomingBatchReceivedAt(
      profileId: _profileId,
      sourceDeviceId: batch.sourceDeviceId,
      sequence: batch.sequence,
      batchId: batch.batchId,
    );
    if (receivedAt == null) {
      throw StateError('Incoming batch was not durably recorded.');
    }
    return ImportResult(
      acknowledgementArtifact: await _acknowledgementSigner.sign(
        draft: GenericVaultAcknowledgementDraft(
          vaultId: _vaultId,
          consumerDeviceId: _sourceDeviceId,
          producerDeviceId: batch.sourceDeviceId,
          appliedThroughSequence: batch.sequence,
          createdAt: receivedAt,
        ),
        signingKey: _signingKey,
      ),
    );
  }

  void _validateRecoveredBatch(
    PreparedOutgoingBatch batch,
    OutgoingBatchReservation reservation,
  ) {
    if (batch.batchId != reservation.batchId ||
        batch.sequence != reservation.sequence ||
        batch.vaultId != _vaultId ||
        batch.sourceDeviceId != _sourceDeviceId) {
      throw StateError('Staged batch does not match the active reservation.');
    }
  }

  Future<PublicKey?> _trustedKeyFromDatabase(String deviceId) async {
    final keys = await _database.readTrustedDevicePublicKeys(vaultId: _vaultId);
    final bytes = keys[deviceId];
    return bytes == null
        ? null
        : SimplePublicKey(bytes, type: KeyPairType.ed25519);
  }

  /// Bounds a scan to one protocol batch without rejecting later changes.
  /// The conservative per-file allowance avoids creating oversized multi-file
  /// batches; an individual oversized file is still legal and travels alone.
  Future<SelectedFolderChangePlan> _limitPlan(
    SelectedFolderChangePlan plan,
    BatchLimits limits,
  ) async {
    if (limits.maxOperations < 1 || limits.maxCipherBytes < 1) {
      throw ArgumentError('Batch limits must be positive.');
    }
    const overheadPerOperation = 64 * 1024;
    var estimatedBytes = 0;
    final selected = <SelectedFolderChange>[];
    for (final change in plan.changes) {
      if (selected.length == limits.maxOperations) break;
      final payloadBytes = change.blobSource == null
          ? 1024
          : await change.blobSource!.length();
      final estimated = payloadBytes + overheadPerOperation;
      if (selected.isNotEmpty &&
          estimatedBytes + estimated > limits.maxCipherBytes) {
        break;
      }
      selected.add(change);
      estimatedBytes += estimated;
    }
    return SelectedFolderChangePlan(List.unmodifiable(selected));
  }
}
