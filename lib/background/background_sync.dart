import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:velock_sync/core/local_data_manager.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_profile.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/android_exchange_channel.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_exchange_root.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_dataset_adapter_factory.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_service.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_service.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/secure_storage/credential_store.dart';
import 'package:velock_sync/infrastructure/secure_storage/device_signing_key_store.dart';
import 'package:velock_sync/infrastructure/secure_storage/vault_key_store.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/engine/sync_download_engine.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_dispatcher.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_dispatcher_factory.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/settings/sync_global_settings.dart';
import 'package:workmanager/workmanager.dart';

const backgroundSyncTaskName = 'velock_sync_periodic';
const backgroundSyncUniqueName =
    'tech.windata.velock.sync.velock_sync.periodic_sync';

abstract interface class BackgroundTaskPlatform {
  Future<void> registerPeriodicSync({
    required String uniqueName,
    required String taskName,
    required Duration frequency,
    required bool requiresNetwork,
    required bool requiresUnmeteredNetwork,
    required bool requiresBatteryNotLow,
    required bool requiresCharging,
  });

  Future<void> cancel(String uniqueName);
}

class WorkmanagerBackgroundTaskPlatform implements BackgroundTaskPlatform {
  const WorkmanagerBackgroundTaskPlatform();

  @override
  Future<void> cancel(String uniqueName) =>
      Workmanager().cancelByUniqueName(uniqueName);

  @override
  Future<void> registerPeriodicSync({
    required String uniqueName,
    required String taskName,
    required Duration frequency,
    required bool requiresNetwork,
    required bool requiresUnmeteredNetwork,
    required bool requiresBatteryNotLow,
    required bool requiresCharging,
  }) => Workmanager().registerPeriodicTask(
    uniqueName,
    taskName,
    frequency: frequency,
    constraints: Constraints(
      networkType: requiresNetwork
          ? (requiresUnmeteredNetwork
                ? NetworkType.unmetered
                : NetworkType.connected)
          : NetworkType.notRequired,
      requiresBatteryNotLow: requiresBatteryNotLow,
      requiresCharging: requiresCharging,
    ),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    tag: backgroundSyncTaskName,
  );
}

class BackgroundNetworkState {
  const BackgroundNetworkState({
    required this.isAvailable,
    required this.isMetered,
  });

  static const unavailable = BackgroundNetworkState(
    isAvailable: false,
    isMetered: true,
  );

  final bool isAvailable;
  final bool isMetered;

  bool permits({required bool allowCellular}) =>
      isAvailable && (!isMetered || allowCellular);
}

abstract interface class BackgroundNetworkPolicy {
  Future<BackgroundNetworkState> current();
}

extension BackgroundNetworkPolicyPermissions on BackgroundNetworkPolicy {
  Future<bool> permits({required bool allowCellular}) async =>
      (await current()).permits(allowCellular: allowCellular);
}

class ConnectivityBackgroundNetworkPolicy implements BackgroundNetworkPolicy {
  ConnectivityBackgroundNetworkPolicy({
    Connectivity? connectivity,
    Future<List<ConnectivityResult>> Function()? checkConnectivity,
  }) : _connectivity = connectivity ?? Connectivity(),
       _checkConnectivity = checkConnectivity;

  final Connectivity _connectivity;
  final Future<List<ConnectivityResult>> Function()? _checkConnectivity;

  @override
  Future<BackgroundNetworkState> current() async {
    final active =
        await (_checkConnectivity ?? _connectivity.checkConnectivity)();
    if (active.contains(ConnectivityResult.wifi) ||
        active.contains(ConnectivityResult.ethernet)) {
      return const BackgroundNetworkState(isAvailable: true, isMetered: false);
    }
    if (active.contains(ConnectivityResult.none)) {
      return BackgroundNetworkState.unavailable;
    }
    // Unknown/VPN transports can be billed just like cellular data. Treat them
    // as metered unless the platform has positively identified Wi-Fi/Ethernet.
    return const BackgroundNetworkState(isAvailable: true, isMetered: true);
  }
}

