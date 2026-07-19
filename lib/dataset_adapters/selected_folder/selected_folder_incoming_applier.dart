import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_storage.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_blob_cipher.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// Applies authenticated Selected Folder operations without allowing a remote
/// payload to escape the authorized root. Operation IDs and vector state are
/// persisted so replaying a batch is harmless after interruption.
class SelectedFolderIncomingApplier {
  SelectedFolderIncomingApplier({
    Directory? root,
    SelectedFolderStorage? storage,
    required String datasetId,
    required String profileId,
    required SyncStateDatabase database,
    required GenericVaultBlobCipher blobCipher,
    Uuid? uuid,
  }) : assert(root != null || storage != null),
       _storage = storage ?? LocalSelectedFolderStorage(root!),
       _datasetId = datasetId,
       _profileId = profileId,
       _database = database,
       _blobCipher = blobCipher,
       _uuid = uuid ?? const Uuid();

  final SelectedFolderStorage _storage;
  final String _datasetId;
  final String _profileId;
  final SyncStateDatabase _database;
  final GenericVaultBlobCipher _blobCipher;
  final Uuid _uuid;

  Future<void> apply({
    required String vaultId,
    required String sourceDeviceId,
    required String batchId,
    required List<SyncOperation> operations,
    required Map<String, Uint8List> blobs,
  }) async {
    if (!await _storage.checkAccess()) {
      throw FolderRootUnavailableException(_storage.rootReference);
    }
    for (final operation in operations) {
      if (await _database.isFolderOperationApplied(
        datasetId: _datasetId,
        operationId: operation.operationId,
      )) {
        continue;
      }
      await _applyOne(
        vaultId: vaultId,
        sourceDeviceId: sourceDeviceId,
        batchId: batchId,
        operation: operation,
        blobs: blobs,
      );
      await _database.recordFolderOperationApplied(
        datasetId: _datasetId,
        operationId: operation.operationId,
        entityId: operation.entityId,
        batchId: batchId,
      );
    }
  }

  Future<void> _applyOne({
    required String vaultId,
    required String sourceDeviceId,
    required String batchId,
    required SyncOperation operation,
    required Map<String, Uint8List> blobs,
  }) async {
    final payload = _payload(operation);
    final target = payload.relativePath;
    final state = await _database.readFolderEntitySyncState(
      datasetId: _datasetId,
      entityId: operation.entityId,
    );
    if (state != null) {
      switch (state.versionVector.compareTo(operation.versionVector)) {
        case VersionVectorComparison.equal:
        case VersionVectorComparison.dominates:
          return;
        case VersionVectorComparison.concurrent:
          await _recordConflict(
            vaultId: vaultId,
            sourceDeviceId: sourceDeviceId,
            batchId: batchId,
            operation: operation,
            payload: payload,
            blobs: blobs,
            target: target,
            localRevisionId: state.revisionId,
            localVersionVector: state.versionVector,
          );
          return;
        case VersionVectorComparison.dominated:
          break;
      }
    }
    if (operation.type == SyncOperationType.delete) {
      if (operation.blobIds.isNotEmpty) {
        throw const FormatException('Delete operation must not contain blobs.');
      }
      await _deleteTarget(target);
      await _database.markFolderEntryImportedDeleted(
        datasetId: _datasetId,
        entityId: operation.entityId,
        deletedAt: operation.createdAt,
      );
    } else {
      await _writeTarget(
        vaultId: vaultId,
        operation: operation,
        payload: payload,
        target: target,
        blobs: blobs,
      );
      await _database.upsertFolderScanEntries(
        datasetId: _datasetId,
        entries: [
          FolderScanEntry(
            entityId: operation.entityId,
            relativePath: payload.relativePath,
            type: payload.entryType,
            size: payload.size,
            modifiedAt: payload.modifiedAt,
            scanGeneration: 0,
          ),
        ],
      );
    }
    await _database.upsertFolderEntitySyncState(
      datasetId: _datasetId,
      entityId: operation.entityId,
      revisionId: operation.revisionId,
      versionVector: operation.versionVector,
      isTombstone: operation.type == SyncOperationType.delete,
    );
  }

