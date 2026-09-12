import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/background/background_sync.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/engine/sync_download_engine.dart';
import 'package:velock_sync/sync_core/engine/sync_profile_runner.dart';
import 'package:velock_sync/sync_core/engine/sync_upload_engine.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_dispatcher.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_executor.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

void main() {
  test(
    'schedules one constrained periodic task when background sync is enabled',
    () async {
      final platform = _FakeBackgroundTaskPlatform();
      final scheduler = BackgroundSyncScheduler(
        platform: platform,
        supported: true,
      );

      await scheduler.enable();

      expect(platform.registration, isNotNull);
      expect(platform.registration!.uniqueName, backgroundSyncUniqueName);
      expect(platform.registration!.taskName, backgroundSyncTaskName);
      expect(
        platform.registration!.frequency,
        BackgroundSyncScheduler.minimumFrequency,
      );
      expect(platform.registration!.requiresNetwork, isTrue);
      expect(platform.registration!.requiresUnmeteredNetwork, isTrue);
      expect(platform.registration!.requiresBatteryNotLow, isTrue);
      expect(platform.registration!.requiresCharging, isFalse);
    },
  );

  test('rejects frequencies below the platform minimum', () async {
    final scheduler = BackgroundSyncScheduler(
      platform: _FakeBackgroundTaskPlatform(),
      supported: true,
    );

    expect(
      () => scheduler.enable(frequency: const Duration(minutes: 14)),
      throwsArgumentError,
    );
  });

  test('uses a metered constraint only when cellular is allowed', () async {
    final platform = _FakeBackgroundTaskPlatform();
    final scheduler = BackgroundSyncScheduler(
      platform: platform,
      supported: true,
    );

    await scheduler.enable(allowCellular: true);

    expect(platform.registration!.requiresUnmeteredNetwork, isFalse);
  });

  test('uses a charging constraint when requested', () async {
    final platform = _FakeBackgroundTaskPlatform();
    final scheduler = BackgroundSyncScheduler(
      platform: platform,
      supported: true,
    );

    await scheduler.enable(requiresCharging: true);

    expect(platform.registration!.requiresCharging, isTrue);
  });

  test('cancels the global background task when disabled', () async {
    final platform = _FakeBackgroundTaskPlatform();
    final scheduler = BackgroundSyncScheduler(
      platform: platform,
      supported: true,
    );

    await scheduler.disable();

    expect(platform.cancelledUniqueName, backgroundSyncUniqueName);
  });

  test('does not schedule on an unsupported platform', () {
    final scheduler = BackgroundSyncScheduler(
      platform: _FakeBackgroundTaskPlatform(),
      supported: false,
    );

    expect(scheduler.enable, throwsUnsupportedError);
  });

  test(
    'network policy permits Wi-Fi but rejects cellular by default',
    () async {
      final wifi = ConnectivityBackgroundNetworkPolicy(
        checkConnectivity: () async => const [ConnectivityResult.wifi],
      );
      final cellular = ConnectivityBackgroundNetworkPolicy(
        checkConnectivity: () async => const [ConnectivityResult.mobile],
      );

      expect(await wifi.permits(allowCellular: false), isTrue);
      expect(await cellular.permits(allowCellular: false), isFalse);
      expect(await cellular.permits(allowCellular: true), isTrue);
      expect((await wifi.current()).isMetered, isFalse);
      expect((await cellular.current()).isMetered, isTrue);
    },
  );

  test('cellular limits bound individual upload and download artifacts', () {
    final limits = BackgroundTransferLimits.cellular(10 * 1024 * 1024);

    expect(limits.uploadLimits.maxCipherBytes, 10 * 1024 * 1024);
    expect(limits.uploadLimits.enforceMaxCipherBytes, isTrue);
    expect(limits.downloadLimits.maxBlobBytes, 10 * 1024 * 1024);
    expect(limits.downloadLimits.maxOperationsBytes, 10 * 1024 * 1024);
  });

  test('power policy preserves the charging-only preference', () async {
    final charging = PlatformBackgroundPowerPolicy(
      isCharging: () async => true,
    );
    final notCharging = PlatformBackgroundPowerPolicy(
      isCharging: () async => false,
    );

    expect(await charging.permits(requiresCharging: true), isTrue);
    expect(await notCharging.permits(requiresCharging: true), isFalse);
    expect(await notCharging.permits(requiresCharging: false), isTrue);
  });

  test(
    'background dispatch applies profile policy and cellular transfer limits',
    () async {
      final database = await SyncStateDatabase.inMemory();
      addTearDown(database.close);
      final profiles = SyncProfileRepository(database);
      await profiles.save(
        _profile(
          'eligible',
          background: const SyncProfileBackgroundPolicy(
            enabled: true,
            allowCellular: true,
            requiresCharging: true,
            cellularMaxTransferBytes: 10 * 1024 * 1024,
          ),
        ),
      );
      await profiles.save(
        _profile(
          'paused',
          state: SyncProfileState.paused,
          background: const SyncProfileBackgroundPolicy(enabled: true),
        ),
      );
      await profiles.save(_profile('not-enabled'));
      final executor = _BackgroundExecutor();
      final result = await runEligibleBackgroundProfiles(
        profiles: profiles,
        dispatcher: SyncProfileDispatcher(
          profiles: profiles,
          executors: [executor],
        ),
        networkPolicy: const _NetworkPolicy(
          BackgroundNetworkState(isAvailable: true, isMetered: true),
        ),
        powerPolicy: const _PowerPolicy(true),
      );

      expect(result, isTrue);
      expect(executor.requests, hasLength(1));
      final request = executor.requests.single;
      expect(request.profile.profileId, 'eligible');
      expect(request.uploadLimits.maxCipherBytes, 10 * 1024 * 1024);
      expect(request.uploadLimits.enforceMaxCipherBytes, isTrue);
      expect(request.downloadLimits.maxBlobBytes, 10 * 1024 * 1024);
    },
  );

  test('global background switch prevents every eligible dispatch', () async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    final profiles = SyncProfileRepository(database);
    await profiles.save(
      _profile(
        'eligible',
        background: const SyncProfileBackgroundPolicy(enabled: true),
      ),
    );
    final executor = _BackgroundExecutor();

    final result = await runEligibleBackgroundProfiles(
      profiles: profiles,
      dispatcher: SyncProfileDispatcher(
        profiles: profiles,
        executors: [executor],
      ),
      networkPolicy: const _NetworkPolicy(
        BackgroundNetworkState(isAvailable: true, isMetered: false),
      ),
      powerPolicy: const _PowerPolicy(true),
      globalBackgroundEnabled: false,
    );

    expect(result, isTrue);
    expect(executor.requests, isEmpty);
  });

  test(
    'network and power policy prevent dispatch without failing the task',
    () async {
      final database = await SyncStateDatabase.inMemory();
      addTearDown(database.close);
      final profiles = SyncProfileRepository(database);
      await profiles.save(
        _profile(
          'wifi-only',
          background: const SyncProfileBackgroundPolicy(enabled: true),
        ),
      );
      await profiles.save(
        _profile(
          'charging-only',
          background: const SyncProfileBackgroundPolicy(
            enabled: true,
            allowCellular: true,
            requiresCharging: true,
          ),
        ),
      );
      final executor = _BackgroundExecutor();
      final dispatcher = SyncProfileDispatcher(
        profiles: profiles,
        executors: [executor],
      );

      await profiles.setState('charging-only', SyncProfileState.paused);
      final cellularResult = await runEligibleBackgroundProfiles(
        profiles: profiles,
        dispatcher: dispatcher,
        networkPolicy: const _NetworkPolicy(
          BackgroundNetworkState(isAvailable: true, isMetered: true),
        ),
        powerPolicy: const _PowerPolicy(true),
      );
      await profiles.setState('wifi-only', SyncProfileState.paused);
      await profiles.setState('charging-only', SyncProfileState.active);
      final powerResult = await runEligibleBackgroundProfiles(
        profiles: profiles,
        dispatcher: dispatcher,
        networkPolicy: const _NetworkPolicy(
          BackgroundNetworkState(isAvailable: true, isMetered: false),
        ),
        powerPolicy: const _PowerPolicy(false),
      );

      expect(cellularResult, isTrue);
      expect(powerResult, isTrue);
      expect(executor.requests, isEmpty);
    },
  );

  test(
    'background continues after failed dispatch while skipped dispatch is benign',
    () async {
      final database = await SyncStateDatabase.inMemory();
      addTearDown(database.close);
      final profiles = SyncProfileRepository(database);
      await profiles.save(
        _profile(
          'failing',
          background: const SyncProfileBackgroundPolicy(enabled: true),
        ),
      );
      await profiles.save(
        _profile(
          'succeeds',
          background: const SyncProfileBackgroundPolicy(enabled: true),
        ),
      );
      await profiles.save(
        _profile(
          'unsupported',
          kind: SyncDatasetKind.velockManaged,
          background: const SyncProfileBackgroundPolicy(enabled: true),
        ),
      );
      final executor = _BackgroundExecutor(failIds: {'failing'});

      final result = await runEligibleBackgroundProfiles(
        profiles: profiles,
        dispatcher: SyncProfileDispatcher(
          profiles: profiles,
          executors: [executor],
        ),
        networkPolicy: const _NetworkPolicy(
          BackgroundNetworkState(isAvailable: true, isMetered: false),
        ),
        powerPolicy: const _PowerPolicy(true),
      );

      expect(result, isFalse);
      expect(executor.requests.map((request) => request.profile.profileId), [
        'failing',
        'succeeds',
      ]);
    },
  );
}

