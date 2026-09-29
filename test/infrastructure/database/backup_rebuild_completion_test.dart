import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:velock_sync/infrastructure/database/sync_state_migrations.dart';
import 'package:velock_sync/infrastructure/database/sync_state_profiles.dart';
import 'package:velock_sync/infrastructure/database/sync_state_records.dart';

void main() {
  late Database db;
  late ProfileQueries profiles;
  final at = DateTime.utc(2026, 9, 27);
  final result = BackupRebuildCompletion(
    runId: 'rebuild',
    startedAt: at,
    completedAt: at,
    destination: '/new',
    objectCount: 3,
    totalBytes: 1024,
  );
  setUp(() async {
    db = sqlite3.openInMemory();
    migrateSyncStateSchema(db, kSyncStateSchemaVersion);
    profiles = ProfileQueries(db);
    await profiles.upsertSyncProfilePayload(
      profileId: 'p',
      datasetId: 'd',
      targetId: 't',
      vaultId: 'v',
      state: 'active',
      payload: '{"state":"active","path":"old"}',
    );
  });
  tearDown(() => db.close());
  Future<bool> save({String expected = '{"state":"active","path":"old"}'}) =>
      profiles.replaceSyncProfilePayloadIfCurrent(
        profileId: 'p',
        expectedPayload: expected,
        datasetId: 'd',
        targetId: 't',
        vaultId: 'v',
        state: 'active',
        payload: '{"state":"active","path":"new"}',
        rebuild: result,
      );
  test('failed history insert rolls back the location change', () async {
    db.execute(
      "CREATE TRIGGER reject_run BEFORE INSERT ON sync_runs BEGIN SELECT RAISE(ABORT, 'disk rejected'); END",
    );
    await expectLater(save(), throwsA(isA<SqliteException>()));
    expect(await profiles.readSyncProfilePayload('p'), contains('old'));
    expect(db.select('SELECT * FROM sync_runs'), isEmpty);
  });
  test('stale or deleted configuration cannot publish success', () async {
    expect(await save(expected: '{"state":"active","path":"stale"}'), false);
    expect(db.select('SELECT * FROM sync_runs'), isEmpty);
    db.execute('DELETE FROM sync_profiles');
    expect(await save(), false);
    expect(db.select('SELECT * FROM sync_runs'), isEmpty);
  });
  test('successful switch and immutable record commit together once', () async {
    expect(await save(), true);
    expect(await profiles.readSyncProfilePayload('p'), contains('new'));
    expect(
      db.select('SELECT * FROM sync_runs').single['rebuild_json'],
      result.encode(),
    );
    expect(await save(expected: '{"state":"active","path":"new"}'), true);
    expect(db.select('SELECT * FROM sync_runs'), hasLength(1));
  });
}
