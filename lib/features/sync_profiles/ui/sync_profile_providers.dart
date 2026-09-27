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
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_profile.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_service.dart';
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

/// One clock for transient authorization, including tests and finalization.
final velockWizardClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

final velockPairingSessionServiceProvider =
    Provider<VelockPairingSessionService>(
      (ref) => PlatformVelockPairingSessionService(
        now: ref.watch(velockWizardClockProvider),
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
    now: ref.watch(velockWizardClockProvider),
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

enum VelockWizardAuthorizationProblem { expired, invalid }

/// Retain setup choices across cloud-account navigation, never the validity of
/// a one-time authorization. Its signed deadline still applies off this page.
class VelockWizardSessionState {
  const VelockWizardSessionState({
    this.session,
    this.approval,
    this.finalization,
    this.connectionNeeded = false,
    this.selectedConnectionId,
    this.selectedRemoteRootSegments = const [],
    this.authorizationProblem,
  });

  final VelockPairingSession? session;
  final VelockPairingControlResponse? approval;
  final VelockProfileFinalizationResult? finalization;
  final bool connectionNeeded;
  final String? selectedConnectionId;
  final List<String> selectedRemoteRootSegments;
  final VelockWizardAuthorizationProblem? authorizationProblem;

  VelockWizardSessionState copyWith({
    VelockPairingControlResponse? approval,
    bool? connectionNeeded,
    String? selectedConnectionId,
    List<String>? selectedRemoteRootSegments,
  }) => VelockWizardSessionState(
    session: session,
    approval: approval ?? this.approval,
    finalization: finalization,
    connectionNeeded: connectionNeeded ?? this.connectionNeeded,
    selectedConnectionId: selectedConnectionId ?? this.selectedConnectionId,
    selectedRemoteRootSegments: selectedRemoteRootSegments == null
        ? this.selectedRemoteRootSegments
        : List.unmodifiable(selectedRemoteRootSegments),
    authorizationProblem: authorizationProblem,
  );
}

class VelockWizardSessionController extends Notifier<VelockWizardSessionState> {
  Timer? _expirationTimer;
  VelockPairingSession? _flowSession;

  @override
  VelockWizardSessionState build() {
    ref.onDispose(() => _expirationTimer?.cancel());
    return const VelockWizardSessionState();
  }

  void sessionStarted(VelockPairingSession session) {
    _flowSession = session;
    state = VelockWizardSessionState(
      session: session,
      connectionNeeded: state.connectionNeeded,
      selectedConnectionId: state.selectedConnectionId,
      selectedRemoteRootSegments: state.selectedRemoteRootSegments,
    );
    _scheduleExpiration();
  }

  void approved(VelockPairingControlResponse approval) {
    if (state.session == null || state.finalization != null) return;
    state = state.copyWith(approval: approval, connectionNeeded: false);
    if (!expireIfNeeded()) _scheduleExpiration();
  }

  void connectionMissing() => state = state.copyWith(connectionNeeded: true);
  void connectionResolved() => state = state.copyWith(connectionNeeded: false);
  void connectionSelected(String id) => state = state.copyWith(
    selectedConnectionId: id,
    selectedRemoteRootSegments: id == state.selectedConnectionId
        ? state.selectedRemoteRootSegments
        : const [],
  );

  void folderSelected(List<String> segments) =>
      state = state.copyWith(selectedRemoteRootSegments: segments);

  DateTime? get _deadline {
    final requestDeadline = state.session?.request.expiresAt;
    if (requestDeadline == null) return null;
    final approvalDeadline = state.approval?.expiresAt;
    return approvalDeadline != null &&
            approvalDeadline.isBefore(requestDeadline)
        ? approvalDeadline
        : requestDeadline;
  }

  void _scheduleExpiration() {
    _expirationTimer?.cancel();
    final deadline = _deadline;
    if (deadline == null || state.finalization != null) return;
    final remaining = deadline.difference(
      ref.read(velockWizardClockProvider)().toUtc(),
    );
    _expirationTimer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      () {
        // A resumed app or an adjusted clock must not rely on the timer alone.
        if (!expireIfNeeded()) _scheduleExpiration();
      },
    );
  }

  bool expireIfNeeded() {
    final session = state.session;
    final deadline = _deadline;
    if (session == null ||
        deadline == null ||
        state.finalization != null ||
        ref.read(velockWizardClockProvider)().toUtc().isBefore(deadline)) {
      return false;
    }
    authorizationInvalidated(session, VelockWizardAuthorizationProblem.expired);
    return true;
  }

  /// Old async checks cannot invalidate a newer authorization or a saved
  /// profile. Only transient state is discarded; cloud accounts are untouched.
  void authorizationInvalidated(
    VelockPairingSession session,
    VelockWizardAuthorizationProblem reason,
  ) {
    if (!identical(state.session, session) || state.finalization != null) {
      return;
    }
    _expirationTimer?.cancel();
    state = VelockWizardSessionState(
      connectionNeeded: state.connectionNeeded,
      selectedConnectionId: state.selectedConnectionId,
      selectedRemoteRootSegments: state.selectedRemoteRootSegments,
      authorizationProblem: reason,
    );
  }

  bool profileFinalized(
    VelockProfileFinalizationResult result, {
    VelockPairingSession? session,
    VelockPairingControlResponse? approval,
  }) {
    final sourceSession = session ?? state.session;
    if (sourceSession == null || !identical(sourceSession, _flowSession)) {
      return false;
    }
    // The finalizer checks expiry immediately before committing the durable
    // profile. A successful commit remains authorized even if its response/ACK
    // arrives after the one-time deadline. Never apply it to a replacement flow.
    _expirationTimer?.cancel();
    state = VelockWizardSessionState(
      finalization: result,
      session: result.pairingAcknowledged ? null : (session ?? state.session),
      approval: result.pairingAcknowledged
          ? null
          : (approval ?? state.approval),
      selectedConnectionId: state.selectedConnectionId,
      selectedRemoteRootSegments: state.selectedRemoteRootSegments,
    );
    return true;
  }

  /// An unfinished ACK must remain retryable when the user re-enters setup.
  void clearCompletedFlow() {
    if (state.finalization?.pairingAcknowledged != true) return;
    reset();
  }

  void acknowledged() {
    _expirationTimer?.cancel();
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

  void reset() {
    _flowSession = null;
    _expirationTimer?.cancel();
    state = const VelockWizardSessionState();
  }
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
      plainFolderService: PlainFolderSyncService(
        database: _database,
        profiles: PlainFolderSyncProfileRepository(_database),
        connections: connections,
      ),
    );
  }
}
