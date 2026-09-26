import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_history_help.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_detail.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_providers.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_dispatcher.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';
import 'package:velock_sync/widgets/common_widgets.dart';

final _profile = VelockSyncProfile(
  profileId: 'p',
  datasetId: 'dataset',
  vaultId: 'vault',
  deviceId: 'consumer',
  displayName: '我的格间',
  connectionId: 'cloud',
  pairedProducerId: 'source',
  pairedProducerPublicKeyId: 'public-key-ref',
  exchangeBindingId: 'binding',
  remoteRootSegments: ['共享给我', 'new folder'],
  backgroundPolicy: const SyncProfileBackgroundPolicy(),
  state: SyncProfileState.active,
  createdAt: DateTime.utc(2026, 9, 26),
).toEnvelope();

ConnectionModel? _connection;

class _Connection extends ConnectionDetail {
  @override
  Future<ConnectionModel?> build(String id) async => _connection;
}

class _Ready implements VelockWizardReadinessService {
  @override
  Future<VelockWizardReadiness> inspect({String? syncAppInstanceId}) async =>
      const VelockWizardReadiness(VelockWizardAvailability.ready);
}

class _NoRuns implements SyncProfileRunService {
  int calls = 0;
  @override
  Future<SyncProfileDispatchResult> runNow(String profileId) async {
    calls++;
    throw StateError('Viewing help must not start sync');
  }
}

void main() {
  late SyncStateDatabase db;
  late SyncProfileRepository repository;
  late _NoRuns runner;
  setUp(() async {
    db = await SyncStateDatabase.inMemory();
    repository = SyncProfileRepository(db);
    runner = _NoRuns();
    await repository.save(_profile);
    await db.startSyncRun(
      runId: 'failed',
      profileId: 'p',
      startedAt: DateTime.utc(2026, 9, 26),
    );
    await db.finishSyncRun(
      runId: 'failed',
      state: 'failed',
      completedAt: DateTime.utc(2026, 9, 26, 1),
      errorCode: 'remote.velock_history_incomplete',
    );
    _connection = ConnectionModel(
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
  });
  tearDown(() => db.close());

  Future<GoRouter> mount(
    WidgetTester tester, {
    String locale = 'zh',
    double scale = 1,
    bool directly = false,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => directly
              ? BackupHistoryHelp(profile: _profile)
              : const SyncProfileDetail(profileId: 'p'),
        ),
        GoRoute(
          path: '/connections/connection/:id',
          builder: (_, state) =>
              Scaffold(body: Text('browser:${state.pathParameters['id']}')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncStateDatabaseProvider.overrideWithValue(db),
          syncProfileRepositoryProvider.overrideWithValue(repository),
          syncProfileRunServiceProvider.overrideWithValue(runner),
          velockWizardReadinessServiceProvider.overrideWithValue(_Ready()),
          connectionDetailProvider('cloud').overrideWith(_Connection.new),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          locale: Locale(locale),
          supportedLocales: const [Locale('zh'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: ThemeData(platform: TargetPlatform.iOS),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets(
    'hero opens specific help, not Manage; back preserves failure and profile',
    (tester) async {
      await mount(tester);
      final before = (await repository.read('p'))!.toJson();
      expect(find.text('云端备份不完整'), findsOneWidget);
      expect(find.text('查看并处理'), findsNothing);
      await tester.tap(find.byKey(const Key('backup-primary-action')));
      await tester.pumpAndSettle();
      expect(find.text('备份为什么停止'), findsOneWidget);
      expect(find.text('需要以前的备份才能继续'), findsOneWidget);
      expect(find.text('后台同步'), findsNothing);
      expect(find.text('重新连接格间'), findsNothing);
      expect(find.text('/base/backup/共享给我/new folder'), findsOneWidget);
      expect(find.textContaining('DO_NOT_DISPLAY'), findsNothing);
      expect(runner.calls, 0);
      await tester.tap(find.byType(AppBackButton));
      await tester.pumpAndSettle();
      expect(find.text('云端备份不完整'), findsOneWidget);
      expect((await repository.read('p'))!.toJson(), before);
      expect(
        (await db.latestSyncRun('p'))!.errorCode,
        'remote.velock_history_incomplete',
      );
      expect(runner.calls, 0);
    },
  );

  testWidgets(
    'browse action uses the actual connection, without starting a run',
    (tester) async {
      await mount(tester, directly: true);
      await tester.scrollUntilVisible(
        find.byKey(const Key('backup-history-browse-location')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('backup-history-browse-location')));
      await tester.pumpAndSettle();
      expect(find.text('browser:cloud'), findsOneWidget);
      expect(runner.calls, 0);
    },
  );

  testWidgets(
    'missing original explains unsupported rebuild and never offers reset',
    (tester) async {
      await mount(tester, directly: true);
      await tester.scrollUntilVisible(
        find.byKey(const Key('backup-history-missing-original')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('backup-history-missing-original')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('backup-history-missing-original')),
      );
      await tester.pumpAndSettle();
      expect(find.text('先保留本机数据和旧备份'), findsOneWidget);
      expect(find.textContaining('当前版本还不能'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(find.text('先保留本机数据和旧备份'), findsNothing);
      expect((await db.latestSyncRun('p'))!.state, 'failed');
      expect(runner.calls, 0);
    },
  );

  testWidgets(
    'missing connection is explicit, not a bogus root or browse action',
    (tester) async {
      _connection = null;
      await mount(tester, directly: true);
      expect(find.text('当前连接已不存在，无法核对保存位置。'), findsOneWidget);
      expect(
        find.byKey(const Key('backup-history-browse-location')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final locale in ['zh', 'en']) {
    testWidgets('$locale help stays usable at large text size', (tester) async {
      await mount(tester, directly: true, locale: locale, scale: 1.8);
      await tester.scrollUntilVisible(
        find.byKey(const Key('backup-history-missing-original')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('backup-history-missing-original')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('backup-history-missing-original')),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          locale == 'zh' ? '先保留本机数据和旧备份' : 'Keep local data and any old backup',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      expect(runner.calls, 0);
    });
  }
}
