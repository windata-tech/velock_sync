import 'package:velock_sync/features/cloud_backup/application/velock_snapshot_providers.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_storage_help.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:material_ui/material_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/cloud_backup/model/backup_presentation.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_widgets.dart';
import 'package:velock_sync/features/cloud_backup/ui/velock_recovery_guide.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_workspace.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_dispatcher.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';

void main() {
  final captureKey = GlobalKey();
  late SyncStateDatabase database;
  late SyncProfileRepository repository;
  setUp(() async {
    database = await SyncStateDatabase.inMemory();
    repository = SyncProfileRepository(database);
    final font = Platform.environment['BACKUP_UI_FONT'];
    if (font != null) {
      final loader = FontLoader('BackupQA')
        ..addFont(
          File(font).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      await loader.load();
      for (final entry in {
        'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
        'packages/cupertino_icons/CupertinoIcons':
            'packages/cupertino_icons/assets/CupertinoIcons.ttf',
      }.entries) {
        final icons = FontLoader(entry.key)
          ..addFont(rootBundle.load(entry.value));
        await icons.load();
      }
    }
  });
  tearDown(() => database.close());

  Widget app(
    Widget home, {
    String locale = 'zh',
    double scale = 1,
    TargetPlatform platform = TargetPlatform.iOS,
    SyncProfileRunService? runService,
    ConnectionRepository? connections,
    Future<bool> Function(String)? continuationReady,
    VelockWizardAvailability readiness = VelockWizardAvailability.ready,
  }) => ProviderScope(
    overrides: [
      syncStateDatabaseProvider.overrideWithValue(database),
      if (continuationReady != null)
        snapshotContinuationReadyProvider.overrideWithValue(continuationReady),
      if (connections != null)
        connectionRepositoryProvider.overrideWithValue(connections),
      syncProfileRepositoryProvider.overrideWithValue(repository),
      velockWizardReadinessServiceProvider.overrideWithValue(_Ready(readiness)),
      if (runService != null)
        syncProfileRunServiceProvider.overrideWithValue(runService),
    ],
    child: MaterialApp(
      locale: Locale(locale),
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: const [...GlobalMaterialLocalizations.delegates],
      theme: ThemeData(
        platform: platform,
        fontFamily: 'BackupQA',
        cupertinoOverrideTheme: CupertinoThemeData(
          textTheme: CupertinoTextThemeData(
            textStyle: const CupertinoTextThemeData().textStyle.copyWith(
              fontFamily: 'BackupQA',
            ),
            actionTextStyle: const CupertinoTextThemeData().actionTextStyle
                .copyWith(fontFamily: 'BackupQA'),
            navTitleTextStyle: const CupertinoTextThemeData().navTitleTextStyle
                .copyWith(fontFamily: 'BackupQA'),
            navLargeTitleTextStyle: const CupertinoTextThemeData()
                .navLargeTitleTextStyle
                .copyWith(fontFamily: 'BackupQA'),
            navActionTextStyle: const CupertinoTextThemeData()
                .navActionTextStyle
                .copyWith(fontFamily: 'BackupQA'),
            tabLabelTextStyle: const CupertinoTextThemeData().tabLabelTextStyle
                .copyWith(fontFamily: 'BackupQA'),
          ),
        ),
        colorSchemeSeed: const Color(0xFF3262FF),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: RepaintBoundary(key: captureKey, child: child!),
      ),
      home: home,
    ),
  );

  testWidgets(
    'a run outside the retained home refreshes its completed summary',
    (tester) async {
      final pending = Completer<SyncProfileDispatchResult>();
      await repository.save(_profile());
      await tester.pumpWidget(
        app(
          Scaffold(
            body: Column(
              children: [
                const Expanded(child: SyncProfilesHome()),
                Consumer(
                  builder: (context, ref, _) => TextButton(
                    onPressed: () =>
                        runSyncWithProgress(context, ref, 'velock'),
                    child: const Text('run from setup'),
                  ),
                ),
              ],
            ),
          ),
          runService: _PendingRunService(pending.future),
        ),
      );
      await tester.pumpAndSettle();
      final home = tester.element(find.byType(SyncProfilesHome));
      expect(find.text('还没有完成首次备份'), findsOneWidget);
      await tester.tap(find.text('run from setup'));
      await tester.pump();
      await database.startSyncRun(
        runId: 'setup-run',
        profileId: 'velock',
        startedAt: DateTime.utc(2026, 9, 27),
      );
      await database.finishSyncRun(
        runId: 'setup-run',
        state: 'completed',
        completedAt: DateTime.utc(2026, 9, 27, 0, 1),
      );
      pending.complete(
        const SyncProfileDispatchResult(
          profileId: 'velock',
          status: SyncProfileDispatchStatus.completed,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        identical(home, tester.element(find.byType(SyncProfilesHome))),
        isTrue,
      );
      expect(find.text('还没有完成首次备份'), findsNothing);
      expect(find.text('上次备份已完成'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('return from owner continues once only after a local receipt', (
    tester,
  ) async {
    await repository.save(_profile());
    var ready = false;
    final pending = Completer<SyncProfileDispatchResult>();
    final service = _PendingRunService(pending.future);
    await tester.pumpWidget(
      app(
        const SyncProfilesHome(),
        runService: service,
        continuationReady: (_) async => ready,
      ),
    );
    await tester.pumpAndSettle();
    expect(service.calls, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    ready = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(service.calls, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(service.calls, 1);
    ready = false;
    pending.complete(
      const SyncProfileDispatchResult(
        profileId: 'velock',
        status: SyncProfileDispatchStatus.completed,
      ),
    );
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(service.calls, 1);
    expect(tester.takeException(), isNull);
  });

  Future<void> capture(WidgetTester tester, String name) async {
    final directory = Platform.environment['BACKUP_UI_SCREENSHOT_DIR'];
    if (directory == null) return;
    await tester.runAsync(() async {
      final boundary =
          captureKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await Directory(directory).create(recursive: true);
      await File(
        '$directory/$name.png',
      ).writeAsBytes(bytes.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final language in ['zh', 'en']) {
    testWidgets(
      'an old Velock replaces setup and restore entries ($language)',
      (tester) async {
        await tester.pumpWidget(
          app(
            const SyncProfilesHome(),
            locale: language,
            readiness: VelockWizardAvailability.velockUpdateRequired,
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('velock-gate-velockUpdateRequired')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('velock-gate-open')), findsOneWidget);
        expect(find.byKey(const Key('velock-gate-recheck')), findsOneWidget);
        expect(find.byKey(const Key('velock-cloud-restore')), findsNothing);
        expect(
          find.textContaining(language == 'zh' ? '2.0.7' : 'Velock 2.0.7'),
          findsOneWidget,
        );
        if (language == 'en') {
          final chinese = RegExp(r'[\u4e00-\u9fff]');
          for (final text in tester.widgetList<Text>(find.byType(Text))) {
            expect(
              chinese.hasMatch(text.data ?? ''),
              isFalse,
              reason: text.data,
            );
          }
        }
      },
    );
  }

  testWidgets('an unsupported build offers no pairing or restore', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        const SyncProfilesHome(),
        platform: TargetPlatform.android,
        readiness: VelockWizardAvailability.unsupportedPlatform,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('velock-gate-unsupportedPlatform')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('velock-gate-open')), findsNothing);
    expect(find.byKey(const Key('velock-cloud-restore')), findsNothing);
  });

  testWidgets('a current Velock still shows setup and restore', (tester) async {
    await tester.pumpWidget(app(const SyncProfilesHome()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('velock-cloud-restore')), findsOneWidget);
    expect(find.byKey(const Key('velock-gate-title')), findsNothing);
  });

  testWidgets(
    'Velock and folder homes are separate destinations even with both profiles',
    (tester) async {
      await repository.save(_profile());
      await repository.save(_profile(folder: true));
      await tester.pumpWidget(app(const SyncProfilesHome()));
      await tester.pumpAndSettle();
      expect(find.text('我的格间'), findsOneWidget);
      expect(find.text('工作文件夹'), findsNothing);
      expect(find.byKey(const Key('selected-folder-create')), findsNothing);
      await tester.pumpWidget(
        app(
          const SyncProfilesHome(
            key: ValueKey('folders'),
            kind: SyncDatasetKind.selectedFolder,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('工作文件夹'), findsOneWidget);
      expect(find.text('我的格间'), findsNothing);
      expect(find.text('从云端恢复'), findsNothing);
    },
  );

  testWidgets(
    'home transfer failure clears progress and keeps a safe page message',
    (tester) async {
      const secret = 'sentinel-home-runner-error';
      final pending = Completer<SyncProfileDispatchResult>();
      await repository.save(_profile());
      await tester.pumpWidget(
        app(
          const SyncProfilesHome(),
          platform: TargetPlatform.android,
          runService: _PendingRunService(pending.future),
        ),
      );
      await tester.pumpAndSettle();

      final primary = find.byKey(const Key('backup-primary-action'));
      await tester.tap(primary);
      // The in-flight state is an inline spinner on the button, so the tree
      // never settles while the run is pending: pump explicit frames instead
      // of pumpAndSettle.
      await tester.pump();

      expect(find.byKey(const Key('sync-progress-dialog')), findsNothing);
      expect(find.text('正在传输，请稍候'), findsOneWidget);
      expect(tester.widget<BackupActionButton>(primary).busy, isTrue);
      expect(tester.widget<BackupActionButton>(primary).onPressed, isNull);
      expect(
        find.descendant(
          of: primary,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );

      // The real runner records the failed run before it throws.
      await database.startSyncRun(
        runId: 'home-run',
        profileId: 'velock',
        startedAt: DateTime.utc(2026, 9, 27),
      );
      await database.finishSyncRun(
        runId: 'home-run',
        state: 'failed',
        completedAt: DateTime.utc(2026, 9, 27, 0, 1),
        errorCode: 'sync.unexpected',
      );
      pending.completeError(StateError(secret));
      await tester.pumpAndSettle();

      // Only the failure interrupts: it stays until the user acknowledges it.
      expect(find.text('备份失败'), findsOneWidget);
      expect(find.byKey(const Key('sync-failure-alert-ok')), findsOneWidget);
      expect(find.textContaining(secret), findsNothing);
      await tester.tap(find.byKey(const Key('sync-failure-alert-ok')));
      await tester.pumpAndSettle();

      // Back to a usable card: no leftover modal, no stuck spinner.
      expect(find.text('备份失败'), findsNothing);
      expect(find.byKey(const Key('sync-progress-dialog')), findsNothing);
      expect(primary, findsOneWidget);
      expect(tester.widget<BackupActionButton>(primary).busy, isFalse);
      expect(tester.widget<BackupActionButton>(primary).onPressed, isNotNull);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('正在传输，请稍候'), findsNothing);
      expect(find.text('同步未完成，请检查同步配置后重试。'), findsOneWidget);
      // Details are a button inside the status card; the old standalone
      // "backup details and settings" row is gone.
      expect(find.text('备份详情与管理'), findsNothing);
      expect(find.text('详情'), findsOneWidget);
      expect(find.textContaining(secret), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'home resume failure stays paused, blocks duplicate taps, and hides raw error',
    (tester) async {
      const secret = 'sentinel-resume-persistence-error';
      final failingRepository = _ResumeGateRepository(database);
      repository = failingRepository;
      await repository.save(
        _profile().copyWith(state: SyncProfileState.paused),
      );
      await tester.pumpWidget(
        app(const SyncProfilesHome(), platform: TargetPlatform.android),
      );
      await tester.pumpAndSettle();

      final primary = find.byKey(const Key('backup-primary-action'));
      expect(find.text('继续'), findsOneWidget);

      await tester.tap(primary);
      await tester.pump();
      expect(failingRepository.resumeCalls, 1);
      expect(find.text('正在传输…'), findsOneWidget);
      expect(tester.widget<BackupActionButton>(primary).onPressed, isNull);

      await tester.tap(primary, warnIfMissed: false);
      await tester.pump();
      expect(failingRepository.resumeCalls, 1);

      failingRepository.resumeGate.completeError(StateError(secret));
      await tester.pumpAndSettle();

      expect(find.text('备份已暂停'), findsOneWidget);
      expect(find.text('继续'), findsOneWidget);
      expect(find.text('暂时无法继续备份，请稍后重试。'), findsOneWidget);
      expect(find.textContaining(secret), findsNothing);
      expect((await repository.read('velock'))?.state, SyncProfileState.paused);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('home reloads by pulling down, not by a header button', (
    tester,
  ) async {
    await repository.save(_profile());
    await tester.pumpWidget(
      app(const SyncProfilesHome(), platform: TargetPlatform.android),
    );
    await tester.pumpAndSettle();

    // The header button only re-read this device's own records, which the
    // page already does after every action, so it was removed.
    expect(find.byTooltip('刷新状态'), findsNothing);
    await tester.fling(find.text('我的格间'), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('我的格间'), findsOneWidget);
  });

  testWidgets(
    'empty home provides two intentions without technical setup choices',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app(const SyncProfilesHome()));
      await tester.pumpAndSettle();
      expect(find.text('开始备份'), findsOneWidget);
      expect(find.text('从云端恢复'), findsOneWidget);
      for (final text in ['Profile', 'SEQ', 'UPSERT', '数据集', '增量批次']) {
        expect(find.textContaining(text), findsNothing);
      }
      expect(tester.takeException(), isNull);
      await capture(tester, '01-velock-home');
    },
  );

  testWidgets('simple detail hides raw diagnostics behind a real drilldown', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await repository.save(_profile());
    await tester.pumpWidget(app(const SyncProfileDetail(profileId: 'velock')));
    await tester.pumpAndSettle();
    expect(find.byType(TabBar), findsNothing);
    expect(find.text('增量批次'), findsNothing);
    expect(find.text('数据块'), findsNothing);
    expect(find.text('立即备份'), findsOneWidget);
    await capture(tester, '02-backup-detail');
    await tester.scrollUntilVisible(
      find.byKey(const Key('backup-diagnostics')),
      220,
    );
    await tester.tap(find.byKey(const Key('backup-diagnostics')));
    await tester.pumpAndSettle();
    expect(find.text('详细记录与诊断'), findsWidgets);
    expect(find.text('已同步的数据'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'detail transfer failure clears progress and keeps the detail page',
    (tester) async {
      const secret = 'sentinel-detail-runner-error';
      final pending = Completer<SyncProfileDispatchResult>();
      await repository.save(_profile());
      await tester.pumpWidget(
        app(
          const SyncProfileDetail(profileId: 'velock'),
          platform: TargetPlatform.android,
          runService: _PendingRunService(pending.future),
        ),
      );
      await tester.pumpAndSettle();

      final primary = find.byKey(const Key('backup-primary-action'));
      await tester.tap(primary);
      // Inline spinner while the run is pending: pump frames, never settle.
      await tester.pump();

      expect(find.byKey(const Key('sync-progress-dialog')), findsNothing);
      expect(find.text('正在传输，请稍候'), findsOneWidget);
      expect(tester.widget<BackupActionButton>(primary).busy, isTrue);
      expect(tester.widget<BackupActionButton>(primary).onPressed, isNull);

      await database.startSyncRun(
        runId: 'detail-run',
        profileId: 'velock',
        startedAt: DateTime.utc(2026, 9, 27),
      );
      await database.finishSyncRun(
        runId: 'detail-run',
        state: 'failed',
        completedAt: DateTime.utc(2026, 9, 27, 0, 1),
        errorCode: 'sync.unexpected',
      );
      pending.completeError(StateError(secret));
      await tester.pumpAndSettle();

      expect(find.text('备份失败'), findsOneWidget);
      expect(find.byKey(const Key('sync-failure-alert-ok')), findsOneWidget);
      expect(find.textContaining(secret), findsNothing);
      await tester.tap(find.byKey(const Key('sync-failure-alert-ok')));
      await tester.pumpAndSettle();

      expect(find.text('备份失败'), findsNothing);
      expect(find.byKey(const Key('sync-progress-dialog')), findsNothing);
      expect(find.byKey(const Key('backup-status-title')), findsOneWidget);
      expect(find.text('传输记录'), findsOneWidget);
      expect(tester.widget<BackupActionButton>(primary).busy, isFalse);
      expect(tester.widget<BackupActionButton>(primary).onPressed, isNotNull);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('正在传输，请稍候'), findsNothing);
      expect(find.text('同步未完成，请检查同步配置后重试。'), findsOneWidget);
      expect(find.textContaining(secret), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manage background switch updates immediately and persists in place',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await repository.save(_profile());
      await tester.pumpWidget(
        app(const SyncProfileDetail(profileId: 'velock')),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('管理'), 220);
      await tester.tap(find.text('管理'));
      await tester.pumpAndSettle();
      expect(find.text('后台策略'), findsOneWidget);

      final backgroundTile = find.ancestor(
        of: find.text('后台同步'),
        matching: find.byType(AdaptiveSwitchListTile),
      );
      expect(
        tester.widget<AdaptiveSwitchListTile>(backgroundTile).value,
        isFalse,
      );

      await tester.tap(backgroundTile);
      await tester.pumpAndSettle();

      expect(find.text('后台策略'), findsOneWidget);
      expect(
        tester.widget<AdaptiveSwitchListTile>(backgroundTile).value,
        isTrue,
      );
      expect(
        (await repository.read('velock'))?.backgroundPolicy.enabled,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'recovery requires the user to restore the original account first',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app(const VelockRecoveryGuide()));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<BackupActionButton>(
              find.byKey(const Key('restore-continue')),
            )
            .onPressed,
        isNull,
      );
      expect(
        find.byType(TextField),
        findsNothing,
      ); // Sync never asks for recovery secrets.
      await capture(tester, '03-restore');
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('restore-account-confirmed')),
          matching: find.byType(CupertinoSwitch),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<BackupActionButton>(
              find.byKey(const Key('restore-continue')),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'existing connection cannot silently start a second account recovery',
    (tester) async {
      await repository.save(_profile());
      await tester.pumpWidget(app(const VelockRecoveryGuide()));
      await tester.pumpAndSettle();
      expect(find.text('这台设备已经连接格间'), findsOneWidget);
      expect(find.byKey(const Key('restore-continue')), findsNothing);
    },
  );

  for (final language in ['zh', 'en']) {
    testWidgets('folder failure card visual and timestamp $language', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await repository.save(_profile(folder: true));
      await database.startSyncRun(
        runId: 'folder-run',
        profileId: 'folder',
        startedAt: DateTime(2026, 9, 26, 9, 15),
      );
      await database.finishSyncRun(
        runId: 'folder-run',
        state: 'failed',
        completedAt: DateTime(2026, 9, 26, 9, 15, 30),
        errorCode: 'provider.webdav.atomic_create_unsupported',
      );
      await tester.pumpWidget(
        app(
          const SyncProfilesHome(kind: SyncDatasetKind.selectedFolder),
          locale: language,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          language == 'zh'
              ? '上次失败：2026-09-26 09:15'
              : 'Last failure: 2026-09-26 09:15',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          language == 'zh' ? '上次传输未通过' : 'The last transfer failed',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await capture(tester, '05-folder-failure-$language');
    });
  }

  for (final language in ['zh', 'en']) {
    testWidgets('storage help visual $language', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        app(
          BackupStorageHelp(profile: _profile(folder: true)),
          locale: language,
          connections: _VisualConnection(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('storage-check')), findsOneWidget);
      expect(find.byKey(const Key('storage-sync')), findsNothing);
      expect(tester.takeException(), isNull);
      await capture(tester, '06-storage-help-$language');
    });
  }

  testWidgets(
    'cloud safety failures are actionable without MOVE or raw codes',
    (tester) async {
      var pressed = 0;
      await tester.pumpWidget(
        app(
          AdaptiveScaffold(
            title: '格间备份',
            body: ListView(
              children: [
                BackupStatusCard(
                  name: '我的格间',
                  presentation: const BackupPresentation(
                    BackupStage.needsAttention,
                    BackupAction.manage,
                    errorCode: 'provider.webdav.atomic_create_unsupported',
                  ),
                  onAction: () => pressed++,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('MOVE'), findsNothing);
      expect(find.textContaining('atomic_create'), findsNothing);
      await tester.tap(find.byKey(const Key('backup-primary-action')));
      await tester.pump();
      expect(pressed, 1);
      await capture(tester, '04-storage-needs-attention');
    },
  );

  for (final language in ['zh', 'en']) {
    testWidgets('320px $language large text does not overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        app(const SyncProfilesHome(), locale: language, scale: 1.6),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        app(
          AdaptiveScaffold(
            title: 'Status',
            body: ListView(
              children: [
                BackupStatusCard(
                  name: 'Velock',
                  presentation: const BackupPresentation(
                    BackupStage.waitingForRestore,
                    BackupAction.openVelock,
                  ),
                  onAction: () {},
                ),
              ],
            ),
          ),
          locale: language,
          scale: 1.6,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}

SyncProfileEnvelope _profile({bool folder = false}) => SyncProfileEnvelope(
  kind: folder ? SyncDatasetKind.selectedFolder : SyncDatasetKind.velockManaged,
  profileId: folder ? 'folder' : 'velock',
  datasetId: 'dataset',
  vaultId: 'vault',
  deviceId: 'consumer',
  displayName: folder ? '工作文件夹' : '我的格间',
  connectionId: 'cloud',
  state: SyncProfileState.active,
  backgroundPolicy: const SyncProfileBackgroundPolicy(),
  dataset: const {
    'schemaVersion': 1,
    'pairedProducerId': 'source',
    'pairedProducerPublicKey': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  },
  createdAt: DateTime.utc(2026, 9, 25),
);

class _Ready implements VelockWizardReadinessService {
  const _Ready([this.availability = VelockWizardAvailability.ready]);
  final VelockWizardAvailability availability;
  @override
  Future<VelockWizardReadiness> inspect({String? syncAppInstanceId}) async =>
      VelockWizardReadiness(availability);
}

class _PendingRunService implements SyncProfileRunService {
  _PendingRunService(this.result);

  final Future<SyncProfileDispatchResult> result;
  int calls = 0;

  @override
  Future<SyncProfileDispatchResult> runNow(String profileId) {
    calls++;
    return result;
  }
}

class _ResumeGateRepository extends SyncProfileRepository {
  _ResumeGateRepository(super.database);

  final Completer<void> resumeGate = Completer<void>();
  int resumeCalls = 0;

  @override
  Future<void> setState(String profileId, SyncProfileState state) async {
    if (state == SyncProfileState.active) {
      resumeCalls++;
      await resumeGate.future;
    }
    return super.setState(profileId, state);
  }
}

class _VisualConnection implements ConnectionRepository {
  @override
  Future<ConnectionModel?> getConnectionById(String id) async =>
      ConnectionModel(
        id: id,
        name: 'NAS',
        source: '',
        target: '',
        protocol: WebDavProtocolModel(
          protocolType: WebDavProtocolType.https,
          address: 'https://example.test',
          port: '443',
          path: '/',
          credentialRef: 'private',
        ),
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        status: ConnectionStatus.pending,
      );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
