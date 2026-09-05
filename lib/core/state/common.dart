import 'dart:io';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart' show Provider;
import 'package:velock_sync/core/app_repository.dart';
import 'package:velock_sync/core/local_data_manager.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_velock_conflict_gateway.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/features/dashboard/repository/dashboard_repository.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/secure_storage/credential_store.dart';
import 'package:velock_sync/sync_core/conflicts/conflict_resolution_service.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

part '../../generated/core/state/common.g.dart';

@riverpod
LocalDataManager localDataManager(Ref ref) {
  return LocalDataManager.instance;
}

@riverpod
AppSetting appSetting(Ref ref) {
  final manager = ref.watch(localDataManagerProvider);
  return AppSetting(manager);
}

@riverpod
DashboardRepository dashboardRepository(Ref ref) {
  final manager = ref.watch(localDataManagerProvider);
  return DashboardRepository(manager);
}

@riverpod
ConnectionRepository connectionRepository(Ref ref) {
  final manager = ref.watch(localDataManagerProvider);
  final credentials = ref.watch(credentialStoreProvider);
  final database = ref.watch(syncStateDatabaseProvider);
  return ConnectionRepository(manager, credentials, database);
}

final credentialStoreProvider = Provider<CredentialStore>(
  (ref) => SecureCredentialStore(),
);

final syncStateDatabaseProvider = Provider<SyncStateDatabase>(
  (ref) => SyncStateDatabase.instance,
);

final syncProfileRepositoryProvider = Provider<SyncProfileRepository>(
  (ref) => SyncProfileRepository(ref.watch(syncStateDatabaseProvider)),
);

/// The UI can request resolution only through the durable domain service.
/// On iOS, Velock uses the dedicated App Group request/signed-receipt control
/// plane; other platforms remain fail-closed.
final conflictResolutionServiceProvider = Provider<ConflictResolutionService>((
  ref,
) {
  final database = ref.watch(syncStateDatabaseProvider);
  final appleVelockGateway = Platform.isIOS
      ? AppleVelockConflictGateway(database: database)
      : null;
  return DurableConflictResolutionService(
    database: database,
    profiles: ref.watch(syncProfileRepositoryProvider),
    velockOpener: appleVelockGateway ?? const FailClosedVelockConflictOpener(),
    velockReceiptVerifier:
        appleVelockGateway ?? const RejectingVelockConflictReceiptVerifier(),
  );
});
