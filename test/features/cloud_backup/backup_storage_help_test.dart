import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/features/cloud_backup/application/backup_destination_service.dart';
import 'package:velock_sync/features/cloud_backup/application/webdav_backup_folder_browser.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_folder_picker.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_storage_help.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_widgets.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_detail.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_home.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_providers.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_dispatcher.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';

const _atomicFailure = 'provider.webdav.atomic_create_unsupported';
const _collectionFailure = 'provider.webdav.collection_not_writable';

SyncProfileEnvelope _velockProfile() => VelockSyncProfile(
  profileId: 'p',
  datasetId: 'dataset',
  vaultId: 'vault',
  deviceId: 'consumer',
  displayName: '我的格间',
  connectionId: 'cloud',
  pairedProducerId: 'source',
  pairedProducerPublicKeyId: 'public-key-ref',
  exchangeBindingId: 'binding',
  remoteRootSegments: const ['共享给我', 'new folder'],
  backgroundPolicy: const SyncProfileBackgroundPolicy(),
  state: SyncProfileState.active,
  createdAt: DateTime.utc(2026, 9, 26),
).toEnvelope();

SyncProfileEnvelope _folderProfile() => SyncProfileEnvelope(
  kind: SyncDatasetKind.selectedFolder,
  profileId: 'p',
  datasetId: 'dataset',
  vaultId: 'vault',
  deviceId: 'consumer',
  displayName: '工作文件夹',
  connectionId: 'cloud',
  state: SyncProfileState.active,
  backgroundPolicy: const SyncProfileBackgroundPolicy(),
  dataset: const {},
  createdAt: DateTime.utc(2026, 9, 26),
);

ConnectionModel _connection() => ConnectionModel(
  id: 'cloud',
  name: '我的 NAS',
  source: 'source',
  target: 'target',
  protocol: const ProtocolModel.webDav(
    protocolType: WebDavProtocolType.https,
    address: 'https://example.invalid/base',
    port: '443',
    path: '/backup',
    credentialRef: 'DO_NOT_DISPLAY',
  ),
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  status: ConnectionStatus.pending,
);

class _Connections implements ConnectionRepository {
  _Connections(this.connection);

  ConnectionModel? connection;
  int getByIdCalls = 0;

