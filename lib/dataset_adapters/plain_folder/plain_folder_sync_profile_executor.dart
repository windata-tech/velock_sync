import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_service.dart';
import 'package:velock_sync/sync_core/engine/sync_download_engine.dart';
import 'package:velock_sync/sync_core/engine/sync_profile_runner.dart';
import 'package:velock_sync/sync_core/engine/sync_upload_engine.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_executor.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';

/// Adapts the plain folder mirror to the common profile dispatcher, so the
/// foreground, resume and background paths all execute the same engine.
///
/// Mirror runs count files, not protocol batches: the shared run result keeps
/// those counts so generic surfaces stay truthful about what moved.
class PlainFolderSyncProfileExecutor implements SyncProfileExecutor {
  const PlainFolderSyncProfileExecutor(this._service);

  final PlainFolderSyncService _service;

  @override
  SyncDatasetKind get kind => SyncDatasetKind.plainFolder;

  @override
  Future<SyncProfileRunResult> run(SyncProfileExecutionRequest request) async {
    final outcome = await _service.run(request.profile.profileId);
    return SyncProfileRunResult(
      runId: outcome.stats.runId,
      upload: outcome.stats.uploadedFileCount == 0
          ? const UploadRunResult.idle()
          : UploadRunResult.summary(
              batchId: null,
              uploadedBlobCount: outcome.stats.uploadedFileCount,
              publishedBatchCount: outcome.stats.uploadedFileCount,
            ),
      download: DownloadRunResult(outcome.stats.downloadedFileCount),
    );
  }
}
