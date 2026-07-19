import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:velock_sync/background/background_sync.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/settings/sync_global_settings.dart';
import 'package:velock_sync/sync_profiles/settings/sync_settings_service.dart';

void main() {
  test(
    'settings persist and refresh the one global platform schedule',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      await fixture.addProfile(backgroundEnabled: true);
      final platform = _RecordingBackgroundPlatform();
      final service = fixture.service(
        backgroundSupported: true,
        scheduler: BackgroundSyncScheduler(platform: platform, supported: true),
      );

      await service.save(const SyncGlobalSettings(backgroundEnabled: false));
      expect(fixture.settings.value.backgroundEnabled, isFalse);
      expect(platform.cancelled, backgroundSyncUniqueName);

      await service.save(const SyncGlobalSettings(backgroundEnabled: true));
      expect(platform.registered, isTrue);
      expect(platform.requiresUnmeteredNetwork, isTrue);
      expect(platform.requiresCharging, isFalse);
    },
  );

  test(
    'staging cleanup preserves recoverable batches and removes debris',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      await fixture.addProfile();
      final profileRoot = Directory(
        p.join(fixture.support.path, 'staging', 'profile-secret'),
      );
      final recoverable = Directory(p.join(profileRoot.path, 'recoverable'));
      final abandoned = Directory(p.join(profileRoot.path, 'abandoned'));
      await recoverable.create(recursive: true);
      await abandoned.create(recursive: true);
      await File(p.join(recoverable.path, 'manifest.json')).writeAsString('{}');
      await File(
        p.join(recoverable.path, 'blob.tmp-1'),
      ).writeAsBytes([1, 2, 3]);
      await File(p.join(abandoned.path, 'orphan')).writeAsBytes([4, 5]);

      final before = await fixture.service().load();
      expect(before.staging.totalBytes, 7);
      expect(before.staging.batchCount, 2);

      final cleanup = await fixture.service().cleanupStaging();

      expect(cleanup.freedBytes, 5);
      expect(cleanup.removedBatchCount, 1);
      expect(cleanup.removedTemporaryFileCount, 1);
      expect(cleanup.preservedRecoverableBatchCount, 1);
      expect(await recoverable.exists(), isTrue);
      expect(await abandoned.exists(), isFalse);
    },
  );

  test(
    'diagnostics contain aggregates but no identifiers paths or payloads',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      await fixture.addProfile();
      await fixture.database.startSyncRun(
        runId: 'SECRET-RUN-ID',
        profileId: 'profile-secret',
        startedAt: DateTime.utc(2026, 7, 18),
      );
      await fixture.database.finishSyncRun(
        runId: 'SECRET-RUN-ID',
        state: 'failed',
        completedAt: DateTime.utc(2026, 7, 18, 0, 1),
        errorCode: 'provider.http.429',
      );
      await fixture.database.startSyncRun(
        runId: 'SECRET-RUN-ID-2',
        profileId: 'profile-secret',
        startedAt: DateTime.utc(2026, 7, 18, 0, 2),
      );
      await fixture.database.finishSyncRun(
        runId: 'SECRET-RUN-ID-2',
        state: 'failed',
        completedAt: DateTime.utc(2026, 7, 18, 0, 3),
        errorCode: 'SECRET_TOKEN_SHAPED_LIKE_A_CODE',
      );

      final diagnostics = await fixture
          .service(now: () => DateTime.utc(2026, 7, 18, 1))
          .exportSanitizedDiagnostics();

      expect(diagnostics, contains('"formatVersion": 1'));
      expect(diagnostics, contains('"selectedFolder": 1'));
      expect(diagnostics, contains('"provider.http.429": 1'));
      expect(diagnostics, isNot(contains('profile-secret')));
      expect(diagnostics, isNot(contains('SECRET-RUN-ID')));
      expect(diagnostics, isNot(contains('SECRET-PATH')));
      expect(diagnostics, isNot(contains('SECRET-KEY-REF')));
      expect(diagnostics, isNot(contains('SECRET-DISPLAY-NAME')));
      expect(diagnostics, isNot(contains('SECRET_TOKEN_SHAPED_LIKE_A_CODE')));
      expect(diagnostics, contains('"redacted.invalid_error_code": 1'));
    },
  );
}

class _Fixture {
  _Fixture._({
    required this.database,
    required this.profiles,
    required this.settings,
    required this.support,
  });

  final SyncStateDatabase database;
  final SyncProfileRepository profiles;
  final _MemorySettingsStore settings;
  final Directory support;

  static Future<_Fixture> create() async {
    final database = await SyncStateDatabase.inMemory();
    return _Fixture._(
      database: database,
      profiles: SyncProfileRepository(database),
      settings: _MemorySettingsStore(),
      support: await Directory.systemTemp.createTemp('velock-settings-'),
    );
  }

  DurableSyncSettingsService service({
    bool backgroundSupported = false,
    BackgroundSyncScheduler? scheduler,
    DateTime Function()? now,
  }) => DurableSyncSettingsService(
    settings: settings,
    profiles: profiles,
    database: database,
    supportDirectory: () async => support,
    scheduler: scheduler,
    backgroundSupported: backgroundSupported,
    now: now,
  );

  Future<void> addProfile({bool backgroundEnabled = false}) => profiles.save(
    SyncProfileEnvelope(
      kind: SyncDatasetKind.selectedFolder,
      profileId: 'profile-secret',
      datasetId: 'SECRET-DATASET-ID',
      vaultId: 'SECRET-VAULT-ID',
      deviceId: 'SECRET-DEVICE-ID',
      displayName: 'SECRET-DISPLAY-NAME',
      connectionId: 'SECRET-CONNECTION-ID',
      state: SyncProfileState.active,
      backgroundPolicy: SyncProfileBackgroundPolicy(enabled: backgroundEnabled),
      dataset: const {
        'rootPath': '/SECRET-PATH',
        'rootKeyRef': 'SECRET-KEY-REF',
        'signingKeyRef': 'SECRET-SIGNING-REF',
      },
      createdAt: DateTime.utc(2026, 7, 18),
    ),
  );

  Future<void> dispose() async {
    await database.close();
    if (await support.exists()) await support.delete(recursive: true);
  }
}

class _MemorySettingsStore implements SyncGlobalSettingsStore {
  SyncGlobalSettings value = const SyncGlobalSettings();

  @override
  Future<SyncGlobalSettings> read() async => value;

  @override
  Future<void> save(SyncGlobalSettings settings) async {
    value = settings;
  }
}

class _RecordingBackgroundPlatform implements BackgroundTaskPlatform {
  bool registered = false;
  String? cancelled;
  bool? requiresUnmeteredNetwork;
  bool? requiresCharging;

  @override
  Future<void> cancel(String uniqueName) async {
    cancelled = uniqueName;
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
    registered = true;
    this.requiresUnmeteredNetwork = requiresUnmeteredNetwork;
    this.requiresCharging = requiresCharging;
  }
}
