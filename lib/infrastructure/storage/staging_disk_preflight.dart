import 'dart:io';

import 'package:velock_sync/infrastructure/storage/available_space_probe.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';

/// Ensures there is a safety margin before a sync starts writing staged data.
class StagingDiskPreflight {
  const StagingDiskPreflight(
    this._availableSpace, {
    this.minimumFreeBytes = 64 * 1024 * 1024,
  }) : assert(minimumFreeBytes > 0);

  final AvailableSpaceProbe _availableSpace;
  final int minimumFreeBytes;

  Future<void> ensureAvailable(Directory stagingRoot) async {
    await stagingRoot.create(recursive: true);
    final available = await _availableSpace.availableBytes(stagingRoot);
    if (available < minimumFreeBytes) {
      throw const StagingDiskSpaceException();
    }
  }
}

class StagingDiskSpaceException implements SyncFailureException {
  const StagingDiskSpaceException();

  @override
  SyncFailure get syncFailure => const SyncFailure(
    errorCode: 'staging.insufficient_space',
    category: SyncErrorCategory.insufficientSpace,
    retryable: true,
    suggestedAction: '释放本地存储空间后重试。',
  );
}
