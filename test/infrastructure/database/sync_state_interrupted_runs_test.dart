/// A killed sync must not leave the app thinking it is still syncing.
///
/// A run row is written as `running` before the transfer and closed when it
/// ends. If the process dies in between, an orphaned row makes the card claim
/// "正在同步" for ever and makes edits and deletion of the location fail
/// permanently, so startup closes those rows.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';

void main() {
  late SyncStateDatabase database;

  setUp(() async {
    database = await SyncStateDatabase.inMemory();
  });

  tearDown(() => database.close());

  Future<void> insertRun(String runId, String profileId, String state) async {
    await database.startSyncRun(
      runId: runId,
      profileId: profileId,
      startedAt: DateTime.utc(2026, 9, 27, 10),
    );
    if (state != 'running') {
      await database.finishSyncRun(
        runId: runId,
        state: state,
        completedAt: DateTime.utc(2026, 9, 27, 10, 5),
      );
    }
  }

  test('startup closes runs left running by a previous process', () async {
    await insertRun('run-1', 'plain-1', 'running');
    await insertRun('run-2', 'plain-1', 'completed');
    await insertRun('run-3', 'backup-1', 'running');

    expect(await database.hasRunningSyncRun('plain-1'), isTrue);

    final closed = await database.failInterruptedSyncRuns();

    expect(closed, 2);
    expect(await database.hasRunningSyncRun('plain-1'), isFalse);
    expect(await database.hasRunningSyncRun('backup-1'), isFalse);
    final latest = await database.latestSyncRun('plain-1');
    expect(latest?.state, 'failed');
    expect(latest?.errorCode, 'sync.interrupted');
  });

  test('a completed history is untouched', () async {
    await insertRun('run-1', 'plain-1', 'completed');

    expect(await database.failInterruptedSyncRuns(), 0);
    expect((await database.latestSyncRun('plain-1'))?.state, 'completed');
  });

  test('stale leases from the dead process are cleared too', () async {
    await insertRun('run-1', 'plain-1', 'running');
    await database.tryAcquireProfileLock(
      profileId: 'plain-1',
      owner: 'dead-process',
      now: DateTime.utc(2026, 9, 27, 10),
      staleAfter: const Duration(minutes: 10),
    );

    await database.failInterruptedSyncRuns();

    // The next run must not wait for the dead owner's lease to expire.
    expect(
      await database.tryAcquireProfileLock(
        profileId: 'plain-1',
        owner: 'this-process',
        now: DateTime.utc(2026, 9, 27, 10, 1),
        staleAfter: const Duration(minutes: 10),
      ),
      isTrue,
    );
  });

  test('the sweep is idempotent', () async {
    await insertRun('run-1', 'plain-1', 'running');

    expect(await database.failInterruptedSyncRuns(), 1);
    expect(await database.failInterruptedSyncRuns(), 0);
  });
}
