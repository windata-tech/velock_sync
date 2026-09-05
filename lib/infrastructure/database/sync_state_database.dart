import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// Persistent state owned by the sync engine. Secrets deliberately never enter
/// this database: rows retain only secure-storage references.
class SyncStateDatabase {
  SyncStateDatabase._(this._database);

  static const _schemaVersion = 9;
  static late SyncStateDatabase _instance;

  final Database _database;

  static SyncStateDatabase get instance => _instance;

  static Future<void> initialize() async {
    final directory = await getApplicationSupportDirectory();
    final file = File(p.join(directory.path, 'velock-sync', 'state.db'));
    _instance = await open(file);
  }

  static Future<SyncStateDatabase> open(File file) async {
    await file.parent.create(recursive: true);
    final database = sqlite3.open(file.path);
    final state = SyncStateDatabase._(database);
    state._migrate();
    return state;
  }

  static Future<SyncStateDatabase> inMemory() async {
    final state = SyncStateDatabase._(sqlite3.openInMemory());
    state._migrate();
    return state;
  }

  Future<int> get schemaVersion async =>
      _database.select('PRAGMA user_version').single.values.single as int;

  Future<List<String>> readConnectionPayloads() async {
    final rows = _database.select(
      'SELECT payload_json FROM connections ORDER BY updated_at ASC, id ASC',
    );
    return rows.map((row) => row['payload_json']! as String).toList();
  }

