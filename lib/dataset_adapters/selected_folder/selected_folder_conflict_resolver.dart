import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/android_document_tree_access.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/apple_security_scoped_folder_access.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_access_authorizer.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_scanner.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_storage.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_profile.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/conflicts/conflict_resolution_service.dart';
import 'package:velock_sync/sync_core/conflicts/conflict_resolution_strategy.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

typedef SelectedFolderConflictSync = Future<void> Function(String profileId);
typedef SelectedFolderConflictStorageFactory =
    SelectedFolderStorage Function(SelectedFolderSyncProfile profile);

/// Resolves Selected Folder file conflicts through the existing scanner and
/// Sync Core execution path. It never marks a conflict complete itself:
/// [DurableConflictResolutionService] does so only after this resolver verifies
/// that the normal outgoing batch advanced the entity to a dominating vector.
class DurableSelectedFolderConflictResolver
    implements SelectedFolderConflictResolver {
  DurableSelectedFolderConflictResolver({
    required SyncStateDatabase database,
    required SelectedFolderSyncProfileRepository profiles,
    required SelectedFolderConflictSync sync,
    AndroidDocumentTreeAccess? androidDocumentTrees,
    AppleSecurityScopedFolderAccess? appleFolders,
    SelectedFolderConflictStorageFactory? storageFactory,
  }) : _database = database,
       _profiles = profiles,
       _sync = sync,
       _androidDocumentTrees =
           androidDocumentTrees ?? MethodChannelAndroidDocumentTreeAccess(),
       _appleFolders =
           appleFolders ?? const MethodChannelAppleSecurityScopedFolderAccess(),
       _storageFactory = storageFactory;

  final SyncStateDatabase _database;
  final SelectedFolderSyncProfileRepository _profiles;
  final SelectedFolderConflictSync _sync;
  final AndroidDocumentTreeAccess _androidDocumentTrees;
  final AppleSecurityScopedFolderAccess _appleFolders;
  final SelectedFolderConflictStorageFactory? _storageFactory;

  @override
  Future<ConflictResolutionArtifact> resolve({
    required SyncConflictRecord conflict,
    required SelectedFolderConflictDetails details,
    required ConflictResolutionStrategy strategy,
  }) async {
    final profile = await _profiles.read(conflict.profileId);
    if (profile == null ||
        profile.state != SelectedFolderProfileState.active ||
        profile.datasetId.isEmpty ||
        profile.deviceId.isEmpty) {
      throw const ConflictResolutionFailure(
        'selected-folder-profile-unavailable',
      );
    }
    if (conflict.entityId.isEmpty ||
        details.entryType != FolderEntryType.file.name) {
      throw const ConflictResolutionFailure(
        'selected-folder-conflict-unsupported',
      );
    }

    final storageSession = _storageFactory == null
        ? await _storageFor(profile)
        : _ConflictStorageSession(_storageFactory(profile));
    final storage = storageSession.storage;
    try {
      if (!await storage.checkAccess()) {
        throw const ConflictResolutionFailure(
          'selected-folder-access-unavailable',
        );
      }
      final localVector = VersionVector(details.localVector);
      final incomingVector = VersionVector(details.incomingVector);
      final mergedBase = _merge(localVector, incomingVector);
      final resolutionIsTombstone =
          details.incomingWasDelete &&
          strategy != ConflictResolutionStrategy.keepLocal;
      var state = await _database.readFolderEntitySyncState(
        datasetId: profile.datasetId,
        entityId: conflict.entityId,
      );
      if (state == null) {
        throw const ConflictResolutionFailure('selected-folder-conflict-stale');
      }

      final alreadyPublished = _isPublished(
        state,
        mergedBase,
        profile.deviceId,
        resolutionIsTombstone,
      );
      if (!alreadyPublished && state.isTombstone) {
        throw const ConflictResolutionFailure('selected-folder-conflict-stale');
      }

      if (!alreadyPublished) {
        final isQueued =
            state.revisionId == details.localRevisionId &&
            state.versionVector == mergedBase;
        if (!isQueued) {
          if (state.revisionId != details.localRevisionId ||
              state.versionVector != localVector) {
            throw const ConflictResolutionFailure(
              'selected-folder-conflict-changed',
            );
          }
          await _applyFilesystemStrategy(
            conflictId: conflict.conflictId,
            storage: storage,
            details: details,
            strategy: strategy,
          );
          await SelectedFolderScanner(
            _database,
          ).scan(datasetId: profile.datasetId, storage: storage);
          await _database.queueFolderConflictResolution(
            datasetId: profile.datasetId,
            entityId: conflict.entityId,
            relativePath: details.target,
            expectedRevisionId: details.localRevisionId,
            expectedVersionVector: localVector,
            mergedBaseVersionVector: mergedBase,
            resolutionIsTombstone: resolutionIsTombstone,
          );
        }

        await _removeTemporaryConflictCopy(
          storage: storage,
          datasetId: profile.datasetId,
          details: details,
          strategy: strategy,
        );
        await _sync(profile.profileId);
        state = await _database.readFolderEntitySyncState(
          datasetId: profile.datasetId,
          entityId: conflict.entityId,
        );
      }

      if (state == null ||
          !_isPublished(
            state,
            mergedBase,
            profile.deviceId,
            resolutionIsTombstone,
          )) {
        throw const ConflictResolutionFailure(
          'selected-folder-resolution-not-published',
        );
      }
      if (strategy == ConflictResolutionStrategy.keepBoth) {
        await _requirePreservedCopyPublished(
          datasetId: profile.datasetId,
          localDeviceId: profile.deviceId,
          relativePath: _preservedCopyPath(conflict.conflictId, details),
        );
      }
      await _removeTemporaryConflictCopy(
        storage: storage,
        datasetId: profile.datasetId,
        details: details,
        strategy: strategy,
      );
      return ConflictResolutionArtifact(
        'selected-folder:${profile.profileId}:${state.revisionId}',
      );
    } finally {
      await storageSession.release();
    }
  }

  Future<void> _applyFilesystemStrategy({
    required String conflictId,
    required SelectedFolderStorage storage,
    required SelectedFolderConflictDetails details,
    required ConflictResolutionStrategy strategy,
  }) async {
    await _requireFile(storage, details.target);
    if (details.incomingWasDelete) {
      switch (strategy) {
        case ConflictResolutionStrategy.keepLocal:
          return;
        case ConflictResolutionStrategy.keepRemote:
          await storage.delete(details.target);
          return;
        case ConflictResolutionStrategy.keepBoth:
          final bytes = await _readFile(storage.file(details.target));
          await storage.writeFileAtomically(
            _preservedCopyPath(conflictId, details),
            bytes,
          );
          await storage.delete(details.target);
          return;
        case ConflictResolutionStrategy.openInVelock:
          throw const ConflictResolutionFailure(
            'selected-folder-conflict-unsupported',
          );
      }
    }
    final incomingConflictCopy = details.incomingConflictCopy;
    if (incomingConflictCopy == null) {
      throw const ConflictResolutionFailure(
        'selected-folder-conflict-file-missing',
      );
    }
    await _requireFile(storage, incomingConflictCopy);
    switch (strategy) {
      case ConflictResolutionStrategy.keepLocal:
      case ConflictResolutionStrategy.keepBoth:
        return;
      case ConflictResolutionStrategy.keepRemote:
        await storage.writeFileAtomically(
          details.target,
          await _readFile(storage.file(incomingConflictCopy)),
        );
      case ConflictResolutionStrategy.openInVelock:
        throw const ConflictResolutionFailure(
          'selected-folder-conflict-unsupported',
        );
    }
  }

  Future<void> _removeTemporaryConflictCopy({
    required SelectedFolderStorage storage,
    required String datasetId,
    required SelectedFolderConflictDetails details,
    required ConflictResolutionStrategy strategy,
  }) async {
    if (details.incomingWasDelete ||
        strategy == ConflictResolutionStrategy.keepBoth) {
      return;
    }
    final incomingConflictCopy = details.incomingConflictCopy;
    if (incomingConflictCopy == null) return;
    await storage.delete(incomingConflictCopy);
    await _database.discardUnpublishedFolderScanEntry(
      datasetId: datasetId,
      relativePath: incomingConflictCopy,
    );
  }

  Future<void> _requirePreservedCopyPublished({
    required String datasetId,
    required String localDeviceId,
    required String relativePath,
  }) async {
    final matches = (await _database.readFolderScanEntries(
      datasetId: datasetId,
    )).where((entry) => entry.relativePath == relativePath);
    if (matches.length != 1) {
      throw const ConflictResolutionFailure(
        'selected-folder-preserved-copy-not-published',
      );
    }
    final copyState = await _database.readFolderEntitySyncState(
      datasetId: datasetId,
      entityId: matches.single.entityId,
    );
    if (copyState == null ||
        copyState.isTombstone ||
        copyState.versionVector[localDeviceId] < 1) {
      throw const ConflictResolutionFailure(
        'selected-folder-preserved-copy-not-published',
      );
    }
  }

  Future<void> _requireFile(
    SelectedFolderStorage storage,
    String relativePath,
  ) async {
    try {
      await storage.file(relativePath).length();
    } on Object {
      throw const ConflictResolutionFailure(
        'selected-folder-conflict-file-missing',
      );
    }
  }

  Future<Uint8List> _readFile(SelectedFolderReadableFile source) async {
    final expectedLength = await source.length();
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in source.openRead()) {
      bytes.add(chunk);
      if (bytes.length > expectedLength) {
        throw const ConflictResolutionFailure(
          'selected-folder-conflict-file-changed',
        );
      }
    }
    if (bytes.length != expectedLength) {
      throw const ConflictResolutionFailure(
        'selected-folder-conflict-file-changed',
      );
    }
    return bytes.takeBytes();
  }

  VersionVector _merge(VersionVector local, VersionVector incoming) {
    final values = <String, int>{...local.values};
    for (final entry in incoming.values.entries) {
      if (entry.value > (values[entry.key] ?? 0)) {
        values[entry.key] = entry.value;
      }
    }
    return VersionVector(values);
  }

  bool _isPublished(
    FolderEntitySyncState state,
    VersionVector mergedBase,
    String localDeviceId,
    bool expectedTombstone,
  ) =>
      state.isTombstone == expectedTombstone &&
      state.versionVector.compareTo(mergedBase) ==
          VersionVectorComparison.dominates &&
      state.versionVector[localDeviceId] > mergedBase[localDeviceId];

  String _preservedCopyPath(
    String conflictId,
    SelectedFolderConflictDetails details,
  ) {
    if (!details.incomingWasDelete) return details.incomingConflictCopy!;
    final digest = sha256.convert(utf8.encode(conflictId)).toString();
    return '${details.target}.velock-conflict-local-$digest';
  }

  Future<_ConflictStorageSession> _storageFor(
    SelectedFolderSyncProfile profile,
  ) async => switch (profile.accessKind) {
    FolderAccessKind.localPath => _ConflictStorageSession(
      LocalSelectedFolderStorage(Directory(profile.rootPath)),
    ),
    FolderAccessKind.androidDocumentTree => _ConflictStorageSession(
      AndroidDocumentTreeStorage(
        treeUri: profile.rootPath,
        access: _androidDocumentTrees,
      ),
    ),
    FolderAccessKind.appleSecurityScopedBookmark => () async {
      final session = await _appleFolders.acquire(profile.rootPath);
      return _ConflictStorageSession(
        LocalSelectedFolderStorage(Directory(session.path)),
        onRelease: () => _appleFolders.release(session.token),
      );
    }(),
  };
}

class _ConflictStorageSession {
  _ConflictStorageSession(this.storage, {Future<void> Function()? onRelease})
    : _onRelease = onRelease;

  final SelectedFolderStorage storage;
  final Future<void> Function()? _onRelease;
  bool _released = false;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _onRelease?.call();
  }
}
