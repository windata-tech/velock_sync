/// Privacy-safe activity projections for the profile list and the backup-health view: aggregate counts and sizes only.
library;

import 'package:sqlite3/sqlite3.dart';

import 'package:velock_sync/infrastructure/database/sync_state_records.dart';

final class ActivityQueries {
  const ActivityQueries(this.db, this.latestRun);

  final Database db;

  /// Latest-run lookup owned by the runs module; injected so the activity
  /// projection never duplicates that query.
  final Future<SyncRunRecord?> Function(String profileId) latestRun;

  /// A privacy-safe status projection for the profile list. It intentionally
  /// contains counts and normalized run state only: neither paths, filenames,
  /// credentials, nor provider response bodies are queried for UI display.
  Future<SyncProfileActivitySummary> readSyncProfileActivity(
    String profileId,
  ) async {
    final run = await latestRun(profileId);
    final transferRows = db.select(
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
    final conflictRows = db.select(
      'SELECT COUNT(*) AS count FROM conflicts '
      'WHERE profile_id = ? AND resolved_at IS NULL',
      [profileId],
    );
    return SyncProfileActivitySummary(
      latestRun: run,
      pendingUploadCount: pendingUploadCount,
      pendingDownloadCount: pendingDownloadCount,
      transferredBytes: transferredBytes,
      unresolvedConflictCount: conflictRows.single['count']! as int,
    );
  }

  /// Privacy-safe inventory of what this profile has already moved.
  ///
  /// Only aggregate counts, sizes and opaque device ids leave this method —
  /// logical keys and provider paths never reach the UI.
  Future<SyncedDataSnapshot> readSyncedDataSnapshot(String profileId) async {
    const kindExpression =
        'CASE '
        "WHEN logical_key LIKE '%/blobs/%' THEN 'blobs' "
        "WHEN logical_key LIKE '%/batches/%' THEN 'batches' "
        "WHEN logical_key LIKE '%/commits/%' THEN 'commits' "
        "WHEN logical_key LIKE '%/checkpoints/%' THEN 'checkpoints' "
        "WHEN logical_key LIKE '%/acknowledgements/%' THEN 'acknowledgements' "
        "WHEN logical_key LIKE '%/members/%' OR logical_key LIKE '%/join-%' "
        "OR logical_key LIKE '%/protocol.json' THEN 'protocol' "
        "WHEN logical_key LIKE '%/retention/%' OR logical_key LIKE '%/gc/%' "
        "THEN 'maintenance' "
        "ELSE 'other' END";

    final transferRows = db.select(
      'SELECT direction, $kindExpression AS kind, COUNT(*) AS count, '
      'COALESCE(SUM(COALESCE(expected_size, completed_bytes, 0)), 0) AS bytes '
      'FROM transfer_jobs WHERE profile_id = ? AND state = ? '
      'GROUP BY direction, kind',
      [profileId, TransferJobState.completed.name],
    );
    final uploadedKinds = <SyncedDataKind>[];
    final downloadedKinds = <SyncedDataKind>[];
    var uploadedCount = 0;
    var uploadedBytes = 0;
    var downloadedCount = 0;
    var downloadedBytes = 0;
    for (final row in transferRows) {
      final entry = SyncedDataKind(
        kind: row['kind']! as String,
        count: row['count']! as int,
        bytes: row['bytes']! as int,
      );
      if (row['direction'] == TransferJobDirection.upload.name) {
        uploadedCount += entry.count;
        uploadedBytes += entry.bytes;
        uploadedKinds.add(entry);
      } else {
        downloadedCount += entry.count;
        downloadedBytes += entry.bytes;
        downloadedKinds.add(entry);
      }
    }

    final pendingRows = db.select(
      'SELECT direction, COUNT(*) AS count FROM transfer_jobs '
      "WHERE profile_id = ? AND state IN ('queued', 'running', 'paused', "
      "'retryWaiting') GROUP BY direction",
      [profileId],
    );
    var pendingUploadCount = 0;
    var pendingDownloadCount = 0;
    for (final row in pendingRows) {
      final count = row['count']! as int;
      if (row['direction'] == TransferJobDirection.upload.name) {
        pendingUploadCount += count;
      } else {
        pendingDownloadCount += count;
      }
    }

    final incomingRows = db.select(
      'SELECT state, COUNT(*) AS count, MAX(received_at) AS last_at '
      'FROM incoming_batches WHERE profile_id = ? GROUP BY state',
      [profileId],
    );
    var appliedIncomingCount = 0;
    var pendingIncomingCount = 0;
    int? incomingLastAt;
    for (final row in incomingRows) {
      final count = row['count']! as int;
      final lastAt = row['last_at'] as int?;
      if (lastAt != null) {
        incomingLastAt = incomingLastAt == null
            ? lastAt
            : (lastAt > incomingLastAt ? lastAt : incomingLastAt);
      }
      if (row['state'] == 'imported') {
        appliedIncomingCount += count;
      } else {
        pendingIncomingCount += count;
      }
    }

    final outgoingRows = db.select(
      'SELECT state, COUNT(*) AS count, '
      'MAX(COALESCE(published_at, created_at)) AS last_at '
      'FROM outgoing_batches WHERE profile_id = ? GROUP BY state',
      [profileId],
    );
    var publishedOutgoingCount = 0;
    var pendingOutgoingCount = 0;
    int? outgoingLastAt;
    for (final row in outgoingRows) {
      final count = row['count']! as int;
      final lastAt = row['last_at'] as int?;
      if (lastAt != null) {
        outgoingLastAt = outgoingLastAt == null
            ? lastAt
            : (lastAt > outgoingLastAt ? lastAt : outgoingLastAt);
      }
      if (row['state'] == 'published') {
        publishedOutgoingCount += count;
      } else {
        pendingOutgoingCount += count;
      }
    }

    final deviceRows = db.select(
      'SELECT producer_device_id, applied_sequence FROM sync_cursors '
      'WHERE profile_id = ? ORDER BY producer_device_id',
      [profileId],
    );

    return SyncedDataSnapshot(
      uploadedKinds: uploadedKinds,
      uploadedCount: uploadedCount,
      uploadedBytes: uploadedBytes,
      downloadedKinds: downloadedKinds,
      downloadedCount: downloadedCount,
      downloadedBytes: downloadedBytes,
      pendingUploadCount: pendingUploadCount,
      pendingDownloadCount: pendingDownloadCount,
      appliedIncomingCount: appliedIncomingCount,
      pendingIncomingCount: pendingIncomingCount,
      incomingLastReceivedAt: incomingLastAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(incomingLastAt, isUtc: true),
      publishedOutgoingCount: publishedOutgoingCount,
      pendingOutgoingCount: pendingOutgoingCount,
      outgoingLastPublishedAt: outgoingLastAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(outgoingLastAt, isUtc: true),
      devices: [
        for (final row in deviceRows)
          SyncedDataDevice(
            deviceId: row['producer_device_id']! as String,
            appliedSequence: row['applied_sequence']! as int,
          ),
      ],
    );
  }
}
