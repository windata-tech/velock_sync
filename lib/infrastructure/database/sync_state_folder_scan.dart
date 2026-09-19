/// Selected-folder scan entries, change tracking and entity sync state for the generic vault dataset.
library;

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'package:velock_sync/infrastructure/database/sync_state_records.dart';
import 'package:velock_sync/infrastructure/database/sync_state_sql.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

final class FolderScanQueries {
  const FolderScanQueries(this.db);

  final Database db;

  /// Starts a new complete-scan attempt. Entries are only tombstoned by the
  /// caller after enumeration has completed without an error.
  Future<int> beginFolderScan({required String datasetId}) async {
    db.execute('BEGIN IMMEDIATE');
    try {
      final current = db.select(
        'SELECT last_generation FROM scan_generations WHERE dataset_id = ?',
        [datasetId],
      );
      final generation = current.isEmpty
          ? 1
          : (current.single['last_generation']! as int) + 1;
      db.execute(
        'INSERT INTO scan_generations (dataset_id, last_generation) VALUES (?, ?) '
        'ON CONFLICT(dataset_id) DO UPDATE SET last_generation = excluded.last_generation',
        [datasetId, generation],
      );
      db.execute('COMMIT');
      return generation;
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<List<FolderScanEntry>> readFolderScanEntries({
    required String datasetId,
    bool includeDeleted = false,
  }) async {
    final rows = db.select(
      'SELECT entity_id, relative_path, metadata_json, scan_generation, deleted_at, pending_generation '
      'FROM scan_entries WHERE dataset_id = ? '
      '${includeDeleted ? '' : 'AND deleted_at IS NULL '}ORDER BY relative_path ASC',
      [datasetId],
    );
    return rows
        .map((row) {
          final metadata =
              jsonDecode(row['metadata_json']! as String)
                  as Map<String, dynamic>;
          return FolderScanEntry(
            entityId: row['entity_id']! as String,
            relativePath: row['relative_path']! as String,
            type: FolderEntryType.values.byName(metadata['type']! as String),
            size: metadata['size'] as int?,
            modifiedAt: dateFromMillis(metadata['modifiedAt'] as int?),
            fileIdentity: metadata['fileIdentity'] as String?,
            contentHash: metadata['contentHash'] as String?,
            scanGeneration: row['scan_generation']! as int,
            deletedAt: dateFromMillis(row['deleted_at'] as int?),
            pendingGeneration: row['pending_generation'] as int?,
          );
        })
        .toList(growable: false);
  }

  Future<void> upsertFolderScanEntries({
    required String datasetId,
    required Iterable<FolderScanEntry> entries,
  }) async {
    final values = entries.toList(growable: false);
    if (values.isEmpty) return;
    db.execute('BEGIN IMMEDIATE');
    try {
      final insert = db.prepare(
        'INSERT INTO scan_entries (dataset_id, entity_id, relative_path, metadata_json, scan_generation, deleted_at, pending_generation) '
        'VALUES (?, ?, ?, ?, ?, NULL, ?) '
        'ON CONFLICT(dataset_id, entity_id) DO UPDATE SET '
        'relative_path = excluded.relative_path, metadata_json = excluded.metadata_json, '
        'scan_generation = excluded.scan_generation, deleted_at = NULL, '
        'pending_generation = excluded.pending_generation',
      );
      try {
        for (final entry in values) {
          insert.execute([
            datasetId,
            entry.entityId,
            entry.relativePath,
            jsonEncode({
              'type': entry.type.name,
              'size': entry.size,
              'modifiedAt': entry.modifiedAt?.toUtc().millisecondsSinceEpoch,
              'fileIdentity': entry.fileIdentity,
              'contentHash': entry.contentHash,
            }),
            entry.scanGeneration,
            entry.pendingGeneration,
          ]);
        }
      } finally {
        insert.close();
      }
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Marks only entries absent from a successfully completed generation as
  /// tombstones. The returned entries are the source for delete operations.
  Future<List<FolderScanEntry>> markMissingFolderEntriesDeleted({
    required String datasetId,
    required int completedGeneration,
    required DateTime deletedAt,
  }) async {
    final missing = (await readFolderScanEntries(
      datasetId: datasetId,
    )).where((entry) => entry.scanGeneration != completedGeneration).toList();
    if (missing.isEmpty) return const [];
    db.execute(
      'UPDATE scan_entries SET deleted_at = ?, pending_generation = ? WHERE dataset_id = ? '
      'AND scan_generation != ? AND deleted_at IS NULL',
      [
        deletedAt.toUtc().millisecondsSinceEpoch,
        completedGeneration,
        datasetId,
        completedGeneration,
      ],
    );
    return missing
        .map(
          (entry) => entry.copyWith(
            deletedAt: deletedAt.toUtc(),
            pendingGeneration: completedGeneration,
          ),
        )
        .toList(growable: false);
  }

  Future<List<FolderScanEntry>> readPendingFolderScanEntries({
    required String datasetId,
  }) async => (await readFolderScanEntries(
    datasetId: datasetId,
    includeDeleted: true,
  )).where((entry) => entry.pendingGeneration != null).toList(growable: false);

  /// Acknowledging a batch clears only changes observed no later than its
  /// completed scan, preserving modifications that happened while it uploaded.
  Future<void> clearFolderPendingChangesThrough({
    required String datasetId,
    required int generation,
  }) async {
    db.execute(
      'UPDATE scan_entries SET pending_generation = NULL WHERE dataset_id = ? '
      'AND pending_generation IS NOT NULL AND pending_generation <= ?',
      [datasetId, generation],
    );
  }

  /// Clears only the entries whose exact revisions were committed. A scan can
  /// contain more than one outgoing batch, so clearing a whole generation here
  /// would silently lose later changes after the first batch publishes.
  Future<void> clearFolderPendingChanges({
    required String datasetId,
    required Iterable<String> entityIds,
    required int generation,
  }) async {
    final ids = entityIds.toSet().toList(growable: false);
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(', ');
    db.execute(
      'UPDATE scan_entries SET pending_generation = NULL '
      'WHERE dataset_id = ? AND pending_generation IS NOT NULL '
      'AND pending_generation <= ? AND entity_id IN ($placeholders)',
      [datasetId, generation, ...ids],
    );
  }

  Future<void> markFolderEntryImportedDeleted({
    required String datasetId,
    required String entityId,
    required DateTime deletedAt,
  }) async {
    db.execute(
      'UPDATE scan_entries SET deleted_at = ?, pending_generation = NULL '
      'WHERE dataset_id = ? AND entity_id = ?',
      [deletedAt.toUtc().millisecondsSinceEpoch, datasetId, entityId],
    );
  }

  Future<FolderEntitySyncState?> readFolderEntitySyncState({
    required String datasetId,
    required String entityId,
  }) async {
    final rows = db.select(
      'SELECT revision_id, version_json, is_tombstone FROM folder_entity_sync_state '
      'WHERE dataset_id = ? AND entity_id = ?',
      [datasetId, entityId],
    );
    if (rows.isEmpty) return null;
    final version = jsonDecode(rows.single['version_json']! as String);
    if (version is! Map<String, dynamic>) {
      throw StateError('Stored entity version vector is invalid.');
    }
    return FolderEntitySyncState(
      entityId: entityId,
      revisionId: rows.single['revision_id']! as String,
      versionVector: VersionVector({
        for (final entry in version.entries)
          if (entry.value is int) entry.key: entry.value as int,
      }),
      isTombstone: (rows.single['is_tombstone']! as int) != 0,
    );
  }

  Future<bool> isFolderOperationApplied({
    required String datasetId,
    required String operationId,
  }) async => db.select(
    'SELECT 1 FROM applied_folder_operations WHERE dataset_id = ? AND operation_id = ?',
    [datasetId, operationId],
  ).isNotEmpty;

  Future<void> recordFolderOperationApplied({
    required String datasetId,
    required String operationId,
    required String entityId,
    required String batchId,
  }) async {
    db.execute(
      'INSERT OR IGNORE INTO applied_folder_operations '
      '(dataset_id, operation_id, entity_id, batch_id, applied_at) VALUES (?, ?, ?, ?, ?)',
      [
        datasetId,
        operationId,
        entityId,
        batchId,
        DateTime.now().toUtc().millisecondsSinceEpoch,
      ],
    );
  }

  Future<void> upsertFolderEntitySyncState({
    required String datasetId,
    required String entityId,
    required String revisionId,
    required VersionVector versionVector,
    required bool isTombstone,
  }) async {
    db.execute(
      'INSERT INTO folder_entity_sync_state '
      '(dataset_id, entity_id, revision_id, version_json, is_tombstone, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(dataset_id, entity_id) DO UPDATE SET '
      'revision_id = excluded.revision_id, version_json = excluded.version_json, '
      'is_tombstone = excluded.is_tombstone, updated_at = excluded.updated_at',
      [
        datasetId,
        entityId,
        revisionId,
        jsonEncode(versionVector.values),
        isTombstone ? 1 : 0,
        DateTime.now().toUtc().millisecondsSinceEpoch,
      ],
    );
  }

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
  }) async {
    db.execute('BEGIN IMMEDIATE');
    try {
      final stateRows = db.select(
        'SELECT revision_id, version_json, is_tombstone '
        'FROM folder_entity_sync_state '
        'WHERE dataset_id = ? AND entity_id = ?',
        [datasetId, entityId],
      );
      if (stateRows.length != 1 ||
          (stateRows.single['is_tombstone']! as int) != 0) {
        throw StateError('Conflict entity state is unavailable.');
      }
      final storedVector = _versionVectorFromJson(
        stateRows.single['version_json']! as String,
      );
      final isInitialState =
          stateRows.single['revision_id'] == expectedRevisionId &&
          storedVector == expectedVersionVector;
      final isRecoveredQueue =
          stateRows.single['revision_id'] == expectedRevisionId &&
          storedVector == mergedBaseVersionVector;
      if (!isInitialState && !isRecoveredQueue) {
        throw StateError('Conflict entity changed during resolution.');
      }

      final scanRows = db.select(
        'SELECT scan_generation, deleted_at FROM scan_entries '
        'WHERE dataset_id = ? AND entity_id = ? AND relative_path = ?',
        [datasetId, entityId, relativePath],
      );
      if (scanRows.length != 1) {
        throw StateError('Conflict target is absent from the folder index.');
      }
      final scanIsTombstone = scanRows.single['deleted_at'] != null;
      if (!resolutionIsTombstone && scanIsTombstone) {
        throw StateError('Conflict target resolution state is inconsistent.');
      }
      final generation = scanRows.single['scan_generation']! as int;
      if (generation < 1) {
        throw StateError('Conflict target has no completed scan generation.');
      }

      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      db.execute(
        'UPDATE folder_entity_sync_state SET version_json = ?, updated_at = ? '
        'WHERE dataset_id = ? AND entity_id = ?',
        [jsonEncode(mergedBaseVersionVector.values), now, datasetId, entityId],
      );
      db.execute(
        'UPDATE scan_entries SET deleted_at = '
        'CASE WHEN ? = 1 THEN COALESCE(deleted_at, ?) ELSE NULL END, '
        'pending_generation = '
        'CASE WHEN pending_generation IS NULL OR pending_generation < ? '
        'THEN ? ELSE pending_generation END '
        'WHERE dataset_id = ? AND entity_id = ?',
        [
          resolutionIsTombstone ? 1 : 0,
          now,
          generation,
          generation,
          datasetId,
          entityId,
        ],
      );
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Removes a scanner row created only for an incoming conflict copy that was
  /// discarded before it ever acquired synchronised entity state. This avoids
  /// publishing a meaningless tombstone for a local-only temporary identity.
  Future<void> discardUnpublishedFolderScanEntry({
    required String datasetId,
    required String relativePath,
  }) async {
    db.execute(
      'DELETE FROM scan_entries '
      'WHERE dataset_id = ? AND relative_path = ? '
      'AND NOT EXISTS ('
      'SELECT 1 FROM folder_entity_sync_state state '
      'WHERE state.dataset_id = scan_entries.dataset_id '
      'AND state.entity_id = scan_entries.entity_id'
      ')',
      [datasetId, relativePath],
    );
  }

  VersionVector _versionVectorFromJson(String encoded) {
    final value = jsonDecode(encoded);
    if (value is! Map<String, dynamic>) {
      throw StateError('Stored entity version vector is invalid.');
    }
    final entries = <String, int>{};
    for (final entry in value.entries) {
      if (entry.key.isEmpty || entry.value is! int || entry.value < 1) {
        throw StateError('Stored entity version vector is invalid.');
      }
      entries[entry.key] = entry.value as int;
    }
    return VersionVector(entries);
  }
}
