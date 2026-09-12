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
