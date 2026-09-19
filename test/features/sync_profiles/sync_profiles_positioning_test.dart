import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/sync_profiles/ui/new_sync_profile.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_workspace.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/app_components.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sync home presents backup and folder sync as two domains', (
    tester,
  ) async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    final repository = SyncProfileRepository(database);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncStateDatabaseProvider.overrideWithValue(database),
          syncProfileRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(home: SyncProfilesHome()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('备份与同步'), findsWidgets);
    // 两个域都还没有内容：各自只给一个动作按钮，而不是「已经建好的行」。
    expect(find.widgetWithText(AppTextButton, '开启格间备份'), findsOneWidget);
    expect(find.widgetWithText(AppTextButton, '新建文件夹同步'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byKey(const Key('velock-backup-enable')),
        matching: find.byType(AdaptiveListTile),
      ),
      findsNothing,
    );
    expect(
      find.ancestor(
        of: find.byKey(const Key('selected-folder-create')),
        matching: find.byType(AdaptiveListTile),
      ),
      findsNothing,
    );
    expect(find.text('开启格间备份'), findsOneWidget);
    expect(find.text('新建文件夹同步'), findsOneWidget);
    // 区段头不再重复状态与计数。
    expect(find.byKey(const Key('velock-backup-status')), findsNothing);
    expect(find.text('未开启'), findsNothing);
    expect(find.text('未创建'), findsNothing);
    expect(find.text('格间备份 · 未开启'), findsNothing);
    expect(find.text('尚未开启'), findsNothing);
    expect(find.byKey(const Key('velock-backup-not-configured')), findsNothing);
    expect(find.text('其他文件'), findsOneWidget);
    expect(find.text('开始同步格间数据'), findsNothing);
    expect(find.textContaining('换机助手'), findsNothing);
  });

  testWidgets('enabled 格间 backup reads as section state, not as a row', (
    tester,
  ) async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    final repository = SyncProfileRepository(database);
    await repository.save(_activeVelockProfile());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncStateDatabaseProvider.overrideWithValue(database),
          syncProfileRepositoryProvider.overrideWithValue(repository),
          velockWizardReadinessServiceProvider.overrideWithValue(
            const _ReadyReadinessService(),
          ),
        ],
        child: const MaterialApp(home: SyncProfilesHome()),
      ),
    );
    await tester.pumpAndSettle();

    // 正常态区段头不再挂徽章，也不再有状态说明行。
    expect(find.byKey(const Key('velock-backup-status')), findsNothing);
    expect(find.text('已开启'), findsNothing);
    expect(find.textContaining('最近成功备份'), findsNothing);
    expect(find.textContaining('零知识备份'), findsNothing);
    // 实例：铺在分组卡片里的那一行，副标题只留最近一次运行时间。
    expect(find.text('test1 的 Velock'), findsOneWidget);
    expect(find.text('尚未备份'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('test1 的 Velock'),
        matching: find.byType(AdaptiveListTile),
      ),
      findsOneWidget,
    );
    // 已有配置时不再出现入口行，避免状态/入口/实例三种语义混在一张卡里。
    expect(find.byKey(const Key('velock-backup-enable')), findsNothing);
  });

  testWidgets('new sync chooser explains both supported data categories', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: NewSyncProfile())),
    );
    await tester.pumpAndSettle();

    expect(find.text('新建同步'), findsOneWidget);
    expect(find.text('备份格间数据'), findsOneWidget);
    expect(find.text('同步文件夹'), findsOneWidget);
    expect(find.textContaining('持续'), findsWidgets);
  });
}

SyncProfileEnvelope _activeVelockProfile() => SyncProfileEnvelope(
  kind: SyncDatasetKind.velockManaged,
  profileId: 'velock-profile',
  datasetId: 'velock-dataset',
  vaultId: 'velock-vault',
  deviceId: 'consumer-device',
  displayName: 'test1 的 Velock',
  connectionId: 'connection-1',
  state: SyncProfileState.active,
  backgroundPolicy: const SyncProfileBackgroundPolicy(),
  dataset: const {
    'schemaVersion': 1,
    'pairedProducerId': 'producer-device',
    'pairedProducerPublicKey': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  },
  createdAt: DateTime.utc(2026, 9, 12),
);

class _ReadyReadinessService implements VelockWizardReadinessService {
  const _ReadyReadinessService();

  @override
  Future<VelockWizardReadiness> inspect({String? syncAppInstanceId}) async =>
      const VelockWizardReadiness(VelockWizardAvailability.ready);
}
