import 'package:velock_sync/sync_core/engine/sync_upload_engine.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_location_guard.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

void main() {
  late SyncStateDatabase db;
  late SyncProfileRepository repo;
  final profile = VelockSyncProfile(
    profileId: 'p',
    datasetId: 'd',
    vaultId: 'v',
    deviceId: 'c',
    displayName: 'Backup',
    connectionId: 'nas',
    pairedProducerId: 'source',
    pairedProducerPublicKeyId: 'key-ref',
    exchangeBindingId: 'binding',
    remoteRootSegments: ['new'],
    backgroundPolicy: const SyncProfileBackgroundPolicy(),
    state: SyncProfileState.active,
    createdAt: DateTime.utc(2026),
  ).toEnvelope();
  setUp(() async {
    db = await SyncStateDatabase.inMemory();
    repo = SyncProfileRepository(db);
    await repo.save(profile);
  });
  tearDown(() => db.close());

  test(
    'only changes scope; trust, applied cursors and failed history remain',
    () async {
      await db.advanceAppliedSequence(
        profileId: 'p',
        producerDeviceId: 'source',
        sequence: 1,
      );
      await db.startSyncRun(
        runId: 'failed',
        profileId: 'p',
        startedAt: DateTime.utc(2026),
      );
      await db.finishSyncRun(
        runId: 'failed',
        state: 'failed',
        completedAt: DateTime.utc(2026),
        errorCode: 'remote.velock_history_incomplete',
      );
      final saved = await repo.selectOriginalVelockFolder(
        expected: profile,
        segments: ['old', '中文 空格'],
      );
      final changedAt = VelockSyncProfile.fromEnvelope(saved).locationChangedAt;
      expect(changedAt, isNotNull);
      expect((await repo.listSummaries()).single.locationChangedAt, changedAt);
      expect(
        saved.toJson(),
        VelockSyncProfile.fromEnvelope(profile)
            .copyWith(
              remoteRootSegments: ['old', '中文 空格'],
              locationChangedAt: changedAt,
            )
            .toEnvelope()
            .toJson(),
      );
      expect(
        await db.appliedSequence(profileId: 'p', producerDeviceId: 'source'),
        1,
      );
      expect(
        (await db.latestSyncRun('p'))!.errorCode,
        'remote.velock_history_incomplete',
      );
    },
  );

  test('rejects active run without mutating', () async {
    await db.startSyncRun(
      runId: 'running',
      profileId: 'p',
      startedAt: DateTime.now(),
    );
    await expectLater(
      repo.selectOriginalVelockFolder(expected: profile, segments: ['old']),
      throwsStateError,
    );
    expect((await repo.read('p'))!.toJson(), profile.toJson());
  });

  test('rejects stale page after another selection', () async {
    await repo.selectOriginalVelockFolder(expected: profile, segments: ['old']);
    await expectLater(
      repo.selectOriginalVelockFolder(expected: profile, segments: ['other']),
      throwsStateError,
    );
    expect(
      VelockSyncProfile.fromEnvelope(
        (await repo.read('p'))!,
      ).remoteRootSegments,
      ['old'],
    );
  });

  test('pre-run lease blocks relocation and releases after failure', () async {
    final entered = Completer<void>();
    final finish = Completer<void>();
    final running = withVelockLocationGuard(db, 'p', () async {
      entered.complete();
      await finish.future;
    });
    await entered.future;
    await expectLater(
      repo.selectOriginalVelockFolder(expected: profile, segments: ['old']),
      throwsA(isA<SyncRunBusyException>()),
    );
    expect((await repo.read('p'))!.toJson(), profile.toJson());
    finish.complete();
    await running;
    await expectLater(
      withVelockLocationGuard(db, 'p', () async => throw StateError('failed')),
      throwsStateError,
    );
    await repo.selectOriginalVelockFolder(expected: profile, segments: ['old']);
  });

  test('invalid path and removed profile never recreated', () async {
    await expectLater(
      repo.selectOriginalVelockFolder(expected: profile, segments: ['..']),
      throwsFormatException,
    );
    await repo.remove('p');
    await expectLater(
      repo.selectOriginalVelockFolder(expected: profile, segments: ['old']),
      throwsStateError,
    );
    expect(await repo.read('p'), isNull);
  });
}
