import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/engine/sync_download_engine.dart';
import 'package:velock_sync/sync_core/engine/sync_profile_runner.dart';
import 'package:velock_sync/sync_core/engine/sync_upload_engine.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_dispatcher.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_executor.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

void main() {
  test(
    'different foreground/resume dispatchers share one run for the same disk DB',
    () async {
      final dir = await Directory.systemTemp.createTemp('dispatch-scope-');
      final db1 = await SyncStateDatabase.open(File('${dir.path}/state.db'));
      final db2 = await SyncStateDatabase.open(File('${dir.path}/state.db'));
      addTearDown(() async {
        await db1.close();
        await db2.close();
        await dir.delete(recursive: true);
      });
      final repo1 = SyncProfileRepository(db1),
          repo2 = SyncProfileRepository(db2);
      await repo1.save(_profile('p'));
      final gate = Completer<SyncProfileRunResult>();
      final background = _FakeExecutor(onRun: (_) => gate.future);
      final foreground = _FakeExecutor();
      final first = SyncProfileDispatcher(
        profiles: repo1,
        executors: [background],
      ).dispatch('p');
      final second = SyncProfileDispatcher(
        profiles: repo2,
        executors: [foreground],
      ).dispatch('p');
      expect(identical(first, second), isTrue);
      gate.complete(_completedRun());
      final results = await Future.wait([first, second]);
      expect(results.every((r) => r.didRun), isTrue);
      expect(background.requests, hasLength(1));
      expect(foreground.requests, isEmpty);
      await SyncProfileDispatcher(
        profiles: repo2,
        executors: [foreground],
      ).dispatch('p');
      expect(foreground.requests, hasLength(1));
    },
  );

  test(
    'independent databases never share work just because profile IDs match',
    () async {
      final db1 = await SyncStateDatabase.inMemory(),
          db2 = await SyncStateDatabase.inMemory();
      addTearDown(db1.close);
      addTearDown(db2.close);
      final repo1 = SyncProfileRepository(db1),
          repo2 = SyncProfileRepository(db2);
      await repo1.save(_profile('p'));
      await repo2.save(_profile('p'));
      final gate = Completer<SyncProfileRunResult>();
      final a = _FakeExecutor(onRun: (_) => gate.future), b = _FakeExecutor();
      final first = SyncProfileDispatcher(
        profiles: repo1,
        executors: [a],
      ).dispatch('p');
      final second = await SyncProfileDispatcher(
        profiles: repo2,
        executors: [b],
      ).dispatch('p');
      expect(second.didRun, isTrue);
      expect(b.requests, hasLength(1));
      gate.complete(_completedRun());
      await first;
    },
  );

  test('another isolate owning a run is busy, not a failed transfer', () async {
    final db = await SyncStateDatabase.inMemory();
    addTearDown(db.close);
    final repo = SyncProfileRepository(db);
    await repo.save(_profile('p'));
    final executor = _FakeExecutor(
      onRun: (_) async => throw const SyncRunBusyException('p'),
    );
    final result = await SyncProfileDispatcher(
      profiles: repo,
      executors: [executor],
    ).dispatch('p');
    expect(result.isAlreadyRunning, isTrue);
    expect(result.didFail, isFalse);
    expect(result.didRun, isFalse);
    expect(await db.latestSyncRun('p'), isNull);
  });

  test('routes an active known profile to its registered executor', () async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    final repository = SyncProfileRepository(database);
    await repository.save(_profile('profile-1'));
    final executor = _FakeExecutor();
    final dispatcher = SyncProfileDispatcher(
      profiles: repository,
      executors: [executor],
    );

    final result = await dispatcher.dispatch('profile-1');

    expect(result.status, SyncProfileDispatchStatus.completed);
    expect(result.run, isNotNull);
    expect(executor.requests.single.profile.profileId, 'profile-1');

    final nextResult = await dispatcher.dispatch('profile-1');
    expect(nextResult.status, SyncProfileDispatchStatus.completed);
    expect(executor.requests, hasLength(2));
  });

  test('skips a paused profile without invoking the executor', () async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    final repository = SyncProfileRepository(database);
    await repository.save(
      _profile('profile-1', state: SyncProfileState.paused),
    );
    final executor = _FakeExecutor();

    final result = await SyncProfileDispatcher(
      profiles: repository,
      executors: [executor],
    ).dispatch('profile-1');

    expect(result.status, SyncProfileDispatchStatus.skippedNotRunnable);
    expect(executor.requests, isEmpty);
  });

  test(
    'skips a supported profile kind when no executor is registered',
    () async {
      final database = await SyncStateDatabase.inMemory();
      addTearDown(database.close);
      final repository = SyncProfileRepository(database);
      await repository.save(
        _profile('velock', kind: SyncDatasetKind.velockManaged),
      );

      final result = await SyncProfileDispatcher(
        profiles: repository,
        executors: const [],
      ).dispatch('velock');

      expect(result.status, SyncProfileDispatchStatus.skippedUnsupported);
    },
  );

  test(
    'joins duplicate concurrent dispatches into one executor invocation',
    () async {
      final database = await SyncStateDatabase.inMemory();
      addTearDown(database.close);
      final repository = SyncProfileRepository(database);
      await repository.save(_profile('profile-1'));
      final gate = Completer<SyncProfileRunResult>();
      final executor = _FakeExecutor(onRun: (_) => gate.future);
      final dispatcher = SyncProfileDispatcher(
        profiles: repository,
        executors: [executor],
      );

      final first = dispatcher.dispatch('profile-1');
      final second = dispatcher.dispatch('profile-1');
      await Future<void>.delayed(Duration.zero);
      expect(executor.requests, hasLength(1));
      gate.complete(_completedRun());

      final results = await Future.wait([first, second]);
      expect(
        results.map((result) => result.status),
        everyElement(SyncProfileDispatchStatus.completed),
      );
      expect(executor.requests, hasLength(1));
    },
  );

  test('dispatchAll continues after one executor failure', () async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    final repository = SyncProfileRepository(database);
    await repository.save(_profile('failing'));
    await repository.save(_profile('succeeds'));
    final executor = _FakeExecutor(
      onRun: (request) {
        if (request.profile.profileId == 'failing') {
          throw StateError('expected failure');
        }
        return Future.value(_completedRun());
      },
    );
    final dispatcher = SyncProfileDispatcher(
      profiles: repository,
      executors: [executor],
    );

    final results = await dispatcher.dispatchAll(
      await repository.listSummaries(),
    );

    expect(results.map((result) => result.status), [
      SyncProfileDispatchStatus.failed,
      SyncProfileDispatchStatus.completed,
    ]);
    expect(executor.requests.map((request) => request.profile.profileId), [
      'failing',
      'succeeds',
    ]);
  });
}

