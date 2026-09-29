import 'package:material_ui/material_ui.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Velock home has only backup and recovery, not ordinary folders',
    (tester) async {
      final database = await SyncStateDatabase.inMemory();
      addTearDown(database.close);
      final repository = SyncProfileRepository(database);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            syncStateDatabaseProvider.overrideWithValue(database),
            syncProfileRepositoryProvider.overrideWithValue(repository),
          ],
          child: const MaterialApp(
            locale: Locale('zh', 'CN'),
            supportedLocales: [Locale('zh', 'CN'), Locale('en')],
            localizationsDelegates: [...GlobalMaterialLocalizations.delegates],
            home: SyncProfilesHome(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('格间备份'), findsWidgets);
      expect(find.byKey(const Key('velock-backup-enable')), findsOneWidget);
      expect(find.text('开始备份'), findsOneWidget);
      expect(find.text('从云端恢复'), findsOneWidget);
      expect(find.byKey(const Key('selected-folder-create')), findsNothing);
      expect(find.text('其他文件'), findsNothing);
      expect(find.textContaining('零知识'), findsNothing);
      expect(find.textContaining('Profile'), findsNothing);
    },
  );

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
        child: const MaterialApp(
          locale: Locale('zh', 'CN'),
          supportedLocales: [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: [...GlobalMaterialLocalizations.delegates],
          home: SyncProfilesHome(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 正常态区段头不再挂徽章，也不再有状态说明行。
    expect(find.text('test1 的 Velock'), findsOneWidget);
    expect(find.text('还没有完成首次备份'), findsOneWidget);
    expect(find.byKey(const Key('backup-primary-action')), findsOneWidget);
    expect(find.text('立即备份'), findsOneWidget);
    expect(find.byKey(const Key('velock-backup-enable')), findsNothing);
    expect(find.byKey(const Key('selected-folder-create')), findsNothing);
  });

  testWidgets('new sync chooser explains both supported data categories', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          locale: Locale('zh', 'CN'),
          supportedLocales: [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: [...GlobalMaterialLocalizations.delegates],
          home: NewSyncProfile(),
        ),
      ),
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