class BackgroundTransferLimits {
  const BackgroundTransferLimits._({
    required this.uploadLimits,
    required this.downloadLimits,
  });

  static const unrestricted = BackgroundTransferLimits._(
    uploadLimits: BatchLimits(),
    downloadLimits: DownloadLimits(),
  );

  factory BackgroundTransferLimits.cellular(int maximumBytes) {
    if (maximumBytes < 1) {
      throw ArgumentError.value(maximumBytes, 'maximumBytes');
    }
    return BackgroundTransferLimits._(
      uploadLimits: BatchLimits(
        maxCipherBytes: maximumBytes,
        enforceMaxCipherBytes: true,
      ),
      downloadLimits: DownloadLimits(
        maxEnvelopeBytes: maximumBytes < 4 * 1024 * 1024
            ? maximumBytes
            : 4 * 1024 * 1024,
        maxOperationsBytes: maximumBytes < 64 * 1024 * 1024
            ? maximumBytes
            : 64 * 1024 * 1024,
        maxBlobBytes: maximumBytes,
      ),
    );
  }

  final BatchLimits uploadLimits;
  final DownloadLimits downloadLimits;
}

abstract interface class BackgroundPowerPolicy {
  Future<bool> permits({required bool requiresCharging});
}

/// Reads the device charging state immediately before a profile is run. The
/// system periodic-task constraint is shared by all profiles, so this second
/// check preserves each profile's opt-in when power settings differ.
class PlatformBackgroundPowerPolicy implements BackgroundPowerPolicy {
  PlatformBackgroundPowerPolicy({Future<bool?> Function()? isCharging})
    : _isCharging = isCharging;

  static const _channel = MethodChannel('tech.windata.velock.sync/power_state');

  final Future<bool?> Function()? _isCharging;

  @override
  Future<bool> permits({required bool requiresCharging}) async {
    if (!requiresCharging) return true;
    try {
      return await (_isCharging ?? _readChargingState)() == true;
    } on Object {
      // Do not transfer on battery power when charging cannot be confirmed.
      return false;
    }
  }

  Future<bool?> _readChargingState() =>
      _channel.invokeMethod<bool>('isCharging');
}

/// One platform task processes every profile whose user-controlled background
/// switch is enabled. A global task is necessary because iOS requires each
/// BGTaskScheduler identifier to be declared statically in Info.plist.
class BackgroundSyncScheduler {
  BackgroundSyncScheduler({BackgroundTaskPlatform? platform, bool? supported})
    : _platform = platform ?? const WorkmanagerBackgroundTaskPlatform(),
      _supported = supported ?? isSupported;

  static const minimumFrequency = Duration(minutes: 15);

  final BackgroundTaskPlatform _platform;
  final bool _supported;

  static bool get isSupported => Platform.isAndroid || Platform.isIOS;

  Future<void> enable({
    Duration frequency = minimumFrequency,
    bool allowCellular = false,
    bool requiresCharging = false,
  }) {
    if (!_supported) {
      throw UnsupportedError(
        'Background sync is not configured on this platform.',
      );
    }
    if (frequency < minimumFrequency) {
      throw ArgumentError.value(
        frequency,
        'frequency',
        'must be at least 15 minutes',
      );
    }
    return _platform.registerPeriodicSync(
      uniqueName: backgroundSyncUniqueName,
      taskName: backgroundSyncTaskName,
      frequency: frequency,
      requiresNetwork: true,
      requiresUnmeteredNetwork: !allowCellular,
      requiresBatteryNotLow: true,
      requiresCharging: requiresCharging,
    );
  }

  Future<void> disable() => _platform.cancel(backgroundSyncUniqueName);
}

Future<void> initializeBackgroundSync() async {
  if (!BackgroundSyncScheduler.isSupported) return;
  await Workmanager().initialize(backgroundSyncDispatcher);
}

