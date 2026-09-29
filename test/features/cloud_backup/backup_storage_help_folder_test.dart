import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_profile.dart';
import 'package:velock_sync/features/cloud_backup/application/backup_destination_service.dart';
import 'package:velock_sync/features/cloud_backup/application/webdav_backup_folder_browser.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_folder_picker.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_storage_help.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

const _atomicFailure = 'provider.webdav.atomic_create_unsupported';

class _Connections implements ConnectionRepository {
  _Connections(this.connection);

  final ConnectionModel connection;

  @override
  Future<ConnectionModel?> getConnectionById(String id) async => connection;

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
    lastRemoteRootSegments = List<String>.of(remoteRootSegments);
    final failure = failureCode;
    if (failure != null) throw BackupDestinationException(failure);
  }
}

final _fileSync = SelectedFolderSyncProfile(
  profileId: 'p',
  datasetId: 'dataset',
  vaultId: 'vault',
  deviceId: 'device',
  displayName: '工作文件夹',
  rootPath: '/safe/Documents',
  connectionId: 'cloud',
  keyId: 'key-1',
  rootKeyRef: 'velock-sync/vault-root/opaque',
  signingKeyRef: 'velock-sync/device-signing/opaque',
  createdAt: DateTime.utc(2026, 9, 26),
);

ConnectionModel _connection() => ConnectionModel(
  id: 'cloud',
  name: '我的 NAS',
  source: 'source',
  target: 'target',
  protocol: const ProtocolModel.webDav(
    protocolType: WebDavProtocolType.https,
    address: 'https://nas.invalid/base',
    port: '443',
    path: '/entry',
    credentialRef: 'DO_NOT_DISPLAY',
  ),
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  status: ConnectionStatus.active,
);