class _FakeBackgroundTaskPlatform implements BackgroundTaskPlatform {
  _Registration? registration;
  String? cancelledUniqueName;

  @override
  Future<void> cancel(String uniqueName) async {
    cancelledUniqueName = uniqueName;
  }

  @override
  Future<void> registerPeriodicSync({
    required String uniqueName,
    required String taskName,
    required Duration frequency,
    required bool requiresNetwork,
    required bool requiresUnmeteredNetwork,
    required bool requiresBatteryNotLow,
    required bool requiresCharging,
  }) async {
    registration = _Registration(
      uniqueName: uniqueName,
      taskName: taskName,
      frequency: frequency,
      requiresNetwork: requiresNetwork,
      requiresUnmeteredNetwork: requiresUnmeteredNetwork,
      requiresBatteryNotLow: requiresBatteryNotLow,
      requiresCharging: requiresCharging,
    );
  }
}

class _Registration {
  const _Registration({
    required this.uniqueName,
    required this.taskName,
    required this.frequency,
    required this.requiresNetwork,
    required this.requiresUnmeteredNetwork,
    required this.requiresBatteryNotLow,
    required this.requiresCharging,
  });

  final String uniqueName;
  final String taskName;
  final Duration frequency;
  final bool requiresNetwork;
  final bool requiresUnmeteredNetwork;
  final bool requiresBatteryNotLow;
  final bool requiresCharging;
}

