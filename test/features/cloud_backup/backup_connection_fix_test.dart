import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_detail.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_home.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_providers.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_dispatcher.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';

/// QA 2026-09-29: after the WebDAV password was changed, a backup failed with
/// 401 and the card only offered a manage page that cannot edit the login,
/// so the backup could never recover.
void main() {
  late SyncStateDatabase database;
  late SyncProfileRepository repository;
  late _RecordingRuns runner;
  final editorQueries = <Map<String, String>>[];

  setUp(() async {
    database = await SyncStateDatabase.inMemory();
    repository = SyncProfileRepository(database);
    runner = _RecordingRuns();
    editorQueries.clear();
    await repository.save(
      VelockSyncProfile(
        profileId: 'p',
        datasetId: 'dataset',
        vaultId: 'vault',
        deviceId: 'consumer',
        displayName: '我的格间',
        connectionId: 'cloud',
        pairedProducerId: 'source',
        pairedProducerPublicKeyId: 'public-key-ref',
        exchangeBindingId: 'binding',
        backgroundPolicy: const SyncProfileBackgroundPolicy(),
        state: SyncProfileState.active,
        createdAt: DateTime.utc(2026, 9, 29),
      ).toEnvelope(),
    );
  });

  tearDown(() => database.close());

  Future<void> seedFailure(String errorCode) async {
    await database.startSyncRun(
      runId: 'failed-run',
      profileId: 'p',
      startedAt: DateTime.utc(2026, 9, 29),
    );
    await database.finishSyncRun(
      runId: 'failed-run',
      state: 'failed',
      completedAt: DateTime.utc(2026, 9, 29, 1),
      errorCode: errorCode,
    );
  }

  Future<void> mount(WidgetTester tester, Widget root) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => root),
        GoRoute(
          name: AppRoutes.newWebDav.name,
          path: AppRoutes.newWebDav.path,
          builder: (context, state) {
            editorQueries.add(state.uri.queryParameters);
            return Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => leaveConnectionEditor(
                    context,
                    state.uri.queryParameters['returnTo'],
                  ),
                  child: const Text('fake-save'),
                ),
              ),
            );
          },
        ),
        GoRoute(
          path: AppRoutes.connections.path,
          builder: (_, _) => const Scaffold(body: Text('connections-list')),
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
          connectionRepositoryProvider.overrideWithValue(_Connections()),
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

  Future<void> fixConnection(WidgetTester tester) async {
    expect(find.text('服务器拒绝了登录'), findsOneWidget);
    expect(find.text('修改连接'), findsOneWidget);
    expect(find.text('查看并处理'), findsNothing);
    await tester.tap(find.byKey(const Key('backup-primary-action')));
    await tester.pumpAndSettle();
    expect(editorQueries.single, {
      'replace': 'cloud',
      'returnTo': connectionEditorPopBack,
    });
    await tester.tap(find.text('fake-save'));
    await tester.pumpAndSettle();
    // Saving only returns; the retry needs its own explicit confirmation.
    expect(find.text('connections-list'), findsNothing);
    expect(find.text('连接已更新'), findsOneWidget);
    expect(runner.calls, 0);
  }

  testWidgets('detail: a rejected sign-in edits the connection, then retries '
      'only after the user confirms', (tester) async {
    await seedFailure('provider.http.401');
    await mount(tester, const SyncProfileDetail(profileId: 'p'));

    await fixConnection(tester);
    await tester.tap(find.text('重试备份').last);
    await tester.pumpAndSettle();
    expect(runner.calls, 1);
  });

  testWidgets('home: choosing "later" after editing starts no backup', (
    tester,
  ) async {
    await seedFailure('provider.webdav.unauthorized');
    await mount(tester, const SyncProfilesHome());

    await fixConnection(tester);
    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();
    expect(find.text('连接已更新'), findsNothing);
    expect(runner.calls, 0);
  });

  testWidgets('leaving the editor without saving offers no retry', (
    tester,
  ) async {
    await seedFailure('provider.http.401');
    await mount(tester, const SyncProfileDetail(profileId: 'p'));

    await tester.tap(find.byKey(const Key('backup-primary-action')));
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).last);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.text('连接已更新'), findsNothing);
    expect(runner.calls, 0);
  });

  testWidgets('detail always keeps a retry for a failure fixed elsewhere', (
    tester,
  ) async {
    // A 403 fixed on the server side needs no change in the app.
    await seedFailure('provider.http.403');
    await mount(tester, const SyncProfileDetail(profileId: 'p'));

    expect(find.text('查看并处理'), findsOneWidget);
    await tester.tap(find.byKey(const Key('backup-retry')));
    await tester.pumpAndSettle();
    expect(runner.calls, 1);
  });

  // QA 2026-09-29 (finding 7): a restored profile never runs in the
  // background, so after Velock applied the backup the card waited forever.
  testWidgets('a restore waiting for Velock offers a progress check', (
    tester,
  ) async {
    await seedFailure('local.velock_snapshot_application_required');
    await mount(tester, const SyncProfileDetail(profileId: 'p'));

    expect(find.byKey(const Key('backup-retry')), findsNothing);
    final check = find.byKey(const Key('backup-check-restore'));
    expect(check, findsOneWidget);
    expect(find.text('检查恢复进度'), findsOneWidget);
    await tester.tap(check);
    await tester.pumpAndSettle();
    expect(runner.calls, 1);
  });

  testWidgets('an object mismatch keeps only its review action', (
    tester,
  ) async {
    await seedFailure('remote.immutable_object_mismatch');
    await mount(tester, const SyncProfileDetail(profileId: 'p'));

    expect(find.byKey(const Key('backup-retry')), findsNothing);
  });
}

ConnectionModel _connection() => ConnectionModel(
  id: 'cloud',
  name: '我的 NAS',
  source: 'source',
  target: 'target',
  protocol: const ProtocolModel.webDav(
    protocolType: WebDavProtocolType.http,
    address: 'http://127.0.0.1',
    port: '8888',
    path: '/',
    credentialRef: 'DO_NOT_DISPLAY',
  ),
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  status: ConnectionStatus.pending,
);

class _Connections implements ConnectionRepository {
  @override
  Future<ConnectionModel?> getConnectionById(String id) async =>
      id == 'cloud' ? _connection() : null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