  Future<void> replaceConnectionPayloads(Map<String, String> payloads) async {
    _database.execute('BEGIN IMMEDIATE');
    try {
      _database.execute('DELETE FROM connections');
      final insert = _database.prepare(
        'INSERT INTO connections (id, payload_json, updated_at) VALUES (?, ?, ?)',
      );
      try {
        final updatedAt = DateTime.now().toUtc().millisecondsSinceEpoch;
        for (final entry in payloads.entries) {
          insert.execute([entry.key, entry.value, updatedAt]);
        }
      } finally {
        insert.close();
      }
      _database.execute('COMMIT');
    } on Object {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<void> upsertSyncProfilePayload({
    required String profileId,
    required String datasetId,
    required String targetId,
    required String vaultId,
    required String state,
    required String payload,
  }) async {
    _database.execute(
      'INSERT INTO sync_profiles (profile_id, dataset_id, target_id, vault_id, state, payload_json, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(profile_id) DO UPDATE SET dataset_id = excluded.dataset_id, target_id = excluded.target_id, vault_id = excluded.vault_id, state = excluded.state, payload_json = excluded.payload_json, updated_at = excluded.updated_at',
      [
        profileId,
        datasetId,
        targetId,
        vaultId,
        state,
        payload,
        DateTime.now().toUtc().millisecondsSinceEpoch,
      ],
    );
  }

  /// Atomically consumes a hash of a pairing challenge.
  ///
  /// Only a SHA-256 digest is persisted; the original challenge never enters
  /// the database, profile JSON, preferences, or logs. A duplicate digest is
  /// a replay and is rejected before the caller sends a pairing request.
  Future<bool> consumeVelockPairingChallenge({
    required String challengeDigest,
    required DateTime consumedAt,
  }) async {
    if (challengeDigest.isEmpty) {
      throw ArgumentError.value(challengeDigest, 'challengeDigest');
    }
    _database.execute(
      'INSERT INTO velock_pairing_challenges (challenge_digest, consumed_at) VALUES (?, ?) '
      'ON CONFLICT(challenge_digest) DO NOTHING',
      [challengeDigest, consumedAt.toUtc().millisecondsSinceEpoch],
    );
    final rows = _database.select('SELECT changes() AS changed');
    return rows.single['changed']! as int == 1;
  }

  Future<String?> readSyncProfilePayload(String profileId) async {
    final rows = _database.select(
      'SELECT payload_json FROM sync_profiles WHERE profile_id = ?',
      [profileId],
    );
    return rows.isEmpty ? null : rows.single['payload_json']! as String;
  }

  /// Returns every locally visible profile. Removed profiles retain their
  /// durable history but can no longer be reconstructed or scheduled.
  Future<List<SyncProfilePayloadRecord>>
  readVisibleSyncProfilePayloads() async {
    final rows = _database.select(
      'SELECT profile_id, state, payload_json FROM sync_profiles '
      'WHERE state != ? ORDER BY updated_at ASC, profile_id ASC',
      ['removed'],
    );
    return rows
        .map(
          (row) => SyncProfilePayloadRecord(
            profileId: row['profile_id']! as String,
            state: row['state']! as String,
            payload: row['payload_json']! as String,
          ),
        )
        .toList(growable: false);
  }

  Future<SyncProfilePayloadRecord?> readVisibleSyncProfilePayload(
    String profileId,
  ) async {
    final rows = _database.select(
      'SELECT profile_id, state, payload_json FROM sync_profiles '
      'WHERE profile_id = ? AND state != ?',
      [profileId, 'removed'],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return SyncProfilePayloadRecord(
      profileId: row['profile_id']! as String,
      state: row['state']! as String,
      payload: row['payload_json']! as String,
    );
  }

  Future<void> setSyncProfileState({
    required String profileId,
    required String state,
  }) async {
    const allowedStates = {
      'active',
      'paused',
      'accessRequired',
      'reauthorizationRequired',
      'blockedByConfiguration',
      'error',
      'removed',
    };
    if (!allowedStates.contains(state)) {
      throw ArgumentError.value(state, 'state');
    }
    final changed = _database.select(
      'UPDATE sync_profiles SET state = ?, updated_at = ? '
      'WHERE profile_id = ? AND state != ? RETURNING profile_id',
      [
        state,
        DateTime.now().toUtc().millisecondsSinceEpoch,
        profileId,
        'removed',
      ],
    );
    if (changed.isEmpty) throw StateError('Sync profile is unavailable.');
  }

  Future<List<String>> readActiveSyncProfilePayloads() async {
    final rows = _database.select(
      'SELECT payload_json FROM sync_profiles WHERE state = ? ORDER BY updated_at ASC, profile_id ASC',
      ['active'],
    );
    return rows.map((row) => row['payload_json']! as String).toList();
  }

  Future<void> startSyncRun({
    required String runId,
    required String profileId,
    required DateTime startedAt,
  }) async {
    _database.execute(
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
    final updated = _database.select(
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

  Future<SyncRunRecord?> latestSyncRun(String profileId) async {
    final rows = _database.select(
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
      completedAt: _dateFromMillis(row['completed_at'] as int?),
      errorCode: row['error_code'] as String?,
      errorCategory: row['error_category'] as String?,
      retryable: _boolFromSql(row['retryable'] as int?),
      retryAfter: _durationFromMillis(row['retry_after_ms'] as int?),
      suggestedAction: row['suggested_action'] as String?,
      providerStatusCode: row['provider_status_code'] as int?,
    );
  }

  Future<bool> hasRunningSyncRun(String profileId) async {
    final rows = _database.select(
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
    final updated = _database.select(
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
    final rows = _database.select(
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
            completedAt: _dateFromMillis(row['completed_at'] as int?),
            errorCode: row['error_code'] as String?,
            errorCategory: row['error_category'] as String?,
            retryable: _boolFromSql(row['retryable'] as int?),
            retryAfter: _durationFromMillis(row['retry_after_ms'] as int?),
            suggestedAction: row['suggested_action'] as String?,
            providerStatusCode: row['provider_status_code'] as int?,
          ),
        )
        .toList(growable: false);
  }

  /// A privacy-safe status projection for the profile list. It intentionally
  /// contains counts and normalized run state only: neither paths, filenames,
  /// credentials, nor provider response bodies are queried for UI display.
  Future<SyncProfileActivitySummary> readSyncProfileActivity(
    String profileId,
  ) async {
    final latestRun = await latestSyncRun(profileId);
    final transferRows = _database.select(
      'SELECT direction, COUNT(*) AS count, COALESCE(SUM(completed_bytes), 0) AS bytes '
      'FROM transfer_jobs WHERE profile_id = ? '
      "AND state IN ('queued', 'running', 'paused', 'retryWaiting') "
      'GROUP BY direction',
      [profileId],
    );
    var pendingUploadCount = 0;
    var pendingDownloadCount = 0;
    var transferredBytes = 0;
    for (final row in transferRows) {
      final count = row['count']! as int;
      final bytes = row['bytes']! as int;
      transferredBytes += bytes;
      switch (row['direction']) {
        case 'upload':
          pendingUploadCount += count;
        case 'download':
          pendingDownloadCount += count;
      }
    }
    final conflictRows = _database.select(
      'SELECT COUNT(*) AS count FROM conflicts '
      'WHERE profile_id = ? AND resolved_at IS NULL',
      [profileId],
    );
    return SyncProfileActivitySummary(
      latestRun: latestRun,
      pendingUploadCount: pendingUploadCount,
      pendingDownloadCount: pendingDownloadCount,
      transferredBytes: transferredBytes,
      unresolvedConflictCount: conflictRows.single['count']! as int,
    );
  }

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
    _database.execute(
      'INSERT INTO transfer_jobs '
      '(transfer_id, profile_id, direction, logical_key, state, expected_size, completed_bytes, expected_hash, provider_checkpoint) '
      'VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?) '
      'ON CONFLICT(transfer_id) DO UPDATE SET '
      'state = excluded.state, expected_size = excluded.expected_size, '
      'completed_bytes = 0, expected_hash = excluded.expected_hash, '
      'provider_checkpoint = excluded.provider_checkpoint, error_code = NULL',
      [
        transferId,
        profileId,
        direction.name,
        logicalKey,
        TransferJobState.running.name,
        expectedSize,
        expectedHash,
        providerCheckpoint,
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
    final updated = _database.select(
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
    final updated = _database.select(
      'UPDATE transfer_jobs SET state = ?, completed_bytes = ?, error_code = NULL '
      'WHERE transfer_id = ? AND state = ? RETURNING transfer_id',
      [
        TransferJobState.completed.name,
        completedBytes,
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
    final updated = _database.select(
      'UPDATE transfer_jobs SET state = ?, error_code = ? '
      'WHERE transfer_id = ? AND state = ? RETURNING transfer_id',
      [
        TransferJobState.failed.name,
        errorCode,
        transferId,
        TransferJobState.running.name,
      ],
    );
    if (updated.isEmpty) throw StateError('Transfer job is not running.');
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
    final rows = _database.select(
      'SELECT transfer_id, profile_id, direction, logical_key, state, expected_size, completed_bytes, expected_hash, retry_count, next_retry_at, provider_checkpoint, error_code '
      'FROM transfer_jobs $where ORDER BY transfer_id ASC LIMIT ?',
      [...arguments, limit],
    );
    return rows
        .map(
          (row) => TransferJobRecord(
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
            nextRetryAt: _dateFromMillis(row['next_retry_at'] as int?),
            providerCheckpoint: row['provider_checkpoint'] as String?,
            errorCode: row['error_code'] as String?,
          ),
        )
        .toList(growable: false);
  }

  /// Acquires the persistent, recoverable lock required for a single active
  /// run per sync profile. A stale lock may be claimed by a new owner.
  Future<bool> tryAcquireProfileLock({
    required String profileId,
    required String owner,
    required DateTime now,
    required Duration staleAfter,
  }) async {
    final nowMillis = now.toUtc().millisecondsSinceEpoch;
    final staleBefore = now.subtract(staleAfter).toUtc().millisecondsSinceEpoch;
    _database.execute('BEGIN IMMEDIATE');
    try {
      final current = _database.select(
        'SELECT owner, heartbeat_at FROM profile_locks WHERE profile_id = ?',
        [profileId],
      );
      if (current.isEmpty ||
          current.single['owner'] == owner ||
          (current.single['heartbeat_at']! as int) < staleBefore) {
        _database.execute(
          'INSERT INTO profile_locks (profile_id, owner, acquired_at, heartbeat_at) VALUES (?, ?, ?, ?) '
          'ON CONFLICT(profile_id) DO UPDATE SET owner = excluded.owner, acquired_at = excluded.acquired_at, heartbeat_at = excluded.heartbeat_at',
          [profileId, owner, nowMillis, nowMillis],
        );
        _database.execute('COMMIT');
        return true;
      }
      _database.execute('COMMIT');
      return false;
    } on Object {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<bool> heartbeatProfileLock({
    required String profileId,
    required String owner,
    required DateTime now,
  }) async {
    final result = _database.select(
      'UPDATE profile_locks SET heartbeat_at = ? WHERE profile_id = ? AND owner = ? RETURNING profile_id',
      [now.toUtc().millisecondsSinceEpoch, profileId, owner],
    );
    return result.isNotEmpty;
  }

  Future<void> recordOutgoingBatch({
    required String profileId,
    required String batchId,
    required int sequence,
    required String state,
  }) async {
    _database.execute(
      'INSERT INTO outgoing_batches (profile_id, batch_id, sequence, state, created_at) VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(profile_id, batch_id) DO UPDATE SET state = excluded.state',
      [
        profileId,
        batchId,
        sequence,
        state,
        DateTime.now().toUtc().millisecondsSinceEpoch,
      ],
    );
  }

  Future<void> markOutgoingBatchPublished({
    required String profileId,
    required String batchId,
    required DateTime publishedAt,
  }) async {
    _database.execute(
      'UPDATE outgoing_batches SET state = ?, published_at = ? WHERE profile_id = ? AND batch_id = ?',
      [
        'published',
        publishedAt.toUtc().millisecondsSinceEpoch,
        profileId,
        batchId,
      ],
    );
  }

  /// Reserves one producer sequence durably. If a prior run crashed before its
  /// commit was acknowledged, that same reservation is returned so callers
  /// reuse the exact batch identity and staged ciphertext.
  Future<OutgoingBatchReservation> reserveOutgoingSequence({
    required String profileId,
    required String sourceDeviceId,
    required String newBatchId,
  }) async {
    _database.execute('BEGIN IMMEDIATE');
    try {
      final existing = _database.select(
        'SELECT sequence, batch_id FROM outgoing_sequence_reservations '
        'WHERE profile_id = ? AND source_device_id = ?',
        [profileId, sourceDeviceId],
      );
      if (existing.isNotEmpty) {
        _database.execute('COMMIT');
        return OutgoingBatchReservation(
          sequence: existing.single['sequence']! as int,
          batchId: existing.single['batch_id']! as String,
          isRecovered: true,
        );
      }
      final published = _database.select(
        'SELECT published_sequence FROM outgoing_sequences '
        'WHERE profile_id = ? AND source_device_id = ?',
        [profileId, sourceDeviceId],
      );
      final sequence = published.isEmpty
          ? 1
          : (published.single['published_sequence']! as int) + 1;
      _database.execute(
        'INSERT INTO outgoing_sequence_reservations '
        '(profile_id, source_device_id, sequence, batch_id, created_at) '
        'VALUES (?, ?, ?, ?, ?)',
        [
          profileId,
          sourceDeviceId,
          sequence,
          newBatchId,
          DateTime.now().toUtc().millisecondsSinceEpoch,
        ],
      );
      _database.execute('COMMIT');
      return OutgoingBatchReservation(
        sequence: sequence,
        batchId: newBatchId,
        isRecovered: false,
      );
    } on Object {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<void> markOutgoingSequencePublished({
    required String profileId,
    required String sourceDeviceId,
    required int sequence,
    required String batchId,
  }) async {
    _database.execute('BEGIN IMMEDIATE');
    try {
      final reservation = _database.select(
        'SELECT sequence, batch_id FROM outgoing_sequence_reservations '
        'WHERE profile_id = ? AND source_device_id = ?',
        [profileId, sourceDeviceId],
      );
      if (reservation.isEmpty) {
        final published = _database.select(
          'SELECT published_sequence FROM outgoing_sequences '
          'WHERE profile_id = ? AND source_device_id = ?',
          [profileId, sourceDeviceId],
        );
        if (published.isNotEmpty &&
            published.single['published_sequence'] == sequence) {
          _database.execute('COMMIT');
          return;
        }
        throw StateError(
          'Published batch does not match the current reservation.',
        );
      }
      if (reservation.single['sequence'] != sequence ||
          reservation.single['batch_id'] != batchId) {
        throw StateError(
          'Published batch does not match the current reservation.',
        );
      }
      _database.execute(
        'INSERT INTO outgoing_sequences (profile_id, source_device_id, published_sequence) VALUES (?, ?, ?) '
        'ON CONFLICT(profile_id, source_device_id) DO UPDATE SET published_sequence = excluded.published_sequence',
        [profileId, sourceDeviceId, sequence],
      );
      _database.execute(
        'DELETE FROM outgoing_sequence_reservations '
        'WHERE profile_id = ? AND source_device_id = ?',
        [profileId, sourceDeviceId],
      );
      _database.execute('COMMIT');
    } on Object {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Releases a reservation that never produced a staged batch. A caller must
  /// provide the exact reservation identity so a different active run cannot
  /// accidentally skip a producer sequence.
  Future<void> cancelOutgoingSequenceReservation({
    required String profileId,
    required String sourceDeviceId,
    required int sequence,
    required String batchId,
  }) async {
    final result = _database.select(
      'DELETE FROM outgoing_sequence_reservations '
      'WHERE profile_id = ? AND source_device_id = ? AND sequence = ? AND batch_id = ? '
      'RETURNING batch_id',
      [profileId, sourceDeviceId, sequence, batchId],
    );
    if (result.isEmpty) {
      throw StateError('Outgoing sequence reservation no longer matches.');
    }
  }

  /// Returns the immediate predecessor needed to bind the next signed batch
  /// into this producer's append-only chain.
  Future<PublishedOutgoingBatchReference?> latestPublishedOutgoingBatch({
    required String profileId,
    required String sourceDeviceId,
  }) async {
    final rows = _database.select(
      'SELECT batch_id, sequence FROM outgoing_batches '
      'WHERE profile_id = ? AND state = ? ORDER BY sequence DESC LIMIT 1',
      [profileId, 'published'],
    );
    if (rows.isEmpty) return null;
    return PublishedOutgoingBatchReference(
      batchId: rows.single['batch_id']! as String,
      sequence: rows.single['sequence']! as int,
    );
  }

  Future<int> appliedSequence({
    required String profileId,
    required String producerDeviceId,
  }) async {
    final rows = _database.select(
      'SELECT applied_sequence FROM sync_cursors WHERE profile_id = ? AND producer_device_id = ?',
      [profileId, producerDeviceId],
    );
    return rows.isEmpty ? 0 : rows.single['applied_sequence']! as int;
  }

  Future<void> recordIncomingBatch({
    required String profileId,
    required String sourceDeviceId,
    required int sequence,
    required String batchId,
    required String state,
  }) async {
    _database.execute(
      'INSERT INTO incoming_batches (profile_id, source_device_id, sequence, batch_id, state, received_at) VALUES (?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(profile_id, source_device_id, sequence, batch_id) DO UPDATE SET state = excluded.state',
      [
        profileId,
        sourceDeviceId,
        sequence,
        batchId,
        state,
        DateTime.now().toUtc().millisecondsSinceEpoch,
      ],
    );
  }

  Future<String?> incomingBatchState({
    required String profileId,
    required String sourceDeviceId,
    required int sequence,
    required String batchId,
  }) async {
    final rows = _database.select(
      'SELECT state FROM incoming_batches WHERE profile_id = ? AND source_device_id = ? AND sequence = ? AND batch_id = ?',
      [profileId, sourceDeviceId, sequence, batchId],
    );
    return rows.isEmpty ? null : rows.single['state']! as String;
  }

  /// The first durable receipt time is used in the signed ACK so retries emit
  /// byte-identical immutable artifacts rather than competing replacements.
  Future<DateTime?> incomingBatchReceivedAt({
    required String profileId,
    required String sourceDeviceId,
    required int sequence,
    required String batchId,
  }) async {
    final rows = _database.select(
      'SELECT received_at FROM incoming_batches '
      'WHERE profile_id = ? AND source_device_id = ? AND sequence = ? AND batch_id = ?',
      [profileId, sourceDeviceId, sequence, batchId],
    );
    return rows.isEmpty
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            rows.single['received_at']! as int,
            isUtc: true,
          );
  }

  Future<void> advanceAppliedSequence({
    required String profileId,
    required String producerDeviceId,
    required int sequence,
  }) async {
    final current = await appliedSequence(
      profileId: profileId,
      producerDeviceId: producerDeviceId,
    );
    if (sequence != current + 1) {
      throw StateError('Applied sequences must be contiguous.');
    }
    _database.execute(
      'INSERT INTO sync_cursors (profile_id, producer_device_id, applied_sequence) VALUES (?, ?, ?) '
      'ON CONFLICT(profile_id, producer_device_id) DO UPDATE SET applied_sequence = excluded.applied_sequence',
      [profileId, producerDeviceId, sequence],
    );
  }

  /// Seeds contiguous-download cursors after a trusted checkpoint has been
  /// durably applied. Unlike individual batch import, a checkpoint may safely
  /// jump from any older cursor to its authenticated covered sequence.
  Future<void> advanceAppliedSequencesFromCheckpoint({
    required String profileId,
    required Map<String, int> coveredSequences,
  }) async {
    _database.execute('BEGIN IMMEDIATE');
    try {
      for (final entry in coveredSequences.entries) {
        if (entry.key.isEmpty || entry.value < 0) {
          throw ArgumentError.value(coveredSequences, 'coveredSequences');
        }
        final rows = _database.select(
          'SELECT applied_sequence FROM sync_cursors WHERE profile_id = ? AND producer_device_id = ?',
          [profileId, entry.key],
        );
        final current = rows.isEmpty
            ? 0
            : rows.single['applied_sequence']! as int;
        if (entry.value <= current) continue;
        _database.execute(
          'INSERT INTO sync_cursors (profile_id, producer_device_id, applied_sequence) VALUES (?, ?, ?) '
          'ON CONFLICT(profile_id, producer_device_id) DO UPDATE SET applied_sequence = excluded.applied_sequence',
          [profileId, entry.key, entry.value],
        );
      }
      _database.execute('COMMIT');
    } on Object {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Starts a new complete-scan attempt. Entries are only tombstoned by the
  /// caller after enumeration has completed without an error.
  Future<int> beginFolderScan({required String datasetId}) async {
    _database.execute('BEGIN IMMEDIATE');
    try {
      final current = _database.select(
        'SELECT last_generation FROM scan_generations WHERE dataset_id = ?',
        [datasetId],
      );
      final generation = current.isEmpty
          ? 1
          : (current.single['last_generation']! as int) + 1;
      _database.execute(
        'INSERT INTO scan_generations (dataset_id, last_generation) VALUES (?, ?) '
        'ON CONFLICT(dataset_id) DO UPDATE SET last_generation = excluded.last_generation',
        [datasetId, generation],
      );
      _database.execute('COMMIT');
      return generation;
    } on Object {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<List<FolderScanEntry>> readFolderScanEntries({
    required String datasetId,
    bool includeDeleted = false,
  }) async {
    final rows = _database.select(
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
            modifiedAt: _dateFromMillis(metadata['modifiedAt'] as int?),
            fileIdentity: metadata['fileIdentity'] as String?,
            contentHash: metadata['contentHash'] as String?,
            scanGeneration: row['scan_generation']! as int,
            deletedAt: _dateFromMillis(row['deleted_at'] as int?),
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
    _database.execute('BEGIN IMMEDIATE');
    try {
      final insert = _database.prepare(
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
      _database.execute('COMMIT');
    } on Object {
      _database.execute('ROLLBACK');
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
    _database.execute(
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
    _database.execute(
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
    _database.execute(
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
    _database.execute(
      'UPDATE scan_entries SET deleted_at = ?, pending_generation = NULL '
      'WHERE dataset_id = ? AND entity_id = ?',
      [deletedAt.toUtc().millisecondsSinceEpoch, datasetId, entityId],
    );
  }

  Future<FolderEntitySyncState?> readFolderEntitySyncState({
    required String datasetId,
    required String entityId,
  }) async {
    final rows = _database.select(
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
  }) async => _database.select(
    'SELECT 1 FROM applied_folder_operations WHERE dataset_id = ? AND operation_id = ?',
    [datasetId, operationId],
  ).isNotEmpty;

  Future<void> recordFolderOperationApplied({
    required String datasetId,
    required String operationId,
    required String entityId,
    required String batchId,
  }) async {
    _database.execute(
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
    _database.execute(
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
    _database.execute('BEGIN IMMEDIATE');
    try {
      final stateRows = _database.select(
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

      final scanRows = _database.select(
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
      _database.execute(
        'UPDATE folder_entity_sync_state SET version_json = ?, updated_at = ? '
        'WHERE dataset_id = ? AND entity_id = ?',
        [jsonEncode(mergedBaseVersionVector.values), now, datasetId, entityId],
      );
      _database.execute(
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
      _database.execute('COMMIT');
    } on Object {
      _database.execute('ROLLBACK');
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
    _database.execute(
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
    _database.execute(
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
    final rows = _database.select(
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
    final rows = _database.select(
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
    _database.execute('BEGIN IMMEDIATE');
    try {
      final conflictRows = _database.select(
        'SELECT resolved_at FROM conflicts WHERE conflict_id = ?',
        [conflictId],
      );
      if (conflictRows.isEmpty) {
        _database.execute('COMMIT');
        return const ConflictResolutionIntentAcquisition.missing();
      }
      if (conflictRows.single['resolved_at'] != null) {
        _database.execute('COMMIT');
        return const ConflictResolutionIntentAcquisition.completed();
      }
      final rows = _database.select(
        'SELECT strategy, state, lease_owner, lease_expires_at FROM conflict_resolution_intents '
        'WHERE conflict_id = ?',
        [conflictId],
      );
      if (rows.isNotEmpty) {
        final current = rows.single;
        if (current['strategy'] != strategy) {
          _database.execute('COMMIT');
          return const ConflictResolutionIntentAcquisition.strategyMismatch();
        }
        if (current['state'] == ConflictResolutionIntentState.completed.name) {
          _database.execute('COMMIT');
          return const ConflictResolutionIntentAcquisition.completed();
        }
        final currentOwner = current['lease_owner'] as String?;
        final expiresAt = current['lease_expires_at'] as int?;
        if (current['state'] == ConflictResolutionIntentState.running.name &&
            currentOwner != owner &&
            expiresAt != null &&
            expiresAt > nowMs) {
          _database.execute('COMMIT');
          return const ConflictResolutionIntentAcquisition.inProgress();
        }
        _database.execute(
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
        _database.execute(
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
      _database.execute('COMMIT');
      return const ConflictResolutionIntentAcquisition.acquired();
    } on Object {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<void> completeConflictResolution({
    required String conflictId,
    required String owner,
    String? completionArtifact,
  }) async {
    _database.execute('BEGIN IMMEDIATE');
    try {
      final rows = _database.select(
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
      final completed = _database.select(
        'UPDATE conflicts SET resolved_at = ? WHERE conflict_id = ? '
        'AND resolved_at IS NULL RETURNING conflict_id',
        [now, conflictId],
      );
      if (completed.isEmpty) {
        throw StateError('Conflict is not unresolved.');
      }
      _database.execute(
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
      _database.execute('COMMIT');
    } on Object {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<void> failConflictResolutionIntent({
    required String conflictId,
    required String owner,
    required String errorCode,
  }) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    _database.execute(
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
    final rows = _database.select(
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
    final changed = _database.select(
      'UPDATE conflicts SET resolved_at = ? '
      'WHERE conflict_id = ? AND resolved_at IS NULL RETURNING conflict_id',
      [DateTime.now().toUtc().millisecondsSinceEpoch, conflictId],
    );
    if (changed.isEmpty) throw StateError('Conflict is not unresolved.');
  }

  /// Records a device only after an explicit local pairing/approval flow. This
  /// API intentionally never reads a remote member object or auto-enrolls it.
  Future<void> trustDevice({
    required String vaultId,
    required String deviceId,
    required Uint8List signingPublicKey,
  }) async {
    if (vaultId.isEmpty || deviceId.isEmpty || signingPublicKey.length != 32) {
      throw ArgumentError('Invalid trusted device identity.');
    }
    _database.execute(
      'INSERT INTO devices (device_id, vault_id, payload_json, updated_at) VALUES (?, ?, ?, ?) '
      'ON CONFLICT(device_id) DO UPDATE SET vault_id = excluded.vault_id, payload_json = excluded.payload_json, updated_at = excluded.updated_at',
      [
        deviceId,
        vaultId,
        jsonEncode({
          'status': 'active',
          'signingPublicKey': base64UrlEncode(
            signingPublicKey,
          ).replaceAll('=', ''),
        }),
        DateTime.now().toUtc().millisecondsSinceEpoch,
      ],
    );
  }

  Future<void> revokeTrustedDevice({
    required String vaultId,
    required String deviceId,
  }) async {
    _database.execute(
      'UPDATE devices SET payload_json = ?, updated_at = ? WHERE device_id = ? AND vault_id = ?',
      [
        jsonEncode({'status': 'revoked'}),
        DateTime.now().toUtc().millisecondsSinceEpoch,
        deviceId,
        vaultId,
      ],
    );
  }

  Future<Map<String, Uint8List>> readTrustedDevicePublicKeys({
    required String vaultId,
  }) async {
    final rows = _database.select(
      'SELECT device_id, payload_json FROM devices WHERE vault_id = ?',
      [vaultId],
    );
    final trusted = <String, Uint8List>{};
    for (final row in rows) {
      final payload = jsonDecode(row['payload_json']! as String);
      if (payload is! Map<String, dynamic> || payload['status'] != 'active') {
        continue;
      }
      final encoded = payload['signingPublicKey'];
      if (encoded is! String) continue;
      try {
        final padding = '=' * ((4 - encoded.length % 4) % 4);
        final key = Uint8List.fromList(base64Url.decode('$encoded$padding'));
        if (key.length == 32) trusted[row['device_id']! as String] = key;
      } on FormatException {
        // Corrupt local records are not trusted; pairing must repair them.
      }
    }
    return Map.unmodifiable(trusted);
  }

  Future<void> releaseProfileLock({
    required String profileId,
    required String owner,
  }) async {
    _database.execute(
      'DELETE FROM profile_locks WHERE profile_id = ? AND owner = ?',
      [profileId, owner],
    );
  }

  Future<void> close() async => _database.close();

  void _migrate() {
    final version =
        _database.select('PRAGMA user_version').single.values.single as int;
    if (version >= _schemaVersion) return;

    _database.execute('BEGIN IMMEDIATE');
    try {
      if (version < 1) {
        for (final statement in _v1Schema) {
          _database.execute(statement);
        }
        _database.execute(
          'INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)',
          [1, DateTime.now().toUtc().millisecondsSinceEpoch],
        );
        _database.execute('PRAGMA user_version = 1');
      }
      if (version < 2) {
        for (final statement in _v2Schema) {
          _database.execute(statement);
        }
        _database.execute(
          'INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)',
          [2, DateTime.now().toUtc().millisecondsSinceEpoch],
        );
        _database.execute('PRAGMA user_version = 2');
      }
      if (version < 3) {
        for (final statement in _v3Schema) {
          _database.execute(statement);
        }
        _database.execute(
          'INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)',
          [3, DateTime.now().toUtc().millisecondsSinceEpoch],
        );
        _database.execute('PRAGMA user_version = 3');
      }
      if (version < 4) {
        for (final statement in _v4Schema) {
          _database.execute(statement);
        }
        _database.execute(
          'INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)',
          [4, DateTime.now().toUtc().millisecondsSinceEpoch],
        );
        _database.execute('PRAGMA user_version = 4');
      }
      if (version < 5) {
        for (final statement in _v5Schema) {
          _database.execute(statement);
        }
        _database.execute(
          'INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)',
          [5, DateTime.now().toUtc().millisecondsSinceEpoch],
        );
        _database.execute('PRAGMA user_version = 5');
      }
      if (version < 6) {
        for (final statement in _v6Schema) {
          _database.execute(statement);
        }
        _database.execute(
          'INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)',
          [6, DateTime.now().toUtc().millisecondsSinceEpoch],
        );
        _database.execute('PRAGMA user_version = 6');
      }
      if (version < 7) {
        for (final statement in _v7Schema) {
          _database.execute(statement);
        }
        _database.execute(
          'INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)',
          [7, DateTime.now().toUtc().millisecondsSinceEpoch],
        );
        _database.execute('PRAGMA user_version = 7');
      }
      if (version < 8) {
        for (final statement in _v8Schema) {
          _database.execute(statement);
        }
        _database.execute(
          'INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)',
          [8, DateTime.now().toUtc().millisecondsSinceEpoch],
        );
        _database.execute('PRAGMA user_version = 8');
      }
      if (version < 9) {
        for (final statement in _v9Schema) {
          _database.execute(statement);
        }
        _database.execute(
          'INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)',
          [9, DateTime.now().toUtc().millisecondsSinceEpoch],
        );
        _database.execute('PRAGMA user_version = 9');
      }
      _database.execute('COMMIT');
    } on Object {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }
}

const _v1Schema = <String>[
  'CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL)',
  'CREATE TABLE IF NOT EXISTS connections (id TEXT PRIMARY KEY, payload_json TEXT NOT NULL, updated_at INTEGER NOT NULL)',
  'CREATE TABLE IF NOT EXISTS provider_credentials_ref (credential_ref TEXT PRIMARY KEY, provider_type TEXT NOT NULL, created_at INTEGER NOT NULL)',
  'CREATE TABLE IF NOT EXISTS remote_targets (target_id TEXT PRIMARY KEY, provider_type TEXT NOT NULL, credential_ref TEXT NOT NULL, payload_json TEXT NOT NULL, updated_at INTEGER NOT NULL)',
  'CREATE TABLE IF NOT EXISTS datasets (dataset_id TEXT PRIMARY KEY, vault_id TEXT NOT NULL, kind TEXT NOT NULL, payload_json TEXT NOT NULL, updated_at INTEGER NOT NULL)',
  'CREATE TABLE IF NOT EXISTS sync_profiles (profile_id TEXT PRIMARY KEY, dataset_id TEXT NOT NULL, target_id TEXT NOT NULL, vault_id TEXT NOT NULL, state TEXT NOT NULL, payload_json TEXT NOT NULL, updated_at INTEGER NOT NULL)',
  'CREATE TABLE IF NOT EXISTS profile_locks (profile_id TEXT PRIMARY KEY, owner TEXT NOT NULL, acquired_at INTEGER NOT NULL, heartbeat_at INTEGER NOT NULL)',
  'CREATE TABLE IF NOT EXISTS devices (device_id TEXT PRIMARY KEY, vault_id TEXT NOT NULL, payload_json TEXT NOT NULL, updated_at INTEGER NOT NULL)',
  'CREATE TABLE IF NOT EXISTS sync_cursors (profile_id TEXT NOT NULL, producer_device_id TEXT NOT NULL, applied_sequence INTEGER NOT NULL, PRIMARY KEY(profile_id, producer_device_id))',
  'CREATE TABLE IF NOT EXISTS sync_runs (run_id TEXT PRIMARY KEY, profile_id TEXT NOT NULL, state TEXT NOT NULL, started_at INTEGER NOT NULL, completed_at INTEGER, error_code TEXT)',
  'CREATE TABLE IF NOT EXISTS transfer_jobs (transfer_id TEXT PRIMARY KEY, profile_id TEXT NOT NULL, direction TEXT NOT NULL, logical_key TEXT NOT NULL, state TEXT NOT NULL, expected_size INTEGER, completed_bytes INTEGER NOT NULL DEFAULT 0, expected_hash TEXT, retry_count INTEGER NOT NULL DEFAULT 0, next_retry_at INTEGER, provider_checkpoint TEXT, error_code TEXT)',
  'CREATE TABLE IF NOT EXISTS remote_objects (profile_id TEXT NOT NULL, logical_key TEXT NOT NULL, provider_ref TEXT, etag TEXT, size INTEGER, hash TEXT, updated_at INTEGER, PRIMARY KEY(profile_id, logical_key))',
  'CREATE TABLE IF NOT EXISTS incoming_batches (profile_id TEXT NOT NULL, source_device_id TEXT NOT NULL, sequence INTEGER NOT NULL, batch_id TEXT NOT NULL, state TEXT NOT NULL, received_at INTEGER NOT NULL, PRIMARY KEY(profile_id, source_device_id, sequence, batch_id))',
  'CREATE TABLE IF NOT EXISTS outgoing_batches (profile_id TEXT NOT NULL, batch_id TEXT NOT NULL, sequence INTEGER NOT NULL, state TEXT NOT NULL, created_at INTEGER NOT NULL, published_at INTEGER, PRIMARY KEY(profile_id, batch_id))',
  'CREATE TABLE IF NOT EXISTS conflicts (conflict_id TEXT PRIMARY KEY, profile_id TEXT NOT NULL, entity_id TEXT NOT NULL, state TEXT NOT NULL, protected_details BLOB, created_at INTEGER NOT NULL, resolved_at INTEGER)',
  'CREATE TABLE IF NOT EXISTS scan_entries (dataset_id TEXT NOT NULL, entity_id TEXT NOT NULL, relative_path TEXT NOT NULL, metadata_json TEXT NOT NULL, scan_generation INTEGER NOT NULL, deleted_at INTEGER, PRIMARY KEY(dataset_id, entity_id), UNIQUE(dataset_id, relative_path))',
];

const _v2Schema = <String>[
  'CREATE TABLE IF NOT EXISTS scan_generations (dataset_id TEXT PRIMARY KEY, last_generation INTEGER NOT NULL)',
];

const _v3Schema = <String>[
  'CREATE TABLE IF NOT EXISTS outgoing_sequences (profile_id TEXT NOT NULL, source_device_id TEXT NOT NULL, published_sequence INTEGER NOT NULL, PRIMARY KEY(profile_id, source_device_id))',
  'CREATE TABLE IF NOT EXISTS outgoing_sequence_reservations (profile_id TEXT NOT NULL, source_device_id TEXT NOT NULL, sequence INTEGER NOT NULL, batch_id TEXT NOT NULL, created_at INTEGER NOT NULL, PRIMARY KEY(profile_id, source_device_id))',
];

const _v4Schema = <String>[
  'ALTER TABLE scan_entries ADD COLUMN pending_generation INTEGER',
];

const _v5Schema = <String>[
  'CREATE TABLE IF NOT EXISTS folder_entity_sync_state (dataset_id TEXT NOT NULL, entity_id TEXT NOT NULL, revision_id TEXT NOT NULL, version_json TEXT NOT NULL, is_tombstone INTEGER NOT NULL, updated_at INTEGER NOT NULL, PRIMARY KEY(dataset_id, entity_id))',
  'CREATE TABLE IF NOT EXISTS applied_folder_operations (dataset_id TEXT NOT NULL, operation_id TEXT NOT NULL, entity_id TEXT NOT NULL, batch_id TEXT NOT NULL, applied_at INTEGER NOT NULL, PRIMARY KEY(dataset_id, operation_id))',
];

const _v6Schema = <String>[
  'ALTER TABLE conflicts ADD COLUMN source_device_id TEXT',
];

const _v7Schema = <String>[
  'ALTER TABLE sync_runs ADD COLUMN error_category TEXT',
  'ALTER TABLE sync_runs ADD COLUMN retryable INTEGER',
  'ALTER TABLE sync_runs ADD COLUMN retry_after_ms INTEGER',
  'ALTER TABLE sync_runs ADD COLUMN suggested_action TEXT',
  'ALTER TABLE sync_runs ADD COLUMN provider_status_code INTEGER',
];

const _v8Schema = <String>[
  'CREATE TABLE IF NOT EXISTS velock_pairing_challenges (challenge_digest TEXT PRIMARY KEY, consumed_at INTEGER NOT NULL)',
];

const _v9Schema = <String>[
  'CREATE TABLE IF NOT EXISTS conflict_resolution_intents (conflict_id TEXT PRIMARY KEY, strategy TEXT NOT NULL, state TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, lease_owner TEXT, lease_expires_at INTEGER, error_code TEXT, receipt_artifact TEXT)',
];

class OutgoingBatchReservation {
  const OutgoingBatchReservation({
    required this.sequence,
    required this.batchId,
    required this.isRecovered,
  });

  final int sequence;
  final String batchId;
  final bool isRecovered;
}

class PublishedOutgoingBatchReference {
  const PublishedOutgoingBatchReference({
    required this.batchId,
    required this.sequence,
  });

  final String batchId;
  final int sequence;
}

class SyncRunRecord {
  const SyncRunRecord({
    required this.runId,
    required this.profileId,
    required this.state,
    required this.startedAt,
    required this.completedAt,
    required this.errorCode,
    required this.errorCategory,
    required this.retryable,
    required this.retryAfter,
    required this.suggestedAction,
    required this.providerStatusCode,
  });

  final String runId;
  final String profileId;
  final String state;
  final DateTime startedAt;
  final DateTime? completedAt;
  final String? errorCode;
  final String? errorCategory;
  final bool? retryable;
  final Duration? retryAfter;
  final String? suggestedAction;
  final int? providerStatusCode;
}

class SyncProfileActivitySummary {
  const SyncProfileActivitySummary({
    required this.latestRun,
    required this.pendingUploadCount,
    required this.pendingDownloadCount,
    required this.transferredBytes,
    required this.unresolvedConflictCount,
  });

  final SyncRunRecord? latestRun;
  final int pendingUploadCount;
  final int pendingDownloadCount;
  final int transferredBytes;
  final int unresolvedConflictCount;
}

class SyncProfilePayloadRecord {
  const SyncProfilePayloadRecord({
    required this.profileId,
    required this.state,
    required this.payload,
  });

  final String profileId;
  final String state;
  final String payload;
}

enum TransferJobDirection { upload, download }

enum TransferJobState {
  queued,
  running,
  paused,
  retryWaiting,
  completed,
  failed,
  cancelled,
}

class TransferJobRecord {
  const TransferJobRecord({
    required this.transferId,
    required this.profileId,
    required this.direction,
    required this.state,
    required this.logicalKey,
    required this.expectedSize,
    required this.completedBytes,
    required this.expectedHash,
    required this.retryCount,
    required this.nextRetryAt,
    required this.providerCheckpoint,
    required this.errorCode,
  });

  final String transferId;
  final String profileId;
  final TransferJobDirection direction;
  final TransferJobState state;
  final String logicalKey;
  final int? expectedSize;
  final int completedBytes;
  final String? expectedHash;
  final int retryCount;
  final DateTime? nextRetryAt;
  final String? providerCheckpoint;
  final String? errorCode;
}

class SyncConflictRecord {
  const SyncConflictRecord({
    required this.conflictId,
    required this.profileId,
    required this.entityId,
    required this.sourceDeviceId,
    required this.type,
    required this.protectedDetails,
    required this.createdAt,
  });

  final String conflictId;
  final String profileId;
  final String entityId;
  final String? sourceDeviceId;
  final String type;

  /// Local-only metadata for a dataset resolver. UI must never render it.
  final String? protectedDetails;
  final DateTime createdAt;
}

enum ConflictResolutionIntentState { running, retryable, completed }

class ConflictResolutionIntentAcquisition {
  const ConflictResolutionIntentAcquisition._(this.status);

  const ConflictResolutionIntentAcquisition.acquired()
    : this._(ConflictResolutionIntentAcquisitionStatus.acquired);
  const ConflictResolutionIntentAcquisition.completed()
    : this._(ConflictResolutionIntentAcquisitionStatus.completed);
  const ConflictResolutionIntentAcquisition.inProgress()
    : this._(ConflictResolutionIntentAcquisitionStatus.inProgress);
  const ConflictResolutionIntentAcquisition.strategyMismatch()
    : this._(ConflictResolutionIntentAcquisitionStatus.strategyMismatch);
  const ConflictResolutionIntentAcquisition.missing()
    : this._(ConflictResolutionIntentAcquisitionStatus.missing);

  final ConflictResolutionIntentAcquisitionStatus status;
}

enum ConflictResolutionIntentAcquisitionStatus {
  acquired,
  completed,
  inProgress,
  strategyMismatch,
  missing,
}

class ConflictResolutionIntentRecord {
  const ConflictResolutionIntentRecord({
    required this.conflictId,
    required this.strategy,
    required this.state,
    required this.createdAt,
    required this.updatedAt,
    required this.leaseOwner,
    required this.leaseExpiresAt,
    required this.errorCode,
    required this.receiptArtifact,
  });

  final String conflictId;
  final String strategy;
  final ConflictResolutionIntentState state;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? leaseOwner;
  final DateTime? leaseExpiresAt;
  final String? errorCode;
  final String? receiptArtifact;
}

class FolderEntitySyncState {
  const FolderEntitySyncState({
    required this.entityId,
    required this.revisionId,
    required this.versionVector,
    required this.isTombstone,
  });

  final String entityId;
  final String revisionId;
  final VersionVector versionVector;
  final bool isTombstone;
}

DateTime? _dateFromMillis(int? value) => value == null
    ? null
    : DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);

Duration? _durationFromMillis(int? value) =>
    value == null ? null : Duration(milliseconds: value);

bool? _boolFromSql(int? value) => value == null ? null : value != 0;
