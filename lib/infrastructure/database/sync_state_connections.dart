/// Connection payload storage (credential references only, never secrets).
library;

import 'package:sqlite3/sqlite3.dart';

final class ConnectionQueries {
  const ConnectionQueries(this.db);

  final Database db;

  Future<List<String>> readConnectionPayloads() async {
    final rows = db.select(
      'SELECT payload_json FROM connections ORDER BY updated_at ASC, id ASC',
    );
    return rows.map((row) => row['payload_json']! as String).toList();
  }

  Future<void> replaceConnectionPayloads(Map<String, String> payloads) async {
    db.execute('BEGIN IMMEDIATE');
    try {
      db.execute('DELETE FROM connections');
      final insert = db.prepare(
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
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
}
