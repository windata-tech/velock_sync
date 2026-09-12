import 'dart:io';

import 'package:uuid/uuid.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_storage.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

export 'selected_folder_storage.dart'
    show
        FolderCaseConflictException,
        FileIdentityResolver,
        FolderPathInvalidException,
        FolderRootUnavailableException;

/// A safety brake for deletion operations. The scanner keeps entries indexed
/// when a threshold is crossed; a later application-layer confirmation can
/// explicitly publish their tombstones.
class DeletionProtectionPolicy {
  const DeletionProtectionPolicy({
    this.maxDeletedEntries = 1000,
    this.maxDeletedFraction = 0.20,
  }) : assert(maxDeletedEntries >= 1),
       assert(maxDeletedFraction > 0 && maxDeletedFraction <= 1);

  final int maxDeletedEntries;
  final double maxDeletedFraction;

  bool requiresConfirmation({
    required int deletedEntryCount,
    required int previousActiveEntryCount,
  }) =>
      deletedEntryCount >= maxDeletedEntries ||
      (previousActiveEntryCount > 0 &&
          deletedEntryCount / previousActiveEntryCount > maxDeletedFraction);
}

class SelectedFolderScanResult {
  const SelectedFolderScanResult({
    required this.generation,
    required this.entries,
    required this.upsertedEntries,
    required this.deletedEntries,
    required this.deletionRequiresConfirmation,
  });

  final int generation;
  final List<FolderScanEntry> entries;

  /// New, revived, renamed, or metadata-changed entries from this complete
  /// scan. These are local change candidates, not protocol operations yet.
  final List<FolderScanEntry> upsertedEntries;
  final List<FolderScanEntry> deletedEntries;
  final bool deletionRequiresConfirmation;
}

/// Scans an already-authorized directory into the local SQLite index.
///
/// It never follows symlinks and only marks deletions after directory
/// enumeration has completed successfully. Provider access and remote writes
/// deliberately remain outside this adapter.
class SelectedFolderScanner {
  SelectedFolderScanner(
    this._database, {
    Uuid? uuid,
    DateTime Function()? now,
    this.fileIdentityResolver,
    this.deletionPolicy = const DeletionProtectionPolicy(),
  }) : _uuid = uuid ?? const Uuid(),
       _now = now ?? DateTime.now;

  final SyncStateDatabase _database;
  final Uuid _uuid;
  final DateTime Function() _now;
  final FileIdentityResolver? fileIdentityResolver;
  final DeletionProtectionPolicy deletionPolicy;

  Future<SelectedFolderScanResult> scan({
    required String datasetId,
    Directory? root,
    SelectedFolderStorage? storage,
  }) async {
    if (storage == null && root == null) {
      throw ArgumentError('Either root or storage is required.');
    }
    final folder =
        storage ??
        LocalSelectedFolderStorage(root!, fileIdentity: fileIdentityResolver);
    if (!await folder.checkAccess()) {
      throw FolderRootUnavailableException(folder.rootReference);
    }
    final generation = await _database.beginFolderScan(datasetId: datasetId);
    final existing = await _database.readFolderScanEntries(
      datasetId: datasetId,
      includeDeleted: true,
    );
    final byPath = {for (final entry in existing) entry.relativePath: entry};
    final byIdentity = <String, FolderScanEntry>{
      for (final entry in existing)
        if (entry.fileIdentity != null) entry.fileIdentity!: entry,
    };
    final seenCaseFoldedPaths = <String, String>{};
    final entries = <FolderScanEntry>[];
    final upsertedEntries = <FolderScanEntry>[];

    await for (final item in folder.listRecursively()) {
      final relativePath = item.relativePath;
      if (isSelectedFolderIgnoredPath(relativePath)) continue;
      final caseFoldedPath = relativePath.toLowerCase();
      final conflicting = seenCaseFoldedPaths[caseFoldedPath];
      if (conflicting != null && conflicting != relativePath) {
        throw FolderCaseConflictException(conflicting, relativePath);
      }
      seenCaseFoldedPaths[caseFoldedPath] = relativePath;

      final identity = item.fileIdentity;
      final existingEntry =
          byPath[relativePath] ??
          (identity == null ? null : byIdentity[identity]);
      final changed =
          existingEntry == null ||
          !_hasSameContent(
            existingEntry,
            FolderScanEntry(
              entityId: existingEntry.entityId,
              relativePath: relativePath,
              type: item.type,
              size: item.size,
              modifiedAt: item.modifiedAt,
              fileIdentity: identity,
              scanGeneration: generation,
            ),
          );
      final scanned = FolderScanEntry(
        entityId: existingEntry?.entityId ?? _uuid.v4(),
        relativePath: relativePath,
        type: item.type,
        size: item.size,
        modifiedAt: item.modifiedAt,
        fileIdentity: identity,
        scanGeneration: generation,
        pendingGeneration: changed
            ? generation
            : existingEntry.pendingGeneration,
      );
      entries.add(scanned);
      if (changed) {
        upsertedEntries.add(scanned);
      }
    }

    // Persist only after the stream ended cleanly. A failed stream therefore
    // cannot make an incomplete listing look like a set of remote deletes.
    await _database.upsertFolderScanEntries(
      datasetId: datasetId,
      entries: entries,
    );
    final previousActiveCount = existing
        .where((entry) => entry.deletedAt == null)
        .length;
    final candidates = (await _database.readFolderScanEntries(
      datasetId: datasetId,
    )).where((entry) => entry.scanGeneration != generation).toList();
    final needsConfirmation = deletionPolicy.requiresConfirmation(
      deletedEntryCount: candidates.length,
      previousActiveEntryCount: previousActiveCount,
    );
    if (!needsConfirmation) {
      await _database.markMissingFolderEntriesDeleted(
        datasetId: datasetId,
        completedGeneration: generation,
        deletedAt: _now(),
      );
    }
    final pending = await _database.readPendingFolderScanEntries(
      datasetId: datasetId,
    );
    return SelectedFolderScanResult(
      generation: generation,
      entries: entries,
      upsertedEntries: pending
          .where((entry) => entry.deletedAt == null)
          .toList(),
      deletedEntries: pending
          .where((entry) => entry.deletedAt != null)
          .toList(),
      deletionRequiresConfirmation: needsConfirmation,
    );
  }

  bool _hasSameContent(FolderScanEntry previous, FolderScanEntry current) =>
      previous.deletedAt == null &&
      previous.relativePath == current.relativePath &&
      previous.type == current.type &&
      previous.size == current.size &&
      previous.modifiedAt?.millisecondsSinceEpoch ==
          current.modifiedAt?.millisecondsSinceEpoch &&
      previous.fileIdentity == current.fileIdentity;
}
