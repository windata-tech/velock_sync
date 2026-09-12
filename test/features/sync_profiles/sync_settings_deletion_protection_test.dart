import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_workspace.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/staging/staging_space_manager.dart';
import 'package:velock_sync/sync_profiles/settings/sync_global_settings.dart';
import 'package:velock_sync/sync_profiles/settings/sync_settings_service.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

void main() {
  testWidgets('shows deletion protection and GC acknowledgement status', (
    tester,
  ) async {
    final service = _FakeSyncSettingsService(
      garbageCollection: GarbageCollectionDiagnostics(
        runId: 'gc-1',
        profileId: 'profile-1',
        vaultId: 'vault-1',
        state: 'completed',
        startedAt: DateTime.utc(2026, 9, 11, 1),
        completedAt: DateTime.utc(2026, 9, 11, 1, 0, 2),
        checkpointId: 'checkpoint-1',
        retentionCutoff: DateTime.utc(2026, 8, 4),
        activeDeviceCount: 2,
        unackedDeviceCount: 1,
        candidateCount: 4,
        eligibleCandidateCount: 1,
        deletedObjectCount: 3,
        retentionManifestComplete: true,
        planId: 'plan-1',
        skipReason: null,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [syncSettingsServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(home: SyncSettings()),
      ),
    );
    await tester.pumpAndSettle();

    // The deletion-protection card sits below the fold on a phone-sized
    // viewport; scroll it into view before asserting on its rows.
    await tester.scrollUntilVisible(
      find.text('最近清理'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('删除保护'), findsWidgets);
    expect(find.text('已开启'), findsOneWidget);
    expect(find.textContaining('实际清理额外保留 7 天缓冲'), findsOneWidget);
    expect(find.textContaining('1 台设备'), findsOneWidget);
    expect(find.textContaining('已删除 3 个对象'), findsOneWidget);
  });

  test(
    'sanitized diagnostics include GC evidence but no device identifiers',
    () async {
      final database = await SyncStateDatabase.inMemory();
      addTearDown(database.close);
      await database.startGarbageCollectionRun(
        runId: 'gc-1',
        profileId: 'profile-1',
        vaultId: 'vault-1',
        startedAt: DateTime.utc(2026, 9, 11, 1),
      );
      await database.finishGarbageCollectionRun(
        runId: 'gc-1',
        state: 'completed',
        completedAt: DateTime.utc(2026, 9, 11, 1, 0, 2),
        checkpointId: 'checkpoint-1',
        retentionCutoff: DateTime.utc(2026, 8, 4),
        activeDeviceCount: 2,
        unackedDeviceCount: 1,
        candidateCount: 4,
        eligibleCandidateCount: 1,
        deletedObjectCount: 3,
        retentionManifestComplete: true,
        planId: 'plan-1',
      );
      final support = await Directory.systemTemp.createTemp('velock-settings-');
      addTearDown(() => support.delete(recursive: true));
      final service = DurableSyncSettingsService(
        settings: _FakeSettingsStore(),
        profiles: SyncProfileRepository(database),
        database: database,
        supportDirectory: () async => support,
        backgroundSupported: false,
        now: () => DateTime.utc(2026, 9, 11, 2),
      );

      final diagnostics =
          jsonDecode(await service.exportSanitizedDiagnostics())
              as Map<String, dynamic>;
      final protection =
          diagnostics['deletionProtection'] as Map<String, dynamic>;
      expect(protection['retentionDays'], 30);
      expect(protection['safetyBufferDays'], 7);
      final latestGc = protection['latestGc'] as Map<String, dynamic>;
      expect(latestGc['state'], 'completed');
      expect(latestGc['checkpointId'], 'checkpoint-1');
      expect(latestGc['unackedDeviceCount'], 1);
      expect(latestGc['eligibleCandidateCount'], 1);
      expect(latestGc['deletedObjectCount'], 3);
      expect(diagnostics['privacy'], containsPair('containsKeys', false));
    },
  );
}

class _FakeSettingsStore implements SyncGlobalSettingsStore {
  @override
  Future<SyncGlobalSettings> read() async => const SyncGlobalSettings();

  @override
  Future<void> save(SyncGlobalSettings settings) async {}
}

class _FakeSyncSettingsService implements SyncSettingsService {
  _FakeSyncSettingsService({required this.garbageCollection});

  final GarbageCollectionDiagnostics? garbageCollection;

  @override
  Future<SyncSettingsCleanupSummary> cleanupStaging() async =>
      const SyncSettingsCleanupSummary();

  @override
  Future<String> exportSanitizedDiagnostics() async => '{}';

  @override
  Future<SyncSettingsSnapshot> load() async => SyncSettingsSnapshot(
    settings: const SyncGlobalSettings(),
    backgroundSupported: false,
    backgroundEligibleProfileCount: 0,
    staging: const StagingSpaceSummary(),
    garbageCollection: garbageCollection,
  );

  @override
  Future<SyncSettingsSnapshot> save(SyncGlobalSettings settings) async =>
      load();
}
