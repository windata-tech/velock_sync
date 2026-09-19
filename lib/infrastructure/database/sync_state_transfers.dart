/// Transfer job tracking for resumable uploads and downloads.
library;

import 'package:sqlite3/sqlite3.dart';

import 'package:velock_sync/infrastructure/database/sync_state_records.dart';
import 'package:velock_sync/infrastructure/database/sync_state_sql.dart';

TransferJobRecord _transferJobFromRow(Map<String, Object?> row) =>
    TransferJobRecord(
      transferId: row['transfer_id']! as String,
      profileId: row['profile_id']! as String,
      direction: TransferJobDirection.values.byName(
        row['direction']! as String,
      ),
      state: TransferJobState.values.byName(row['state']! as String),
      logicalKey: row['logical_key']! as String,
      expectedSize: row['expected_size'] as int?,
      completedBytes: row['completed_bytes']! as int,
      expectedHash: row['expected_hash'] as String?,
      retryCount: row['retry_count']! as int,
      nextRetryAt: dateFromMillis(row['next_retry_at'] as int?),
      providerCheckpoint: row['provider_checkpoint'] as String?,
      errorCode: row['error_code'] as String?,
      createdAt: dateFromMillis(row['created_at'] as int?),
      completedAt: dateFromMillis(row['completed_at'] as int?),
    );

final class TransferQueries {
  const TransferQueries(this.db);

  final Database db;

  /// Starts or resumes one durable, provider-neutral object transfer. The
  /// logical key is opaque protocol metadata; credentials and provider payloads
  /// never enter this table.
  Future<void> beginTransferJob({
    required String transferId,
    required String profileId,
    required TransferJobDirection direction,
    required String logicalKey,
    int? expectedSize,
    String? expectedHash,
    String? providerCheckpoint,
  }) async {
    if (transferId.isEmpty || profileId.isEmpty || logicalKey.isEmpty) {
      throw ArgumentError('Transfer job identity is required.');
    }
    if (expectedSize != null && expectedSize < 0) {
      throw ArgumentError.value(expectedSize, 'expectedSize');
    }
    db.execute(
      'INSERT INTO transfer_jobs '
      '(transfer_id, profile_id, direction, logical_key, state, expected_size, completed_bytes, expected_hash, provider_checkpoint, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, ?) '
      'ON CONFLICT(transfer_id) DO UPDATE SET '
      'state = excluded.state, expected_size = excluded.expected_size, '
      'completed_bytes = 0, expected_hash = excluded.expected_hash, '
      'provider_checkpoint = excluded.provider_checkpoint, error_code = NULL, '
      'completed_at = NULL',
      [
        transferId,
        profileId,
        direction.name,
        logicalKey,
        TransferJobState.running.name,
        expectedSize,
        expectedHash,
        providerCheckpoint,
        DateTime.now().toUtc().millisecondsSinceEpoch,
      ],
    );
  }

  Future<void> updateTransferProgress({
    required String transferId,
    required int completedBytes,
    String? providerCheckpoint,
  }) async {
    if (completedBytes < 0) {
      throw ArgumentError.value(completedBytes, 'completedBytes');
    }
    final updated = db.select(
      'UPDATE transfer_jobs SET completed_bytes = ?, provider_checkpoint = COALESCE(?, provider_checkpoint) '
      'WHERE transfer_id = ? AND state = ? RETURNING transfer_id',
      [
        completedBytes,
        providerCheckpoint,
        transferId,
        TransferJobState.running.name,
      ],
    );
    if (updated.isEmpty) throw StateError('Transfer job is not running.');
  }

  Future<void> completeTransferJob({
    required String transferId,
    required int completedBytes,
  }) async {
    final updated = db.select(
      'UPDATE transfer_jobs SET state = ?, completed_bytes = ?, error_code = NULL, '
      'completed_at = COALESCE(completed_at, ?) '
      'WHERE transfer_id = ? AND state = ? RETURNING transfer_id',
      [
        TransferJobState.completed.name,
        completedBytes,
        DateTime.now().toUtc().millisecondsSinceEpoch,
        transferId,
        TransferJobState.running.name,
      ],
    );
    if (updated.isEmpty) throw StateError('Transfer job is not running.');
  }

  Future<void> failTransferJob({
    required String transferId,
    required String errorCode,
  }) async {
    if (errorCode.isEmpty) throw ArgumentError.value(errorCode, 'errorCode');
    final updated = db.select(
      'UPDATE transfer_jobs SET state = ?, error_code = ?, '
      'completed_at = COALESCE(completed_at, ?) '
      'WHERE transfer_id = ? AND state = ? RETURNING transfer_id',
      [
        TransferJobState.failed.name,
        errorCode,
        DateTime.now().toUtc().millisecondsSinceEpoch,
        transferId,
        TransferJobState.running.name,
      ],
    );
    if (updated.isEmpty) throw StateError('Transfer job is not running.');
  }

  /// Completed (or failed) transfers in reverse chronological order.
  ///
  /// Powers the itemised "what moved, and when" lists; logical keys stay
  /// opaque and are only mapped to a coarse content category by the caller.
  Future<List<TransferJobRecord>> listTransferHistory({
    required String profileId,
    DateTime? from,
    DateTime? to,
    int limit = 50,
  }) async {
    if (limit < 1 || limit > 200) throw ArgumentError.value(limit, 'limit');
    final clauses = <String>['profile_id = ?', 'completed_at IS NOT NULL'];
    final arguments = <Object?>[profileId];
    if (from != null) {
      clauses.add('completed_at >= ?');
      arguments.add(from.toUtc().millisecondsSinceEpoch);
    }
    if (to != null) {
      clauses.add('completed_at <= ?');
      arguments.add(to.toUtc().millisecondsSinceEpoch);
    }
    try {
      final rows = db.select(
        'SELECT transfer_id, profile_id, direction, logical_key, state, expected_size, completed_bytes, expected_hash, retry_count, next_retry_at, provider_checkpoint, error_code, created_at, completed_at '
        'FROM transfer_jobs WHERE ${clauses.join(' AND ')} '
        'ORDER BY completed_at DESC LIMIT ?',
        [...arguments, limit],
      );
      return rows.map(_transferJobFromRow).toList(growable: false);
    } on Object {
      // Databases that predate the transfer timestamp columns simply have no
      // itemised history to show; the page must still load.
      return const [];
    }
  }

  Future<List<TransferJobRecord>> listTransferJobs({
    String? profileId,
    bool includeCompleted = false,
    int limit = 50,
  }) async {
    if (limit < 1 || limit > 500) throw ArgumentError.value(limit, 'limit');
    final clauses = <String>[];
    final arguments = <Object?>[];
    if (profileId != null) {
      clauses.add('profile_id = ?');
      arguments.add(profileId);
    }
    if (!includeCompleted) {
      clauses.add('state != ?');
      arguments.add(TransferJobState.completed.name);
    }
    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    final rows = db.select(
      'SELECT transfer_id, profile_id, direction, logical_key, state, expected_size, completed_bytes, expected_hash, retry_count, next_retry_at, provider_checkpoint, error_code, created_at, completed_at '
      'FROM transfer_jobs $where ORDER BY transfer_id ASC LIMIT ?',
      [...arguments, limit],
    );
    return rows.map(_transferJobFromRow).toList(growable: false);
  }
}
