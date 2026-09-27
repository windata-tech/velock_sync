/// A run that moved nothing must never be reported as 「已完成」.
///
/// The run sheet prints "上传对象 0 个 · 0 B" right under its status, so a
/// completed-but-empty run says 「无需传输」 instead. The stored run state is
/// unchanged: only the sentence the user reads is derived from the objects the
/// run itself moved.
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/sync_profiles/model/sync_run_outcome.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_workspace.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';

const _profileId = 'velock-profile';

void main() {
  group('the run window belongs to the run', () {
    final startedAt = DateTime.utc(2026, 9, 26, 22, 27);
    final finishedAt = DateTime.utc(2026, 9, 26, 22, 29);

    test('an object moved inside the window is part of that run', () {
      final transferred = runWindowTransfers(
        _run(startedAt: startedAt, completedAt: finishedAt),
        [
          _transfer(completedAt: startedAt.add(const Duration(seconds: 30))),
        ],
      );
      expect(transferred, hasLength(1));
    });

    test('objects of another window or profile are not', () {
      final history = [
        // Before this run started.
        _transfer(completedAt: startedAt.subtract(const Duration(minutes: 1))),
        // Re-stamped by a later run that moved the same object again.
        _transfer(completedAt: finishedAt.add(const Duration(minutes: 1))),
        // Another profile's object with the same timestamp.
        _transfer(
          profileId: 'other-profile',
          completedAt: startedAt.add(const Duration(seconds: 30)),
        ),
        // Never completed.
        _transfer(completedAt: null),
      ];
      expect(
        runWindowTransfers(
          _run(startedAt: startedAt, completedAt: finishedAt),
          history,
        ),
        isEmpty,
      );
    });
  });

  group('the conclusion names what the run did', () {
    test('a completed run that moved nothing is not “已完成”', () {
      expect(
        syncRunConclusionLabel(_run(state: 'completed'), transfers: const []),
        '无需传输',
      );
    });

    test('a completed run that moved objects is still “已完成”', () {
      expect(
        syncRunConclusionLabel(
          _run(state: 'completed'),
          transfers: [_transfer(completedAt: DateTime.utc(2026, 9, 26, 22, 28))],
        ),
        '已完成',
      );
    });

    test('running, failed and unknown states keep their own words', () {
      final moved = [_transfer(completedAt: DateTime.utc(2026, 9, 26, 22, 28))];
      expect(
        syncRunConclusionLabel(_run(state: 'running'), transfers: moved),
        '运行中',
      );
      expect(
        syncRunConclusionLabel(_run(state: 'failed'), transfers: moved),
        '失败',
      );
      // A state the app does not know is never smoothed into a conclusion.
      expect(
        syncRunConclusionLabel(_run(state: 'quarantined'), transfers: moved),
        'quarantined',
      );
    });
  });

  testWidgets('the run sheet says “无需传输” above its zero object counts', (
    tester,
  ) async {
    await _pumpRunSheet(
      tester,
      _run(startedAt: DateTime.utc(2026, 9, 26, 22, 27), state: 'completed'),
      const [],
    );

    expect(find.text('同步记录 · 无需传输'), findsOneWidget);
    expect(find.text('传输明细'), findsOneWidget);
    expect(find.text('本次没有传输任何对象'), findsOneWidget);
    expect(find.text('上传对象'), findsOneWidget);
    expect(find.text('0 个 · 0 B'), findsNWidgets(2));
    // The status row plus its title: “已完成” appears nowhere in the sheet.
    expect(find.text('无需传输'), findsOneWidget);
    expect(find.text('已完成'), findsNothing);
  });

  testWidgets('the run sheet keeps “已完成” for a run that moved objects', (
    tester,
  ) async {
    final at = DateTime.utc(2026, 9, 26, 22, 28);
    await _pumpRunSheet(
      tester,
      _run(
        startedAt: at.subtract(const Duration(minutes: 1)),
        completedAt: at,
        state: 'completed',
      ),
      [_transfer(completedAt: at, bytes: 296)],
    );

    expect(find.text('同步记录 · 已完成'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('无需传输'), findsNothing);
    expect(find.text('1 个 · 296 B'), findsOneWidget);
  });

  testWidgets('the English sheet never falls back to Chinese', (tester) async {
    await _pumpRunSheet(
      tester,
      _run(state: 'completed'),
      const [],
      locale: const Locale('en'),
    );

    expect(find.text('Sync run · Nothing to transfer'), findsOneWidget);
    expect(find.text('Nothing to transfer'), findsOneWidget);
    expect(find.text('Completed'), findsNothing);
  });

  testWidgets('the transfer history and its overview agree with the sheet', (
    tester,
  ) async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    await SyncProfileRepository(database).save(_velockProfile());

    // One run that moved an object, then a later run with nothing pending.
    await database.startSyncRun(
      runId: 'run-moved-object',
      profileId: _profileId,
      startedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 2)),
    );
    await database.beginTransferJob(
      transferId: 'transfer-1',
      profileId: _profileId,
      direction: TransferJobDirection.upload,
      logicalKey: 'vault/batches/batch-1',
      expectedSize: 296,
    );
    await database.completeTransferJob(
      transferId: 'transfer-1',
      completedBytes: 296,
    );
    await database.finishSyncRun(
      runId: 'run-moved-object',
      state: 'completed',
      completedAt: DateTime.now().toUtc(),
    );
    // The empty run starts strictly after the object landed, so that object is
    // not attributed to it.
    final landedAt = (await database.listTransferHistory(
      profileId: _profileId,
    )).single.completedAt!;
    await database.startSyncRun(
      runId: 'run-nothing',
      profileId: _profileId,
      startedAt: landedAt.add(const Duration(milliseconds: 1)),
    );
    await database.finishSyncRun(
      runId: 'run-nothing',
      state: 'completed',
      completedAt: landedAt.add(const Duration(milliseconds: 2)),
    );

    await _pumpDetail(tester, database);

    // The overview summarises the newest run with the same word as the list.
    expect(find.textContaining('无需传输 · '), findsOneWidget);

    await tester.ensureVisible(find.text('传输记录'));
    await tester.tap(find.text('传输记录'));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const Key('history-run-run-nothing')),
        matching: find.text('无需传输'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('history-run-run-moved-object')),
        matching: find.text('已完成'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('history-run-run-nothing')));
    await tester.pumpAndSettle();
    expect(find.text('同步记录 · 无需传输'), findsOneWidget);
    expect(find.text('无需传输'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}

SyncRunRecord _run({
  String state = 'completed',
  DateTime? startedAt,
  DateTime? completedAt,
  String profileId = _profileId,
}) => SyncRunRecord(
  runId: 'run-$state-${startedAt?.millisecondsSinceEpoch ?? 0}',
  profileId: profileId,
  state: state,
  startedAt: startedAt ?? DateTime.utc(2026, 9, 26, 22, 27),
  completedAt: completedAt,
  errorCode: null,
  errorCategory: null,
  retryable: null,
  retryAfter: null,
  suggestedAction: null,
  providerStatusCode: null,
);

TransferJobRecord _transfer({
  String profileId = _profileId,
  DateTime? completedAt,
  int bytes = 1024,
}) => TransferJobRecord(
  transferId: 'job-$profileId-${completedAt?.millisecondsSinceEpoch ?? 'open'}',
  profileId: profileId,
  direction: TransferJobDirection.upload,
  state: completedAt == null
      ? TransferJobState.running
      : TransferJobState.completed,
  logicalKey: 'vault/batches/batch-1',
  expectedSize: bytes,
  completedBytes: bytes,
  expectedHash: null,
  retryCount: 0,
  nextRetryAt: null,
  providerCheckpoint: null,
  errorCode: null,
  createdAt: completedAt,
  completedAt: completedAt,
);

Future<void> _pumpRunSheet(
  WidgetTester tester,
  SyncRunRecord run,
  List<TransferJobRecord> history, {
  Locale locale = const Locale('zh', 'CN'),
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showRunDetails(context, run, history: history),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _pumpDetail(
  WidgetTester tester,
  SyncStateDatabase database,
) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      syncStateDatabaseProvider.overrideWithValue(database),
      syncProfileRepositoryProvider.overrideWithValue(
        SyncProfileRepository(database),
      ),
      velockWizardReadinessServiceProvider.overrideWithValue(
        const _UnavailableReadinessService(),
      ),
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    initialLocation: '/sync-profiles/$_profileId',
    routes: [
      GoRoute(
        path: '/sync-profiles/:profileId',
        builder: (context, state) =>
            SyncProfileDetail(profileId: state.pathParameters['profileId']!),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

SyncProfileEnvelope _velockProfile() => SyncProfileEnvelope(
  kind: SyncDatasetKind.velockManaged,
  profileId: _profileId,
  datasetId: 'velock-dataset',
  vaultId: 'velock-vault',
  deviceId: 'consumer-device',
  displayName: '家庭 NAS 的格间',
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

class _UnavailableReadinessService implements VelockWizardReadinessService {
  const _UnavailableReadinessService();

  @override
  Future<VelockWizardReadiness> inspect({String? syncAppInstanceId}) async =>
      const VelockWizardReadiness(
        VelockWizardAvailability.temporarilyUnavailable,
      );
}