class _FakeExecutor implements SyncProfileExecutor {
  _FakeExecutor({
    Future<SyncProfileRunResult> Function(SyncProfileExecutionRequest)? onRun,
  }) : _onRun = onRun ?? ((_) async => _completedRun());

  final Future<SyncProfileRunResult> Function(SyncProfileExecutionRequest)
  _onRun;
  final List<SyncProfileExecutionRequest> requests = [];

  @override
  SyncDatasetKind get kind => SyncDatasetKind.selectedFolder;

  @override
  Future<SyncProfileRunResult> run(SyncProfileExecutionRequest request) {
    requests.add(request);
    return _onRun(request);
  }
}

SyncProfileRunResult _completedRun() => const SyncProfileRunResult(
  runId: 'run-1',
  upload: UploadRunResult.idle(),
  download: DownloadRunResult(0),
);

SyncProfileEnvelope _profile(
  String profileId, {
  SyncDatasetKind kind = SyncDatasetKind.selectedFolder,
  SyncProfileState state = SyncProfileState.active,
}) => SyncProfileEnvelope(
  kind: kind,
  profileId: profileId,
  datasetId: 'dataset-$profileId',
  vaultId: 'vault-$profileId',
  deviceId: 'device-$profileId',
  displayName: 'Profile $profileId',
  connectionId: 'connection-$profileId',
  state: state,
  backgroundPolicy: const SyncProfileBackgroundPolicy(),
  dataset: const {
    'rootKeyRef': 'secure/root',
    'signingKeyRef': 'secure/signing',
  },
  createdAt: DateTime.utc(2026, 7, 17),
);
