/// Schema definitions and forward-only migrations for the sync state
/// database.
///
/// Migrations run inside one immediate transaction and are applied in order;
/// there are no downgrades. Version `10` was shipped before `11` exists in
/// some stores, so the blocks are deliberately independent.
library;

import 'package:sqlite3/sqlite3.dart';

const int kSyncStateSchemaVersion = 12;

void migrateSyncStateSchema(Database db, int targetVersion) {
  final version = db.select('PRAGMA user_version').single.values.single as int;
  if (version >= targetVersion) return;

  db.execute('BEGIN IMMEDIATE');
  try {
    if (version < 1) {
      for (final statement in _v1Schema) {
        db.execute(statement);
      }
      db.execute(
        'INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)',
        [1, DateTime.now().toUtc().millisecondsSinceEpoch],
      );
      db.execute('PRAGMA user_version = 1');
    }
    if (version < 2) {
      for (final statement in _v2Schema) {
        db.execute(statement);
      }
      db.execute(
        'INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)',
        [2, DateTime.now().toUtc().millisecondsSinceEpoch],
      );
      db.execute('PRAGMA user_version = 2');
    }
    if (version < 3) {
      for (final statement in _v3Schema) {
        db.execute(statement);
      }
      db.execute(
        'INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)',
        [3, DateTime.now().toUtc().millisecondsSinceEpoch],
      );
      db.execute('PRAGMA user_version = 3');
    }
    if (version < 4) {
      for (final statement in _v4Schema) {
        db.execute(statement);
      }
      db.execute(
        'INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)',
        [4, DateTime.now().toUtc().millisecondsSinceEpoch],
      );
      db.execute('PRAGMA user_version = 4');
    }
    if (version < 5) {
      for (final statement in _v5Schema) {
        db.execute(statement);
      }
      db.execute(
        'INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)',
        [5, DateTime.now().toUtc().millisecondsSinceEpoch],
      );
      db.execute('PRAGMA user_version = 5');
    }
    if (version < 6) {
      for (final statement in _v6Schema) {
        db.execute(statement);
      }
      db.execute(
        'INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)',
        [6, DateTime.now().toUtc().millisecondsSinceEpoch],
      );
      db.execute('PRAGMA user_version = 6');
    }
    if (version < 7) {
      for (final statement in _v7Schema) {
        db.execute(statement);
      }
      db.execute(
        'INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)',
        [7, DateTime.now().toUtc().millisecondsSinceEpoch],
      );
      db.execute('PRAGMA user_version = 7');
    }
    if (version < 8) {
      for (final statement in _v8Schema) {
        db.execute(statement);
      }
      db.execute(
        'INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)',
        [8, DateTime.now().toUtc().millisecondsSinceEpoch],
      );
      db.execute('PRAGMA user_version = 8');
    }
    if (version < 9) {
      for (final statement in _v9Schema) {
        db.execute(statement);
      }
      db.execute(
        'INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)',
        [9, DateTime.now().toUtc().millisecondsSinceEpoch],
      );
      db.execute('PRAGMA user_version = 9');
    }
    if (version < 10) {
      for (final statement in _v10Schema) {
        db.execute(statement);
      }
      db.execute(
        'INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)',
        [10, DateTime.now().toUtc().millisecondsSinceEpoch],
      );
      db.execute('PRAGMA user_version = 10');
    }
    if (version < 11) {
      final hasTransferJobs = db
          .select(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name = 'transfer_jobs'",
          )
          .isNotEmpty;
      if (hasTransferJobs) {
        for (final statement in _v11Schema) {
          db.execute(statement);
        }
      }
      db.execute(
        'INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)',
        [11, DateTime.now().toUtc().millisecondsSinceEpoch],
      );
      db.execute('PRAGMA user_version = 11');
    }
    if (version < 12) {
      for (final statement in _v12Schema) {
        db.execute(statement);
      }
      db.execute(
        'INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)',
        [12, DateTime.now().toUtc().millisecondsSinceEpoch],
      );
      db.execute('PRAGMA user_version = 12');
    }
    db.execute('COMMIT');
  } on Object catch (error, stackTrace) {
    db.execute('ROLLBACK');
    Error.throwWithStackTrace(error, stackTrace);
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

const _v11Schema = <String>[
  'ALTER TABLE transfer_jobs ADD COLUMN created_at INTEGER',
  'ALTER TABLE transfer_jobs ADD COLUMN completed_at INTEGER',
];

const _v10Schema = <String>[
  'CREATE TABLE IF NOT EXISTS garbage_collection_runs ('
      'run_id TEXT PRIMARY KEY, profile_id TEXT NOT NULL, vault_id TEXT NOT NULL, '
      'state TEXT NOT NULL, started_at INTEGER NOT NULL, completed_at INTEGER, '
      'checkpoint_id TEXT, retention_cutoff INTEGER, active_device_count INTEGER NOT NULL DEFAULT 0, '
      'unacked_device_count INTEGER NOT NULL DEFAULT 0, candidate_count INTEGER NOT NULL DEFAULT 0, '
      'eligible_candidate_count INTEGER NOT NULL DEFAULT 0, deleted_object_count INTEGER NOT NULL DEFAULT 0, '
      'retention_manifest_complete INTEGER, plan_id TEXT, skip_reason TEXT)',
  'CREATE INDEX IF NOT EXISTS idx_gc_runs_profile_started '
      'ON garbage_collection_runs(profile_id, started_at DESC)',
];

/// Plain folder mirror state: baseline metadata per path, the conflict log and
/// per-run counters. File content never enters this database.
const _v12Schema = <String>[
  'CREATE TABLE IF NOT EXISTS mirror_entries ('
      'profile_id TEXT NOT NULL, relative_path TEXT NOT NULL, kind TEXT NOT NULL, '
      'local_size INTEGER NOT NULL DEFAULT 0, local_mtime INTEGER, '
      'remote_size INTEGER NOT NULL DEFAULT 0, remote_mtime INTEGER, '
      'remote_etag TEXT, synced_at INTEGER NOT NULL, '
      'PRIMARY KEY (profile_id, relative_path))',
  'CREATE TABLE IF NOT EXISTS mirror_conflicts ('
      'conflict_id TEXT PRIMARY KEY, profile_id TEXT NOT NULL, '
      'relative_path TEXT NOT NULL, kind TEXT NOT NULL, resolution TEXT NOT NULL, '
      'detected_at INTEGER NOT NULL)',
  'CREATE INDEX IF NOT EXISTS idx_mirror_conflicts_profile '
      'ON mirror_conflicts(profile_id, detected_at DESC)',
  'CREATE TABLE IF NOT EXISTS mirror_run_stats ('
      'run_id TEXT PRIMARY KEY, profile_id TEXT NOT NULL, started_at INTEGER NOT NULL, '
      'finished_at INTEGER, uploaded_file_count INTEGER NOT NULL DEFAULT 0, '
      'downloaded_file_count INTEGER NOT NULL DEFAULT 0, '
      'deleted_local_count INTEGER NOT NULL DEFAULT 0, '
      'deleted_remote_count INTEGER NOT NULL DEFAULT 0, '
      'conflict_count INTEGER NOT NULL DEFAULT 0, '
      'held_deletion_count INTEGER NOT NULL DEFAULT 0, '
      'skipped_count INTEGER NOT NULL DEFAULT 0, '
      'bytes_transferred INTEGER NOT NULL DEFAULT 0, failure_code TEXT)',
  'CREATE INDEX IF NOT EXISTS idx_mirror_run_stats_profile '
      'ON mirror_run_stats(profile_id, started_at DESC)',
];
