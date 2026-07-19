import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/engine/sync_download_engine.dart';
import 'package:velock_sync/sync_core/engine/sync_profile_runner.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';

class SyncProfileExecutionRequest {
  const SyncProfileExecutionRequest({
    required this.profile,
    this.uploadLimits = const BatchLimits(),
    this.downloadLimits = const DownloadLimits(),
  });

  final SyncProfileEnvelope profile;
  final BatchLimits uploadLimits;
  final DownloadLimits downloadLimits;
}

abstract interface class SyncProfileExecutor {
  SyncDatasetKind get kind;

  Future<SyncProfileRunResult> run(SyncProfileExecutionRequest request);
}
