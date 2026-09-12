import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_profile_executor.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_service.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile_executor.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_service.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_dispatcher.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

/// Builds the one executor registry used by foreground and background runs.
/// The dataset services keep ownership of their Sync Core orchestration; this
/// factory only prevents the two entry points from drifting into different
/// dispatcher compositions.
class SyncProfileDispatcherFactory {
  const SyncProfileDispatcherFactory._();

  static SyncProfileDispatcher create({
    required SyncProfileRepository profiles,
    required SelectedFolderSyncService selectedFolderService,
    required VelockSyncRunner velockService,
  }) => SyncProfileDispatcher(
    profiles: profiles,
    executors: [
      SelectedFolderSyncProfileExecutor(selectedFolderService),
      VelockSyncProfileExecutor(velockService),
    ],
  );
}
