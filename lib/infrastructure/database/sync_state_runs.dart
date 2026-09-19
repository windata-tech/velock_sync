/// Sync run and garbage-collection run bookkeeping, including the recovery of runs interrupted by process termination.
library;

import 'package:sqlite3/sqlite3.dart';

import 'package:velock_sync/infrastructure/database/sync_state_records.dart';
import 'package:velock_sync/infrastructure/database/sync_state_sql.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';

final class RunQueries {
  const RunQueries(this.db);

  final Database db;

  Future<void> startSyncRun({
    required String runId,
    required String profileId,
    required DateTime startedAt,
  }) async {
    db.execute(
      'INSERT INTO sync_runs (run_id, profile_id, state, started_at) VALUES (?, ?, ?, ?)',
      [runId, profileId, 'running', startedAt.toUtc().millisecondsSinceEpoch],
    );
  }

  Future<void> finishSyncRun({
    required String runId,
    required String state,
    required DateTime completedAt,
    String? errorCode,
    SyncFailure? failure,
  }) async {
    if (state != 'completed' && state != 'failed') {
      throw ArgumentError.value(state, 'state');
    }
    if (errorCode != null && failure != null) {
      throw ArgumentError('Provide errorCode or failure, not both.');
    }
    final resolvedErrorCode = failure?.errorCode ?? errorCode;
    final updated = db.select(
      'UPDATE sync_runs SET state = ?, completed_at = ?, error_code = ?, error_category = ?, retryable = ?, retry_after_ms = ?, suggested_action = ?, provider_status_code = ? '
      'WHERE run_id = ? AND state = ? RETURNING run_id',
      [
        state,
        completedAt.toUtc().millisecondsSinceEpoch,
        resolvedErrorCode,
        failure?.category.name,
        failure == null ? null : (failure.retryable ? 1 : 0),
        failure?.retryAfter?.inMilliseconds,
        failure?.suggestedAction,
        failure?.providerStatusCode,
        runId,
        'running',
      ],
    );
    if (updated.isEmpty) throw StateError('Sync run is not active.');
  }

