import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';

/// Reads and safely reclaims app-private selected-folder staging storage.
///
/// Recoverable batches always have an atomically-written `manifest.json`; this
/// manager preserves them. It only removes abandoned batch directories with no
/// manifest and same-directory temporary artifacts, while holding the profile
/// lock so it cannot race an active sync.
class StagingSpaceManager {
  StagingSpaceManager(
    this._database, {
    Uuid? uuid,
    DateTime Function()? now,
    this.lockLease = const Duration(minutes: 5),
  }) : _uuid = uuid ?? const Uuid(),
       _now = now ?? DateTime.now;

  final SyncStateDatabase _database;
  final Uuid _uuid;
  final DateTime Function() _now;
  final Duration lockLease;

  Future<StagingSpaceSummary> inspect(Directory profileStagingRoot) async {
    if (!await profileStagingRoot.exists()) {
      return const StagingSpaceSummary();
    }
    var totalBytes = 0;
    var fileCount = 0;
    var batchCount = 0;
    await for (final child in profileStagingRoot.list(followLinks: false)) {
      if (child is Directory) {
        batchCount++;
      }
    }
    await for (final entity in profileStagingRoot.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      totalBytes += await entity.length();
      fileCount++;
    }
    return StagingSpaceSummary(
      totalBytes: totalBytes,
      fileCount: fileCount,
      batchCount: batchCount,
    );
  }

  Future<StagingCleanupResult> safelyCleanup({
    required String profileId,
    required Directory profileStagingRoot,
  }) async {
    final owner = 'staging-cleanup/${_uuid.v4()}';
    final acquired = await _database.tryAcquireProfileLock(
      profileId: profileId,
      owner: owner,
      now: _now(),
      staleAfter: lockLease,
    );
    if (!acquired) throw const StagingMaintenanceBusyException();
    try {
      if (!await profileStagingRoot.exists()) {
        return const StagingCleanupResult();
      }
      var freedBytes = 0;
      var removedBatchCount = 0;
      var removedTemporaryFileCount = 0;
      var preservedRecoverableBatchCount = 0;
      final children = await profileStagingRoot
          .list(followLinks: false)
          .toList();
      for (final child in children) {
        if (child is! Directory) continue;
        final manifest = File(p.join(child.path, 'manifest.json'));
        if (!await manifest.exists()) {
          freedBytes += await _directoryBytes(child);
          await child.delete(recursive: true);
          removedBatchCount++;
          continue;
        }
        preservedRecoverableBatchCount++;
        await for (final entity in child.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is! File || !p.basename(entity.path).contains('.tmp-')) {
            continue;
          }
          freedBytes += await entity.length();
          await entity.delete();
          removedTemporaryFileCount++;
        }
      }
      return StagingCleanupResult(
        freedBytes: freedBytes,
        removedBatchCount: removedBatchCount,
        removedTemporaryFileCount: removedTemporaryFileCount,
        preservedRecoverableBatchCount: preservedRecoverableBatchCount,
      );
    } finally {
      await _database.releaseProfileLock(profileId: profileId, owner: owner);
    }
  }

  static Future<int> _directoryBytes(Directory directory) async {
    var total = 0;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }
}

class StagingSpaceSummary {
  const StagingSpaceSummary({
    this.totalBytes = 0,
    this.fileCount = 0,
    this.batchCount = 0,
  });

  final int totalBytes;
  final int fileCount;
  final int batchCount;
}

class StagingCleanupResult {
  const StagingCleanupResult({
    this.freedBytes = 0,
    this.removedBatchCount = 0,
    this.removedTemporaryFileCount = 0,
    this.preservedRecoverableBatchCount = 0,
  });

  final int freedBytes;
  final int removedBatchCount;
  final int removedTemporaryFileCount;
  final int preservedRecoverableBatchCount;
}

class StagingMaintenanceBusyException implements SyncFailureException {
  const StagingMaintenanceBusyException();

  @override
  SyncFailure get syncFailure => const SyncFailure(
    errorCode: 'staging.maintenance_busy',
    category: SyncErrorCategory.userActionRequired,
    retryable: true,
    suggestedAction: '请等待当前同步完成后再清理暂存空间。',
  );
}
