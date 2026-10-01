import 'package:velock_sync/features/cloud_backup/application/velock_snapshot_providers.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_home.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_widgets.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_folder_picker.dart';
import 'package:velock_sync/features/cloud_backup/application/backup_destination_service.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';
import 'package:velock_sync/features/cloud_backup/application/webdav_backup_folder_browser.dart';
import 'package:material_ui/material_ui.dart';
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
    return SyncProfileDispatchResult(
      profileId: profileId,
      status: SyncProfileDispatchStatus.skippedNotRunnable,
    );
  }
}

void main() {
  final captureKey = GlobalKey();
  late SyncStateDatabase db;
  late SyncProfileRepository repository;
  late _NoRuns runner;
  setUp(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    final font = Platform.environment['BACKUP_UI_FONT'];
    if (font != null) {
      await (FontLoader('BackupQA')..addFont(
            File(font).readAsBytes().then((b) => ByteData.sublistView(b)),
          ))
          .load();
    }

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
    bool home = false,
    bool settle = true,
    bool missingBackup = false,
    BackupFolderCreator? createFolder,
  }) async {
    final remote = InMemoryObjectStore(
      answerNotFoundForMissingCollections: true,
    );
    if (!missingBackup) {
      await remote.put(
        LogicalKeys.commit(
          _profile.vaultId,
          VelockSyncProfile.fromEnvelope(_profile).pairedProducerId,
          1,
          'fixture',
        ),
        Stream.value([1]),
        contentLength: 1,
      );
    }
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => home
              ? const SyncProfilesHome()
              : directly
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
          velockBackupRebuildServiceProvider.overrideWith(
            (ref) async =>
                throw StateError('No draft in this navigation fixture'),
          ),
          if (createFolder != null)
            backupFolderCreatorProvider.overrideWithValue(createFolder),
          backupDestinationServiceProvider.overrideWithValue(
            BackupDestinationService(
              open: (_) async => remote,
              openScoped: (_, _) async => remote,
            ),
          ),
          syncStateDatabaseProvider.overrideWithValue(db),
          syncProfileRepositoryProvider.overrideWithValue(repository),
          syncProfileRunServiceProvider.overrideWithValue(runner),
          velockWizardReadinessServiceProvider.overrideWithValue(_Ready()),
          connectionDetailProvider('cloud').overrideWith(_Connection.new),
          backupFolderLoaderProvider.overrideWithValue(
            ({required protocol, required relativeSegments}) async =>
                const <WebDavBackupFolder>[],
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          locale: Locale(locale),
          supportedLocales: const [Locale('zh'), Locale('en')],
          localizationsDelegates: const [
            ...GlobalMaterialLocalizations.delegates,
          ],
          theme: ThemeData(
            platform: TargetPlatform.iOS,
            cupertinoOverrideTheme: CupertinoThemeData(
              textTheme: CupertinoTextThemeData(
                textStyle: const CupertinoTextThemeData().textStyle.copyWith(
                  fontFamily: 'BackupQA',
                ),
                actionTextStyle: const CupertinoTextThemeData().actionTextStyle
                    .copyWith(fontFamily: 'BackupQA'),
                navTitleTextStyle: const CupertinoTextThemeData()
                    .navTitleTextStyle
                    .copyWith(fontFamily: 'BackupQA'),
                navActionTextStyle: const CupertinoTextThemeData()
                    .navActionTextStyle
                    .copyWith(fontFamily: 'BackupQA'),
              ),
            ),
            fontFamily: Platform.environment['BACKUP_UI_FONT'] == null
                ? null
                : 'BackupQA',
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: RepaintBoundary(key: captureKey, child: child!),
          ),
        ),
      ),
    );
    // A running transfer renders an inline spinner on the primary action, which
    // animates forever: callers asserting the in-flight state pump explicit
    // frames instead of waiting for the tree to settle.
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
    return router;
  }

  testWidgets(
    'manage relocation can create a folder on the right without saving or syncing',
    (tester) async {
      final created = <String>[];
      await mount(
        tester,
        createFolder:
            ({
              required protocol,
              required relativeSegments,
              required name,
            }) async {
              created.add([...relativeSegments, name].join('/'));
            },
      );
      await tester.tap(find.text('管理'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('manage-change-location')));
      await tester.pumpAndSettle();
      expect(find.text('选择备份文件夹'), findsOneWidget);
      expect(find.text('找到原备份文件夹'), findsNothing);
      final newFolder = find.byKey(const Key('new-backup-folder'));
      expect(newFolder, findsOneWidget);
      expect(find.byTooltip('新建文件夹'), findsOneWidget);
      expect(
        tester.getCenter(newFolder).dx,
        greaterThan(tester.getCenter(find.text('上一级')).dx),
      );
      await tester.tap(newFolder);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('new-backup-folder-name')),
        '新的备份',
      );
      await tester.pump();
      await tester.tap(find.text('创建并进入'));
      await tester.pumpAndSettle();
      expect(created, ['共享给我/new folder/新的备份']);
      expect(find.text('/base/backup/共享给我/new folder/新的备份'), findsOneWidget);
      expect(
        VelockSyncProfile.fromEnvelope(
          (await repository.read('p'))!,
        ).remoteRootSegments,
        ['共享给我', 'new folder'],
      );
      expect(runner.calls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('finding original history remains read only', (tester) async {
    await mount(tester, directly: true);
    await tester.tap(find.byKey(const Key('backup-history-browse-location')));
    await tester.pumpAndSettle();
    expect(find.text('找到原备份文件夹'), findsOneWidget);
    expect(find.byKey(const Key('new-backup-folder')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  for (final home in [false, true]) {
    for (final outcome in ['completed', 'failed']) {
      testWidgets(
        '${home ? 'home' : 'detail'} tracks external running -> $outcome without another tap',
        (tester) async {
          await db.startSyncRun(
            runId: 'background-run',
            profileId: 'p',
            startedAt: DateTime.utc(2026, 9, 27),
          );
          try {
            await mount(tester, home: home, settle: false);
            // The in-flight state lives on the card and its primary action.
            expect(find.text('正在传输，请稍候'), findsOneWidget);
            expect(find.byKey(const Key('sync-progress-dialog')), findsNothing);
            final primary = find.byKey(const Key('backup-primary-action'));
            expect(tester.widget<BackupActionButton>(primary).busy, isTrue);
            expect(
              find.descendant(
                of: primary,
                matching: find.byType(CircularProgressIndicator),
              ),
              findsOneWidget,
            );
            await db.finishSyncRun(
              runId: 'background-run',
              state: outcome,
              completedAt: DateTime.utc(2026, 9, 27, 0, 1),
              errorCode: outcome == 'failed' ? 'sync.unexpected' : null,
            );
            await tester.pump(const Duration(seconds: 1));
            await tester.pumpAndSettle();
            expect(find.text('正在传输，请稍候'), findsNothing);
            expect(tester.widget<BackupActionButton>(primary).busy, isFalse);
            expect(find.byType(CircularProgressIndicator), findsNothing);
            expect(
              find.text(outcome == 'completed' ? '上次备份已完成' : '有一件事需要你处理'),
              findsOneWidget,
            );
            expect((await db.latestSyncRun('p'))!.state, outcome);
            expect(runner.calls, 0);
            // Terminal state stops polling; nothing should revert to running.
            await tester.pump(const Duration(seconds: 3));
            expect(find.text('正在传输，请稍候'), findsNothing);
            expect(tester.widget<BackupActionButton>(primary).busy, isFalse);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
          }
        },
      );
    }
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
      expect(find.text('找回备份位置'), findsOneWidget);
      expect(find.text('请选择原来的备份文件夹'), findsOneWidget);
      // Measure painted blue ink, not the Icon box or 44px hit target.
      final iconRect = tester.getRect(find.byIcon(Icons.chevron_left_rounded));
      final surfaceLeft = tester
          .getTopLeft(
            find
                .descendant(
                  of: find.byType(BackupCard).first,
                  matching: find.byType(DecoratedBox),
                )
                .first,
          )
          .dx;
      expect(
        tester
            .getTopLeft(
              find.byKey(const Key('backup-history-missing-original')),
            )
            .dx,
        surfaceLeft,
        reason: 'Secondary action shares the same page grid as the cards',
      );
      await tester.runAsync(() async {
        final boundary =
            captureKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final rgba = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        int? inkLeft;
        for (
          var y = (iconRect.top * 2).floor();
          y < (iconRect.bottom * 2).ceil();
          y++
        ) {
          for (
            var x = (iconRect.left * 2).floor();
            x < (iconRect.right * 2).ceil();
            x++
          ) {
            final i = (y * image.width + x) * 4;
            final r = rgba.getUint8(i),
                g = rgba.getUint8(i + 1),
                b = rgba.getUint8(i + 2);
            if (b > r + 40 && b > g + 20) {
              if (inkLeft == null || x < inkLeft) inkLeft = x;
            }
          }
        }
        image.dispose();
        expect(inkLeft, isNotNull);
        expect(
          inkLeft! / 2,
          closeTo(surfaceLeft, 1.5),
          reason:
              'Visible back chevron must align with the card left edge, not receive a second nav inset',
        );
      });
      final output = Platform.environment['BACKUP_UI_SCREENSHOT_DIR'];
      if (output != null) {
        await tester.runAsync(() async {
          final boundary =
              captureKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          await Directory(output).create(recursive: true);
          await File(
            '$output/history-help.png',
          ).writeAsBytes(bytes.buffer.asUint8List());
          image.dispose();
        });
      }
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
    'browse is a read-only picker; selecting and cancelling does not mutate',
    (tester) async {
      await mount(tester, directly: true);
      await tester.scrollUntilVisible(
        find.byKey(const Key('backup-history-browse-location')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('backup-history-browse-location')));
      await tester.pumpAndSettle();
      expect(find.byType(BackupFolderPicker), findsOneWidget);
      expect(find.byKey(const Key('new-backup-folder')), findsNothing);
      expect(runner.calls, 0);
      await tester.tap(find.byKey(const Key('backup-folder-up')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('use-backup-folder')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('backup-location-confirm')), findsOneWidget);
      expect((await repository.read('p'))!.toJson(), _profile.toJson());
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect((await repository.read('p'))!.toJson(), _profile.toJson());
      expect(runner.calls, 0);
    },
  );

  for (final home in [true, false]) {
    testWidgets(
      'saved location offers check without clearing failed history (home: $home)',
      (tester) async {
        await repository.selectOriginalVelockFolder(
          expected: _profile,
          segments: ['original'],
        );
        await mount(tester, home: home);
        expect(find.text('保存位置已更改'), findsOneWidget);
        expect(find.text('检查并备份'), findsOneWidget);
        expect(find.text('云端备份不完整'), findsNothing);
        expect(
          (await db.latestSyncRun('p'))!.errorCode,
          'remote.velock_history_incomplete',
        );
        await tester.tap(find.byKey(const Key('backup-primary-action')));
        await tester.pumpAndSettle();
        expect(runner.calls, 1);
        expect(find.byKey(const Key('backup-history-help')), findsNothing);
      },
    );
  }

  testWidgets('unrelated folder is rejected before confirmation and save', (
    tester,
  ) async {
    await mount(tester, directly: true, missingBackup: true);
    final before = (await repository.read('p'))!.toJson();
    await tester.tap(find.byKey(const Key('backup-history-browse-location')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('backup-folder-up')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('use-backup-folder')));
    await tester.pumpAndSettle();
    expect(find.text('这里没有找到原备份'), findsOneWidget);
    expect(find.byKey(const Key('backup-location-confirm')), findsNothing);
    expect(find.text('备份位置已更新'), findsNothing);
    expect((await repository.read('p'))!.toJson(), before);
    expect(runner.calls, 0);
  });

  testWidgets(
    'confirming folder saves only location; backup requires a separate explicit action',
    (tester) async {
      await mount(tester, directly: true);
      await tester.tap(find.byKey(const Key('backup-history-browse-location')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('backup-folder-up')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('use-backup-folder')));
      await tester.pumpAndSettle();
      expect(runner.calls, 0);
      expect(find.text('保存位置'), findsOneWidget);
      expect(find.text('确认并继续备份'), findsNothing);
      expect(find.textContaining('不启动同步'), findsOneWidget);
      await tester.tap(find.byKey(const Key('backup-location-confirm')));
      await tester.pumpAndSettle();
      expect(runner.calls, 0);
      expect(find.text('备份位置已更新'), findsOneWidget);
      expect(find.text('本次只保存目录，尚未开始备份。'), findsOneWidget);
      expect(find.text('请选择原来的备份文件夹'), findsNothing);
      expect(
        find.byKey(const Key('backup-history-missing-original')),
        findsNothing,
      );
      // Saving the location never starts a transfer, so nothing is in flight and
      // no blocking progress surface exists at all.
      expect(find.byKey(const Key('sync-progress-dialog')), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('本次检查没有发现'), findsNothing);
      final saved = (await repository.read('p'))!;
      expect(VelockSyncProfile.fromEnvelope(saved).remoteRootSegments, [
        '共享给我',
      ]);
      expect(
        saved.dataset['pairedProducerId'],
        _profile.dataset['pairedProducerId'],
      );
      expect(saved.connectionId, 'cloud');
      expect(
        (await db.latestSyncRun('p'))!.errorCode,
        'remote.velock_history_incomplete',
      );
      expect(find.text('/base/backup/共享给我'), findsOneWidget);
      expect(find.byKey(const Key('backup-history-feedback')), findsNothing);
      final output = Platform.environment['BACKUP_UI_SCREENSHOT_DIR'];
      if (output != null) {
        await tester.runAsync(() async {
          final boundary =
              captureKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          await Directory(output).create(recursive: true);
          await File(
            '$output/folder-confirmed.png',
          ).writeAsBytes(bytes.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.byKey(const Key('backup-history-start-backup')));
      await tester.pumpAndSettle();
      expect(runner.calls, 1);
      expect(find.text('本次只保存目录，尚未开始备份。'), findsNothing);
    },
  );

  testWidgets(
    'Done returns without starting sync; failed stale save never claims success',
    (tester) async {
      await mount(tester);
      await tester.tap(find.byKey(const Key('backup-primary-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('backup-history-browse-location')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('use-backup-folder')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('backup-location-confirm')));
      await tester.pumpAndSettle();
      expect(runner.calls, 0);
      await tester.tap(find.byKey(const Key('backup-history-done')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('backup-history-help')), findsNothing);
      expect(runner.calls, 0);
      expect(
        (await db.latestSyncRun('p'))!.errorCode,
        'remote.velock_history_incomplete',
      );

      expect(find.text('保存位置已更改'), findsOneWidget);
      expect(find.text('检查并备份'), findsOneWidget);
      expect(find.text('云端备份不完整'), findsNothing);
      final saved = (await repository.read('p'))!;
      showBackupHistoryHelp(
        tester.element(find.byType(SyncProfileDetail)),
        saved,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('backup-history-browse-location')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('use-backup-folder')));
      await tester.pumpAndSettle();
      await repository.setState('p', SyncProfileState.paused);
      await tester.tap(find.byKey(const Key('backup-location-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('备份位置已更新'), findsNothing);
      expect(find.textContaining('目录未保存'), findsOneWidget);
      expect(runner.calls, 0);
    },
  );

  testWidgets(
    'missing original opens explicit rebuild flow without changing the profile',
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
      expect(find.text('原备份丢失后，仍可重新备份'), findsOneWidget);
      expect(find.text('选择新文件夹'), findsOneWidget);
      expect(find.textContaining('只存在于已丢失云端的数据'), findsOneWidget);
      expect((await repository.read('p'))!.toJson(), _profile.toJson());
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
          locale == 'zh'
              ? '原备份丢失后，仍可重新备份'
              : 'Create a backup when the original is lost',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      expect(runner.calls, 0);
    });
  }
}