void main() {
  late SyncStateDatabase database;
  late SyncProfileRepository profiles;
  late SelectedFolderSyncProfileRepository fileSyncProfiles;
  late _Connections connections;
  late _RecordingDestination destination;

  setUp(() async {
    database = await SyncStateDatabase.inMemory();
    profiles = SyncProfileRepository(database);
    fileSyncProfiles = SelectedFolderSyncProfileRepository(database);
    connections = _Connections(_connection());
    destination = _RecordingDestination();
    await fileSyncProfiles.save(_fileSync);
  });

  tearDown(() => database.close());

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => BackupStorageHelp(
            profile: SyncProfileEnvelope.fromJson(_fileSync.toJson()),
          ),
        ),
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
          syncProfileRepositoryProvider.overrideWithValue(profiles),
          selectedFolderProfilesProvider.overrideWithValue(fileSyncProfiles),
          connectionRepositoryProvider.overrideWithValue(connections),
          backupDestinationServiceProvider.overrideWithValue(destination),
          backupFolderLoaderProvider.overrideWithValue(
            ({required protocol, required relativeSegments}) async => [
              for (final name in const ['111', '222'])
                WebDavBackupFolder(name: name),
            ],
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
  }

  testWidgets('opening the page performs no remote check', (tester) async {
    await mount(tester);

    expect(find.text('检查云端位置'), findsOneWidget);
    expect(find.text('/base/entry'), findsOneWidget);
    expect(find.byKey(const Key('storage-change-folder')), findsOneWidget);
    expect(find.byKey(const Key('storage-check')), findsOneWidget);
    expect(destination.checkCalls, 0);
    expect(find.byKey(const Key('storage-sync')), findsNothing);
  });

  testWidgets('long explanations wait until the user asks for them', (
    tester,
  ) async {
    await mount(tester);

    // Before a check the page states only what is needed to act.
    expect(find.textContaining('只写入并清理一个临时测试文件'), findsOneWidget);
    expect(find.textContaining('不会改动后台同步'), findsNothing);
    expect(find.byKey(const Key('storage-fix-hint')), findsNothing);
    expect(find.textContaining('要检查的是云端能否安全写入'), findsNothing);

    await tester.tap(find.byKey(const Key('storage-detail-toggle')));
    await tester.pumpAndSettle();

    expect(find.textContaining('不会改动后台同步'), findsOneWidget);
    expect(find.textContaining('不代表文件已经备份成功'), findsOneWidget);
    expect(find.text('收起'), findsOneWidget);
  });

  testWidgets(
    'an unwritable root offers choosing a writable folder, saving without syncing',
    (tester) async {
      destination.failureCode = _atomicFailure;
      await mount(tester);

      await tester.tap(find.byKey(const Key('storage-check')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('用下面的“选择可写入文件夹”换一个这个账号能写入的文件夹'),
        findsOneWidget,
      );
      expect(find.textContaining('尚不支持直接迁移'), findsNothing);
      // The long explanation is not repeated next to the actionable hint.
      expect(find.textContaining('不会改动后台同步'), findsNothing);

      await tester.tap(find.byKey(const Key('storage-change-folder')));
      await tester.pumpAndSettle();

      expect(find.text('111'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('backup-folder-111')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('use-backup-folder')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('storage-confirm-folder')), findsOneWidget);
      expect(find.textContaining('不改动连接本身'), findsOneWidget);
      await tester.tap(find.byKey(const Key('storage-confirm-folder')));
      await tester.pumpAndSettle();

      expect(find.text('保存位置已更新，请重新检查；本次只保存目录，尚未同步。'), findsOneWidget);
      expect(find.text('/base/entry/111'), findsOneWidget);
      expect(find.byKey(const Key('storage-sync')), findsNothing);
      // Saving a location does not transfer anything: neither a blocking
      // progress surface nor an in-flight inline spinner is shown.
      expect(find.byKey(const Key('sync-progress-dialog')), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(destination.checkCalls, 1);
      expect((await fileSyncProfiles.read('p'))!.remoteRootSegments, ['111']);
      // The connection itself and the local folder are untouched.
      expect(
        (connections.connection.protocol as WebDavProtocolModel).path,
        '/entry',
      );
      expect((await fileSyncProfiles.read('p'))!.rootPath, '/safe/Documents');
    },
  );

  testWidgets('cancelling the confirmation changes nothing', (tester) async {
    await mount(tester);

    await tester.tap(find.byKey(const Key('storage-change-folder')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('backup-folder-222')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('use-backup-folder')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect((await fileSyncProfiles.read('p'))!.remoteRootSegments, isEmpty);
    expect(find.text('/base/entry'), findsOneWidget);
    expect(destination.checkCalls, 0);
  });

  testWidgets('choosing the connection root is refused with a reason', (
    tester,
  ) async {
    await mount(tester);

    await tester.tap(find.byKey(const Key('storage-change-folder')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('use-backup-folder')));
    await tester.pumpAndSettle();

    expect(find.textContaining('请选择连接里的一个具体文件夹'), findsOneWidget);
    expect(find.byKey(const Key('storage-confirm-folder')), findsNothing);
    expect((await fileSyncProfiles.read('p'))!.remoteRootSegments, isEmpty);
  });

  testWidgets('a chosen folder is checked at its own scope', (tester) async {
    await fileSyncProfiles.selectSyncFolder(
      expected: (await fileSyncProfiles.read('p'))!,
      segments: const ['111'],
    );
    await mount(tester);

    expect(find.text('/base/entry/111'), findsOneWidget);
    await tester.tap(find.byKey(const Key('storage-check')));
    await tester.pumpAndSettle();

    expect(destination.lastRemoteRootSegments, ['111']);
    expect(find.text('位置检查通过，尚未同步'), findsOneWidget);
    expect(find.byKey(const Key('storage-sync')), findsOneWidget);
  });

  testWidgets(
    'a rejected relocation keeps the previous scope and explains it',
    (tester) async {
      await mount(tester);

      await tester.tap(find.byKey(const Key('storage-change-folder')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('backup-folder-111')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('use-backup-folder')));
      await tester.pumpAndSettle();
      // The task is paused underneath the page, so the save must be rejected.
      await fileSyncProfiles.pause('p');
      await tester.tap(find.byKey(const Key('storage-confirm-folder')));
      await tester.pumpAndSettle();

      expect(find.textContaining('位置未保存'), findsOneWidget);
      expect(find.text('保存位置已更新，请重新检查；本次只保存目录，尚未同步。'), findsNothing);
      expect(
        (await database.readSyncProfilePayload('p'))!,
        isNot(contains('"remoteRootSegments":["111"]')),
      );
    },
  );
}