  @override
  Future<ConnectionModel?> getConnectionById(String id) async {
    getByIdCalls++;
    return connection;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingDestination extends BackupDestinationService {
  _RecordingDestination()
    : super(
        open: (_) async =>
            throw StateError('Destination open is not expected.'),
      );

  int checkCalls = 0;
  String? lastConnectionId;
  String? lastVaultId;
  List<String> lastTrustedProducerIds = const [];
  bool? lastRestoring;
  List<String> lastRemoteRootSegments = const [];
  String? failureCode;

  @override
  Future<void> check({
    required String connectionId,
    required String vaultId,
    required Iterable<String> trustedProducerIds,
    required bool restoring,
    List<String> remoteRootSegments = const [],
  }) async {
    checkCalls++;
    lastConnectionId = connectionId;
    lastVaultId = vaultId;
    lastTrustedProducerIds = List<String>.of(trustedProducerIds);
    lastRestoring = restoring;
    lastRemoteRootSegments = List<String>.of(remoteRootSegments);
    final failure = failureCode;
    if (failure != null) throw BackupDestinationException(failure);
  }
}

class _RecordingRuns implements SyncProfileRunService {
  int calls = 0;

  @override
  Future<SyncProfileDispatchResult> runNow(String profileId) async {
    calls++;
    return SyncProfileDispatchResult(
      profileId: profileId,
      status: SyncProfileDispatchStatus.skippedNotRunnable,
    );
  }
}

class _Ready implements VelockWizardReadinessService {
  @override
  Future<VelockWizardReadiness> inspect({String? syncAppInstanceId}) async =>
      const VelockWizardReadiness(VelockWizardAvailability.ready);
}

void main() {
  late SyncStateDatabase database;
  late SyncProfileRepository repository;
  late _Connections connections;
  late _RecordingDestination destination;
  late _RecordingRuns runner;

  setUp(() async {
    database = await SyncStateDatabase.inMemory();
    repository = SyncProfileRepository(database);
    connections = _Connections(_connection());
    destination = _RecordingDestination();
    runner = _RecordingRuns();
  });

  tearDown(() => database.close());

  Future<void> seedFailedRun(
    SyncProfileEnvelope profile, {
    required String errorCode,
  }) async {
    await repository.save(profile);
    await database.startSyncRun(
      runId: 'old-run',
      profileId: profile.profileId,
      startedAt: DateTime.utc(2026, 9, 26),
    );
    await database.finishSyncRun(
      runId: 'old-run',
      state: 'failed',
      completedAt: DateTime.utc(2026, 9, 26, 1),
      errorCode: errorCode,
    );
  }

  Future<GoRouter> mount(WidgetTester tester, Widget root) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => root),
        GoRoute(
          path: '/connections/connection/:id',
          builder: (_, state) =>
              Scaffold(body: Text('browse:${state.pathParameters['id']}')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncStateDatabaseProvider.overrideWithValue(database),
          syncProfileRepositoryProvider.overrideWithValue(repository),
          syncProfileRunServiceProvider.overrideWithValue(runner),
          velockWizardReadinessServiceProvider.overrideWithValue(_Ready()),
          connectionRepositoryProvider.overrideWithValue(connections),
          backupDestinationServiceProvider.overrideWithValue(destination),
          backupFolderLoaderProvider.overrideWithValue(
            ({required protocol, required relativeSegments}) async =>
                relativeSegments.length == 2
                ? const [WebDavBackupFolder(name: '可写')]
                : const [],
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('zh'),
          supportedLocales: const [Locale('zh'), Locale('en')],
          localizationsDelegates: const [
            ...GlobalMaterialLocalizations.delegates,
          ],
          theme: ThemeData(platform: TargetPlatform.iOS),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  Future<void> expectOldFailurePreserved(
    Map<String, Object?> profileBefore,
  ) async {
    expect((await repository.read('p'))!.toJson(), profileBefore);
    final run = await database.latestSyncRun('p');
    expect(run, isNotNull);
    expect(run!.runId, 'old-run');
    expect(run.state, 'failed');
    expect(run.errorCode, _atomicFailure);
  }

  testWidgets(
    'home opens storage help for atomic write failure without manage or recovery',
    (tester) async {
      final profile = _velockProfile();
      await seedFailedRun(profile, errorCode: _atomicFailure);
      await mount(tester, const SyncProfilesHome());

      expect(find.text('检查保存位置'), findsOneWidget);
      expect(find.text('查看并处理'), findsNothing);
      expect(find.text('生成恢复包'), findsNothing);
      expect(destination.checkCalls, 0);
      expect(runner.calls, 0);

      await tester.tap(find.byKey(const Key('backup-primary-action')));
      await tester.pumpAndSettle();

      expect(find.byType(BackupStorageHelp), findsOneWidget);
      expect(find.text('云端保存位置'), findsOneWidget);
      expect(find.byType(BackupStatusCard), findsNothing);
      expect(find.text('查看并处理'), findsNothing);
      expect(find.text('生成恢复包'), findsNothing);
      expect(destination.checkCalls, 0);
      expect(runner.calls, 0);
      expect(connections.getByIdCalls, 1);
    },
  );

  testWidgets(
    'detail opens storage help for collection failure without manage or recovery',
    (tester) async {
      final profile = _velockProfile();
      await seedFailedRun(profile, errorCode: _collectionFailure);
      await mount(tester, const SyncProfileDetail(profileId: 'p'));

      expect(find.text('检查保存位置'), findsOneWidget);
      expect(find.text('查看并处理'), findsNothing);
      expect(find.text('生成恢复包'), findsNothing);

      await tester.tap(find.byKey(const Key('backup-primary-action')));
      await tester.pumpAndSettle();

      expect(find.byType(BackupStorageHelp), findsOneWidget);
      expect(find.text('云端保存位置'), findsOneWidget);
      expect(find.byType(BackupStatusCard), findsNothing);
      expect(find.text('查看并处理'), findsNothing);
      expect(find.text('生成恢复包'), findsNothing);
      expect(destination.checkCalls, 0);
      expect(runner.calls, 0);
      expect(connections.getByIdCalls, 1);
    },
  );

  testWidgets(
    'open does not probe and success offers sync only after an explicit check',
    (tester) async {
      final profile = _velockProfile();
      await seedFailedRun(profile, errorCode: _atomicFailure);
      final profileBefore = (await repository.read('p'))!.toJson();
      await mount(tester, BackupStorageHelp(profile: profile));

      expect(find.text('云端保存位置'), findsOneWidget);
      // Why the page opened comes from the recorded run, not a new probe.
      expect(find.text('这个文件夹不能写入。请换一个这个账号有写入权限的文件夹。'), findsOneWidget);
      expect(find.byKey(const Key('storage-change-folder')), findsOneWidget);
      expect(find.byKey(const Key('storage-check')), findsOneWidget);
      expect(find.byKey(const Key('storage-sync')), findsNothing);
      expect(destination.checkCalls, 0);
      expect(runner.calls, 0);
      await expectOldFailurePreserved(profileBefore);

      await tester.tap(find.byKey(const Key('storage-check')));
      await tester.pumpAndSettle();

      expect(destination.checkCalls, 1);
      expect(destination.lastConnectionId, 'cloud');
      expect(destination.lastVaultId, 'vault');
      expect(destination.lastTrustedProducerIds, isEmpty);
      expect(destination.lastRestoring, isFalse);
      expect(destination.lastRemoteRootSegments, ['共享给我', 'new folder']);
      expect(runner.calls, 0);
      expect(find.text('可以写入，还没有开始备份'), findsOneWidget);
      expect(find.byKey(const Key('storage-sync')), findsOneWidget);
      await expectOldFailurePreserved(profileBefore);

      await tester.tap(find.byKey(const Key('storage-sync')));
      await tester.pumpAndSettle();
      expect(runner.calls, 1);
    },
  );

  testWidgets('failed check is persistent and never offers sync', (
    tester,
  ) async {
    final profile = _velockProfile();
    await seedFailedRun(profile, errorCode: _atomicFailure);
    final profileBefore = (await repository.read('p'))!.toJson();
    destination.failureCode = _collectionFailure;
    await mount(tester, BackupStorageHelp(profile: profile));

    await tester.tap(find.byKey(const Key('storage-check')));
    await tester.pumpAndSettle();

    expect(destination.checkCalls, 1);
    expect(runner.calls, 0);
    expect(find.byKey(const Key('storage-sync')), findsNothing);
    expect(find.text('这个文件夹不能写入。请换一个这个账号有写入权限的文件夹。'), findsOneWidget);
    // The fix is offered right there, ahead of checking again.
    expect(
      tester.getTopLeft(find.byKey(const Key('storage-change-folder'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('storage-check'))).dy),
    );
    await tester.pump(const Duration(seconds: 5));
    expect(find.byKey(const Key('storage-feedback')), findsOneWidget);
    expect(find.byKey(const Key('storage-sync')), findsNothing);
    await expectOldFailurePreserved(profileBefore);
  });

  testWidgets('Velock check uses the profile child-directory scope', (
    tester,
  ) async {
    final profile = _velockProfile();
    await repository.save(profile);
    await mount(tester, BackupStorageHelp(profile: profile));

    expect(find.text('/base/backup/共享给我/new folder'), findsOneWidget);
    await tester.tap(find.byKey(const Key('storage-check')));
    await tester.pumpAndSettle();

    expect(destination.lastRemoteRootSegments, ['共享给我', 'new folder']);
  });

  testWidgets('selected-folder check uses the empty connection-root scope', (
    tester,
  ) async {
    final profile = _folderProfile();
    await repository.save(profile);
    await mount(tester, BackupStorageHelp(profile: profile));

    expect(find.text('/base/backup'), findsOneWidget);
    await tester.tap(find.byKey(const Key('storage-check')));
    await tester.pumpAndSettle();

    expect(destination.lastRemoteRootSegments, isEmpty);
    expect(runner.calls, 0);
  });

  testWidgets('a Velock backup moves to another folder from here', (
    tester,
  ) async {
    final profile = _velockProfile();
    await seedFailedRun(profile, errorCode: _collectionFailure);
    destination.failureCode = _collectionFailure;
    await mount(tester, BackupStorageHelp(profile: profile));

    await tester.tap(find.byKey(const Key('storage-check')));
    await tester.pumpAndSettle();
    destination.failureCode = null;

    await tester.tap(find.byKey(const Key('storage-change-folder')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('new-backup-folder')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('backup-folder-可写')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('use-backup-folder')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('backup-location-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('已改用新文件夹。先检查一下，再开始备份。'), findsOneWidget);
    expect(find.text('/base/backup/共享给我/new folder/可写'), findsOneWidget);
    expect(
      VelockSyncProfile.fromEnvelope(
        (await repository.read('p'))!,
      ).remoteRootSegments,
      ['共享给我', 'new folder', '可写'],
    );
    // Saving is not backing up, and the next check uses the new folder.
    expect(runner.calls, 0);
    expect(find.byKey(const Key('storage-sync')), findsNothing);
    await tester.tap(find.byKey(const Key('storage-check')));
    await tester.pumpAndSettle();
    expect(destination.lastRemoteRootSegments, ['共享给我', 'new folder', '可写']);
    expect(find.byKey(const Key('storage-sync')), findsOneWidget);
  });

  testWidgets('a rejected sign-in offers editing the connection', (
    tester,
  ) async {
    final profile = _velockProfile();
    await repository.save(profile);
    destination.failureCode = 'provider.http.401';
    await mount(tester, BackupStorageHelp(profile: profile));

    await tester.tap(find.byKey(const Key('storage-check')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('storage-fix-connection')), findsOneWidget);
    expect(find.text('修改连接'), findsOneWidget);
    expect(find.byKey(const Key('storage-change-folder')), findsNothing);
  });

  testWidgets(
    'a backup with history is never just pointed at a folder without it',
    (tester) async {
      // The 2026-10-04 trap: the first backup published 11 batches, then the
      // location was changed to an empty folder and every run after that
      // stopped with "history missing". Moving now means a new full backup.
      final profile = _velockProfile();
      await seedFailedRun(profile, errorCode: _collectionFailure);
      await database.recordOutgoingBatch(
        profileId: 'p',
        batchId: 'b1',
        sequence: 1,
        state: 'uploading',
      );
      await database.markOutgoingBatchPublished(
        profileId: 'p',
        batchId: 'b1',
        publishedAt: DateTime.utc(2026, 9, 26),
      );
      destination.failureCode = _collectionFailure;
      await mount(tester, BackupStorageHelp(profile: profile));
      await tester.tap(find.byKey(const Key('storage-check')));
      await tester.pumpAndSettle();
      // The chosen folder holds no copy of this backup.
      destination.failureCode = 'backup_not_found';

      await tester.tap(find.byKey(const Key('storage-change-folder')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('backup-folder-可写')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('use-backup-folder')));
      await tester.pumpAndSettle();

      expect(destination.lastRestoring, isTrue);
      expect(find.byKey(const Key('backup-location-confirm')), findsNothing);
      expect(find.byKey(const Key('backup-location-rebuild')), findsOneWidget);
      expect(find.text('建立完整备份'), findsOneWidget);

      // "Choose another" goes back to the picker; nothing was saved.
      await tester.tap(find.text('换一个文件夹'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('use-backup-folder')), findsOneWidget);
      expect(
        VelockSyncProfile.fromEnvelope(
          (await repository.read('p'))!,
        ).remoteRootSegments,
        ['共享给我', 'new folder'],
      );
      expect(runner.calls, 0);
    },
  );
}