  Future<void> startGarbageCollectionRun({
    required String runId,
    required String profileId,
    required String vaultId,
    required DateTime startedAt,
  }) async {
    db.execute(
      'INSERT INTO garbage_collection_runs '
      '(run_id, profile_id, vault_id, state, started_at, active_device_count, '
      'unacked_device_count, candidate_count, eligible_candidate_count, '
      'deleted_object_count) VALUES (?, ?, ?, ?, ?, 0, 0, 0, 0, 0)',
      [
        runId,
        profileId,
        vaultId,
        'running',
        startedAt.toUtc().millisecondsSinceEpoch,
      ],
    );
  }

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
  }) async {
    if (state != 'completed' && state != 'skipped' && state != 'failed') {
      throw ArgumentError.value(state, 'state');
    }
    final updated = db.select(
      'UPDATE garbage_collection_runs SET state = ?, completed_at = ?, '
      'checkpoint_id = ?, retention_cutoff = ?, active_device_count = ?, '
      'unacked_device_count = ?, candidate_count = ?, '
      'eligible_candidate_count = ?, deleted_object_count = ?, '
      'retention_manifest_complete = ?, plan_id = ?, skip_reason = ? '
      'WHERE run_id = ? AND state = ? RETURNING run_id',
      [
        state,
        completedAt.toUtc().millisecondsSinceEpoch,
        checkpointId,
        retentionCutoff?.toUtc().millisecondsSinceEpoch,
        activeDeviceCount,
        unackedDeviceCount,
        candidateCount,
        eligibleCandidateCount,
        deletedObjectCount,
        retentionManifestComplete == null
            ? null
            : (retentionManifestComplete ? 1 : 0),
        planId,
        skipReason,
        runId,
        'running',
      ],
    );
    if (updated.isEmpty) {
      throw StateError('Garbage collection run is not active.');
    }
  }

  Future<GarbageCollectionDiagnostics?>
  latestGarbageCollectionDiagnostics() async {
    final rows = db.select(
      'SELECT run_id, profile_id, vault_id, state, started_at, completed_at, '
      'checkpoint_id, retention_cutoff, active_device_count, '
      'unacked_device_count, candidate_count, eligible_candidate_count, '
      'deleted_object_count, retention_manifest_complete, plan_id, skip_reason '
      'FROM garbage_collection_runs ORDER BY started_at DESC LIMIT 1',
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return GarbageCollectionDiagnostics(
      runId: row['run_id']! as String,
      profileId: row['profile_id']! as String,
      vaultId: row['vault_id']! as String,
      state: row['state']! as String,
      startedAt: DateTime.fromMillisecondsSinceEpoch(
        row['started_at']! as int,
        isUtc: true,
      ),
      completedAt: dateFromMillis(row['completed_at'] as int?),
      checkpointId: row['checkpoint_id'] as String?,
      retentionCutoff: dateFromMillis(row['retention_cutoff'] as int?),
      activeDeviceCount: row['active_device_count']! as int,
      unackedDeviceCount: row['unacked_device_count']! as int,
      candidateCount: row['candidate_count']! as int,
      eligibleCandidateCount: row['eligible_candidate_count']! as int,
      deletedObjectCount: row['deleted_object_count']! as int,
      retentionManifestComplete:
          (row['retention_manifest_complete'] as int?) == 1,
      planId: row['plan_id'] as String?,
      skipReason: row['skip_reason'] as String?,
    );
  }

  Future<SyncRunRecord?> latestSyncRun(String profileId) async {
    final rows = db.select(
      'SELECT run_id, state, started_at, completed_at, error_code, error_category, retryable, retry_after_ms, suggested_action, provider_status_code '
      'FROM sync_runs WHERE profile_id = ? ORDER BY started_at DESC LIMIT 1',
      [profileId],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return SyncRunRecord(
      runId: row['run_id']! as String,
      profileId: profileId,
      state: row['state']! as String,
      startedAt: DateTime.fromMillisecondsSinceEpoch(
        row['started_at']! as int,
        isUtc: true,
      ),
      completedAt: dateFromMillis(row['completed_at'] as int?),
      errorCode: row['error_code'] as String?,
      errorCategory: row['error_category'] as String?,
      retryable: boolFromSql(row['retryable'] as int?),
      retryAfter: durationFromMillis(row['retry_after_ms'] as int?),
      suggestedAction: row['suggested_action'] as String?,
      providerStatusCode: row['provider_status_code'] as int?,
    );
  }

  Future<bool> hasRunningSyncRun(String profileId) async {
    final rows = db.select(
      'SELECT 1 FROM sync_runs WHERE profile_id = ? AND state = ? LIMIT 1',
      [profileId, 'running'],
    );
    return rows.isNotEmpty;
  }

  /// Closes runs that were interrupted by process termination before their
  /// normal completion callback ran. This is used only for an explicit local
  /// profile removal, so a removed profile cannot leave a permanent "running"
  /// record that blocks future cleanup.
  Future<int> failRunningSyncRunsForProfile({
    required String profileId,
    required String errorCode,
    DateTime? completedAt,
  }) async {
    if (profileId.isEmpty || errorCode.isEmpty) {
      throw ArgumentError('Profile and error identities are required.');
    }
    final updated = db.select(
      'UPDATE sync_runs SET state = ?, completed_at = ?, error_code = ? '
      'WHERE profile_id = ? AND state = ? RETURNING run_id',
      [
        'failed',
        (completedAt ?? DateTime.now()).toUtc().millisecondsSinceEpoch,
        errorCode,
        profileId,
        'running',
      ],
    );
    return updated.length;
  }

  Future<List<SyncRunRecord>> listRecentSyncRuns({
    String? profileId,
    int limit = 50,
  }) async {
    if (limit < 1 || limit > 500) throw ArgumentError.value(limit, 'limit');
    if (profileId != null && profileId.isEmpty) {
      throw ArgumentError.value(profileId, 'profileId');
    }
    final rows = db.select(
      'SELECT run_id, profile_id, state, started_at, completed_at, error_code, error_category, retryable, retry_after_ms, suggested_action, provider_status_code '
      'FROM sync_runs${profileId == null ? '' : ' WHERE profile_id = ?'} '
      'ORDER BY started_at DESC, run_id ASC LIMIT ?',
      profileId == null ? [limit] : [profileId, limit],
    );
    return rows
        .map(
          (row) => SyncRunRecord(
            runId: row['run_id']! as String,
            profileId: row['profile_id']! as String,
            state: row['state']! as String,
            startedAt: DateTime.fromMillisecondsSinceEpoch(
              row['started_at']! as int,
              isUtc: true,
            ),
            completedAt: dateFromMillis(row['completed_at'] as int?),
            errorCode: row['error_code'] as String?,
            errorCategory: row['error_category'] as String?,
            retryable: boolFromSql(row['retryable'] as int?),
            retryAfter: durationFromMillis(row['retry_after_ms'] as int?),
            suggestedAction: row['suggested_action'] as String?,
            providerStatusCode: row['provider_status_code'] as int?,
          ),
        )
        .toList(growable: false);
  }
}
