/// Persistent state of plain (unencrypted) folder mirror locations.
///
/// Only paths, sizes, timestamps and counters are stored: the mirrored file
/// content lives in the user's local folder and in the remote folder, never in
/// this database.
library;

import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/mirror_models.dart';

final class MirrorQueries {
  MirrorQueries(this.db);

  final Database db;
  Uuid _uuid = const Uuid();

  /// Test seam: deterministic conflict identifiers.
  // ignore: use_setters_to_change_properties
  void useUuid(Uuid uuid) => _uuid = uuid;

  Future<Map<String, MirrorBaselineEntry>> readMirrorEntries(
    String profileId,
  ) async {
    final rows = db.select(
      'SELECT relative_path, kind, local_size, local_mtime, remote_size, '
      'remote_mtime, remote_etag, synced_at FROM mirror_entries '
      'WHERE profile_id = ?',
      [profileId],
    );
    final entries = <String, MirrorBaselineEntry>{};
    for (final row in rows) {
      final path = row['relative_path']! as String;
      final kind = MirrorEntryKind.values.firstWhere(
        (value) => value.name == row['kind'],
        orElse: () => MirrorEntryKind.file,
      );
      entries[path] = MirrorBaselineEntry(
        relativePath: path,
        kind: kind,
        localSize: (row['local_size'] as int?) ?? 0,
        localModifiedAt: _time(row['local_mtime']),
        remoteSize: (row['remote_size'] as int?) ?? 0,
        remoteModifiedAt: _time(row['remote_mtime']),
        remoteEtag: row['remote_etag'] as String?,
        syncedAt:
            _time(row['synced_at']) ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
    }
    return entries;
  }

  Future<void> upsertMirrorEntries(
    String profileId,
    Iterable<MirrorBaselineEntry> entries,
  ) async {
    for (final entry in entries) {
      db.execute(
        'INSERT INTO mirror_entries (profile_id, relative_path, kind, '
        'local_size, local_mtime, remote_size, remote_mtime, remote_etag, '
        'synced_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(profile_id, relative_path) DO UPDATE SET '
        'kind = excluded.kind, local_size = excluded.local_size, '
        'local_mtime = excluded.local_mtime, '
        'remote_size = excluded.remote_size, '
        'remote_mtime = excluded.remote_mtime, '
        'remote_etag = excluded.remote_etag, synced_at = excluded.synced_at',
        [
          profileId,
          entry.relativePath,
          entry.kind.name,
          entry.localSize,
          entry.localModifiedAt?.toUtc().millisecondsSinceEpoch,
          entry.remoteSize,
          entry.remoteModifiedAt?.toUtc().millisecondsSinceEpoch,
          entry.remoteEtag,
          entry.syncedAt.toUtc().millisecondsSinceEpoch,
        ],
      );
    }
  }

  Future<void> deleteMirrorEntries(
    String profileId,
    Iterable<String> relativePaths,
  ) async {
    for (final path in relativePaths) {
      db.execute(
        'DELETE FROM mirror_entries WHERE profile_id = ? AND relative_path = ?',
        [profileId, path],
      );
    }
  }

  Future<void> clearMirrorEntries(String profileId) async {
    db.execute('DELETE FROM mirror_entries WHERE profile_id = ?', [profileId]);
  }

  /// Saves a relocated location and drops the mirror state of the old binding
  /// in ONE transaction.
  ///
  /// Changing the local or the remote folder invalidates everything the old
  /// baseline described. Two separate writes leave a window - a failed second
  /// write, or a process that dies in between - in which the profile points at
  /// a new folder while the old baseline still plans deletions against it, so
  /// files nobody asked to delete disappear.
  ///
  /// The profile statement mirrors `ProfileQueries.upsertSyncProfilePayload`
  /// exactly; it is repeated here because only one transaction can span both
  /// tables on this connection.
  Future<void> relocateMirrorProfile({
    required String profileId,
    required String datasetId,
    required String targetId,
    required String state,
    required String payload,
    bool resetBaseline = true,
  }) async {
    db.execute('BEGIN IMMEDIATE');
    try {
      db.execute(
        'INSERT INTO sync_profiles (profile_id, dataset_id, target_id, vault_id, '
        'state, payload_json, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(profile_id) DO UPDATE SET dataset_id = excluded.dataset_id, '
        'target_id = excluded.target_id, vault_id = excluded.vault_id, '
        'state = excluded.state, payload_json = excluded.payload_json, '
        'updated_at = excluded.updated_at',
        [
          profileId,
          datasetId,
          targetId,
          '',
          state,
          payload,
          DateTime.now().toUtc().millisecondsSinceEpoch,
        ],
      );
      if (resetBaseline) {
        _deleteMirrorState(profileId);
      }
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Everything one location learned about its OLD folders.
  void _deleteMirrorState(String profileId) {
    db.execute('DELETE FROM mirror_entries WHERE profile_id = ?', [profileId]);
    db.execute('DELETE FROM mirror_conflicts WHERE profile_id = ?', [
      profileId,
    ]);
    db.execute('DELETE FROM mirror_run_stats WHERE profile_id = ?', [
      profileId,
    ]);
  }

  Future<void> recordMirrorConflicts(
    String profileId,
    Iterable<MirrorPlannedConflict> conflicts,
    DateTime detectedAt,
  ) async {
    for (final conflict in conflicts) {
      db.execute(
        'INSERT INTO mirror_conflicts (conflict_id, profile_id, '
        'relative_path, kind, resolution, detected_at) VALUES (?, ?, ?, ?, ?, ?)',
        [
          _uuid.v4(),
          profileId,
          conflict.relativePath,
          conflict.kind.name,
          conflict.resolution.name,
          detectedAt.toUtc().millisecondsSinceEpoch,
        ],
      );
    }
  }

  Future<List<MirrorConflictRecord>> readMirrorConflicts(
    String profileId, {
    int limit = 50,
  }) async {
    if (limit < 1) throw ArgumentError.value(limit, 'limit');
    final rows = db.select(
      'SELECT conflict_id, relative_path, kind, resolution, detected_at '
      'FROM mirror_conflicts WHERE profile_id = ? '
      'ORDER BY detected_at DESC, conflict_id DESC LIMIT ?',
      [profileId, limit],
    );
    final records = <MirrorConflictRecord>[];
    for (final row in rows) {
      final kind = MirrorConflictRecord.parseKind(row['kind']);
      final resolution = MirrorConflictRecord.parseResolution(
        row['resolution'],
      );
      if (kind == null || resolution == null) continue;
      records.add(
        MirrorConflictRecord(
          conflictId: row['conflict_id']! as String,
          relativePath: row['relative_path']! as String,
          kind: kind,
          resolution: resolution,
          detectedAt:
              _time(row['detected_at']) ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        ),
      );
    }
    return records;
  }

  Future<int> countMirrorConflicts(String profileId) async {
    final rows = db.select(
      'SELECT COUNT(*) AS total FROM mirror_conflicts WHERE profile_id = ?',
      [profileId],
    );
    return (rows.single['total'] as int?) ?? 0;
  }

  /// Conflicts are informational once resolved; the log is bounded so a
  /// long-lived location cannot grow forever.
  Future<void> trimMirrorConflicts(String profileId, {int keep = 200}) async {
    db.execute(
      'DELETE FROM mirror_conflicts WHERE profile_id = ? AND conflict_id NOT IN ('
      'SELECT conflict_id FROM mirror_conflicts WHERE profile_id = ? '
      'ORDER BY detected_at DESC, conflict_id DESC LIMIT ?)',
      [profileId, profileId, keep],
    );
  }

  Future<void> saveMirrorRunStats(MirrorRunStats stats) async {
    db.execute(
      'INSERT INTO mirror_run_stats (run_id, profile_id, started_at, '
      'finished_at, uploaded_file_count, downloaded_file_count, '
      'deleted_local_count, deleted_remote_count, conflict_count, '
      'held_deletion_count, skipped_count, bytes_transferred, failure_code) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(run_id) DO UPDATE SET finished_at = excluded.finished_at, '
      'uploaded_file_count = excluded.uploaded_file_count, '
      'downloaded_file_count = excluded.downloaded_file_count, '
      'deleted_local_count = excluded.deleted_local_count, '
      'deleted_remote_count = excluded.deleted_remote_count, '
      'conflict_count = excluded.conflict_count, '
      'held_deletion_count = excluded.held_deletion_count, '
      'skipped_count = excluded.skipped_count, '
      'bytes_transferred = excluded.bytes_transferred, '
      'failure_code = excluded.failure_code',
      [
        stats.runId,
        stats.profileId,
        stats.startedAt.toUtc().millisecondsSinceEpoch,
        stats.finishedAt?.toUtc().millisecondsSinceEpoch,
        stats.uploadedFileCount,
        stats.downloadedFileCount,
        stats.deletedLocalCount,
        stats.deletedRemoteCount,
        stats.conflictCount,
        stats.heldDeletionCount,
        stats.skippedCount,
        stats.bytesTransferred,
        stats.failureCode,
      ],
    );
  }

  Future<MirrorRunStats?> readLatestMirrorRunStats(String profileId) async {
    final rows = db.select(
      'SELECT run_id, profile_id, started_at, finished_at, '
      'uploaded_file_count, downloaded_file_count, deleted_local_count, '
      'deleted_remote_count, conflict_count, held_deletion_count, '
      'skipped_count, bytes_transferred, failure_code FROM mirror_run_stats '
      'WHERE profile_id = ? ORDER BY started_at DESC, run_id DESC LIMIT 1',
      [profileId],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return MirrorRunStats(
      runId: row['run_id']! as String,
      profileId: row['profile_id']! as String,
      startedAt:
          _time(row['started_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      finishedAt: _time(row['finished_at']),
      uploadedFileCount: (row['uploaded_file_count'] as int?) ?? 0,
      downloadedFileCount: (row['downloaded_file_count'] as int?) ?? 0,
      deletedLocalCount: (row['deleted_local_count'] as int?) ?? 0,
      deletedRemoteCount: (row['deleted_remote_count'] as int?) ?? 0,
      conflictCount: (row['conflict_count'] as int?) ?? 0,
      heldDeletionCount: (row['held_deletion_count'] as int?) ?? 0,
      skippedCount: (row['skipped_count'] as int?) ?? 0,
      bytesTransferred: (row['bytes_transferred'] as int?) ?? 0,
      failureCode: row['failure_code'] as String?,
    );
  }

  static DateTime? _time(Object? value) {
    if (value is! int) return null;
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  }
}
