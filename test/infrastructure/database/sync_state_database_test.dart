import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  group('SyncStateDatabase', () {
    late SyncStateDatabase database;

    setUp(() async {
      database = await SyncStateDatabase.inMemory();
    });

    tearDown(() async {
      await database.close();
    });

    test(
      'creates the current state schema and replaces connection records atomically',
      () async {
        expect(await database.schemaVersion, 9);

        await database.replaceConnectionPayloads({
          'connection-a': '{"id":"connection-a"}',
          'connection-b': '{"id":"connection-b"}',
        });
        await database.replaceConnectionPayloads({
          'connection-c': '{"id":"connection-c"}',
        });

        expect(await database.readConnectionPayloads(), [
          '{"id":"connection-c"}',
        ]);
      },
    );

    test('upgrades a V5 conflict table without dropping its rows', () async {
      final directory = await Directory.systemTemp.createTemp('velock-state-');
      final file = File('${directory.path}/state.db');
      final old = sqlite.sqlite3.open(file.path);
      old.execute(
        'CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL)',
      );
      old.execute(
        'CREATE TABLE conflicts (conflict_id TEXT PRIMARY KEY, profile_id TEXT NOT NULL, entity_id TEXT NOT NULL, state TEXT NOT NULL, protected_details BLOB, created_at INTEGER NOT NULL, resolved_at INTEGER)',
      );
      old.execute(
        'CREATE TABLE sync_runs (run_id TEXT PRIMARY KEY, profile_id TEXT NOT NULL, state TEXT NOT NULL, started_at INTEGER NOT NULL, completed_at INTEGER, error_code TEXT)',
      );
      old.execute(
        "INSERT INTO conflicts VALUES ('old-conflict', 'profile-1', 'entity-1', 'modify-modify', NULL, 0, NULL)",
      );
      old.execute('PRAGMA user_version = 5');
      old.dispose();

      final upgraded = await SyncStateDatabase.open(file);
      try {
        expect(await upgraded.schemaVersion, 9);
        final conflict = (await upgraded.listUnresolvedConflicts()).single;
        expect(conflict.conflictId, 'old-conflict');
        expect(conflict.sourceDeviceId, isNull);
      } finally {
        await upgraded.close();
        await directory.delete(recursive: true);
      }
    });

    test(
      'persists conflict resolution intents and only completes a conflict for its owner',
      () async {
        await database.recordFolderConflict(
          conflictId: 'conflict-1',
          profileId: 'profile-1',
          entityId: 'opaque-entity',
          sourceDeviceId: 'remote-device',
          localRevisionId: 'local-revision',
          incomingRevisionId: 'remote-revision',
          type: 'concurrent',
          protectedDetails: '{"version":1}',
        );
        final now = DateTime.utc(2026, 7, 17, 12);

        expect(
          (await database.acquireConflictResolutionIntent(
            conflictId: 'conflict-1',
            strategy: 'keepLocal',
            owner: 'job-a',
            now: now,
            lease: const Duration(minutes: 5),
          )).status,
          ConflictResolutionIntentAcquisitionStatus.acquired,
        );
        expect(
          (await database.acquireConflictResolutionIntent(
            conflictId: 'conflict-1',
            strategy: 'keepLocal',
            owner: 'job-b',
            now: now.add(const Duration(minutes: 1)),
            lease: const Duration(minutes: 5),
          )).status,
          ConflictResolutionIntentAcquisitionStatus.inProgress,
        );
        expect(
          (await database.acquireConflictResolutionIntent(
            conflictId: 'conflict-1',
            strategy: 'keepRemote',
            owner: 'job-b',
            now: now.add(const Duration(minutes: 1)),
            lease: const Duration(minutes: 5),
          )).status,
          ConflictResolutionIntentAcquisitionStatus.strategyMismatch,
        );

        await expectLater(
          database.completeConflictResolution(
            conflictId: 'conflict-1',
            owner: 'job-b',
          ),
          throwsStateError,
        );
        await database.completeConflictResolution(
          conflictId: 'conflict-1',
          owner: 'job-a',
          completionArtifact: 'local-action:opaque',
        );

        final intent = await database.readConflictResolutionIntent(
          'conflict-1',
        );
        expect(intent!.state, ConflictResolutionIntentState.completed);
        expect(intent.receiptArtifact, 'local-action:opaque');
        expect(await database.readUnresolvedConflict('conflict-1'), isNull);
        expect(
          (await database.acquireConflictResolutionIntent(
            conflictId: 'conflict-1',
            strategy: 'keepLocal',
            owner: 'job-c',
            now: now.add(const Duration(minutes: 6)),
            lease: const Duration(minutes: 5),
          )).status,
          ConflictResolutionIntentAcquisitionStatus.completed,
        );
      },
    );

    test(
      'expired conflict resolution leases can be safely recovered',
      () async {
        await database.recordFolderConflict(
          conflictId: 'conflict-1',
          profileId: 'profile-1',
          entityId: 'opaque-entity',
          sourceDeviceId: 'remote-device',
          localRevisionId: 'local-revision',
          incomingRevisionId: 'remote-revision',
          type: 'concurrent',
        );
        final now = DateTime.utc(2026, 7, 17, 12);
        await database.acquireConflictResolutionIntent(
          conflictId: 'conflict-1',
          strategy: 'keepBoth',
          owner: 'crashed-job',
          now: now,
          lease: const Duration(minutes: 5),
        );

        expect(
          (await database.acquireConflictResolutionIntent(
            conflictId: 'conflict-1',
            strategy: 'keepBoth',
            owner: 'recovery-job',
            now: now.add(const Duration(minutes: 6)),
            lease: const Duration(minutes: 5),
          )).status,
          ConflictResolutionIntentAcquisitionStatus.acquired,
        );
        final intent = await database.readConflictResolutionIntent(
          'conflict-1',
        );
        expect(intent!.state, ConflictResolutionIntentState.running);
        expect(intent.leaseOwner, 'recovery-job');
      },
    );

    test(
      'persists only pairing challenge digests and consumes each once',
      () async {
        expect(
          await database.consumeVelockPairingChallenge(
            challengeDigest: 'sha256-digest-only',
            consumedAt: DateTime.utc(2026, 7, 17),
          ),
          isTrue,
        );
        expect(
          await database.consumeVelockPairingChallenge(
            challengeDigest: 'sha256-digest-only',
            consumedAt: DateTime.utc(2026, 7, 17, 0, 1),
          ),
          isFalse,
        );
      },
    );

    test(
      'allows only one active profile lock and recovers stale locks',
      () async {
        final now = DateTime.utc(2026, 7, 14, 12);
        const lease = Duration(minutes: 5);

        expect(
          await database.tryAcquireProfileLock(
            profileId: 'profile-1',
            owner: 'run-a',
            now: now,
            staleAfter: lease,
          ),
          isTrue,
        );
        expect(
          await database.tryAcquireProfileLock(
            profileId: 'profile-1',
            owner: 'run-b',
            now: now.add(const Duration(minutes: 1)),
            staleAfter: lease,
          ),
          isFalse,
        );
        expect(
          await database.tryAcquireProfileLock(
            profileId: 'profile-1',
            owner: 'run-b',
            now: now.add(const Duration(minutes: 6)),
            staleAfter: lease,
          ),
          isTrue,
        );
        expect(
          await database.heartbeatProfileLock(
            profileId: 'profile-1',
            owner: 'run-b',
            now: now.add(const Duration(minutes: 7)),
          ),
          isTrue,
        );

        await database.releaseProfileLock(
          profileId: 'profile-1',
          owner: 'run-b',
        );
        expect(
          await database.tryAcquireProfileLock(
            profileId: 'profile-1',
            owner: 'run-a',
            now: now.add(const Duration(minutes: 7)),
            staleAfter: lease,
          ),
          isTrue,
        );
      },
    );

    test('reserves and then advances one durable outgoing sequence', () async {
      final first = await database.reserveOutgoingSequence(
        profileId: 'profile-1',
        sourceDeviceId: 'device-1',
        newBatchId: 'batch-1',
      );
      final recovered = await database.reserveOutgoingSequence(
        profileId: 'profile-1',
        sourceDeviceId: 'device-1',
        newBatchId: 'batch-other',
      );
      expect(first.sequence, 1);
      expect(recovered.batchId, 'batch-1');
      expect(recovered.isRecovered, isTrue);

      await database.markOutgoingSequencePublished(
        profileId: 'profile-1',
        sourceDeviceId: 'device-1',
        sequence: 1,
        batchId: 'batch-1',
      );
      final second = await database.reserveOutgoingSequence(
        profileId: 'profile-1',
        sourceDeviceId: 'device-1',
        newBatchId: 'batch-2',
      );
      expect(second.sequence, 2);
      expect(second.isRecovered, isFalse);
    });

    test('cancels only the exact unused outgoing reservation', () async {
      final reservation = await database.reserveOutgoingSequence(
        profileId: 'profile-1',
        sourceDeviceId: 'device-1',
        newBatchId: 'batch-1',
      );
      await database.cancelOutgoingSequenceReservation(
        profileId: 'profile-1',
        sourceDeviceId: 'device-1',
        sequence: reservation.sequence,
        batchId: reservation.batchId,
      );
      final retried = await database.reserveOutgoingSequence(
        profileId: 'profile-1',
        sourceDeviceId: 'device-1',
        newBatchId: 'batch-2',
      );
      expect(retried.sequence, 1);
      expect(retried.batchId, 'batch-2');
    });

    test(
      'advances checkpoint cursors monotonically as one transaction',
      () async {
        await database.advanceAppliedSequencesFromCheckpoint(
          profileId: 'profile-1',
          coveredSequences: {'device-a': 5, 'device-b': 2},
        );
        await database.advanceAppliedSequencesFromCheckpoint(
          profileId: 'profile-1',
          coveredSequences: {'device-a': 3, 'device-b': 4},
        );

        expect(
          await database.appliedSequence(
            profileId: 'profile-1',
            producerDeviceId: 'device-a',
          ),
          5,
        );
        expect(
          await database.appliedSequence(
            profileId: 'profile-1',
            producerDeviceId: 'device-b',
          ),
          4,
        );
        await expectLater(
          database.advanceAppliedSequencesFromCheckpoint(
            profileId: 'profile-1',
            coveredSequences: {'': 2},
          ),
          throwsArgumentError,
        );
        expect(
          await database.appliedSequence(
            profileId: 'profile-1',
            producerDeviceId: 'device-a',
          ),
          5,
        );
      },
    );

    test('persists folder revision state and operation idempotency', () async {
      await database.upsertFolderEntitySyncState(
        datasetId: 'folder-1',
        entityId: 'entity-1',
        revisionId: 'revision-1',
        versionVector: VersionVector({'device-1': 2}),
        isTombstone: false,
      );
      await database.recordFolderOperationApplied(
        datasetId: 'folder-1',
        operationId: 'operation-1',
        entityId: 'entity-1',
        batchId: 'batch-1',
      );

      final state = await database.readFolderEntitySyncState(
        datasetId: 'folder-1',
        entityId: 'entity-1',
      );
      expect(state!.versionVector, VersionVector({'device-1': 2}));
      expect(state.isTombstone, isFalse);
      expect(
        await database.isFolderOperationApplied(
          datasetId: 'folder-1',
          operationId: 'operation-1',
        ),
        isTrue,
      );
    });

    test(
      'persists transfer progress and only exposes active jobs by default',
      () async {
        await database.beginTransferJob(
          transferId: 'transfer-1',
          profileId: 'profile-1',
          direction: TransferJobDirection.upload,
          logicalKey: 'velock-sync/v1/vault-1/blobs/ab/blob-1.blob',
          expectedSize: 100,
          expectedHash: 'hash',
        );
        await database.updateTransferProgress(
          transferId: 'transfer-1',
          completedBytes: 40,
        );

        final running = (await database.listTransferJobs()).single;
        expect(running.state, TransferJobState.running);
        expect(running.completedBytes, 40);
        expect(running.expectedSize, 100);

        await database.completeTransferJob(
          transferId: 'transfer-1',
          completedBytes: 100,
        );
        expect(await database.listTransferJobs(), isEmpty);
        final completed = (await database.listTransferJobs(
          includeCompleted: true,
        )).single;
        expect(completed.state, TransferJobState.completed);
        expect(completed.completedBytes, 100);
      },
    );

    test(
      'returns privacy-safe profile activity and tracks resolved conflicts',
      () async {
        final startedAt = DateTime.utc(2026, 7, 15, 10);
        await database.startSyncRun(
          runId: 'run-1',
          profileId: 'profile-1',
          startedAt: startedAt,
        );
        await database.finishSyncRun(
          runId: 'run-1',
          state: 'completed',
          completedAt: startedAt.add(const Duration(minutes: 1)),
        );
        await database.recordFolderConflict(
          conflictId: 'conflict-1',
          profileId: 'profile-1',
          entityId: 'opaque-entity',
          sourceDeviceId: 'device-remote',
          localRevisionId: 'local',
          incomingRevisionId: 'remote',
          type: 'concurrent',
        );

        final activity = await database.readSyncProfileActivity('profile-1');
        expect(activity.latestRun!.state, 'completed');
        expect(
          (await database.listRecentSyncRuns()).single.profileId,
          'profile-1',
        );
        expect(activity.pendingUploadCount, 0);
        expect(activity.pendingDownloadCount, 0);
        expect(activity.transferredBytes, 0);
        expect(activity.unresolvedConflictCount, 1);
        expect(
          (await database.listUnresolvedConflicts(
            profileId: 'profile-1',
          )).single.sourceDeviceId,
          'device-remote',
        );

        await database.markConflictResolved('conflict-1');
        expect(
          await database.listUnresolvedConflicts(profileId: 'profile-1'),
          isEmpty,
        );
        expect(
          (await database.readSyncProfileActivity(
            'profile-1',
          )).unresolvedConflictCount,
          0,
        );
      },
    );

    test(
      'filters recent sync history by profile without changing global history',
      () async {
        final first = DateTime.utc(2026, 7, 15, 10);
        final second = DateTime.utc(2026, 7, 15, 11);
        final third = DateTime.utc(2026, 7, 15, 12);
        for (final entry in [
          ('profile-a-old', 'profile-a', first),
          ('profile-b', 'profile-b', second),
          ('profile-a-new', 'profile-a', third),
        ]) {
          await database.startSyncRun(
            runId: entry.$1,
            profileId: entry.$2,
            startedAt: entry.$3,
          );
          await database.finishSyncRun(
            runId: entry.$1,
            state: 'completed',
            completedAt: entry.$3.add(const Duration(seconds: 1)),
          );
        }

        expect(
          (await database.listRecentSyncRuns(
            profileId: 'profile-a',
          )).map((run) => run.runId),
          ['profile-a-new', 'profile-a-old'],
        );
        expect((await database.listRecentSyncRuns()).map((run) => run.runId), [
          'profile-a-new',
          'profile-b',
          'profile-a-old',
        ]);
        expect(
          () => database.listRecentSyncRuns(profileId: ''),
          throwsArgumentError,
        );
      },
    );

    test('returns only explicitly active trusted device keys', () async {
      await database.trustDevice(
        vaultId: 'vault-1',
        deviceId: 'device-a',
        signingPublicKey: Uint8List(32),
      );
      await database.trustDevice(
        vaultId: 'vault-1',
        deviceId: 'device-b',
        signingPublicKey: Uint8List.fromList(List<int>.filled(32, 1)),
      );
      await database.revokeTrustedDevice(
        vaultId: 'vault-1',
        deviceId: 'device-b',
      );

      final keys = await database.readTrustedDevicePublicKeys(
        vaultId: 'vault-1',
      );
      expect(keys.keys, ['device-a']);
      expect(keys['device-a'], Uint8List(32));
    });

    test('stores only safe failure metadata for a failed sync run', () async {
      final startedAt = DateTime.utc(2026, 7, 15, 10);
      await database.startSyncRun(
        runId: 'run-1',
        profileId: 'profile-1',
        startedAt: startedAt,
      );
      await database.finishSyncRun(
        runId: 'run-1',
        state: 'failed',
        completedAt: startedAt.add(const Duration(seconds: 1)),
        failure: const SyncFailure(
          errorCode: 'provider.http.429',
          category: SyncErrorCategory.rateLimited,
          retryable: true,
          retryAfter: Duration(seconds: 30),
          providerStatusCode: 429,
          suggestedAction: '请等待后自动重试。',
        ),
      );

      final run = await database.latestSyncRun('profile-1');
      expect(run!.errorCode, 'provider.http.429');
      expect(run.errorCategory, 'rateLimited');
      expect(run.retryable, isTrue);
      expect(run.retryAfter, const Duration(seconds: 30));
      expect(run.providerStatusCode, 429);
      expect(run.suggestedAction, '请等待后自动重试。');
    });
  });
}
