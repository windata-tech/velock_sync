import 'dart:io';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/android_exchange_channel.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_exchange_root.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_dataset_adapter_factory.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_snapshot_recovery.dart';
import 'package:velock_sync/features/cloud_backup/application/velock_backup_rebuild_service.dart';
import 'package:velock_sync/features/connection/remote_object_store_factory.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';

final snapshotVelockLauncherProvider = Provider<Future<bool> Function(Uri)>(
  (ref) =>
      (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
);
final snapshotAdapterFactoryProvider = Provider<VelockDatasetAdapterFactory>(
  (ref) => PlatformVelockDatasetAdapterFactory(
    androidExchange: MethodChannelAndroidExchangeChannel(),
    appleRootLocator: AppleExchangeRootLocator(),
  ),
);
final snapshotRemoteOpenerProvider =
    Provider<Future<RemoteObjectStore> Function(String, List<String>)>((ref) {
      final connections = ref.watch(connectionRepositoryProvider);
      return (id, segments) async {
        final connection = await connections.getConnectionById(id);
        if (connection == null) {
          throw StateError('Backup connection was removed.');
        }
        return RemoteObjectStoreFactory.create(
          connections: connections,
          protocol: connection.protocol,
          remoteRootSegments: segments,
        );
      };
    });
final velockBackupRebuildServiceProvider =
    FutureProvider<VelockBackupRebuildService>((ref) async {
      final database = ref.watch(syncStateDatabaseProvider),
          profiles = ref.watch(syncProfileRepositoryProvider);
      final factory = ref.watch(snapshotAdapterFactoryProvider),
          openRemote = ref.watch(snapshotRemoteOpenerProvider),
          launch = ref.watch(snapshotVelockLauncherProvider);
      final support = await getApplicationSupportDirectory();
      return VelockBackupRebuildService(
        database: database,
        profiles: profiles,
        adapterFactory: factory,
        jobs: VelockBackupRebuildJobs(
          Directory('${support.path}/snapshot-rebuild-jobs'),
        ),
        openRemote: openRemote,
        launchVelock: launch,
      );
    });
final velockSnapshotRecoveryServiceProvider =
    Provider<VelockSnapshotRecoveryService>(
      (ref) => VelockSnapshotRecoveryService(
        database: ref.watch(syncStateDatabaseProvider),
        profiles: ref.watch(syncProfileRepositoryProvider),
        adapterFactory: ref.watch(snapshotAdapterFactoryProvider),
        openRemote: ref.watch(snapshotRemoteOpenerProvider),
        launchVelock: ref.watch(snapshotVelockLauncherProvider),
      ),
    );

final snapshotContinuationReadyProvider =
    Provider<Future<bool> Function(String)>((ref) {
      return ref.watch(velockSnapshotRecoveryServiceProvider).hasAppliedReceipt;
    });
