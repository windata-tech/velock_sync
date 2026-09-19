/// Riverpod providers and session state shared by the sync-profiles
/// pages (home, wizard, detail, settings).
library;

import 'dart:async';

import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/core/app_repository.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_profile.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_service.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_exchange_root.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_pairing_control_channel.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/android_exchange_channel.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_dataset_adapter_factory.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_queue_probe.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_service.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/secure_storage/device_signing_key_store.dart';
import 'package:velock_sync/infrastructure/secure_storage/vault_key_store.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_dispatcher.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_dispatcher_factory.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/diagnostics/remote_inventory_service.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/settings/sync_global_settings.dart';
import 'package:velock_sync/sync_profiles/settings/sync_settings_service.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_pairing_session.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_profile_finalizer.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';

/// UI-level seam so widget tests can verify the Velock action without
/// executing platform IPC, providers, or a remote transfer.
abstract interface class SyncProfileRunService {
  Future<SyncProfileDispatchResult> runNow(String profileId);
}

final velockExchangeQueueProbeProvider = Provider<VelockExchangeQueueProbe>(
  (ref) => const VelockExchangeQueueProbe(),
);

/// Read-only remote inventory used by the detail page.
final remoteInventoryServiceProvider = Provider<RemoteInventoryService>(
  (ref) => RemoteInventoryService(
    connections: ref.watch(connectionRepositoryProvider),
  ),
);

final syncProfileRunServiceProvider = Provider<SyncProfileRunService>(
  (ref) => _ForegroundSyncProfileRunService(
    database: ref.watch(syncStateDatabaseProvider),
    profiles: ref.watch(syncProfileRepositoryProvider),
    connections: ref.watch(connectionRepositoryProvider),
  ),
);

final syncSettingsServiceProvider = Provider<SyncSettingsService>(
  (ref) => DurableSyncSettingsService(
    settings: LocalSyncGlobalSettingsStore(ref.watch(localDataManagerProvider)),
    profiles: ref.watch(syncProfileRepositoryProvider),
    database: ref.watch(syncStateDatabaseProvider),
    supportDirectory: getApplicationSupportDirectory,
  ),
);

final velockWizardReadinessServiceProvider =
    Provider<VelockWizardReadinessService>(
      (ref) => PlatformVelockWizardReadinessService(),
    );

final velockPairingSessionServiceProvider =
    Provider<VelockPairingSessionService>(
      (ref) => PlatformVelockPairingSessionService(
        control: Platform.isIOS || Platform.isMacOS
            ? ApplePairingControlChannel()
            : MethodChannelAndroidExchangeChannel(),
      ),
    );

final velockSyncAppInstanceIdProvider = Provider<Future<String> Function()>((
  ref,
) {
  final localData = ref.watch(localDataManagerProvider);
  return () async {
    var appInstanceId = await localData.getStringAsync(AppKeys.deviceId);
    if (appInstanceId == null || appInstanceId.trim().isEmpty) {
      appInstanceId = const Uuid().v4();
      await localData.setStringAsync(AppKeys.deviceId, appInstanceId);
    }
    return appInstanceId;
  };
});

final velockWizardConnectionsProvider =
    Provider<Future<List<ConnectionModel>> Function()>(
      (ref) => ref.watch(connectionRepositoryProvider).loadConnections,
    );

final velockProfileFinalizerProvider = Provider<VelockProfileFinalizer>((ref) {
  final profiles = ref.watch(syncProfileRepositoryProvider);
  final connections = ref.watch(connectionRepositoryProvider);
  final database = ref.watch(syncStateDatabaseProvider);
  return VelockProfileFinalizationService(
    saveProfile: profiles.save,
    retainProducerTrust:
        ({required vaultId, required producerId, required signingPublicKey}) =>
            database.trustDevice(
              vaultId: vaultId,
              deviceId: producerId,
              signingPublicKey: signingPublicKey,
            ),
    readProfiles: () =>
        profiles.listSummaries(kind: SyncDatasetKind.velockManaged),
    readConnection: connections.getConnectionById,
    pairing: ref.watch(velockPairingSessionServiceProvider),
  );
});

/// Existing Velock-managed sync profiles. A device may only keep one Velock
/// pairing, so a created profile blocks starting another pairing until it is
/// deleted. Auto-disposed so leaving and re-entering the wizard re-reads the
/// repository after a deletion.
final velockExistingProfilesProvider =
    FutureProvider.autoDispose<List<SyncProfileSummary>>((ref) {
      ref.watch(profilesRevisionProvider);
      return ref
          .watch(syncProfileRepositoryProvider)
          .listSummaries(kind: SyncDatasetKind.velockManaged);
    });