  Future<void> _recordConflict({
    required String vaultId,
    required String sourceDeviceId,
    required String batchId,
    required SyncOperation operation,
    required _IncomingPayload payload,
    required Map<String, Uint8List> blobs,
    required String target,
    required String localRevisionId,
    required VersionVector localVersionVector,
  }) async {
    String? protectedDetails;
    if (payload.entryType == FolderEntryType.file) {
      String? conflictCopy;
      if (operation.type != SyncOperationType.delete) {
        conflictCopy = '$target.velock-conflict-${_uuid.v4()}';
        await _writeFile(vaultId, operation, conflictCopy, blobs);
      }
      // This opaque local-only metadata is written only after the durable
      // conflict input is present. Delete conflicts need no content copy. It
      // intentionally excludes blob bytes and decrypted file content; the
      // generic activity UI must never render it.
      final details = <String, Object?>{
        'version': 1,
        'target': target,
        'entryType': payload.entryType.name,
        'localRevisionId': localRevisionId,
        'incomingRevisionId': operation.revisionId,
        'localVector': localVersionVector.values,
        'incomingVector': operation.versionVector.values,
        'incomingWasDelete': operation.type == SyncOperationType.delete,
      };
      if (conflictCopy != null) {
        details['incomingConflictCopy'] = conflictCopy;
      }
      protectedDetails = jsonEncode(details);
    }
    await _database.recordFolderConflict(
      conflictId: _uuid.v4(),
      profileId: _profileId,
      entityId: operation.entityId,
      sourceDeviceId: sourceDeviceId,
      localRevisionId: localRevisionId,
      incomingRevisionId: operation.revisionId,
      type: operation.type == SyncOperationType.delete
          ? 'delete-modify'
          : 'modify-modify',
      protectedDetails: protectedDetails,
    );
  }

  Future<void> _writeTarget({
    required String vaultId,
    required SyncOperation operation,
    required _IncomingPayload payload,
    required String target,
    required Map<String, Uint8List> blobs,
  }) async {
    if (payload.entryType == FolderEntryType.directory) {
      if (operation.blobIds.isNotEmpty) {
        throw const FormatException(
          'Directory operation must not contain blobs.',
        );
      }
      await _storage.createDirectory(target);
      return;
    }
    await _writeFile(vaultId, operation, target, blobs);
  }

  Future<void> _writeFile(
    String vaultId,
    SyncOperation operation,
    String target,
    Map<String, Uint8List> blobs,
  ) async {
    if (operation.blobIds.length != 1) {
      throw const FormatException(
        'File operation must contain exactly one blob.',
      );
    }
    final blobId = operation.blobIds.single;
    final encrypted = blobs[blobId];
    if (encrypted == null) {
      throw const FormatException('Referenced blob is absent.');
    }
    final plaintext = await _blobCipher.decrypt(
      vaultId: vaultId,
      blobId: blobId,
      encrypted: encrypted,
    );
    await _storage.writeFileAtomically(target, plaintext);
  }

  Future<void> _deleteTarget(String target) => _storage.delete(target);

  _IncomingPayload _payload(SyncOperation operation) {
    final value = jsonDecode(utf8.decode(operation.protectedPayload));
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Selected Folder payload is invalid.');
    }
    final path = value['relativePath'];
    final type = value['entryType'];
    if (path is! String || type is! String) {
      throw const FormatException('Selected Folder payload is invalid.');
    }
    validateSelectedFolderRelativePath(path);
    return _IncomingPayload(
      relativePath: path,
      entryType: FolderEntryType.values.byName(type),
      size: value['size'] as int?,
      modifiedAt: value['modifiedAt'] == null
          ? null
          : DateTime.parse(value['modifiedAt'] as String).toUtc(),
    );
  }
}

class _IncomingPayload {
  const _IncomingPayload({
    required this.relativePath,
    required this.entryType,
    required this.size,
    required this.modifiedAt,
  });

  final String relativePath;
  final FolderEntryType entryType;
  final int? size;
  final DateTime? modifiedAt;
}
