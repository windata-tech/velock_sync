/// Sync profile envelope persistence and lifecycle state transitions.
library;

import 'dart:convert';

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

  /// Compare-and-swap only. A removed/stale profile cannot be resurrected by a
  /// late upload completion, including a change from another process.
  Future<bool> replaceSyncProfilePayloadIfCurrent({
    BackupRebuildCompletion? rebuild,
    required String profileId,
    required String expectedPayload,
    required String datasetId,
    required String targetId,
    required String vaultId,
    required String state,
    required String payload,
  }) async {
    db.execute('BEGIN IMMEDIATE');
    try {
      final rows = db.select(
        'SELECT state, payload_json FROM sync_profiles WHERE profile_id = ?',
        [profileId],
      );
      if (rows.length != 1 || rows.single['state'] != 'active') {
        db.execute('ROLLBACK');
        return false;
      }
      final previous = rows.single['payload_json']! as String;
      final decoded = jsonDecode(previous) as Map<String, dynamic>;
      decoded['state'] = rows.single['state'];
      if (jsonEncode(_orderedJson(decoded)) !=
          jsonEncode(_orderedJson(jsonDecode(expectedPayload)))) {
        db.execute('ROLLBACK');
        return false;
      }
      db.execute(
        'UPDATE sync_profiles SET dataset_id = ?, target_id = ?, vault_id = ?, state = ?, payload_json = ?, updated_at = ? '
        'WHERE profile_id = ? AND state = ? AND payload_json = ?',
        [
          datasetId,
          targetId,
          vaultId,
          state,
          payload,
          DateTime.now().toUtc().millisecondsSinceEpoch,
          profileId,
          'active',
          previous,
        ],
      );
      final changed = db.updatedRows == 1;
      if (changed && rebuild != null) {
        db.execute(
          'INSERT INTO sync_runs (run_id, profile_id, state, started_at, completed_at, rebuild_json) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(run_id) DO NOTHING',
          [
            rebuild.runId,
            profileId,
            'completed',
            rebuild.startedAt.toUtc().millisecondsSinceEpoch,
            rebuild.completedAt.toUtc().millisecondsSinceEpoch,
            rebuild.encode(),
          ],
        );
      }
      db.execute('COMMIT');
      return changed;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Retires [retiredProfileId] and inserts its replacement in one
  /// transaction, or changes nothing.
  ///
  /// The retired row must still be visible (any state except `removed`), hold
  /// exactly [expectedRetiredPayload] and have no running sync run. The
  /// replacement must be a new profile ID. Used by re-pairing, so a failed or
  /// abandoned pairing never leaves the device without its original profile.
  Future<bool> retireSyncProfileAndInsertReplacement({
    required String retiredProfileId,
    required String expectedRetiredPayload,
    required String profileId,
    required String datasetId,
    required String targetId,
    required String vaultId,
    required String state,
    required String payload,
  }) async {
    if (profileId == retiredProfileId) {
      throw ArgumentError.value(profileId, 'profileId', 'must be new');
    }
    db.execute('BEGIN IMMEDIATE');
    try {
      final rows = db.select(
        'SELECT state, payload_json FROM sync_profiles WHERE profile_id = ?',
        [retiredProfileId],
      );
      if (rows.length != 1 || rows.single['state'] == 'removed') {
        db.execute('ROLLBACK');
        return false;
      }
      final previous = rows.single['payload_json']! as String;
      final decoded = jsonDecode(previous) as Map<String, dynamic>;
      decoded['state'] = rows.single['state'];
      final running = db.select(
        'SELECT 1 FROM sync_runs WHERE profile_id = ? AND state = ? LIMIT 1',
        [retiredProfileId, 'running'],
      );
      final taken = db.select(
        'SELECT 1 FROM sync_profiles WHERE profile_id = ? LIMIT 1',
        [profileId],
      );
      if (running.isNotEmpty ||
          taken.isNotEmpty ||
          jsonEncode(_orderedJson(decoded)) !=
              jsonEncode(_orderedJson(jsonDecode(expectedRetiredPayload)))) {
        db.execute('ROLLBACK');
        return false;
      }
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      db.execute(
        'UPDATE sync_profiles SET state = ?, updated_at = ? '
        'WHERE profile_id = ? AND payload_json = ?',
        ['removed', now, retiredProfileId, previous],
      );
      if (db.updatedRows != 1) {
        db.execute('ROLLBACK');
        return false;
      }
      db.execute(
        'INSERT INTO sync_profiles (profile_id, dataset_id, target_id, vault_id, state, payload_json, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [profileId, datasetId, targetId, vaultId, state, payload, now],
      );
      db.execute('COMMIT');
      return true;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
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

Object? _orderedJson(Object? value) {
  if (value is Map<String, dynamic>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _orderedJson(value[key])};
  }
  if (value is List) return value.map(_orderedJson).toList();
  return value;
}
