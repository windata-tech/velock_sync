/// A killed sync must not leave the app thinking it is still syncing.
///
/// A run row is written as `running` before the transfer and closed when it
/// ends. If the process dies in between, an orphaned row makes the card claim
/// "正在同步" for ever and makes edits and deletion of the location fail
/// permanently, so startup closes those rows.
library;

import 'dart:io';

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
    final directory = await Directory.systemTemp.createTemp('sync-sweep-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/state.db');
    final dead = await SyncStateDatabase.open(file, processToken: 'dead');
    await dead.startSyncRun(
      runId: 'run-1',
      profileId: 'plain-1',
      startedAt: DateTime.utc(2026, 9, 27, 10),
    );
    await dead.tryAcquireProfileLock(
      profileId: 'velock-location:plain-1',
      owner: 'owner-1',
      now: DateTime.utc(2026, 9, 27, 10),
      staleAfter: const Duration(minutes: 10),
    );
    await dead.close();

    final live = await SyncStateDatabase.open(file, processToken: 'live');
    addTearDown(live.close);
    expect(await live.failInterruptedSyncRuns(), 1);

    // The next run must not wait for the dead owner's lease to expire.
    expect(
      await live.tryAcquireProfileLock(
        profileId: 'velock-location:plain-1',
        owner: 'owner-2',
        now: DateTime.utc(2026, 9, 27, 10, 1),
        staleAfter: const Duration(minutes: 10),
      ),
      isTrue,
    );
  });

  test('a run still owned by this process survives a resume sweep', () async {
    // Regression: the foreground coordinator runs the sweep on every resume
    // and network change. It used to fail the run the user had just started
    // and delete its lock, so the finished upload then reported a failure and
    // a background task could start the same location concurrently.
    final directory = await Directory.systemTemp.createTemp('sync-sweep-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/state.db');
    final ui = await SyncStateDatabase.open(file, processToken: 'pid-7');
    addTearDown(ui.close);
    // A second connection of the same process, like a background isolate.
    final background = await SyncStateDatabase.open(
      file,
      processToken: 'pid-7',
    );
    addTearDown(background.close);

    await ui.startSyncRun(
      runId: 'live-run',
      profileId: 'backup-1',
      startedAt: DateTime.utc(2026, 9, 27, 10),
    );
    await ui.tryAcquireProfileLock(
      profileId: 'velock-location:backup-1',
      owner: 'owner-1',
      now: DateTime.utc(2026, 9, 27, 10),
      staleAfter: const Duration(minutes: 5),
    );

    expect(await ui.failInterruptedSyncRuns(), 0);
    expect(await background.failInterruptedSyncRuns(), 0);
    expect(await ui.hasRunningSyncRun('backup-1'), isTrue);
    expect(
      await background.tryAcquireProfileLock(
        profileId: 'velock-location:backup-1',
        owner: 'owner-2',
        now: DateTime.utc(2026, 9, 27, 10, 1),
        staleAfter: const Duration(minutes: 5),
      ),
      isFalse,
      reason: 'the live run keeps its location lock',
    );

    // The run can still finish normally.
    await ui.finishSyncRun(
      runId: 'live-run',
      state: 'completed',
      completedAt: DateTime.utc(2026, 9, 27, 10, 2),
    );
    expect((await ui.latestSyncRun('backup-1'))?.state, 'completed');
  });

  test('a dead run is closed while a live one next to it is kept', () async {
    final directory = await Directory.systemTemp.createTemp('sync-sweep-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/state.db');
    final dead = await SyncStateDatabase.open(file, processToken: 'pid-1');
    await dead.startSyncRun(
      runId: 'dead-run',
      profileId: 'plain-1',
      startedAt: DateTime.utc(2026, 9, 27, 9),
    );
    await dead.tryAcquireProfileLock(
      profileId: 'velock-location:plain-1',
      owner: 'owner-1',
      now: DateTime.utc(2026, 9, 27, 9),
      staleAfter: const Duration(minutes: 5),
    );
    await dead.close();

    final live = await SyncStateDatabase.open(file, processToken: 'pid-2');
    addTearDown(live.close);
    await live.startSyncRun(
      runId: 'live-run',
      profileId: 'backup-1',
      startedAt: DateTime.utc(2026, 9, 27, 10),
    );
    await live.tryAcquireProfileLock(
      profileId: 'velock-location:backup-1',
      owner: 'owner-2',
      now: DateTime.utc(2026, 9, 27, 10),
      staleAfter: const Duration(minutes: 5),
    );

    expect(await live.failInterruptedSyncRuns(), 1);
    expect(await live.hasRunningSyncRun('plain-1'), isFalse);
    expect(await live.hasRunningSyncRun('backup-1'), isTrue);
  });

  test('the sweep is idempotent', () async {
    await insertRun('run-1', 'plain-1', 'running');

    expect(await database.failInterruptedSyncRuns(), 1);
    expect(await database.failInterruptedSyncRuns(), 0);
  });
}
