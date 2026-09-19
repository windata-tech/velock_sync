/// Process-local profile locks with heartbeats.
library;

import 'package:sqlite3/sqlite3.dart';

final class LockQueries {
  const LockQueries(this.db);

  final Database db;

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
    db.execute('BEGIN IMMEDIATE');
    try {
      final current = db.select(
        'SELECT owner, heartbeat_at FROM profile_locks WHERE profile_id = ?',
        [profileId],
      );
      if (current.isEmpty ||
          current.single['owner'] == owner ||
          (current.single['heartbeat_at']! as int) < staleBefore) {
        db.execute(
          'INSERT INTO profile_locks (profile_id, owner, acquired_at, heartbeat_at) VALUES (?, ?, ?, ?) '
          'ON CONFLICT(profile_id) DO UPDATE SET owner = excluded.owner, acquired_at = excluded.acquired_at, heartbeat_at = excluded.heartbeat_at',
          [profileId, owner, nowMillis, nowMillis],
        );
        db.execute('COMMIT');
        return true;
      }
      db.execute('COMMIT');
      return false;
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<bool> heartbeatProfileLock({
    required String profileId,
    required String owner,
    required DateTime now,
  }) async {
    final result = db.select(
      'UPDATE profile_locks SET heartbeat_at = ? WHERE profile_id = ? AND owner = ? RETURNING profile_id',
      [now.toUtc().millisecondsSinceEpoch, profileId, owner],
    );
    return result.isNotEmpty;
  }

  Future<void> releaseProfileLock({
    required String profileId,
    required String owner,
  }) async {
    db.execute('DELETE FROM profile_locks WHERE profile_id = ? AND owner = ?', [
      profileId,
      owner,
    ]);
  }
}
