import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/mirror_models.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

final _syncedAt = DateTime.utc(2026, 9, 19, 8, 31);

/// One baseline row for a mirrored file, with only the interesting parts
/// overridden per test.
MirrorBaselineEntry _file(
  String relativePath, {
  int? size,
  DateTime? localModifiedAt,
  DateTime? remoteModifiedAt,
  String? remoteEtag,
  DateTime? syncedAt,
}) => MirrorBaselineEntry(
  relativePath: relativePath,
  kind: MirrorEntryKind.file,
  localSize: size ?? 0,
  localModifiedAt: localModifiedAt,
  remoteSize: size ?? 0,
  remoteModifiedAt: remoteModifiedAt,
  remoteEtag: remoteEtag,
  syncedAt: syncedAt ?? _syncedAt,
);

MirrorPlannedConflict _conflict(
  String relativePath, {
  MirrorConflictKind kind = MirrorConflictKind.bothModified,
  MirrorConflictResolution resolution = MirrorConflictResolution.keepBoth,
}) => MirrorPlannedConflict(
  relativePath: relativePath,
  kind: kind,
  resolution: resolution,
);

void main() {
  group('SyncStateDatabase plain folder mirror state', () {
    late SyncStateDatabase database;

    setUp(() async {
      database = await SyncStateDatabase.inMemory();
    });

    tearDown(() async {
      await database.close();
    });

    test('creates the version 12 mirror tables', () async {
      expect(await database.schemaVersion, 13);

      // The facade exposes no raw SQL handle, so each of the three v12 tables
      // is proven to exist by writing and reading it back through the public
      // mirror methods: a missing table would throw "no such table" here.
      expect(await database.readMirrorEntries('profile-1'), isEmpty);
      await database.upsertMirrorEntries('profile-1', [
        _file('photos/IMG_0001.jpg'),
      ]);
      expect((await database.readMirrorEntries('profile-1')).keys, [
        'photos/IMG_0001.jpg',
      ]);

      expect(await database.readMirrorConflicts('profile-1'), isEmpty);
      await database.recordMirrorConflicts('profile-1', [
        _conflict('photos/IMG_0001.jpg'),
      ], detectedAt: _syncedAt);
      expect(await database.countMirrorConflicts('profile-1'), 1);

      expect(await database.readLatestMirrorRunStats('profile-1'), isNull);
      await database.saveMirrorRunStats(
        MirrorRunStats(
          runId: 'run-1',
          profileId: 'profile-1',
          startedAt: _syncedAt,
        ),
      );
      expect(
        (await database.readLatestMirrorRunStats('profile-1'))!.runId,
        'run-1',
      );
    });

    test('adds the mirror tables to an existing version 11 database', () async {
      final directory = await Directory.systemTemp.createTemp('velock-mirror-');
      final file = File('${directory.path}/state.db');
      final old = sqlite.sqlite3.open(file.path);
      old.execute(
        'CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL)',
      );
      old.execute('CREATE TABLE sync_runs (run_id TEXT PRIMARY KEY)');
      old.execute('INSERT INTO schema_migrations VALUES (11, 0)');
      old.execute('PRAGMA user_version = 11');
      old.close();

      final upgraded = await SyncStateDatabase.open(file);
      try {
        expect(await upgraded.schemaVersion, 13);
        await upgraded.upsertMirrorEntries('profile-1', [
          _file('photos/IMG_0001.jpg', size: 2048),
        ]);
        expect(
          (await upgraded.readMirrorEntries(
            'profile-1',
          )).values.single.localSize,
          2048,
        );
        await upgraded.recordMirrorConflicts('profile-1', [
          _conflict('photos/IMG_0001.jpg'),
        ], detectedAt: _syncedAt);
        expect(await upgraded.countMirrorConflicts('profile-1'), 1);
        await upgraded.saveMirrorRunStats(
          MirrorRunStats(
            runId: 'run-1',
            profileId: 'profile-1',
            startedAt: _syncedAt,
          ),
        );
        expect(
          (await upgraded.readLatestMirrorRunStats('profile-1'))!.runId,
          'run-1',
        );
      } finally {
        await upgraded.close();
        await directory.delete(recursive: true);
      }
    });

    test(
      'round-trips baseline sizes, UTC timestamps, etags and kinds',
      () async {
        // A local (non-UTC) timestamp must come back as the same UTC instant.
        final localModifiedAt = DateTime.utc(2026, 9, 19, 8, 30, 15).toLocal();
        await database.upsertMirrorEntries('profile-1', [
          MirrorBaselineEntry(
            relativePath: 'photos/IMG_0001.jpg',
            kind: MirrorEntryKind.file,
            localSize: 4096,
            localModifiedAt: localModifiedAt,
            remoteSize: 4097,
            remoteModifiedAt: DateTime.utc(2026, 9, 19, 8, 30, 17),
            remoteEtag: '"etag-1"',
            syncedAt: _syncedAt,
          ),
          MirrorBaselineEntry(
            relativePath: 'photos',
            kind: MirrorEntryKind.directory,
            syncedAt: _syncedAt,
          ),
        ]);

        final entries = await database.readMirrorEntries('profile-1');
        expect(
          entries.keys,
          unorderedEquals(['photos', 'photos/IMG_0001.jpg']),
        );

        final file = entries['photos/IMG_0001.jpg']!;
        expect(file.kind, MirrorEntryKind.file);
        expect(file.localSize, 4096);
        expect(file.remoteSize, 4097);
        expect(file.localModifiedAt, DateTime.utc(2026, 9, 19, 8, 30, 15));
        expect(file.localModifiedAt!.isUtc, isTrue);
        expect(file.remoteModifiedAt, DateTime.utc(2026, 9, 19, 8, 30, 17));
        expect(file.remoteModifiedAt!.isUtc, isTrue);
        expect(file.remoteEtag, '"etag-1"');
        expect(file.syncedAt, _syncedAt);
        expect(file.syncedAt.isUtc, isTrue);

        final directory = entries['photos']!;
        expect(directory.kind, MirrorEntryKind.directory);
        expect(directory.localSize, 0);
        expect(directory.remoteSize, 0);
        expect(directory.localModifiedAt, isNull);
        expect(directory.remoteModifiedAt, isNull);
        expect(directory.remoteEtag, isNull);
        expect(directory.syncedAt, _syncedAt);

        expect(await database.readMirrorEntries('profile-2'), isEmpty);
      },
    );

    test(
      'updates one path on a second upsert instead of duplicating it',
      () async {
        final first = DateTime.utc(2026, 9, 19, 8, 30, 15);
        final second = DateTime.utc(2026, 9, 19, 9, 0, 0);
        await database.upsertMirrorEntries('profile-1', [
          _file(
            'photos/IMG_0001.jpg',
            size: 100,
            localModifiedAt: first,
            remoteEtag: '"v1"',
          ),
          _file('photos/renamed', size: 10),
        ]);

        await database.upsertMirrorEntries('profile-1', [
          _file(
            'photos/IMG_0001.jpg',
            size: 200,
            localModifiedAt: second,
            remoteModifiedAt: second,
            remoteEtag: '"v2"',
            syncedAt: second,
          ),
          // The same path can legitimately become a directory on a later run.
          MirrorBaselineEntry(
            relativePath: 'photos/renamed',
            kind: MirrorEntryKind.directory,
            syncedAt: second,
          ),
        ]);

        final entries = await database.readMirrorEntries('profile-1');
        expect(entries, hasLength(2));
        final updated = entries['photos/IMG_0001.jpg']!;
        expect(updated.localSize, 200);
        expect(updated.remoteSize, 200);
        expect(updated.localModifiedAt, second);
        expect(updated.remoteModifiedAt, second);
        expect(updated.remoteEtag, '"v2"');
        expect(updated.syncedAt, second);
        expect(entries['photos/renamed']!.kind, MirrorEntryKind.directory);
      },
    );

    test('deletes only the named baseline paths of one profile', () async {
      await database.upsertMirrorEntries('profile-1', [
        _file('photos/a.jpg'),
        _file('photos/b.jpg'),
        _file('photos/c.jpg'),
      ]);
      await database.upsertMirrorEntries('profile-2', [_file('photos/a.jpg')]);

      await database.deleteMirrorEntries('profile-1', ['photos/b.jpg']);

      expect(
        (await database.readMirrorEntries('profile-1')).keys,
        unorderedEquals(['photos/a.jpg', 'photos/c.jpg']),
      );
      // The identical path of another profile must survive.
      expect((await database.readMirrorEntries('profile-2')).keys, [
        'photos/a.jpg',
      ]);

      // Deleting an unknown path is a no-op, not an error.
      await database.deleteMirrorEntries('profile-1', ['photos/missing.jpg']);
      expect(await database.readMirrorEntries('profile-1'), hasLength(2));
    });

    test('clears every baseline path of one profile only', () async {
      await database.upsertMirrorEntries('profile-1', [
        _file('photos/a.jpg'),
        _file('photos/b.jpg'),
      ]);
      await database.upsertMirrorEntries('profile-2', [_file('photos/a.jpg')]);

      await database.clearMirrorEntries('profile-1');

      expect(await database.readMirrorEntries('profile-1'), isEmpty);
      expect((await database.readMirrorEntries('profile-2')).keys, [
        'photos/a.jpg',
      ]);
    });

    test(
      'records conflicts newest first and counts them per profile',
      () async {
        await database.recordMirrorConflicts('profile-1', [
          _conflict(
            'photos/IMG_0001.jpg',
            kind: MirrorConflictKind.bothModified,
            resolution: MirrorConflictResolution.keepBoth,
          ),
        ], detectedAt: DateTime.utc(2026, 9, 19, 8));
        await database.recordMirrorConflicts('profile-1', [
          _conflict(
            'docs/report.pdf',
            kind: MirrorConflictKind.deleteVersusModify,
            resolution: MirrorConflictResolution.preferRemote,
          ),
          _conflict(
            'docs/notes.txt',
            kind: MirrorConflictKind.bothCreated,
            resolution: MirrorConflictResolution.preferLocal,
          ),
        ], detectedAt: DateTime.utc(2026, 9, 19, 9));
        await database.recordMirrorConflicts('profile-2', [
          _conflict('other/file.bin'),
        ], detectedAt: DateTime.utc(2026, 9, 19, 10));

        expect(await database.countMirrorConflicts('profile-1'), 3);
        expect(await database.countMirrorConflicts('profile-2'), 1);
        expect(await database.countMirrorConflicts('profile-unknown'), 0);

        final records = await database.readMirrorConflicts('profile-1');
        expect(records, hasLength(3));
        expect(records.map((record) => record.detectedAt), [
          DateTime.utc(2026, 9, 19, 9),
          DateTime.utc(2026, 9, 19, 9),
          DateTime.utc(2026, 9, 19, 8),
        ]);
        expect(records.first.detectedAt.isUtc, isTrue);
        expect(records.first.conflictId, isNotEmpty);

        final byPath = {
          for (final record in records) record.relativePath: record,
        };
        expect(
          byPath['photos/IMG_0001.jpg']!.kind,
          MirrorConflictKind.bothModified,
        );
        expect(
          byPath['photos/IMG_0001.jpg']!.resolution,
          MirrorConflictResolution.keepBoth,
        );
        expect(
          byPath['docs/report.pdf']!.kind,
          MirrorConflictKind.deleteVersusModify,
        );
        expect(
          byPath['docs/report.pdf']!.resolution,
          MirrorConflictResolution.preferRemote,
        );
        expect(byPath['docs/notes.txt']!.kind, MirrorConflictKind.bothCreated);
        expect(
          byPath['docs/notes.txt']!.resolution,
          MirrorConflictResolution.preferLocal,
        );

        expect(
          await database.readMirrorConflicts('profile-1', limit: 2),
          hasLength(2),
        );
        expect(
          (await database.readMirrorConflicts('profile-2')).single.relativePath,
          'other/file.bin',
        );
        expect(
          () => database.readMirrorConflicts('profile-1', limit: 0),
          throwsArgumentError,
        );
      },
    );

    test('trimming keeps only the newest conflicts of one profile', () async {
      for (var index = 0; index < 5; index++) {
        await database.recordMirrorConflicts('profile-1', [
          _conflict('photos/$index.jpg'),
        ], detectedAt: DateTime.utc(2026, 9, 19, 8, index));
      }
      await database.recordMirrorConflicts('profile-2', [
        _conflict('other/file.bin'),
      ], detectedAt: DateTime.utc(2026, 9, 19, 8));

      await database.trimMirrorConflicts('profile-1', keep: 2);

      expect(
        (await database.readMirrorConflicts(
          'profile-1',
        )).map((record) => record.relativePath),
        ['photos/4.jpg', 'photos/3.jpg'],
      );
      expect(await database.countMirrorConflicts('profile-1'), 2);
      // Another profile's log is never touched.
      expect(await database.countMirrorConflicts('profile-2'), 1);

      // A larger budget than the log keeps everything.
      await database.trimMirrorConflicts('profile-1', keep: 10);
      expect(await database.countMirrorConflicts('profile-1'), 2);
    });

    test(
      'round-trips every run counter, finished time and failure code',
      () async {
        final startedAt = DateTime.utc(2026, 9, 19, 8);
        final finishedAt = startedAt.add(const Duration(seconds: 12));
        await database.saveMirrorRunStats(
          MirrorRunStats(
            runId: 'run-1',
            profileId: 'profile-1',
            startedAt: startedAt,
            finishedAt: finishedAt,
            uploadedFileCount: 3,
            downloadedFileCount: 4,
            deletedLocalCount: 5,
            deletedRemoteCount: 6,
            conflictCount: 7,
            heldDeletionCount: 8,
            skippedCount: 9,
            bytesTransferred: 10 * 1024 * 1024,
            failureCode: 'provider.webdav.collection_not_writable',
          ),
        );

        final failed = (await database.readLatestMirrorRunStats('profile-1'))!;
        expect(failed.runId, 'run-1');
        expect(failed.profileId, 'profile-1');
        expect(failed.startedAt, startedAt);
        expect(failed.startedAt.isUtc, isTrue);
        expect(failed.finishedAt, finishedAt);
        expect(failed.uploadedFileCount, 3);
        expect(failed.downloadedFileCount, 4);
        expect(failed.deletedLocalCount, 5);
        expect(failed.deletedRemoteCount, 6);
        expect(failed.conflictCount, 7);
        expect(failed.heldDeletionCount, 8);
        expect(failed.skippedCount, 9);
        expect(failed.bytesTransferred, 10 * 1024 * 1024);
        expect(failed.failureCode, 'provider.webdav.collection_not_writable');
        expect(failed.didFail, isTrue);

        // A later, successful run becomes the latest one and clears the failure.
        final secondStart = startedAt.add(const Duration(minutes: 5));
        await database.saveMirrorRunStats(
          MirrorRunStats(
            runId: 'run-2',
            profileId: 'profile-1',
            startedAt: secondStart,
            uploadedFileCount: 1,
            downloadedFileCount: 2,
          ),
        );

        final latest = (await database.readLatestMirrorRunStats('profile-1'))!;
        expect(latest.runId, 'run-2');
        expect(latest.startedAt, secondStart);
        expect(latest.finishedAt, isNull);
        expect(latest.uploadedFileCount, 1);
        expect(latest.downloadedFileCount, 2);
        expect(latest.deletedLocalCount, 0);
        expect(latest.deletedRemoteCount, 0);
        expect(latest.conflictCount, 0);
        expect(latest.heldDeletionCount, 0);
        expect(latest.skippedCount, 0);
        expect(latest.bytesTransferred, 0);
        expect(latest.failureCode, isNull);
        expect(latest.didFail, isFalse);

        expect(await database.readLatestMirrorRunStats('profile-2'), isNull);
      },
    );

    test(
      'a failed run keeps the honest held-deletion count of its run row',
      () async {
        final startedAt = DateTime.utc(2026, 9, 19, 8);
        // The run that reported the pending confirmations.
        await database.saveMirrorRunStats(
          MirrorRunStats(
            runId: 'run-held',
            profileId: 'profile-1',
            startedAt: startedAt,
            finishedAt: startedAt.add(const Duration(seconds: 3)),
            heldDeletionCount: 6,
          ),
        );
        // A later run failed before the deletion phase: it carries the failure
        // code, and the six pending deletions are still true.
        await database.saveMirrorRunStats(
          MirrorRunStats(
            runId: 'run-failed',
            profileId: 'profile-1',
            startedAt: startedAt.add(const Duration(minutes: 5)),
            finishedAt: startedAt.add(const Duration(minutes: 5, seconds: 2)),
            heldDeletionCount: 6,
            failureCode: 'plain_folder.remote_folder_missing',
          ),
        );

        final latest = (await database.readLatestMirrorRunStats('profile-1'))!;
        expect(latest.runId, 'run-failed');
        expect(latest.didFail, isTrue);
        expect(
          latest.heldDeletionCount,
          6,
          reason: 'the failure never replaces the pending count with a zero',
        );
        expect(latest.changedCount, 0);
      },
    );

    test('updates one run row instead of appending a second one', () async {
      final startedAt = DateTime.utc(2026, 9, 19, 8);
      await database.saveMirrorRunStats(
        MirrorRunStats(
          runId: 'run-1',
          profileId: 'profile-1',
          startedAt: startedAt,
        ),
      );
      expect(
        (await database.readLatestMirrorRunStats('profile-1'))!.finishedAt,
        isNull,
      );

      final finishedAt = startedAt.add(const Duration(seconds: 30));
      await database.saveMirrorRunStats(
        MirrorRunStats(
          runId: 'run-1',
          profileId: 'profile-1',
          // A different start time proves the second save reused the row: a
          // duplicate insert would have become the newest row instead.
          startedAt: startedAt.add(const Duration(hours: 1)),
          finishedAt: finishedAt,
          downloadedFileCount: 5,
        ),
      );

      final latest = (await database.readLatestMirrorRunStats('profile-1'))!;
      expect(latest.runId, 'run-1');
      expect(latest.startedAt, startedAt);
      expect(latest.finishedAt, finishedAt);
      expect(latest.downloadedFileCount, 5);
    });
  });
}
