import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
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
        child: const MaterialApp(
          locale: Locale('zh', 'CN'),
          supportedLocales: [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: [...GlobalMaterialLocalizations.delegates],
          home: SyncSettings(),
        ),
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
    // The staging card is gone: nothing writes those batches any more.
    expect(find.text('暂存空间'), findsNothing);
    expect(find.byKey(const Key('cleanup-staging')), findsNothing);
  });

  testWidgets('does not claim protection before a trusted checkpoint', (
    tester,
  ) async {
    // Device evidence 2026-09-27: every pass skipped at `checkpoint-missing`,
    // yet the card said 已开启 · 最近清理 刚刚 · 0 台设备. Each of those was
    // wrong: the policy could not act, the timestamp was the skipped check, and
    // the counts were never measured.
    final service = _FakeSyncSettingsService(
      garbageCollection: GarbageCollectionDiagnostics(
        runId: 'gc-1',
        profileId: 'profile-1',
        vaultId: 'vault-1',
        state: 'skipped',
        startedAt: DateTime.utc(2026, 9, 27, 2, 16, 21),
        completedAt: DateTime.utc(2026, 9, 27, 2, 16, 21),
        checkpointId: null,
        retentionCutoff: null,
        activeDeviceCount: 0,
        unackedDeviceCount: 0,
        candidateCount: 0,
        eligibleCandidateCount: 0,
        deletedObjectCount: 0,
        retentionManifestComplete: null,
        planId: null,
        skipReason: 'checkpoint-missing',
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [syncSettingsServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(
          locale: Locale('zh', 'CN'),
          supportedLocales: [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: [...GlobalMaterialLocalizations.delegates],
          home: SyncSettings(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('最近清理'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('已开启'), findsNothing);
    expect(find.text('尚未生效'), findsOneWidget);
    expect(find.text('尚未执行'), findsOneWidget);
    expect(find.text('尚未统计'), findsNWidgets(2));
    expect(find.textContaining('0 台设备'), findsNothing);
    expect(find.textContaining('尚未获得可信检查点，本次安全清理已跳过'), findsOneWidget);
    expect(find.textContaining('上次检查：'), findsOneWidget);
  });

  testWidgets('says cleanup never ran when no pass has been recorded', (
    tester,
  ) async {
    final service = _FakeSyncSettingsService(garbageCollection: null);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [syncSettingsServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(
          locale: Locale('zh', 'CN'),
          supportedLocales: [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: [...GlobalMaterialLocalizations.delegates],
          home: SyncSettings(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('最近清理'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('尚未生效'), findsOneWidget);
    expect(find.text('尚未执行'), findsOneWidget);
    expect(find.text('尚未统计'), findsNWidgets(2));
    expect(
      find.textContaining('完成一次包含有效检查点的同步后才会开始安全清理'),
      findsOneWidget,
    );
  });

  testWidgets('does not claim a cleanup when a completed pass deleted nothing', (
    tester,
  ) async {
    // Device evidence 2026-09-27 10:37 (first pass after the recovery fix):
    // state=completed, 1 candidate, 0 eligible, 0 deleted — the retention
    // window had not passed, so nothing was reclaimed. A completed pass is a
    // check, not a cleanup.
    final service = _FakeSyncSettingsService(
      garbageCollection: GarbageCollectionDiagnostics(
        runId: 'gc-1',
        profileId: 'profile-1',
        vaultId: 'vault-1',
        state: 'completed',
        startedAt: DateTime.utc(2026, 9, 27, 2, 37, 34),
        completedAt: DateTime.utc(2026, 9, 27, 2, 37, 35),
        checkpointId: 'v1-54c5db05cb5c7ea2ee875505e1cee346',
        retentionCutoff: DateTime.utc(2026, 8, 21),
        activeDeviceCount: 1,
        unackedDeviceCount: 0,
        candidateCount: 1,
        eligibleCandidateCount: 0,
        deletedObjectCount: 0,
        retentionManifestComplete: true,
        planId: null,
        skipReason: null,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [syncSettingsServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(
          locale: Locale('zh', 'CN'),
          supportedLocales: [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: [...GlobalMaterialLocalizations.delegates],
          home: SyncSettings(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('最近清理'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('已开启'), findsOneWidget);
    expect(find.text('尚未执行'), findsOneWidget);
    expect(find.text('0 台设备'), findsOneWidget);
    expect(find.text('1 台'), findsOneWidget);
    expect(
      find.textContaining('本次检查 1 个候选，0 个满足清理条件，已删除 0 个对象'),
      findsOneWidget,
    );
  });

  testWidgets('says an eligible plan was only counted while deletion is paused', (
    tester,
  ) async {
    // GC must not delete Velock commit markers while the remote history guard
    // requires every sequence, so a fully eligible plan is recorded as
    // `deletion-paused`. The card must not suggest anything was removed.
    final service = _FakeSyncSettingsService(
      garbageCollection: GarbageCollectionDiagnostics(
        runId: 'gc-1',
        profileId: 'profile-1',
        vaultId: 'vault-1',
        state: 'skipped',
        startedAt: DateTime.now().toUtc(),
        completedAt: DateTime.now().toUtc(),
        checkpointId: 'checkpoint-1',
        retentionCutoff: DateTime.utc(2026, 8, 21),
        activeDeviceCount: 1,
        unackedDeviceCount: 0,
        candidateCount: 2,
        eligibleCandidateCount: 2,
        deletedObjectCount: 0,
        retentionManifestComplete: true,
        planId: null,
        skipReason: 'deletion-paused',
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [syncSettingsServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(
          locale: Locale('zh', 'CN'),
          supportedLocales: [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: [...GlobalMaterialLocalizations.delegates],
          home: SyncSettings(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('最近清理'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('尚未执行'), findsOneWidget);
    expect(
      find.textContaining('2 个对象已满足清理条件；这一版只统计，不删除云端备份。'),
      findsOneWidget,
    );
    expect(find.textContaining('已删除'), findsNothing);
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
