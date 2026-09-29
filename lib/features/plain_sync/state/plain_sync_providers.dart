import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/mirror_models.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_profile.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_service.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_access_authorizer.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';

final plainFolderProfilesProvider = Provider<PlainFolderSyncProfileRepository>(
  (ref) =>
      PlainFolderSyncProfileRepository(ref.watch(syncStateDatabaseProvider)),
);

/// Native folder picker, injectable so widget tests never touch a platform
/// channel.
final folderAccessAuthorizerProvider = Provider<FolderAccessAuthorizer>(
  (ref) => NativeFolderAccessAuthorizer(),
);

final plainFolderServiceProvider = Provider<PlainFolderSyncService>(
  (ref) => PlainFolderSyncService(
    database: ref.watch(syncStateDatabaseProvider),
    profiles: ref.watch(plainFolderProfilesProvider),
    connections: ref.watch(connectionRepositoryProvider),
  ),
);

/// Proves a remote folder exists and accepts a write before a location is
/// created. Injectable so the setup wizard can be tested without a provider.
typedef PlainRemoteWritableCheck =
    Future<void> Function({
      required String connectionId,
      required List<String> remoteRootSegments,
    });

final plainRemoteWritableCheckProvider = Provider<PlainRemoteWritableCheck>(
  (ref) =>
      ({required connectionId, required remoteRootSegments}) => ref
          .read(plainFolderServiceProvider)
          .checkRemoteWritableFor(
            connectionId: connectionId,
            remoteRootSegments: remoteRootSegments,
          ),
);

/// One plain sync location as the list and detail pages need it.
class PlainLocationView {
  const PlainLocationView({
    required this.profile,
    required this.connection,
    required this.stats,
    required this.conflictCount,
    required this.latestRunState,
    required this.latestRunFailureCode,
  });

  final PlainFolderSyncProfile profile;
  final ConnectionModel? connection;
  final MirrorRunStats? stats;
  final int conflictCount;
  final String? latestRunState;
  final String? latestRunFailureCode;

  String get remotePath => profile.remoteRootSegments.isEmpty
      ? '/'
      : '/${profile.remoteRootSegments.join('/')}';

  /// Empty when the connection row is gone: the list and detail pages render
  /// their own localized "connection deleted" line instead of a stored name.
  String get connectionName => connection?.name ?? '';

  bool get isRunning => latestRunState == 'running';

  bool get didFail => latestRunFailureCode != null;

  bool get hasHeldDeletions => (stats?.heldDeletionCount ?? 0) > 0;

  bool get hasConflicts => conflictCount > 0;

  bool get hasSyncedBefore => stats?.finishedAt != null;
}

final plainLocationViewsProvider = FutureProvider<List<PlainLocationView>>((
  ref,
) async {
  final database = ref.watch(syncStateDatabaseProvider);
  final profiles = await ref.watch(plainFolderProfilesProvider).list();
  final views = <PlainLocationView>[];
  for (final profile in profiles) {
    final connection = await ref
        .watch(connectionRepositoryProvider)
        .getConnectionById(profile.connectionId);
    final stats = await database.readLatestMirrorRunStats(profile.profileId);
    final conflictCount = await database.countMirrorConflicts(
      profile.profileId,
    );
    final activity = await database.readSyncProfileActivity(profile.profileId);
    views.add(
      PlainLocationView(
        profile: profile,
        connection: connection,
        stats: stats,
        conflictCount: conflictCount,
        latestRunState: activity.latestRun?.state,
        latestRunFailureCode: activity.latestRun?.errorCode,
      ),
    );
  }
  return views;
});
