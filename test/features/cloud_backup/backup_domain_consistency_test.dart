import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/cloud_backup/model/backup_presentation.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_widgets.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_detail.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_home.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_providers.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';

const _folderFailureCode = 'provider.webdav.atomic_create_unsupported';
const _folderFailureMessage = '上次传输未通过云端安全写入检查，已停止以保护已有数据。请检查此任务的保存位置和服务设置。';

void main() {
  late SyncStateDatabase database;
  late SyncProfileRepository repository;

  setUp(() async {
    database = await SyncStateDatabase.inMemory();
    repository = SyncProfileRepository(database);
  });

  tearDown(() => database.close());

  testWidgets(
    'mixed domains keep completed Velock and failed folder card semantics in sync',
    (tester) async {
      await repository.save(_velockProfile());
      await repository.save(_folderProfile());

      await database.startSyncRun(
        runId: 'velock-completed',
        profileId: 'velock',
        startedAt: DateTime.utc(2026, 9, 26, 8),
      );
      await database.finishSyncRun(
        runId: 'velock-completed',
        state: 'completed',
        completedAt: DateTime.utc(2026, 9, 26, 8, 1),
      );

      await database.startSyncRun(
        runId: 'folder-failed',
        profileId: 'folder',
        startedAt: DateTime.utc(2026, 9, 26, 9, 15),
      );
      await database.finishSyncRun(
        runId: 'folder-failed',
        state: 'failed',
        completedAt: DateTime.utc(2026, 9, 26, 9, 15, 30),
        errorCode: _folderFailureCode,
      );

      await tester.pumpWidget(
        _app(
          const SyncProfilesHome(),
          database: database,
          repository: repository,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('我的格间'), findsOneWidget);
      expect(find.text('上次备份已完成'), findsOneWidget);
      expect(find.text(_folderFailureMessage), findsNothing);
      expect(find.text('工作文件夹'), findsNothing);
      final velockCard = _onlyStatusCard(tester);
      expect(velockCard.isVelock, isTrue);
      expect(velockCard.presentation.stage, BackupStage.lastTransferCompleted);
      expect(velockCard.presentation.errorCode, isNull);

      await tester.pumpWidget(
        _app(
          const SyncProfilesHome(
            key: ValueKey('folder-home'),
            kind: SyncDatasetKind.selectedFolder,
          ),
          database: database,
          repository: repository,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('文件夹同步与格间备份是独立任务，状态分别记录。'), findsOneWidget);
      _expectFailedFolderCard(tester);
      expect(find.text('我的格间'), findsNothing);
      expect(find.text('上次备份已完成'), findsNothing);

      final homeCard = _onlyStatusCard(tester);

      await tester.pumpWidget(
        _app(
          const SyncProfileDetail(profileId: 'folder'),
          database: database,
          repository: repository,
        ),
      );
      await tester.pumpAndSettle();

      _expectFailedFolderCard(tester);
      final detailCard = _onlyStatusCard(tester);

      expect(detailCard.isVelock, homeCard.isVelock);
      expect(detailCard.presentation.stage, homeCard.presentation.stage);
      expect(detailCard.presentation.action, homeCard.presentation.action);
      expect(
        detailCard.presentation.errorCode,
        homeCard.presentation.errorCode,
      );
      expect(detailCard.presentation.failedAt, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'running folder sync is transferred, never a stale synced badge',
    (tester) async {
      await repository.save(_folderProfile());
      await database.startSyncRun(
        runId: 'folder-running',
        profileId: 'folder',
        startedAt: DateTime.utc(2026, 9, 26, 10),
      );

      try {
        await tester.pumpWidget(
          _app(
            const SyncProfilesHome(
              key: ValueKey('folder-running-home'),
              kind: SyncDatasetKind.selectedFolder,
            ),
            database: database,
            repository: repository,
          ),
        );
        // The running transfer is shown inline on the card and its button, so
        // the tree never settles while the spinner animates.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.text('正在传输，请稍候'), findsOneWidget);
        expect(find.text('正在传输…'), findsOneWidget);
        expect(find.text('已同步'), findsNothing);
        // The progress state is inline: no blocking dialog for a running task.
        expect(find.byKey(const Key('sync-progress-dialog')), findsNothing);

        final card = _onlyStatusCard(tester);
        expect(card.isVelock, isFalse);
        expect(card.presentation.stage, BackupStage.transferring);
        expect(card.presentation.action, BackupAction.transfer);
        expect(
          tester
              .widget<BackupActionButton>(
                find.byKey(const Key('backup-primary-action')),
              )
              .busy,
          isTrue,
        );
        expect(
          tester
              .widget<BackupActionButton>(
                find.byKey(const Key('backup-primary-action')),
              )
              .onPressed,
          isNull,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await database.finishSyncRun(
          runId: 'folder-running',
          state: 'completed',
          completedAt: DateTime.utc(2026, 9, 26, 10, 1),
        );
      }
    },
  );
}

void _expectFailedFolderCard(WidgetTester tester) {
  expect(find.text('工作文件夹'), findsWidgets);
  expect(find.text('云端位置需要检查'), findsOneWidget);
  expect(find.text(_folderFailureMessage), findsOneWidget);
  expect(find.text('检查保存位置'), findsOneWidget);
  expect(find.text('已同步'), findsNothing);

  final card = _onlyStatusCard(tester);
  expect(card.isVelock, isFalse);
  expect(card.presentation.stage, BackupStage.needsAttention);
  expect(card.presentation.action, BackupAction.checkStorage);
  expect(card.presentation.errorCode, _folderFailureCode);
  expect(card.presentation.failedAt, isNotNull);
}

BackupStatusCard _onlyStatusCard(WidgetTester tester) {
  final finder = find.byType(BackupStatusCard);
  expect(finder, findsOneWidget);
  return tester.widget<BackupStatusCard>(finder);
}

Widget _app(
  Widget home, {
  required SyncStateDatabase database,
  required SyncProfileRepository repository,
}) => ProviderScope(
  overrides: [
    syncStateDatabaseProvider.overrideWithValue(database),
    syncProfileRepositoryProvider.overrideWithValue(repository),
    velockWizardReadinessServiceProvider.overrideWithValue(
      const _HealthyReadiness(),
    ),
  ],
  child: MaterialApp(
    locale: const Locale('zh'),
    supportedLocales: const [Locale('zh'), Locale('en')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: home,
  ),
);

SyncProfileEnvelope _velockProfile() => SyncProfileEnvelope(
  kind: SyncDatasetKind.velockManaged,
  profileId: 'velock',
  datasetId: 'velock-dataset',
  vaultId: 'vault',
  deviceId: 'device',
  displayName: '我的格间',
  connectionId: 'cloud',
  state: SyncProfileState.active,
  backgroundPolicy: const SyncProfileBackgroundPolicy(),
  dataset: const {
    'pairedProducerId': 'source',
    'pairedProducerPublicKeyId': 'public-key-ref',
    'exchangeBindingId': 'binding',
  },
  createdAt: DateTime.utc(2026, 9, 26),
);

SyncProfileEnvelope _folderProfile() => SyncProfileEnvelope(
  kind: SyncDatasetKind.selectedFolder,
  profileId: 'folder',
  datasetId: 'folder-dataset',
  vaultId: 'vault',
  deviceId: 'device',
  displayName: '工作文件夹',
  connectionId: 'cloud',
  state: SyncProfileState.active,
  backgroundPolicy: const SyncProfileBackgroundPolicy(),
  dataset: const {
    'accessKind': 'localPath',
    'keyId': 'folder-key-ref',
    'rootKeyRef': 'root-key-ref',
    'rootPath': '/tmp/velock-test-folder',
    'signingKeyRef': 'signing-key-ref',
  },
  createdAt: DateTime.utc(2026, 9, 26),
);

class _HealthyReadiness implements VelockWizardReadinessService {
  const _HealthyReadiness();

  @override
  Future<VelockWizardReadiness> inspect({String? syncAppInstanceId}) async =>
      const VelockWizardReadiness(VelockWizardAvailability.ready);
}
