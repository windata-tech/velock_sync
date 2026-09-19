/// Conflict records and durable conflict-resolution intents.
library;

import 'package:sqlite3/sqlite3.dart';

import 'package:velock_sync/infrastructure/database/sync_state_records.dart';

final class ConflictQueries {
  const ConflictQueries(this.db);

  final Database db;

  Future<void> recordFolderConflict({
    required String conflictId,
    required String profileId,
    required String entityId,
    required String sourceDeviceId,
    required String localRevisionId,
    required String incomingRevisionId,
    required String type,
    String? protectedDetails,
  }) async {
    db.execute(
      'INSERT INTO conflicts '
      '(conflict_id, profile_id, entity_id, source_device_id, state, protected_details, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        conflictId,
        profileId,
        entityId,
        sourceDeviceId,
        '$type:$localRevisionId:$incomingRevisionId',
        protectedDetails,
        DateTime.now().toUtc().millisecondsSinceEpoch,
      ],
    );
  }

  Future<SyncConflictRecord?> readUnresolvedConflict(String conflictId) async {
    final rows = db.select(
      'SELECT conflict_id, profile_id, entity_id, source_device_id, state, '
      'protected_details, created_at FROM conflicts '
      'WHERE conflict_id = ? AND resolved_at IS NULL',
      [conflictId],
    );
    return rows.isEmpty ? null : _conflictFromRow(rows.single);
  }

  Future<List<SyncConflictRecord>> listUnresolvedConflicts({
    String? profileId,
  }) async {
    final where = profileId == null
        ? 'resolved_at IS NULL'
        : 'profile_id = ? AND resolved_at IS NULL';
    final rows = db.select(
      'SELECT conflict_id, profile_id, entity_id, source_device_id, state, '
      'protected_details, created_at FROM conflicts '
      'WHERE $where ORDER BY created_at DESC, conflict_id ASC',
      profileId == null ? const [] : [profileId],
    );
    return rows.map(_conflictFromRow).toList(growable: false);
  }

  SyncConflictRecord _conflictFromRow(Row row) => SyncConflictRecord(
    conflictId: row['conflict_id']! as String,
    profileId: row['profile_id']! as String,
    entityId: row['entity_id']! as String,
    sourceDeviceId: row['source_device_id'] as String?,
    type: row['state']! as String,
    protectedDetails: row['protected_details'] as String?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      row['created_at']! as int,
      isUtc: true,
    ),
  );

  Future<ConflictResolutionIntentAcquisition> acquireConflictResolutionIntent({
    required String conflictId,
    required String strategy,
    required String owner,
    required DateTime now,
    required Duration lease,
  }) async {
    if (conflictId.isEmpty ||
        strategy.isEmpty ||
        owner.isEmpty ||
        lease <= Duration.zero) {
      throw ArgumentError('Invalid conflict resolution intent.');
    }
    final nowMs = now.toUtc().millisecondsSinceEpoch;
    final leaseExpiresAt = now.add(lease).toUtc().millisecondsSinceEpoch;
    db.execute('BEGIN IMMEDIATE');
    try {
      final conflictRows = db.select(
        'SELECT resolved_at FROM conflicts WHERE conflict_id = ?',
        [conflictId],
      );
      if (conflictRows.isEmpty) {
        db.execute('COMMIT');
        return const ConflictResolutionIntentAcquisition.missing();
      }
      if (conflictRows.single['resolved_at'] != null) {
        db.execute('COMMIT');
        return const ConflictResolutionIntentAcquisition.completed();
      }
      final rows = db.select(
        'SELECT strategy, state, lease_owner, lease_expires_at FROM conflict_resolution_intents '
        'WHERE conflict_id = ?',
        [conflictId],
      );
      if (rows.isNotEmpty) {
        final current = rows.single;
        if (current['strategy'] != strategy) {
          db.execute('COMMIT');
          return const ConflictResolutionIntentAcquisition.strategyMismatch();
        }
        if (current['state'] == ConflictResolutionIntentState.completed.name) {
          db.execute('COMMIT');
          return const ConflictResolutionIntentAcquisition.completed();
        }
        final currentOwner = current['lease_owner'] as String?;
        final expiresAt = current['lease_expires_at'] as int?;
        if (current['state'] == ConflictResolutionIntentState.running.name &&
            currentOwner != owner &&
            expiresAt != null &&
            expiresAt > nowMs) {
          db.execute('COMMIT');
          return const ConflictResolutionIntentAcquisition.inProgress();
        }
        db.execute(
          'UPDATE conflict_resolution_intents SET state = ?, updated_at = ?, '
          'lease_owner = ?, lease_expires_at = ?, error_code = NULL '
          'WHERE conflict_id = ?',
          [
            ConflictResolutionIntentState.running.name,
            nowMs,
            owner,
            leaseExpiresAt,
            conflictId,
          ],
        );
      } else {
        db.execute(
          'INSERT INTO conflict_resolution_intents '
          '(conflict_id, strategy, state, created_at, updated_at, lease_owner, lease_expires_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?)',
          [
            conflictId,
            strategy,
            ConflictResolutionIntentState.running.name,
            nowMs,
            nowMs,
            owner,
            leaseExpiresAt,
          ],
        );
      }
      db.execute('COMMIT');
      return const ConflictResolutionIntentAcquisition.acquired();
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<void> completeConflictResolution({
    required String conflictId,
    required String owner,
    String? completionArtifact,
  }) async {
    db.execute('BEGIN IMMEDIATE');
    try {
      final rows = db.select(
        'SELECT state, lease_owner FROM conflict_resolution_intents WHERE conflict_id = ?',
        [conflictId],
      );
      if (rows.isEmpty ||
          rows.single['state'] != ConflictResolutionIntentState.running.name ||
          rows.single['lease_owner'] != owner) {
        throw StateError(
          'Conflict resolution intent is not owned by this job.',
        );
      }
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      final completed = db.select(
        'UPDATE conflicts SET resolved_at = ? WHERE conflict_id = ? '
        'AND resolved_at IS NULL RETURNING conflict_id',
        [now, conflictId],
      );
      if (completed.isEmpty) {
        throw StateError('Conflict is not unresolved.');
      }
      db.execute(
        'UPDATE conflict_resolution_intents SET state = ?, updated_at = ?, '
        'lease_owner = NULL, lease_expires_at = NULL, receipt_artifact = ? '
        'WHERE conflict_id = ?',
        [
          ConflictResolutionIntentState.completed.name,
          now,
          completionArtifact,
          conflictId,
        ],
      );
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<void> failConflictResolutionIntent({
    required String conflictId,
    required String owner,
    required String errorCode,
  }) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    db.execute(
      'UPDATE conflict_resolution_intents SET state = ?, updated_at = ?, '
      'lease_owner = NULL, lease_expires_at = NULL, error_code = ? '
      'WHERE conflict_id = ? AND state = ? AND lease_owner = ?',
      [
        ConflictResolutionIntentState.retryable.name,
        now,
        errorCode,
        conflictId,
        ConflictResolutionIntentState.running.name,
        owner,
      ],
    );
  }

  Future<ConflictResolutionIntentRecord?> readConflictResolutionIntent(
    String conflictId,
  ) async {
    final rows = db.select(
      'SELECT conflict_id, strategy, state, created_at, updated_at, lease_owner, '
      'lease_expires_at, error_code, receipt_artifact '
      'FROM conflict_resolution_intents WHERE conflict_id = ?',
      [conflictId],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return ConflictResolutionIntentRecord(
      conflictId: row['conflict_id']! as String,
      strategy: row['strategy']! as String,
      state: ConflictResolutionIntentState.values.byName(
        row['state']! as String,
      ),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        row['created_at']! as int,
        isUtc: true,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        row['updated_at']! as int,
        isUtc: true,
      ),
      leaseOwner: row['lease_owner'] as String?,
      leaseExpiresAt: row['lease_expires_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              row['lease_expires_at']! as int,
              isUtc: true,
            ),
      errorCode: row['error_code'] as String?,
      receiptArtifact: row['receipt_artifact'] as String?,
    );
  }

  /// Kept for legacy internal callers only. UI and domain code must use
  /// [completeConflictResolution] after a durable resolution action.
  Future<void> markConflictResolved(String conflictId) async {
    final changed = db.select(
      'UPDATE conflicts SET resolved_at = ? '
      'WHERE conflict_id = ? AND resolved_at IS NULL RETURNING conflict_id',
      [DateTime.now().toUtc().millisecondsSinceEpoch, conflictId],
    );
    if (changed.isEmpty) throw StateError('Conflict is not unresolved.');
  }
}