class _NetworkPolicy implements BackgroundNetworkPolicy {
  const _NetworkPolicy(this.state);

  final BackgroundNetworkState state;

  @override
  Future<BackgroundNetworkState> current() async => state;
}

class _PowerPolicy implements BackgroundPowerPolicy {
  const _PowerPolicy(this.allows);

  final bool allows;

  @override
  Future<bool> permits({required bool requiresCharging}) async =>
      !requiresCharging || allows;
}

class _BackgroundExecutor implements SyncProfileExecutor {
  _BackgroundExecutor({Set<String> failIds = const {}}) : _failIds = failIds;

  final Set<String> _failIds;
  final List<SyncProfileExecutionRequest> requests = [];

  @override
  SyncDatasetKind get kind => SyncDatasetKind.selectedFolder;

  @override
  Future<SyncProfileRunResult> run(SyncProfileExecutionRequest request) async {
    requests.add(request);
    if (_failIds.contains(request.profile.profileId)) {
      throw StateError('expected background failure');
    }
    return const SyncProfileRunResult(
      runId: 'run-1',
      upload: UploadRunResult.idle(),
      download: DownloadRunResult(0),
    );
  }
}

SyncProfileEnvelope _profile(
  String profileId, {
  SyncDatasetKind kind = SyncDatasetKind.selectedFolder,
  SyncProfileState state = SyncProfileState.active,
  SyncProfileBackgroundPolicy background = const SyncProfileBackgroundPolicy(),
}) => SyncProfileEnvelope(
  kind: kind,
  profileId: profileId,
  datasetId: 'dataset-$profileId',
  vaultId: 'vault-$profileId',
  deviceId: 'device-$profileId',
  displayName: 'Profile $profileId',
  connectionId: 'connection-$profileId',
  state: state,
  backgroundPolicy: background,
  dataset: const {
    'rootKeyRef': 'secure/root',
    'signingKeyRef': 'secure/signing',
  },
  createdAt: DateTime.utc(2026, 7, 17),
);
