import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_service.dart';
import 'package:velock_sync/sync_core/engine/sync_profile_runner.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_executor.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';

/// Registers the zero-knowledge Velock service with the common dispatcher.
class VelockSyncProfileExecutor implements SyncProfileExecutor {
  const VelockSyncProfileExecutor(this._service);

  final VelockSyncRunner _service;

  @override
  SyncDatasetKind get kind => SyncDatasetKind.velockManaged;

  @override
  Future<SyncProfileRunResult> run(SyncProfileExecutionRequest request) =>
      _service.run(
        request.profile.profileId,
        uploadLimits: request.uploadLimits,
        downloadLimits: request.downloadLimits,
      );
}
