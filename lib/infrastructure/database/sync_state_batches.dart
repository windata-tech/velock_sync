/// Outgoing/incoming batch reservations, publication and applied sequence bookkeeping.
library;

import 'package:sqlite3/sqlite3.dart';

import 'package:velock_sync/infrastructure/database/sync_state_records.dart';

final class BatchQueries {
  const BatchQueries(this.db);

  final Database db;

  Future<void> recordOutgoingBatch({
    required String profileId,
    required String batchId,
    required int sequence,
    required String state,
  }) async {
    db.execute(
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
    db.execute(
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
    db.execute('BEGIN IMMEDIATE');
    try {
      final existing = db.select(
        'SELECT sequence, batch_id FROM outgoing_sequence_reservations '
        'WHERE profile_id = ? AND source_device_id = ?',
        [profileId, sourceDeviceId],
      );
      if (existing.isNotEmpty) {
        db.execute('COMMIT');
        return OutgoingBatchReservation(
          sequence: existing.single['sequence']! as int,
          batchId: existing.single['batch_id']! as String,
          isRecovered: true,
        );
      }
      final published = db.select(
        'SELECT published_sequence FROM outgoing_sequences '
        'WHERE profile_id = ? AND source_device_id = ?',
        [profileId, sourceDeviceId],
      );
      final sequence = published.isEmpty
          ? 1
          : (published.single['published_sequence']! as int) + 1;
      db.execute(
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
      db.execute('COMMIT');
      return OutgoingBatchReservation(
        sequence: sequence,
        batchId: newBatchId,
        isRecovered: false,
      );
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<void> markOutgoingSequencePublished({
    required String profileId,
    required String sourceDeviceId,
    required int sequence,
    required String batchId,
  }) async {
    db.execute('BEGIN IMMEDIATE');
    try {
      final reservation = db.select(
        'SELECT sequence, batch_id FROM outgoing_sequence_reservations '
        'WHERE profile_id = ? AND source_device_id = ?',
        [profileId, sourceDeviceId],
      );
      if (reservation.isEmpty) {
        final published = db.select(
          'SELECT published_sequence FROM outgoing_sequences '
          'WHERE profile_id = ? AND source_device_id = ?',
          [profileId, sourceDeviceId],
        );
        if (published.isNotEmpty &&
            published.single['published_sequence'] == sequence) {
          db.execute('COMMIT');
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
      db.execute(
        'INSERT INTO outgoing_sequences (profile_id, source_device_id, published_sequence) VALUES (?, ?, ?) '
        'ON CONFLICT(profile_id, source_device_id) DO UPDATE SET published_sequence = excluded.published_sequence',
        [profileId, sourceDeviceId, sequence],
      );
      db.execute(
        'DELETE FROM outgoing_sequence_reservations '
        'WHERE profile_id = ? AND source_device_id = ?',
        [profileId, sourceDeviceId],
      );
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
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
    final result = db.select(
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
    final rows = db.select(
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
    final rows = db.select(
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
    db.execute(
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
    final rows = db.select(
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
    final rows = db.select(
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
    db.execute(
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
    db.execute('BEGIN IMMEDIATE');
    try {
      for (final entry in coveredSequences.entries) {
        if (entry.key.isEmpty || entry.value < 0) {
          throw ArgumentError.value(coveredSequences, 'coveredSequences');
        }
        final rows = db.select(
          'SELECT applied_sequence FROM sync_cursors WHERE profile_id = ? AND producer_device_id = ?',
          [profileId, entry.key],
        );
        final current = rows.isEmpty
            ? 0
            : rows.single['applied_sequence']! as int;
        if (entry.value <= current) continue;
        db.execute(
          'INSERT INTO sync_cursors (profile_id, producer_device_id, applied_sequence) VALUES (?, ?, ?) '
          'ON CONFLICT(profile_id, producer_device_id) DO UPDATE SET applied_sequence = excluded.applied_sequence',
          [profileId, entry.key, entry.value],
        );
      }
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
}