/// App-scoped pairing state for the Velock wizard. Holding the session outside
/// the page keeps an approved pairing usable after the user leaves the wizard
/// to create a missing connection and returns.
class VelockWizardSessionState {
  const VelockWizardSessionState({
    this.session,
    this.approval,
    this.finalization,
    this.connectionNeeded = false,
  });

  final VelockPairingSession? session;
  final VelockPairingControlResponse? approval;
  final VelockProfileFinalizationResult? finalization;

  /// Set when the wizard found no active remote connection while an approved
  /// pairing was waiting to continue.
  final bool connectionNeeded;

  VelockWizardSessionState copyWith({
    VelockPairingSession? session,
    VelockPairingControlResponse? approval,
    VelockProfileFinalizationResult? finalization,
    bool? connectionNeeded,
  }) => VelockWizardSessionState(
    session: session ?? this.session,
    approval: approval ?? this.approval,
    finalization: finalization ?? this.finalization,
    connectionNeeded: connectionNeeded ?? this.connectionNeeded,
  );
}

class VelockWizardSessionController extends Notifier<VelockWizardSessionState> {
  @override
  VelockWizardSessionState build() => const VelockWizardSessionState();

  void sessionStarted(VelockPairingSession session) =>
      state = VelockWizardSessionState(session: session);

  void approved(VelockPairingControlResponse approval) =>
      state = state.copyWith(approval: approval, connectionNeeded: false);

  void connectionMissing() => state = state.copyWith(connectionNeeded: true);

  /// The missing remote connection has since been created; the approved
  /// pairing can continue without the "connection needed" banner.
  void connectionResolved() => state = state.copyWith(connectionNeeded: false);

  void profileFinalized(VelockProfileFinalizationResult result) =>
      state = state.copyWith(
        finalization: result,
        session: result.pairingAcknowledged ? null : state.session,
        approval: result.pairingAcknowledged ? null : state.approval,
        connectionNeeded: false,
      );

  /// A freshly opened wizard must not keep showing an already-completed
  /// profile: the home list is the canonical place to see created profiles.
  /// In-progress pairings (approval waiting for a connection) are preserved.
  void clearCompletedFlow() {
    if (state.finalization == null) return;
    state = const VelockWizardSessionState();
  }

  void acknowledged() {
    final result = state.finalization;
    state = VelockWizardSessionState(
      finalization: result == null
          ? null
          : VelockProfileFinalizationResult(
              profile: result.profile,
              pairingAcknowledged: true,
            ),
    );
  }

  void reset() => state = const VelockWizardSessionState();
}

final velockWizardSessionProvider =
    NotifierProvider<VelockWizardSessionController, VelockWizardSessionState>(
      VelockWizardSessionController.new,
    );

/// Bumped whenever a profile is created so the Sync home can reload its list
/// even while its page state is kept alive by the navigation shell.
class ProfilesRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final profilesRevisionProvider = NotifierProvider<ProfilesRevision, int>(
  ProfilesRevision.new,
);

class _ForegroundSyncProfileRunService implements SyncProfileRunService {
  _ForegroundSyncProfileRunService({
    required SyncStateDatabase database,
    required SyncProfileRepository profiles,
    required this.connections,
  }) : _database = database,
       _profiles = profiles;

  final SyncStateDatabase _database;
  final SyncProfileRepository _profiles;
  final ConnectionRepository connections;
  Future<SyncProfileDispatcher>? _dispatcher;

  @override
  Future<SyncProfileDispatchResult> runNow(String profileId) async =>
      (await (_dispatcher ??= _buildDispatcher())).dispatch(profileId);

  Future<SyncProfileDispatcher> _buildDispatcher() async {
    final supportDirectory = await getApplicationSupportDirectory();
    final stagingRoot = Directory('${supportDirectory.path}/staging');
    final selectedFolderProfiles = SelectedFolderSyncProfileRepository(
      _database,
    );
    final selectedFolderService = SelectedFolderSyncService(
      database: _database,
      profiles: selectedFolderProfiles,
      connections: connections,
      vaultKeys: SecureVaultKeyStore(),
      signingKeys: SecureDeviceSigningKeyStore(),
      stagingRoot: stagingRoot,
    );
    final velockService = VelockSyncService(
      database: _database,
      profiles: _profiles,
      connections: connections,
      adapterFactory: PlatformVelockDatasetAdapterFactory(
        androidExchange: MethodChannelAndroidExchangeChannel(),
        appleRootLocator: AppleExchangeRootLocator(),
      ),
      stagingRoot: stagingRoot,
    );
    return SyncProfileDispatcherFactory.create(
      profiles: _profiles,
      selectedFolderService: selectedFolderService,
      velockService: velockService,
    );
  }
}