/// Entrypoint retained by the VM for Android WorkManager and iOS
/// BGTaskScheduler. It initializes all dependencies inside the background
/// isolate before reconstructing the same service used by foreground sync.
@pragma('vm:entry-point')
void backgroundSyncDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName != backgroundSyncTaskName &&
        taskName != backgroundSyncUniqueName &&
        taskName != Workmanager.iOSBackgroundTask) {
      return true;
    }
    return runEnabledBackgroundProfiles();
  });
}

/// Runs common, opted-in profile summaries using the same dispatcher as a
/// foreground "Sync now" action. It intentionally treats a skipped profile as
/// non-failing: a lifecycle or capability change can race a scheduled task.
Future<bool> runEligibleBackgroundProfiles({
  required SyncProfileRepository profiles,
  required SyncProfileDispatcher dispatcher,
  required BackgroundNetworkPolicy networkPolicy,
  required BackgroundPowerPolicy powerPolicy,
  bool globalBackgroundEnabled = true,
}) async {
  if (!globalBackgroundEnabled) return true;
  final enabled = await profiles.listBackgroundEligible();
  if (enabled.isEmpty) return true;

  final networkState = await networkPolicy.current();
  var succeeded = true;
  for (final profile in enabled) {
    try {
      final policy = profile.backgroundPolicy;
      if (!networkState.permits(allowCellular: policy.allowCellular) ||
          !await powerPolicy.permits(
            requiresCharging: policy.requiresCharging,
          )) {
        continue;
      }
      final limits = networkState.isMetered
          ? BackgroundTransferLimits.cellular(policy.cellularMaxTransferBytes)
          : BackgroundTransferLimits.unrestricted;
      final result = await dispatcher.dispatch(
        profile.profileId,
        uploadLimits: limits.uploadLimits,
        downloadLimits: limits.downloadLimits,
      );
      if (result.didFail) succeeded = false;
    } on Object {
      // Continue so one profile's unavailable access never blocks another.
      succeeded = false;
    }
  }
  return succeeded;
}

/// Runs the same opted-in profiles used by the platform scheduler. The
/// foreground lifecycle coordinator calls this after a resume or a network
/// recovery, so it never needs a second sync implementation.
Future<bool> runEnabledBackgroundProfiles({
  BackgroundNetworkPolicy? networkPolicy,
  BackgroundPowerPolicy? powerPolicy,
}) async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    await LocalDataManager.instance.init();
    final globalSettings = await LocalSyncGlobalSettingsStore(
      LocalDataManager.instance,
    ).read();
    if (!globalSettings.backgroundEnabled) return true;
    await SyncStateDatabase.initialize();
    final database = SyncStateDatabase.instance;
    final selectedFolderProfiles = SelectedFolderSyncProfileRepository(
      database,
    );
    final supportDirectory = await getApplicationSupportDirectory();
    final connections = ConnectionRepository(
      LocalDataManager.instance,
      SecureCredentialStore(),
      database,
    );
    final selectedFolderService = SelectedFolderSyncService(
      database: database,
      profiles: selectedFolderProfiles,
      connections: connections,
      vaultKeys: SecureVaultKeyStore(),
      signingKeys: SecureDeviceSigningKeyStore(),
      stagingRoot: Directory('${supportDirectory.path}/staging'),
    );
    final profiles = SyncProfileRepository(database);
    final velockService = VelockSyncService(
      database: database,
      profiles: profiles,
      connections: connections,
      adapterFactory: PlatformVelockDatasetAdapterFactory(
        androidExchange: MethodChannelAndroidExchangeChannel(),
        appleRootLocator: AppleExchangeRootLocator(),
      ),
      stagingRoot: Directory('${supportDirectory.path}/staging'),
    );
    return runEligibleBackgroundProfiles(
      profiles: profiles,
      dispatcher: SyncProfileDispatcherFactory.create(
        profiles: profiles,
        selectedFolderService: selectedFolderService,
        velockService: velockService,
      ),
      networkPolicy: networkPolicy ?? ConnectivityBackgroundNetworkPolicy(),
      powerPolicy: powerPolicy ?? PlatformBackgroundPowerPolicy(),
      globalBackgroundEnabled: globalSettings.backgroundEnabled,
    );
  } on Object {
    return false;
  }
}
