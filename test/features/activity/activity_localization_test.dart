/// The activity page's copy, pinned in both locales.
///
/// The page used to be Chinese-only: ~54 raw literals and no `syncText` call,
/// so an English device showed 活动 / 最近同步 / 待处理冲突 and a Chinese conflict
/// menu. Localizing it must not change a single Chinese character — this test
/// renders the real page (real in-memory database, real rows) with
/// `Locale('zh', 'CN')` and freezes today's wording, then does the same in
/// English.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/activity/ui/sync_activity.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/conflicts/conflict_resolution_service.dart';
import 'package:velock_sync/sync_core/conflicts/conflict_resolution_strategy.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

void main() {
  testWidgets('the activity page keeps its Chinese copy', (tester) async {
    final database = await _seededDatabase();
    await _pumpActivity(tester, database, const Locale('zh', 'CN'));

    expect(find.text('活动'), findsWidgets);
    expect(find.text('同步记录与待处理项'), findsOneWidget);
    expect(find.text('最近运行'), findsOneWidget);
    expect(find.text('待恢复'), findsOneWidget);
    expect(find.text('冲突'), findsOneWidget);
    expect(find.text('最近同步'), findsOneWidget);
    expect(find.text('同步失败'), findsOneWidget);
    // The run, the transfers and the conflict all show the same profile and
    // time, so this row is expected more than once.
    expect(find.text('Family NAS · 刚刚'), findsWidgets);
    expect(find.text('远端拒绝了访问，请重新授权后再试。'), findsOneWidget);
    expect(find.text('待恢复传输'), findsOneWidget);
    expect(find.text('上传进行中'), findsOneWidget);
    expect(find.text('Family NAS · 2 KB / 4 KB'), findsOneWidget);
    expect(find.text('下载进行中'), findsOneWidget);
    expect(find.text('Family NAS · 2 KB 已传输'), findsOneWidget);
    expect(find.text('待处理冲突'), findsOneWidget);
    expect(find.text('两个设备都修改了内容'), findsOneWidget);

    await tester.tap(find.text('同步失败'));
    await tester.pumpAndSettle();
    for (final label in const [
      '同步配置',
      '开始时间',
      '结束时间',
      '结果',
      '可能原因',
      '建议操作',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('未完成'), findsOneWidget);
    expect(find.textContaining('技术详情'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(CupertinoIcons.ellipsis_circle));
    await tester.pumpAndSettle();
    expect(find.text('保留本地版本'), findsOneWidget);
    expect(find.text('保留远端版本'), findsOneWidget);
    expect(find.text('保留两个版本'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the activity page keeps its English copy', (tester) async {
    final database = await _seededDatabase();
    await _pumpActivity(tester, database, const Locale('en'));

    expect(find.text('Activity'), findsWidgets);
    expect(find.text('Sync history and open items'), findsOneWidget);
    expect(find.text('Recent syncs'), findsOneWidget);
    expect(find.text('Sync failed'), findsOneWidget);
    expect(find.text('Transfers to resume'), findsOneWidget);
    expect(find.text('Upload in progress'), findsOneWidget);
    expect(find.text('Family NAS · 2 KB / 4 KB'), findsOneWidget);
    expect(find.text('Download in progress'), findsOneWidget);
    expect(find.text('Family NAS · 2 KB transferred'), findsOneWidget);
    expect(
      find.text('Remote access was denied. Authorize access again and retry.'),
      findsOneWidget,
    );
    expect(find.text('Conflicts to review'), findsOneWidget);
    expect(find.text('Both devices changed this item'), findsOneWidget);

    await tester.tap(find.text('Sync failed'));
    await tester.pumpAndSettle();
    expect(find.text('Result'), findsOneWidget);
    expect(find.text('Not completed'), findsOneWidget);
    expect(find.text('Likely cause'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(CupertinoIcons.ellipsis_circle));
    await tester.pumpAndSettle();
    expect(find.text('Keep this device version'), findsOneWidget);
    expect(find.text('Keep remote version'), findsOneWidget);
    expect(find.text('Keep both versions'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the empty activity page is localized', (tester) async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    await _pumpActivity(tester, database, const Locale('zh', 'CN'));
    expect(find.text('还没有同步活动'), findsOneWidget);
    expect(
      find.text('同步运行、待恢复传输和需要处理的冲突会集中显示在这里。'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    // A second mount gets its own container; the empty state is what the user
    // sees before any run has been recorded.
    await _pumpEmptyActivity(tester, const Locale('en'));
    expect(find.text('No sync activity yet'), findsOneWidget);
    expect(
      find.text(
        'Sync runs, transfers waiting to resume and conflicts that need attention all appear here.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

/// A fresh empty database in its own container, for the English empty state.
Future<void> _pumpEmptyActivity(WidgetTester tester, Locale locale) async {
  final database = await SyncStateDatabase.inMemory();
  addTearDown(database.close);
  await _pumpActivity(tester, database, locale);
}

/// One failed run, one upload in flight and one unresolved conflict.
Future<SyncStateDatabase> _seededDatabase() async {
  final database = await SyncStateDatabase.inMemory();
  addTearDown(database.close);
  final repository = SyncProfileRepository(database);
  await repository.save(_profile('profile-1'));
  await database.startSyncRun(
    runId: 'run-1',
    profileId: 'profile-1',
    startedAt: DateTime.now().toUtc(),
  );
  await database.finishSyncRun(
    runId: 'run-1',
    state: 'failed',
    completedAt: DateTime.now().toUtc(),
    failure: const SyncFailure(
      errorCode: 'provider.http.401',
      category: SyncErrorCategory.authenticationRequired,
      retryable: true,
      suggestedAction: 'Sign in again.',
    ),
  );
  await database.beginTransferJob(
    transferId: 'transfer-1',
    profileId: 'profile-1',
    direction: TransferJobDirection.upload,
    logicalKey: 'opaque-protocol-key',
    expectedSize: 4096,
  );
  await database.updateTransferProgress(
    transferId: 'transfer-1',
    completedBytes: 2048,
  );
  // No expected size, so the row shows the transferred amount on its own.
  await database.beginTransferJob(
    transferId: 'transfer-2',
    profileId: 'profile-1',
    direction: TransferJobDirection.download,
    logicalKey: 'opaque-protocol-key-2',
  );
  await database.updateTransferProgress(
    transferId: 'transfer-2',
    completedBytes: 2048,
  );
  await database.recordFolderConflict(
    conflictId: 'conflict-1',
    profileId: 'profile-1',
    entityId: 'entity-1',
    sourceDeviceId: 'device-2',
    localRevisionId: 'revision-local',
    incomingRevisionId: 'revision-remote',
    type: 'modify-modify',
  );
  return database;
}

Future<void> _pumpActivity(
  WidgetTester tester,
  SyncStateDatabase database,
  Locale locale,
) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // A new container per mount, so re-pumping cannot reuse stale state.
  final container = ProviderContainer(
    overrides: [
      syncStateDatabaseProvider.overrideWithValue(database),
      syncProfileRepositoryProvider.overrideWithValue(
        SyncProfileRepository(database),
      ),
      conflictResolutionServiceProvider.overrideWithValue(
        _UnusedConflictResolution(),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: PlatformProvider(
        initialPlatform: TargetPlatform.iOS,
        builder: (_) => PlatformApp(
          locale: locale,
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: const SyncActivity(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

SyncProfileEnvelope _profile(String profileId) => SyncProfileEnvelope(
  kind: SyncDatasetKind.selectedFolder,
  profileId: profileId,
  datasetId: 'dataset-$profileId',
  vaultId: 'vault-$profileId',
  deviceId: 'device-$profileId',
  displayName: 'Family NAS',
  connectionId: 'connection-$profileId',
  state: SyncProfileState.active,
  backgroundPolicy: const SyncProfileBackgroundPolicy(),
  dataset: const {
    'rootPath': '/safe/path',
    'rootKeyRef': 'secure/root',
    'signingKeyRef': 'secure/signing',
  },
  createdAt: DateTime.utc(2026, 9, 27),
);

/// The page reads the service on every build; resolving is never exercised here.
class _UnusedConflictResolution implements ConflictResolutionService {
  @override
  Future<ConflictResolutionResult> resolve({
    required String conflictId,
    required ConflictResolutionStrategy strategy,
  }) async => const ConflictResolutionResult.completed();
}
