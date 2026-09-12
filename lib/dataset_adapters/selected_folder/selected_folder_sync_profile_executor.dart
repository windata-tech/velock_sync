import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_service.dart';
import 'package:velock_sync/sync_core/engine/sync_profile_runner.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_executor.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';

/// Adapts the existing Selected Folder orchestration to the common profile
/// dispatcher. The service remains the sole owner of SyncProfileRunner setup.
class SelectedFolderSyncProfileExecutor implements SyncProfileExecutor {
  const SelectedFolderSyncProfileExecutor(this._service);

  final SelectedFolderSyncService _service;

  @override
  SyncDatasetKind get kind => SyncDatasetKind.selectedFolder;

  @override
  Future<SyncProfileRunResult> run(SyncProfileExecutionRequest request) =>
      _service.run(
        request.profile.profileId,
        uploadLimits: request.uploadLimits,
        downloadLimits: request.downloadLimits,
      );
}
