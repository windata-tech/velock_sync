/// Sync profile envelope persistence and lifecycle state transitions.
library;

import 'package:sqlite3/sqlite3.dart';

import 'package:velock_sync/infrastructure/database/sync_state_records.dart';

final class ProfileQueries {
  const ProfileQueries(this.db);

  final Database db;

  Future<void> upsertSyncProfilePayload({
    required String profileId,
    required String datasetId,
    required String targetId,
    required String vaultId,
    required String state,
    required String payload,
  }) async {
    db.execute(
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
    db.execute(
      'INSERT INTO velock_pairing_challenges (challenge_digest, consumed_at) VALUES (?, ?) '
      'ON CONFLICT(challenge_digest) DO NOTHING',
      [challengeDigest, consumedAt.toUtc().millisecondsSinceEpoch],
    );
    final rows = db.select('SELECT changes() AS changed');
    return rows.single['changed']! as int == 1;
  }

  Future<String?> readSyncProfilePayload(String profileId) async {
    final rows = db.select(
      'SELECT payload_json FROM sync_profiles WHERE profile_id = ?',
      [profileId],
    );
    return rows.isEmpty ? null : rows.single['payload_json']! as String;
  }

  Future<List<SyncProfilePayloadRecord>>
  readVisibleSyncProfilePayloads() async {
    final rows = db.select(
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
    final rows = db.select(
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
    final changed = db.select(
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
    final rows = db.select(
      'SELECT payload_json FROM sync_profiles WHERE state = ? ORDER BY updated_at ASC, profile_id ASC',
      ['active'],
    );
    return rows.map((row) => row['payload_json']! as String).toList();
  }
}
