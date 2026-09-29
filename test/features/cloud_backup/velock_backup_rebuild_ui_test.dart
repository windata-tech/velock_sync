import 'package:go_router/go_router.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_providers.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_dispatcher.dart';
import 'dart:async';
import 'dart:io';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_snapshot_control.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/features/cloud_backup/application/velock_backup_rebuild_service.dart';
import 'package:velock_sync/features/cloud_backup/application/velock_snapshot_providers.dart';
import 'package:velock_sync/features/cloud_backup/ui/velock_backup_rebuild.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';

void main() {
  final now = DateTime.now().toUtc();
  final profile = VelockSyncProfile(
    profileId: 'p',
    datasetId: 'dataset',
    vaultId: 'vault',
    deviceId: 'sync',
    displayName: 'Backup',
    connectionId: 'nas',
    pairedProducerId: 'owner',
    pairedProducerPublicKeyId: 'key',
    exchangeBindingId: 'a' * 43,
    remoteRootSegments: ['old'],
    backgroundPolicy: const SyncProfileBackgroundPolicy(),
    state: SyncProfileState.active,
    createdAt: now,
  ).toEnvelope();
  final job = VelockBackupRebuildJob(
    original: profile,
    destination: ['new'],
    request: SnapshotControlRequest(
      requestId: 'request',
      challenge: 'challenge',
      operation: 'build',
      snapshotId: 'request',
      vaultId: 'vault',
      producerId: 'owner',
      actorDeviceId: 'owner',
      actorPublicKeyId: 'key',
      exchangeBindingId: 'a' * 43,
      syncAppInstanceId: 'sync',
      destinationLabel: 'NAS /new',
      destinationHash: VelockBackupRebuildJob.destinationDigest('nas', ['new']),
      createdAt: now,
      expiresAt: now.add(const Duration(minutes: 5)),
    ),
  );
  late _Service service;
  late _NoRuns runner;
  setUp(() {
    service = _Service(_Jobs(job));
    runner = _NoRuns();
  });
  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          velockBackupRebuildServiceProvider.overrideWith((_) async => service),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: const [Locale('zh')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: VelockBackupRebuildPage(
            profile: profile,
            connection: ConnectionModel(
              id: 'nas',
              name: 'NAS',
              source: 'local',
              target: '/root',
              createdAt: now,
              updatedAt: now,
              status: ConnectionStatus.pending,
              protocol: const ProtocolModel.webDav(
                protocolType: WebDavProtocolType.https,
                address: 'https://example.com',
                port: '443',
                path: '/root',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    for (final fromDetail in [false, true]) {
      testWidgets(
        'completed rebuild returns home from detail=$fromDetail on $platform',
        (tester) async {
          service.ready = true;
          service.pending = Completer<SyncProfileEnvelope>()..complete(profile);
          late BuildContext entryContext;
          final router = GoRouter(
            initialLocation: fromDetail ? '/detail' : '/',
            routes: [
              StatefulShellRoute.indexedStack(
                builder: (_, _, shell) => shell,
                branches: [
                  StatefulShellBranch(
                    routes: [
                      GoRoute(
                        path: '/',
                        builder: (context, _) {
                          if (!fromDetail) entryContext = context;
                          return const Scaffold(body: Text('Backup home'));
                        },
                      ),
                    ],
                  ),
                ],
              ),
              GoRoute(
                path: '/detail',
                builder: (context, _) {
                  entryContext = context;
                  return const Scaffold(body: Text('Backup detail'));
                },
              ),
            ],
          );
          addTearDown(router.dispose);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                velockBackupRebuildServiceProvider.overrideWith(
                  (_) async => service,
                ),
                syncProfileRunServiceProvider.overrideWithValue(runner),
              ],
              child: MaterialApp.router(
                routerConfig: router,
                locale: const Locale('zh'),
                supportedLocales: const [Locale('zh')],
                localizationsDelegates: GlobalMaterialLocalizations.delegates,
                theme: ThemeData(platform: platform),
              ),
            ),
          );
          await tester.pumpAndSettle();
          Route<void> route(WidgetBuilder builder) =>
              platform == TargetPlatform.iOS
              ? CupertinoPageRoute<void>(builder: builder)
              : MaterialPageRoute<void>(builder: builder);
          final navigator = Navigator.of(entryContext);
          // Production opens both help and rebuild with Navigator.push over the
          // existing GoRouter page, including the preserved home tab branch.
          unawaited(
            navigator.push(
              route((_) => const Scaffold(body: Text('History help'))),
            ),
          );
          await tester.pumpAndSettle();
          unawaited(
            navigator.push(
              route(
                (_) => VelockBackupRebuildPage(
                  profile: profile,
                  connection: ConnectionModel(
                    id: 'nas',
                    name: 'NAS',
                    source: 'local',
                    target: '/root',
                    createdAt: now,
                    updatedAt: now,
                    status: ConnectionStatus.pending,
                    protocol: const ProtocolModel.webDav(
                      protocolType: WebDavProtocolType.https,
                      address: 'https://example.com',
                      port: '443',
                      path: '/root',
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('backup-rebuild-primary')));
          await tester.pumpAndSettle();
          expect(find.text('已切换到新备份位置'), findsOneWidget);
          await tester.tap(find.text('返回备份'));
          await tester.pumpAndSettle();
          expect(find.text('Backup home'), findsOneWidget);
          expect(find.byType(VelockBackupRebuildPage), findsNothing);
          expect(find.text('History help'), findsNothing);
          expect(router.routeInformationProvider.value.uri.path, '/');
          expect(service.uploads, 1);
          expect(runner.calls, 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'pending draft gives an explicit return path without claiming upload',
    (tester) async {
      await mount(tester);
      expect(find.text('请在格间确认备份内容'), findsOneWidget);
      expect(find.text('NAS /new'), findsOneWidget);
      expect(service.opens, 0);
      expect(service.uploads, 0);
      await tester.tap(find.byKey(const Key('backup-rebuild-primary')));
      await tester.pumpAndSettle();
      expect(service.opens, 1);
      expect(service.uploads, 0);
      service.ready = true;
      await tester.tap(find.byKey(const Key('backup-rebuild-refresh')));
      await tester.pumpAndSettle();
      expect(find.text('上传新备份'), findsOneWidget);
      expect(service.uploads, 0);
    },
  );
  testWidgets('returning from Velock with the backup ready uploads it', (
    tester,
  ) async {
    await mount(tester);
    expect(service.uploads, 0);
    service.ready = true;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    // The upload's busy spinner never settles; pump fixed frames.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(service.uploads, 1);
  });
  testWidgets('a pending rebuild can be abandoned for another folder', (
    tester,
  ) async {
    // The page used to have no way out: a folder that was deleted or not
    // writable brought the same pending job back on every visit.
    await mount(tester);
    expect(find.text('NAS /new'), findsOneWidget);

    await tester.tap(find.byKey(const Key('backup-rebuild-discard')));
    await tester.pumpAndSettle();

    expect((service.jobs as _Jobs).discarded, ['p']);
    expect(find.text('NAS /new'), findsNothing);
    expect(find.text('选择新文件夹'), findsOneWidget);
    expect(service.uploads, 0);
  });
  testWidgets(
    'upload stays inline, blocks duplicate taps and keeps failure visible',
    (tester) async {
      service.ready = true;
      service.pending = Completer<SyncProfileEnvelope>();
      await mount(tester);
      await tester.tap(find.byKey(const Key('backup-rebuild-primary')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(service.uploads, 1);
      expect(find.text('50%'), findsOneWidget);
      expect(find.text('已切换到新备份位置'), findsNothing);
      await tester.tap(find.byKey(const Key('backup-rebuild-primary')));
      await tester.pump();
      expect(service.uploads, 1);
      service.pending!.completeError(StateError('offline'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('新备份尚未完成'), findsOneWidget);
      expect(find.textContaining('原备份位置未改变'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(find.text('上传新备份'), findsOneWidget);
      expect(find.text('已切换到新备份位置'), findsNothing);
    },
  );
  testWidgets(
    'a late readiness result after disposal does not change another page',
    (tester) async {
      service.readiness = Completer<bool>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            velockBackupRebuildServiceProvider.overrideWith(
              (_) async => service,
            ),
          ],
          child: MaterialApp(
            home: VelockBackupRebuildPage(
              profile: profile,
              connection: ConnectionModel(
                id: 'nas',
                name: 'NAS',
                source: 'local',
                target: '/root',
                createdAt: now,
                updatedAt: now,
                status: ConnectionStatus.pending,
                protocol: const ProtocolModel.webDav(
                  protocolType: WebDavProtocolType.https,
                  address: 'https://example.com',
                  port: '443',
                  path: '/root',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: Text('Elsewhere')));
      service.readiness!.complete(true);
      await tester.pumpAndSettle();
      expect(find.text('Elsewhere'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

class _Jobs extends VelockBackupRebuildJobs {
  _Jobs(this.value) : super(Directory('/unused'));
  VelockBackupRebuildJob? value;
  final discarded = <String>[];
  @override
  Future<VelockBackupRebuildJob?> read(String profileId) async => value;
  @override
  Future<void> discard(String profileId) async {
    discarded.add(profileId);
    value = null;
  }
}

class _Service implements VelockBackupRebuildService {
  _Service(this.jobs);
  @override
  final VelockBackupRebuildJobs jobs;
  bool ready = false;
  int opens = 0, uploads = 0;
  Completer<bool>? readiness;
  Completer<SyncProfileEnvelope>? pending;
  @override
  Future<bool> isReady(VelockBackupRebuildJob job) async =>
      readiness == null ? ready : readiness!.future;
  @override
  Future<void> open(VelockBackupRebuildJob job) async {
    opens++;
  }

  @override
  Future<SyncProfileEnvelope> finish(
    VelockBackupRebuildJob job, {
    void Function(int, int)? onProgress,
  }) async {
    uploads++;
    onProgress?.call(5, 10);
    return pending!.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
