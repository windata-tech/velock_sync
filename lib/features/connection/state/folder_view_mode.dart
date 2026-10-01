import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/app_repository.dart';
import 'package:velock_sync/core/local_data_manager.dart';

/// How remote folders are laid out: tiles in a grid, or rows in a list.
///
/// One choice for every folder screen (the connection browser and the folder
/// pickers), so switching in one place is what the user sees everywhere.
enum FolderViewMode {
  grid('grid'),
  list('list');

  const FolderViewMode(this.storageValue);
  final String storageValue;

  static FolderViewMode fromStored(String? value) =>
      value == list.storageValue ? list : grid;
}

/// Loaded once after local preferences initialize, before runApp.
final folderViewModeBootstrapProvider = Provider<FolderViewMode>(
  (ref) => FolderViewMode.grid,
);

final folderViewModeWriterProvider = Provider<Future<void> Function(String)>(
  (ref) =>
      (value) =>
          LocalDataManager.instance.setString(AppKeys.folderViewMode, value),
);

final folderViewModeProvider =
    NotifierProvider<FolderViewModeController, FolderViewMode>(
      FolderViewModeController.new,
    );

class FolderViewModeController extends Notifier<FolderViewMode> {
  @override
  FolderViewMode build() => ref.watch(folderViewModeBootstrapProvider);

  Future<void> toggle() => select(
    state == FolderViewMode.grid ? FolderViewMode.list : FolderViewMode.grid,
  );

  /// Switches at once; remembering the choice is best effort, a failed write
  /// only means the next launch opens with the previous layout.
  Future<void> select(FolderViewMode mode) async {
    state = mode;
    try {
      await ref.read(folderViewModeWriterProvider)(mode.storageValue);
    } on Object {
      /* the layout already switched for this session */
    }
  }
}
