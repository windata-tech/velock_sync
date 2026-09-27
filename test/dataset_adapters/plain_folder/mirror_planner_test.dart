/// Unit tests for the pure plain-folder mirror planner.
///
/// `MirrorPlanner` is the only place where direction, first-sync policy,
/// conflict policy and deletion protection meet, and it performs no I/O, so
/// every combination promised by `docs/design/plain-folder-sync.md` §3/§4 is
/// pinned here.
///
/// Assertions describe the behaviour of the current implementation. Places
/// where that behaviour contradicts the design doc are marked `// NOTE:`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/mirror_models.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// Timestamps recorded in the baseline / observed on both sides.
final _t0 = DateTime.utc(2026, 9, 27, 10, 0, 0);
final _t1 = DateTime.utc(2026, 9, 27, 10, 30, 0);
final _t2 = DateTime.utc(2026, 9, 27, 11, 0, 0);

/// `conflictCopyPathFor` renders `now.toLocal()`, so a local [DateTime] keeps
/// the expected stamp readable in every timezone.
final _now = DateTime(2026, 9, 27, 14, 3, 5);
const _stamp = '2026-09-27 14-03-05';

MirrorEntry _file(
  String path, {
  int size = 1,
  DateTime? modifiedAt,
  String? etag,
}) => MirrorEntry(
  relativePath: path,
  kind: MirrorEntryKind.file,
  size: size,
  modifiedAt: modifiedAt,
  etag: etag,
);

MirrorEntry _dir(String path) =>
    MirrorEntry(relativePath: path, kind: MirrorEntryKind.directory);

MirrorBaselineEntry _baseFile(
  String path, {
  required int size,
  required DateTime modifiedAt,
  String? etag,
  int? remoteSize,
  DateTime? remoteModifiedAt,
}) => MirrorBaselineEntry(
  relativePath: path,
  kind: MirrorEntryKind.file,
  localSize: size,
  localModifiedAt: modifiedAt,
  remoteSize: remoteSize ?? size,
  remoteModifiedAt: remoteModifiedAt ?? modifiedAt,
  remoteEtag: etag,
  syncedAt: _t0,
);

MirrorBaselineEntry _baseDir(String path) => MirrorBaselineEntry(
  relativePath: path,
  kind: MirrorEntryKind.directory,
  syncedAt: _t0,
);

Map<String, MirrorEntry> _files(
  List<String> names, {
  int size = 5,
  DateTime? modifiedAt,
}) => {
  for (final name in names)
    name: _file(name, size: size, modifiedAt: modifiedAt ?? _t0),
};

Map<String, MirrorBaselineEntry> _baselines(
  List<String> names, {
  int size = 5,
  DateTime? modifiedAt,
}) => {
  for (final name in names)
    name: _baseFile(name, size: size, modifiedAt: modifiedAt ?? _t0),
};

/// `d1.txt` … `d<count>.txt`.
List<String> _numbered(int count) => [
  for (var i = 1; i <= count; i++) 'd$i.txt',
];

MirrorPlan _plan({
  Map<String, MirrorEntry> local = const {},
  Map<String, MirrorEntry> remote = const {},
  Map<String, MirrorBaselineEntry> baseline = const {},
  SyncDirection direction = SyncDirection.bidirectional,
  MirrorConflictPolicy conflictPolicy = MirrorConflictPolicy.keepBoth,
  MirrorInitialSyncPolicy initialSyncPolicy = MirrorInitialSyncPolicy.merge,
  MirrorListingScope listingScope = const MirrorListingScope.complete(),
  Set<String>? confirmedDeletions,
  Set<String> verifiedIdenticalPaths = const {},
  Set<String> deferredPaths = const {},
  MirrorPlanner planner = const MirrorPlanner(),
  DateTime? now,
}) => planner.plan(
  local: local,
  remote: remote,
  baseline: baseline,
  direction: direction,
  conflictPolicy: conflictPolicy,
  initialSyncPolicy: initialSyncPolicy,
  now: now ?? _now,
  listingScope: listingScope,
  confirmedDeletions: confirmedDeletions,
  verifiedIdenticalPaths: verifiedIdenticalPaths,
  deferredPaths: deferredPaths,
);

MirrorAction _onlyAction(MirrorPlan plan) {
  expect(plan.actions, hasLength(1), reason: 'expected exactly one action');
  return plan.actions.single;
}

List<String> _pathsOf(MirrorPlan plan, MirrorActionType type) => [
  for (final action in plan.actions)
    if (action.type == type) action.relativePath,
];

/// Every counter reported by [MirrorPlanStats] must equal the number of actions
/// it describes.
void _expectStatsMatchActions(MirrorPlan plan) {
  expect(
    plan.stats.uploadCount,
    _pathsOf(plan, MirrorActionType.uploadFile).length,
  );
  expect(
    plan.stats.downloadCount,
    _pathsOf(plan, MirrorActionType.downloadFile).length,
  );
  expect(
    plan.stats.deleteRemoteCount,
    _pathsOf(plan, MirrorActionType.deleteRemoteEntry).length,
  );
  expect(
    plan.stats.deleteLocalCount,
    _pathsOf(plan, MirrorActionType.deleteLocalEntry).length,
  );
  expect(
    plan.stats.createDirectoryCount,
    _pathsOf(plan, MirrorActionType.createRemoteDirectory).length +
        _pathsOf(plan, MirrorActionType.createLocalDirectory).length,
  );
}

void main() {
  // -------------------------------------------------------------------------
  // §4.3 — no baseline yet (first sync / brand-new path)
  // -------------------------------------------------------------------------

  group('MirrorPlanner without a baseline', () {
    test(
      'uploads a local-only file in bidirectional/uploadOnly and keeps it in '
      'downloadOnly',
      () {
        final local = {'a.txt': _file('a.txt', size: 5, modifiedAt: _t0)};

        for (final direction in [
          SyncDirection.bidirectional,
          SyncDirection.uploadOnly,
        ]) {
          final plan = _plan(local: local, direction: direction);
          final action = _onlyAction(plan);
          expect(action.type, MirrorActionType.uploadFile);
          expect(action.relativePath, 'a.txt');
          expect(action.outcome, MirrorPathOutcome.uploaded);
          expect(action.local, same(local['a.txt']));
          expect(action.remote, isNull);
          expect(action.conflictCopyPath, isNull);
          expect(action.isDeletion, isFalse);
          expect(plan.conflicts, isEmpty);
          expect(plan.removedBaselinePaths, isEmpty);
          expect(plan.heldDeletions, isNull);
          expect(plan.stats.uploadCount, 1);
          expect(plan.stats.unchangedCount, 0);
          expect(plan.stats.skippedLocalOnlyCount, 0);
          _expectStatsMatchActions(plan);
        }

        final skipped = _plan(
          local: local,
          direction: SyncDirection.downloadOnly,
        );
        expect(skipped.actions, isEmpty);
        expect(skipped.conflicts, isEmpty);
        expect(skipped.removedBaselinePaths, isEmpty);
        expect(skipped.stats.skippedLocalOnlyCount, 1);
        expect(skipped.stats.skippedRemoteOnlyCount, 0);
        expect(skipped.stats.uploadCount, 0);
        expect(skipped.stats.downloadCount, 0);
        // A path kept in place for direction reasons is skipped, not
        // unchanged: the run summary must not claim it matched.
        expect(skipped.stats.unchangedCount, 0);
      },
    );

    test(
      'downloads a remote-only file in bidirectional/downloadOnly and keeps it '
      'in uploadOnly',
      () {
        final remote = {'b.txt': _file('b.txt', size: 7, modifiedAt: _t0)};

        for (final direction in [
          SyncDirection.bidirectional,
          SyncDirection.downloadOnly,
        ]) {
          final plan = _plan(remote: remote, direction: direction);
          final action = _onlyAction(plan);
          expect(action.type, MirrorActionType.downloadFile);
          expect(action.relativePath, 'b.txt');
          expect(action.outcome, MirrorPathOutcome.downloaded);
          expect(action.local, isNull);
          expect(action.remote, same(remote['b.txt']));
          expect(action.conflictCopyPath, isNull);
          expect(plan.conflicts, isEmpty);
          expect(plan.removedBaselinePaths, isEmpty);
          expect(plan.stats.downloadCount, 1);
          expect(plan.stats.unchangedCount, 0);
          expect(plan.stats.skippedRemoteOnlyCount, 0);
          _expectStatsMatchActions(plan);
        }

        final skipped = _plan(
          remote: remote,
          direction: SyncDirection.uploadOnly,
        );
        expect(skipped.actions, isEmpty);
        expect(skipped.conflicts, isEmpty);
        expect(skipped.stats.skippedRemoteOnlyCount, 1);
        expect(skipped.stats.skippedLocalOnlyCount, 0);
        expect(skipped.stats.uploadCount, 0);
        expect(skipped.stats.downloadCount, 0);
        expect(skipped.stats.unchangedCount, 0);
      },
    );

    test('adopts an equal-size pair whose mtimes are inside the 2 s '
        'tolerance', () {
      expect(mirrorTimeTolerance, const Duration(seconds: 2));

      final local = {'a.txt': _file('a.txt', size: 10, modifiedAt: _t0)};

      for (final delta in [
        Duration.zero,
        const Duration(seconds: 1),
        const Duration(seconds: 2),
      ]) {
        final plan = _plan(
          local: local,
          remote: {
            'a.txt': _file('a.txt', size: 10, modifiedAt: _t0.add(delta)),
          },
        );
        expect(plan.actions, isEmpty, reason: 'delta $delta must be adopted');
        expect(plan.conflicts, isEmpty);
        expect(plan.stats.unchangedCount, 1);
        expect(plan.stats.uploadCount, 0);
        expect(plan.stats.downloadCount, 0);
        expect(plan.removedBaselinePaths, isEmpty);
      }

      // Outside the tolerance the pair is ambiguous, so `merge` plans a
      // conflict instead of guessing.
      final ambiguous = _plan(
        local: local,
        remote: {
          'a.txt': _file(
            'a.txt',
            size: 10,
            modifiedAt: _t0.add(const Duration(seconds: 3)),
          ),
        },
      );
      expect(_onlyAction(ambiguous).type, MirrorActionType.downloadFile);
      expect(ambiguous.conflicts.single.kind, MirrorConflictKind.bothCreated);
    });

    test('merge keeps both versions when the two sides disagree', () {
      final local = {'c.txt': _file('c.txt', size: 10, modifiedAt: _t0)};
      final remote = {'c.txt': _file('c.txt', size: 20, modifiedAt: _t0)};

      // Defaults are `merge` + `keepBoth`.
      final plan = _plan(local: local, remote: remote);

      expect(plan.conflicts, hasLength(1));
      final conflict = plan.conflicts.single;
      expect(conflict.relativePath, 'c.txt');
      expect(conflict.kind, MirrorConflictKind.bothCreated);
      expect(conflict.resolution, MirrorConflictResolution.keepBoth);
      expect(conflict.conflictCopyPath, 'c (本机冲突 $_stamp).txt');

      final action = _onlyAction(plan);
      expect(action.type, MirrorActionType.downloadFile);
      expect(action.relativePath, 'c.txt');
      expect(action.outcome, MirrorPathOutcome.downloaded);
      expect(action.local, same(local['c.txt']));
      expect(action.remote, same(remote['c.txt']));
      // The local version is renamed to this path before the remote version
      // takes the original name, so neither side is lost.
      expect(action.conflictCopyPath, conflict.conflictCopyPath);
      expect(plan.stats.downloadCount, 1);
      expect(plan.stats.uploadCount, 0);
      expect(plan.removedBaselinePaths, isEmpty);
      _expectStatsMatchActions(plan);
    });

    test('localWins uploads and remoteWins downloads without a conflict', () {
      final local = {'c.txt': _file('c.txt', size: 10, modifiedAt: _t0)};
      final remote = {'c.txt': _file('c.txt', size: 20, modifiedAt: _t0)};

      final localWins = _plan(
        local: local,
        remote: remote,
        initialSyncPolicy: MirrorInitialSyncPolicy.localWins,
      );
      final upload = _onlyAction(localWins);
      expect(upload.type, MirrorActionType.uploadFile);
      expect(upload.outcome, MirrorPathOutcome.uploaded);
      expect(upload.conflictCopyPath, isNull);
      expect(localWins.conflicts, isEmpty);
      expect(localWins.stats.uploadCount, 1);

      final remoteWins = _plan(
        local: local,
        remote: remote,
        initialSyncPolicy: MirrorInitialSyncPolicy.remoteWins,
      );
      final download = _onlyAction(remoteWins);
      expect(download.type, MirrorActionType.downloadFile);
      expect(download.outcome, MirrorPathOutcome.downloaded);
      expect(download.conflictCopyPath, isNull);
      expect(remoteWins.conflicts, isEmpty);
      expect(remoteWins.stats.downloadCount, 1);
    });

    test('merge resolves the same conflict with the configured policy', () {
      final local = {'c.txt': _file('c.txt', size: 10, modifiedAt: _t0)};
      final remote = {'c.txt': _file('c.txt', size: 20, modifiedAt: _t0)};

      final preferLocal = _plan(
        local: local,
        remote: remote,
        conflictPolicy: MirrorConflictPolicy.preferLocal,
      );
      expect(_onlyAction(preferLocal).type, MirrorActionType.uploadFile);
      expect(_onlyAction(preferLocal).conflictCopyPath, isNull);
      expect(
        preferLocal.conflicts.single.resolution,
        MirrorConflictResolution.preferLocal,
      );

      final preferRemote = _plan(
        local: local,
        remote: remote,
        conflictPolicy: MirrorConflictPolicy.preferRemote,
      );
      expect(_onlyAction(preferRemote).type, MirrorActionType.downloadFile);
      expect(_onlyAction(preferRemote).conflictCopyPath, isNull);
      expect(
        preferRemote.conflicts.single.resolution,
        MirrorConflictResolution.preferRemote,
      );

      // NOTE: design doc §4.3 describes `merge` unconditionally as
      // 「本机版本另存冲突副本 + 下载远端版本」, but `_conflict` always applies
      // `MirrorConflictPolicy`. With `merge` + `preferLocal`/`preferRemote` the
      // first sync therefore *overwrites* one of the two pre-existing versions
      // (a conflict row is still recorded, so it is not silent). §3 (policy
      // applies to every conflict) and §4.3 (merge always keeps both) conflict
      // with each other; the implementation follows §3.
    });

    test('one-way directions ignore the first-sync policy entirely', () {
      final local = {'c.txt': _file('c.txt', size: 10, modifiedAt: _t0)};
      final remote = {'c.txt': _file('c.txt', size: 20, modifiedAt: _t0)};

      final upload = _plan(
        local: local,
        remote: remote,
        direction: SyncDirection.uploadOnly,
        initialSyncPolicy: MirrorInitialSyncPolicy.remoteWins,
      );
      expect(_onlyAction(upload).type, MirrorActionType.uploadFile);
      expect(upload.conflicts, isEmpty);

      final download = _plan(
        local: local,
        remote: remote,
        direction: SyncDirection.downloadOnly,
        initialSyncPolicy: MirrorInitialSyncPolicy.localWins,
      );
      expect(_onlyAction(download).type, MirrorActionType.downloadFile);
      expect(download.conflicts, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // §4.2 — baseline exists, one side changed
  // -------------------------------------------------------------------------

  group('MirrorPlanner with a baseline, one side changed', () {
    final baseline = {
      'a.txt': _baseFile('a.txt', size: 5, modifiedAt: _t0, etag: 'e1'),
    };

    test('a local change is uploaded in bidirectional/uploadOnly and reverted '
        'in downloadOnly', () {
      final local = {'a.txt': _file('a.txt', size: 9, modifiedAt: _t1)};
      final remote = {
        'a.txt': _file('a.txt', size: 5, modifiedAt: _t0, etag: 'e1'),
      };

      for (final direction in [
        SyncDirection.bidirectional,
        SyncDirection.uploadOnly,
      ]) {
        final plan = _plan(
          local: local,
          remote: remote,
          baseline: baseline,
          direction: direction,
        );
        final action = _onlyAction(plan);
        expect(action.type, MirrorActionType.uploadFile);
        expect(action.outcome, MirrorPathOutcome.uploaded);
        expect(action.local, same(local['a.txt']));
        expect(plan.conflicts, isEmpty);
        expect(plan.removedBaselinePaths, isEmpty);
        expect(plan.stats.uploadCount, 1);
        expect(plan.stats.unchangedCount, 0);
        _expectStatsMatchActions(plan);
      }

      // downloadOnly treats the remote side as the only source of truth, so the
      // local edit is rolled back to the baseline content.
      final reverted = _plan(
        local: local,
        remote: remote,
        baseline: baseline,
        direction: SyncDirection.downloadOnly,
      );
      final action = _onlyAction(reverted);
      expect(action.type, MirrorActionType.downloadFile);
      expect(action.outcome, MirrorPathOutcome.downloaded);
      expect(action.local, same(local['a.txt']));
      expect(reverted.conflicts, isEmpty);
      expect(reverted.stats.downloadCount, 1);
      expect(reverted.stats.uploadCount, 0);
    });

    test('a remote change is downloaded in bidirectional/downloadOnly and '
        'overwritten from local in uploadOnly', () {
      final local = {
        'a.txt': _file('a.txt', size: 5, modifiedAt: _t0, etag: 'e1'),
      };
      // Size *and* etag differ from the baseline.
      final remote = {
        'a.txt': _file('a.txt', size: 9, modifiedAt: _t1, etag: 'e2'),
      };

      for (final direction in [
        SyncDirection.bidirectional,
        SyncDirection.downloadOnly,
      ]) {
        final plan = _plan(
          local: local,
          remote: remote,
          baseline: baseline,
          direction: direction,
        );
        final action = _onlyAction(plan);
        expect(action.type, MirrorActionType.downloadFile);
        expect(action.outcome, MirrorPathOutcome.downloaded);
        expect(action.remote, same(remote['a.txt']));
        expect(plan.conflicts, isEmpty);
        expect(plan.stats.downloadCount, 1);
        expect(plan.stats.unchangedCount, 0);
        _expectStatsMatchActions(plan);
      }

      final uploaded = _plan(
        local: local,
        remote: remote,
        baseline: baseline,
        direction: SyncDirection.uploadOnly,
      );
      final action = _onlyAction(uploaded);
      expect(action.type, MirrorActionType.uploadFile);
      expect(action.local, same(local['a.txt']));
      expect(uploaded.conflicts, isEmpty);
      expect(uploaded.stats.uploadCount, 1);
    });

    test('an untouched pair produces no action', () {
      final local = {
        'a.txt': _file('a.txt', size: 5, modifiedAt: _t0, etag: 'e1'),
      };
      final remote = {
        'a.txt': _file('a.txt', size: 5, modifiedAt: _t0, etag: 'e1'),
      };

      for (final direction in SyncDirection.values) {
        final plan = _plan(
          local: local,
          remote: remote,
          baseline: baseline,
          direction: direction,
        );
        expect(plan.actions, isEmpty, reason: direction.name);
        expect(plan.conflicts, isEmpty);
        expect(plan.stats.unchangedCount, 1);
        expect(plan.stats.skippedLocalOnlyCount, 0);
        expect(plan.stats.skippedRemoteOnlyCount, 0);
        expect(plan.removedBaselinePaths, isEmpty);
      }
    });
  });

  // -------------------------------------------------------------------------
  // §4.2 — baseline exists, both sides changed
  // -------------------------------------------------------------------------

  group('MirrorPlanner with a baseline, both sides changed', () {
    final baseline = {
      'a.txt': _baseFile('a.txt', size: 5, modifiedAt: _t0, etag: 'e1'),
    };
    final local = {'a.txt': _file('a.txt', size: 9, modifiedAt: _t1)};
    final remote = {
      'a.txt': _file('a.txt', size: 12, modifiedAt: _t2, etag: 'e2'),
    };

    test('keepBoth downloads the remote version and preserves the local '
        'one', () {
      final plan = _plan(local: local, remote: remote, baseline: baseline);

      final conflict = plan.conflicts.single;
      expect(conflict.relativePath, 'a.txt');
      expect(conflict.kind, MirrorConflictKind.bothModified);
      expect(conflict.resolution, MirrorConflictResolution.keepBoth);
      expect(conflict.conflictCopyPath, 'a (本机冲突 $_stamp).txt');

      final action = _onlyAction(plan);
      expect(action.type, MirrorActionType.downloadFile);
      expect(action.outcome, MirrorPathOutcome.downloaded);
      expect(action.local, same(local['a.txt']));
      expect(action.remote, same(remote['a.txt']));
      expect(action.conflictCopyPath, conflict.conflictCopyPath);
      expect(plan.stats.downloadCount, 1);
      expect(plan.removedBaselinePaths, isEmpty);
      _expectStatsMatchActions(plan);
    });

    test('preferLocal uploads and preferRemote downloads, each with a conflict '
        'row', () {
      final preferLocal = _plan(
        local: local,
        remote: remote,
        baseline: baseline,
        conflictPolicy: MirrorConflictPolicy.preferLocal,
      );
      final upload = _onlyAction(preferLocal);
      expect(upload.type, MirrorActionType.uploadFile);
      expect(upload.outcome, MirrorPathOutcome.uploaded);
      expect(upload.conflictCopyPath, isNull);
      expect(
        preferLocal.conflicts.single.resolution,
        MirrorConflictResolution.preferLocal,
      );

      final preferRemote = _plan(
        local: local,
        remote: remote,
        baseline: baseline,
        conflictPolicy: MirrorConflictPolicy.preferRemote,
      );
      final download = _onlyAction(preferRemote);
      expect(download.type, MirrorActionType.downloadFile);
      expect(download.outcome, MirrorPathOutcome.downloaded);
      expect(download.conflictCopyPath, isNull);
      expect(
        preferRemote.conflicts.single.resolution,
        MirrorConflictResolution.preferRemote,
      );

      for (final plan in [preferLocal, preferRemote]) {
        expect(plan.conflicts, hasLength(1));
        expect(plan.conflicts.single.kind, MirrorConflictKind.bothModified);
        expect(plan.conflicts.single.relativePath, 'a.txt');
        _expectStatsMatchActions(plan);
      }
    });

    test('uploadOnly uploads and downloadOnly downloads without a '
        'conflict', () {
      // Deliberately "wrong" policies would still be ignored, because the
      // conflict policy only applies to bidirectional locations.
      final upload = _plan(
        local: local,
        remote: remote,
        baseline: baseline,
        direction: SyncDirection.uploadOnly,
        conflictPolicy: MirrorConflictPolicy.preferRemote,
      );
      expect(_onlyAction(upload).type, MirrorActionType.uploadFile);
      expect(upload.conflicts, isEmpty);
      expect(upload.stats.uploadCount, 1);

      final download = _plan(
        local: local,
        remote: remote,
        baseline: baseline,
        direction: SyncDirection.downloadOnly,
        conflictPolicy: MirrorConflictPolicy.preferLocal,
      );
      expect(_onlyAction(download).type, MirrorActionType.downloadFile);
      expect(download.conflicts, isEmpty);
      expect(download.stats.downloadCount, 1);
    });
  });

  // -------------------------------------------------------------------------
  // §4.2 — baseline exists, one side deleted
  // -------------------------------------------------------------------------

  group('MirrorPlanner with a baseline, one side deleted', () {
    final baseline = {
      'a.txt': _baseFile('a.txt', size: 5, modifiedAt: _t0, etag: 'e1'),
    };
    final remoteUnchanged = {
      'a.txt': _file('a.txt', size: 5, modifiedAt: _t0, etag: 'e1'),
    };
    final localUnchanged = {
      'a.txt': _file('a.txt', size: 5, modifiedAt: _t0),
    };

    test('a local deletion deletes the remote file in bidirectional/uploadOnly '
        'and is restored in downloadOnly', () {
      for (final direction in [
        SyncDirection.bidirectional,
        SyncDirection.uploadOnly,
      ]) {
        final plan = _plan(
          remote: remoteUnchanged,
          baseline: baseline,
          direction: direction,
        );
        final action = _onlyAction(plan);
        expect(action.type, MirrorActionType.deleteRemoteEntry);
        expect(action.relativePath, 'a.txt');
        expect(action.isDeletion, isTrue);
        expect(action.isDirectoryOperation, isFalse);
        expect(action.remote, same(remoteUnchanged['a.txt']));
        // NOTE: deletion actions carry `MirrorPathOutcome.unchanged` because the
        // enum has no "deleted" value. `MirrorBaselineEntry.forOutcome` would
        // build a bogus row for a `unchanged` outcome with a null side, but
        // nothing in lib/ calls `forOutcome`; the service drops the baseline row
        // explicitly instead.
        expect(action.outcome, MirrorPathOutcome.unchanged);
        expect(plan.conflicts, isEmpty);
        expect(plan.removedBaselinePaths, ['a.txt']);
        expect(plan.stats.deleteRemoteCount, 1);
        expect(plan.stats.deleteLocalCount, 0);
        // 1 baseline row is far below `fractionCheckMinimumEntries`.
        expect(plan.heldDeletions, isNull);
        _expectStatsMatchActions(plan);
      }

      final restored = _plan(
        remote: remoteUnchanged,
        baseline: baseline,
        direction: SyncDirection.downloadOnly,
      );
      expect(_onlyAction(restored).type, MirrorActionType.downloadFile);
      expect(restored.removedBaselinePaths, isEmpty);
      expect(restored.conflicts, isEmpty);
    });

    test('a remote deletion deletes the local file in bidirectional/'
        'downloadOnly and is re-uploaded in uploadOnly', () {
      for (final direction in [
        SyncDirection.bidirectional,
        SyncDirection.downloadOnly,
      ]) {
        final plan = _plan(
          local: localUnchanged,
          baseline: baseline,
          direction: direction,
        );
        final action = _onlyAction(plan);
        expect(action.type, MirrorActionType.deleteLocalEntry);
        expect(action.isDeletion, isTrue);
        expect(action.local, same(localUnchanged['a.txt']));
        expect(plan.conflicts, isEmpty);
        expect(plan.removedBaselinePaths, ['a.txt']);
        expect(plan.stats.deleteLocalCount, 1);
        expect(plan.stats.deleteRemoteCount, 0);
        expect(plan.heldDeletions, isNull);
        _expectStatsMatchActions(plan);
      }

      // Only-upload: the local folder is the only source of truth, so the file
      // is put back on the remote side.
      final reuploaded = _plan(
        local: localUnchanged,
        baseline: baseline,
        direction: SyncDirection.uploadOnly,
      );
      final action = _onlyAction(reuploaded);
      expect(action.type, MirrorActionType.uploadFile);
      expect(action.local, same(localUnchanged['a.txt']));
      expect(reuploaded.removedBaselinePaths, isEmpty);
      expect(reuploaded.conflicts, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // §4.2 — delete versus modify
  // -------------------------------------------------------------------------

  group('MirrorPlanner delete-versus-modify', () {
    final baseline = {
      'a.txt': _baseFile('a.txt', size: 5, modifiedAt: _t0, etag: 'e1'),
    };

    test('a locally modified file survives a remote deletion', () {
      final local = {'a.txt': _file('a.txt', size: 9, modifiedAt: _t1)};

      final plan = _plan(local: local, baseline: baseline);

      final action = _onlyAction(plan);
      expect(action.type, MirrorActionType.uploadFile);
      expect(action.outcome, MirrorPathOutcome.uploaded);
      expect(action.local, same(local['a.txt']));
      expect(plan.stats.uploadCount, 1);
      expect(plan.stats.deleteLocalCount, 0);
      expect(plan.heldDeletions, isNull);

      final conflict = plan.conflicts.single;
      expect(conflict.relativePath, 'a.txt');
      expect(conflict.kind, MirrorConflictKind.deleteVersusModify);
      expect(conflict.resolution, MirrorConflictResolution.preferLocal);
      expect(conflict.conflictCopyPath, isNull);
      // The baseline row stays so the resurrected file keeps being tracked.
      expect(plan.removedBaselinePaths, isEmpty);
      _expectStatsMatchActions(plan);

      // uploadOnly carries the modification the same way.
      final uploadOnly = _plan(
        local: local,
        baseline: baseline,
        direction: SyncDirection.uploadOnly,
      );
      expect(_onlyAction(uploadOnly).type, MirrorActionType.uploadFile);
      expect(uploadOnly.conflicts, isEmpty);

      // downloadOnly follows the remote side: the local edit is discarded
      // (design doc §3: 本机对已同步文件的改动会被覆盖（回滚）).
      final downloadOnly = _plan(
        local: local,
        baseline: baseline,
        direction: SyncDirection.downloadOnly,
      );
      expect(_onlyAction(downloadOnly).type, MirrorActionType.deleteLocalEntry);
      expect(downloadOnly.conflicts, isEmpty);
    });

    test('a remotely modified file survives a local deletion', () {
      final remote = {
        'a.txt': _file('a.txt', size: 12, modifiedAt: _t2, etag: 'e2'),
      };

      final plan = _plan(remote: remote, baseline: baseline);

      final action = _onlyAction(plan);
      expect(action.type, MirrorActionType.downloadFile);
      expect(action.outcome, MirrorPathOutcome.downloaded);
      expect(action.remote, same(remote['a.txt']));
      expect(plan.stats.downloadCount, 1);
      expect(plan.stats.deleteRemoteCount, 0);
      expect(plan.heldDeletions, isNull);

      final conflict = plan.conflicts.single;
      expect(conflict.kind, MirrorConflictKind.deleteVersusModify);
      expect(conflict.resolution, MirrorConflictResolution.preferRemote);
      expect(plan.removedBaselinePaths, isEmpty);
      _expectStatsMatchActions(plan);
    });
  });

  // -------------------------------------------------------------------------
  // §4.2 — deleted on both sides
  // -------------------------------------------------------------------------

  group('MirrorPlanner with both sides deleted', () {
    test('drops the baseline rows and plans nothing', () {
      final baseline = _baselines(['gone.txt', 'gone2.txt']);

      final plan = _plan(baseline: baseline);

      expect(plan.actions, isEmpty);
      expect(plan.conflicts, isEmpty);
      expect(plan.heldDeletions, isNull);
      expect(plan.stats.deleteLocalCount, 0);
      expect(plan.stats.deleteRemoteCount, 0);
      expect(plan.stats.unchangedCount, 0);
      expect(plan.stats.deferredCount, 0);
      expect(plan.removedBaselinePaths, ['gone.txt', 'gone2.txt']);
    });
  });

  // -------------------------------------------------------------------------
  // §4.5 / §3 — directories
  // -------------------------------------------------------------------------

  group('MirrorPlanner directories', () {
    test('creates a local-only directory remotely and keeps it in downloadOnly',
        () {
      final local = {'photos': _dir('photos')};

      for (final direction in [
        SyncDirection.bidirectional,
        SyncDirection.uploadOnly,
      ]) {
        final plan = _plan(local: local, direction: direction);
        final action = _onlyAction(plan);
        expect(action.type, MirrorActionType.createRemoteDirectory);
        expect(action.relativePath, 'photos');
        expect(action.outcome, MirrorPathOutcome.remoteDirectoryCreated);
        expect(action.local, same(local['photos']));
        expect(action.remote, isNull);
        expect(action.isDirectoryOperation, isTrue);
        expect(action.isDeletion, isFalse);
        expect(plan.stats.createDirectoryCount, 1);
        expect(plan.removedBaselinePaths, isEmpty);
        _expectStatsMatchActions(plan);
      }

      final skipped = _plan(
        local: local,
        direction: SyncDirection.downloadOnly,
      );
      expect(skipped.actions, isEmpty);
      expect(skipped.stats.createDirectoryCount, 0);
      // A directory kept in place for direction reasons is reported exactly
      // like a skipped file.
      expect(skipped.stats.skippedLocalOnlyCount, 1);
      expect(skipped.stats.unchangedCount, 0);
    });

    test('creates a remote-only directory locally and keeps it in uploadOnly',
        () {
      final remote = {'docs': _dir('docs')};

      for (final direction in [
        SyncDirection.bidirectional,
        SyncDirection.downloadOnly,
      ]) {
        final plan = _plan(remote: remote, direction: direction);
        final action = _onlyAction(plan);
        expect(action.type, MirrorActionType.createLocalDirectory);
        expect(action.relativePath, 'docs');
        expect(action.outcome, MirrorPathOutcome.localDirectoryCreated);
        expect(action.remote, same(remote['docs']));
        expect(action.local, isNull);
        expect(action.isDirectoryOperation, isTrue);
        expect(plan.stats.createDirectoryCount, 1);
        _expectStatsMatchActions(plan);
      }

      final skipped = _plan(
        remote: remote,
        direction: SyncDirection.uploadOnly,
      );
      expect(skipped.actions, isEmpty);
      expect(skipped.stats.createDirectoryCount, 0);
      expect(skipped.stats.skippedRemoteOnlyCount, 1);
      expect(skipped.stats.unchangedCount, 0);
    });

    test('never deletes a directory whose children survive on the other side',
        () {
      final baseline = {
        'photos': _baseDir('photos'),
        'photos/a.txt': _baseFile('photos/a.txt', size: 5, modifiedAt: _t0),
      };
      final local = {
        'photos': _dir('photos'),
        'photos/a.txt': _file('photos/a.txt', size: 5, modifiedAt: _t0),
      };
      // The remote collection entry is missing from the listing, but its child
      // is still there, so deleting the local directory would destroy a copy of
      // a file that still exists remotely.
      final remote = {
        'photos/a.txt': _file('photos/a.txt', size: 5, modifiedAt: _t0),
      };

      final plan = _plan(baseline: baseline, local: local, remote: remote);

      expect(plan.actions, isEmpty);
      expect(plan.stats.deleteLocalCount, 0);
      expect(plan.stats.deleteRemoteCount, 0);
      expect(plan.removedBaselinePaths, isEmpty);
      expect(plan.stats.unchangedCount, 2);
    });

    test('plans the deletion of a directory that is empty on the other side',
        () {
      final baseline = {
        'old': _baseDir('old'),
        'old/inner': _baseDir('old/inner'),
      };
      final local = {'old': _dir('old'), 'old/inner': _dir('old/inner')};

      // The remote side has nothing left under `old`.
      final plan = _plan(baseline: baseline, local: local);

      final deletions = plan.actions.where((action) => action.isDeletion);
      expect(deletions, hasLength(2));
      expect(
        deletions.every(
          (action) => action.type == MirrorActionType.deleteLocalEntry,
        ),
        isTrue,
      );
      // The planner emits paths in ascending order (parent first); the executor
      // re-sorts deletions deepest-first before running them
      // (`plain_folder_sync_service._apply`), which is what keeps a recursive
      // parent delete safe.
      expect(plan.actions.map((action) => action.relativePath), [
        'old',
        'old/inner',
      ]);
      expect(plan.stats.deleteLocalCount, 2);
      expect(plan.stats.deleteRemoteCount, 0);
      expect(plan.removedBaselinePaths, ['old', 'old/inner']);
      // Two rows are below `fractionCheckMinimumEntries`, so the 1000-entry
      // limit applies and the deletions are executed.
      expect(plan.heldDeletions, isNull);
      _expectStatsMatchActions(plan);
    });
  });

  // -------------------------------------------------------------------------
  // Verification hints: verifiedIdenticalPaths / deferredPaths
  // -------------------------------------------------------------------------

  group('MirrorPlanner verification hints', () {
    test('verifiedIdenticalPaths adopts an ambiguous same-size pair', () {
      final local = {'a.txt': _file('a.txt', size: 10, modifiedAt: _t0)};
      final remote = {
        'a.txt': _file(
          'a.txt',
          size: 10,
          modifiedAt: _t0.add(const Duration(minutes: 5)),
        ),
      };

      final unverified = _plan(local: local, remote: remote);
      expect(unverified.conflicts.single.kind, MirrorConflictKind.bothCreated);
      expect(unverified.stats.downloadCount, 1);

      final verified = _plan(
        local: local,
        remote: remote,
        verifiedIdenticalPaths: {'a.txt'},
      );
      expect(verified.actions, isEmpty);
      expect(verified.conflicts, isEmpty);
      expect(verified.stats.unchangedCount, 1);
      expect(verified.stats.downloadCount, 0);
      expect(verified.removedBaselinePaths, isEmpty);

      // A hint for a different path changes nothing.
      final unrelated = _plan(
        local: local,
        remote: remote,
        verifiedIdenticalPaths: {'zzz.txt'},
      );
      expect(unrelated.stats.downloadCount, 1);
      expect(unrelated.conflicts, hasLength(1));

      // The hint is only consulted for paths without a baseline: once a
      // baseline exists, size+mtime (and etag) decide.
      final withBaseline = _plan(
        local: {'a.txt': _file('a.txt', size: 9, modifiedAt: _t1)},
        remote: {'a.txt': _file('a.txt', size: 12, modifiedAt: _t2)},
        baseline: {'a.txt': _baseFile('a.txt', size: 5, modifiedAt: _t0)},
        verifiedIdenticalPaths: {'a.txt'},
      );
      expect(withBaseline.conflicts, hasLength(1));
      expect(
        withBaseline.conflicts.single.kind,
        MirrorConflictKind.bothModified,
      );
    });

    test('deferredPaths plan nothing and are counted as deferred', () {
      final baseline = {
        'edited.txt': _baseFile('edited.txt', size: 5, modifiedAt: _t0),
        'deleted.txt': _baseFile('deleted.txt', size: 5, modifiedAt: _t0),
      };
      final local = {
        'edited.txt': _file('edited.txt', size: 9, modifiedAt: _t1),
      };
      final remote = {
        'edited.txt': _file('edited.txt', size: 5, modifiedAt: _t0),
        'deleted.txt': _file('deleted.txt', size: 5, modifiedAt: _t0),
        'fresh.txt': _file('fresh.txt', size: 3, modifiedAt: _t0),
      };

      // Without the hints these three paths would be an upload, a deletion and
      // a download.
      final control = _plan(baseline: baseline, local: local, remote: remote);
      expect(_pathsOf(control, MirrorActionType.uploadFile), ['edited.txt']);
      expect(_pathsOf(control, MirrorActionType.deleteRemoteEntry), [
        'deleted.txt',
      ]);
      expect(_pathsOf(control, MirrorActionType.downloadFile), ['fresh.txt']);
      expect(control.stats.deferredCount, 0);

      final deferred = _plan(
        baseline: baseline,
        local: local,
        remote: remote,
        deferredPaths: {'edited.txt', 'deleted.txt', 'fresh.txt'},
      );
      expect(deferred.actions, isEmpty);
      expect(deferred.conflicts, isEmpty);
      expect(deferred.stats.deferredCount, 3);
      expect(deferred.stats.uploadCount, 0);
      expect(deferred.stats.downloadCount, 0);
      expect(deferred.stats.deleteRemoteCount, 0);
      expect(deferred.stats.deleteLocalCount, 0);
      expect(deferred.stats.unchangedCount, 0);
      expect(deferred.stats.skippedLocalOnlyCount, 0);
      expect(deferred.stats.skippedRemoteOnlyCount, 0);
      expect(deferred.heldDeletions, isNull);
      // A deferred path keeps its baseline row, so the next run still sees the
      // deletion (unlike a *held* deletion, see the deletion-protection group).
      expect(deferred.removedBaselinePaths, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // §4.4 — deletion protection
  // -------------------------------------------------------------------------

  group('MirrorPlanner deletion protection', () {
    test('holds every deletion once maxDeletedEntries is exceeded', () {
      const planner = MirrorPlanner(
        deletionProtection: MirrorDeletionProtection(
          maxDeletedEntries: 2,
          maxDeletedFraction: 1.0,
          fractionCheckMinimumEntries: 100,
        ),
      );
      final names = _numbered(5);
      final local = {
        ..._files(names.sublist(3)),
        'new.txt': _file('new.txt', size: 3, modifiedAt: _t0),
      };

      final plan = _plan(
        local: local,
        remote: _files(names),
        baseline: _baselines(names),
        planner: planner,
      );

      final held = plan.heldDeletions;
      expect(held, isNotNull);
      expect(held!.isEmpty, isFalse);
      expect(held.actions.map((action) => action.relativePath), [
        'd1.txt',
        'd2.txt',
        'd3.txt',
      ]);
      expect(held.actions.every((action) => action.isDeletion), isTrue);
      expect(held.knownEntryCount, 5);
      expect(held.limit, 2);

      // No deletion reaches the executable list; everything else still runs.
      expect(plan.actions.where((action) => action.isDeletion), isEmpty);
      expect(plan.stats.deleteRemoteCount, 0);
      expect(plan.stats.deleteLocalCount, 0);
      expect(_onlyAction(plan).relativePath, 'new.txt');
      expect(plan.stats.uploadCount, 1);
      expect(plan.stats.unchangedCount, 2);
      _expectStatsMatchActions(plan);

      // A withheld deletion keeps its baseline row: dropping it would make the
      // next run treat the file as brand new and download it back, silently
      // undoing the user's deletion instead of asking about it.
      expect(plan.removedBaselinePaths, isEmpty);

      // The next unconfirmed run therefore plans the very same deletions.
      final nextRun = _plan(
        local: local,
        remote: _files(names),
        baseline: _baselines(names),
        planner: planner,
      );
      expect(
        nextRun.heldDeletions!.actions.map((action) => action.relativePath),
        ['d1.txt', 'd2.txt', 'd3.txt'],
      );
      expect(nextRun.removedBaselinePaths, isEmpty);
      _expectStatsMatchActions(nextRun);

      // Only the explicitly confirmed run deletes them, and only then are the
      // baseline rows dropped.
      final confirmed = _plan(
        local: local,
        remote: _files(names),
        baseline: _baselines(names),
        planner: planner,
        confirmedDeletions: const {'d1.txt', 'd2.txt', 'd3.txt'},
      );
      expect(confirmed.heldDeletions, isNull);
      expect(_pathsOf(confirmed, MirrorActionType.deleteRemoteEntry), [
        'd1.txt',
        'd2.txt',
        'd3.txt',
      ]);
      expect(confirmed.removedBaselinePaths, ['d1.txt', 'd2.txt', 'd3.txt']);
      _expectStatsMatchActions(confirmed);
    });

    test('holds every deletion once the baseline fraction is exceeded', () {
      final names = _numbered(10);
      final remote = _files(names);
      final baseline = _baselines(names);

      // 3 deletions out of 10 baseline rows: limit = ceil(10 * 0.2) = 2.
      // Actions follow the planner's lexicographic path order, so `d10.txt`
      // comes before `d8.txt`.
      final overLimit = _plan(
        local: _files(names.sublist(0, 7)),
        remote: remote,
        baseline: baseline,
      );
      final held = overLimit.heldDeletions;
      expect(held, isNotNull);
      expect(held!.actions.map((action) => action.relativePath), [
        'd10.txt',
        'd8.txt',
        'd9.txt',
      ]);
      expect(held.knownEntryCount, 10);
      expect(held.limit, 2);
      expect(overLimit.actions, isEmpty);
      expect(overLimit.stats.deleteRemoteCount, 0);
      expect(overLimit.stats.deleteLocalCount, 0);
      expect(overLimit.stats.unchangedCount, 7);
      _expectStatsMatchActions(overLimit);

      // Exactly at the limit (2 of 10 = 20%) the deletions are executed.
      final withinLimit = _plan(
        local: _files(names.sublist(0, 8)),
        remote: remote,
        baseline: baseline,
      );
      expect(withinLimit.heldDeletions, isNull);
      expect(withinLimit.actions.map((action) => action.relativePath), [
        'd10.txt',
        'd9.txt',
      ]);
      expect(withinLimit.stats.deleteRemoteCount, 2);
      expect(withinLimit.stats.unchangedCount, 8);
      expect(withinLimit.removedBaselinePaths, ['d10.txt', 'd9.txt']);
      _expectStatsMatchActions(withinLimit);
    });

    test('holds local and remote deletions against one shared limit', () {
      const planner = MirrorPlanner(
        deletionProtection: MirrorDeletionProtection(
          maxDeletedEntries: 3,
          maxDeletedFraction: 1.0,
          fractionCheckMinimumEntries: 100,
        ),
      );
      final names = _numbered(5);
      // d1/d2/d4 are gone locally (delete remote), the remote lost d5
      // (delete local); d3 is still on both sides.
      final plan = _plan(
        local: _files(['d3.txt', 'd5.txt']),
        remote: _files(['d1.txt', 'd2.txt', 'd3.txt', 'd4.txt']),
        baseline: _baselines(names),
        planner: planner,
      );

      expect(plan.heldDeletions, isNotNull);
      expect(plan.heldDeletions!.actions, hasLength(4));
      expect(plan.heldDeletions!.limit, 3);
      expect(plan.actions, isEmpty);
      expect(plan.stats.deleteRemoteCount, 0);
      expect(plan.stats.deleteLocalCount, 0);
    });

    test('fewer baseline rows than fractionCheckMinimumEntries never trip the '
        'fraction check', () {
      // Default protection: 1000 entries / 20% / minimum 5 baseline rows.
      final names = _numbered(3);

      final plan = _plan(
        remote: _files(names),
        baseline: _baselines(names),
      );
      expect(plan.heldDeletions, isNull);
      expect(plan.actions, hasLength(3));
      expect(plan.stats.deleteRemoteCount, 3);
      expect(plan.removedBaselinePaths, ['d1.txt', 'd2.txt', 'd3.txt']);

      // The minimum is a real gate: with it lowered to 2 rows, the same three
      // rows make 2 of 3 deletions exceed ceil(3 * 0.2) = 1.
      const strict = MirrorPlanner(
        deletionProtection: MirrorDeletionProtection(
          maxDeletedFraction: 0.2,
          fractionCheckMinimumEntries: 2,
        ),
      );
      final strictPlan = _plan(
        remote: _files(names),
        baseline: _baselines(names),
        planner: strict,
      );
      expect(strictPlan.heldDeletions, isNotNull);
      expect(strictPlan.heldDeletions!.limit, 1);
      expect(strictPlan.heldDeletions!.actions, hasLength(3));
      expect(strictPlan.actions, isEmpty);
    });

    test('confirmed deletions apply exactly the paths the user was shown', () {
      const planner = MirrorPlanner(
        deletionProtection: MirrorDeletionProtection(
          maxDeletedEntries: 2,
          maxDeletedFraction: 1.0,
          fractionCheckMinimumEntries: 100,
        ),
      );
      final names = _numbered(5);

      MirrorPlan run({Set<String>? confirmedDeletions}) => _plan(
        local: _files(names.sublist(3)),
        remote: _files(names),
        baseline: _baselines(names),
        planner: planner,
        confirmedDeletions: confirmedDeletions,
      );

      final unconfirmed = run();
      final confirmed = run(
        confirmedDeletions: const {'d1.txt', 'd2.txt', 'd3.txt'},
      );

      // Without confirmation every deletion is held, nothing is deleted and
      // every baseline row survives for the next attempt.
      expect(unconfirmed.heldDeletions?.actions, hasLength(3));
      expect(unconfirmed.heldDeletions!.paths, {'d1.txt', 'd2.txt', 'd3.txt'});
      expect(
        unconfirmed.actions.where((action) => action.isDeletion),
        isEmpty,
      );
      expect(unconfirmed.stats.deleteRemoteCount, 0);
      expect(unconfirmed.stats.deleteLocalCount, 0);
      expect(unconfirmed.removedBaselinePaths, isEmpty);

      // The confirmed run performs exactly those deletions.
      expect(confirmed.heldDeletions, isNull);
      expect(_pathsOf(confirmed, MirrorActionType.deleteRemoteEntry), [
        'd1.txt',
        'd2.txt',
        'd3.txt',
      ]);
      expect(confirmed.stats.deleteRemoteCount, 3);
      expect(confirmed.removedBaselinePaths, ['d1.txt', 'd2.txt', 'd3.txt']);
      _expectStatsMatchActions(confirmed);
    });

    test('a plan that grew since the confirmation re-holds the unseen paths', () {
      const planner = MirrorPlanner(
        deletionProtection: MirrorDeletionProtection(
          maxDeletedEntries: 2,
          maxDeletedFraction: 1.0,
          fractionCheckMinimumEntries: 100,
        ),
      );
      final names = _numbered(5);
      final baseline = _baselines(names);

      // The user was shown three deletions and confirmed those three paths.
      final shown = _plan(
        local: _files(names.sublist(3)),
        remote: _files(names),
        baseline: baseline,
        planner: planner,
      );
      final confirmedPaths = shown.heldDeletions!.paths;
      expect(confirmedPaths, {'d1.txt', 'd2.txt', 'd3.txt'});

      // Between the summary and the confirmed run another local file vanished,
      // so the fresh plan holds four deletions. Only the confirmed three may
      // run; the fourth is held again instead of being deleted unseen.
      final confirmed = _plan(
        local: _files(['d5.txt']),
        remote: _files(names),
        baseline: baseline,
        planner: planner,
        confirmedDeletions: confirmedPaths,
      );

      expect(_pathsOf(confirmed, MirrorActionType.deleteRemoteEntry), [
        'd1.txt',
        'd2.txt',
        'd3.txt',
      ]);
      expect(confirmed.stats.deleteRemoteCount, 3);
      expect(confirmed.heldDeletions, isNotNull);
      expect(confirmed.heldDeletions!.paths, {'d4.txt'});
      expect(
        confirmed.removedBaselinePaths,
        ['d1.txt', 'd2.txt', 'd3.txt'],
        reason: 'the re-held path keeps its baseline row',
      );
      _expectStatsMatchActions(confirmed);
    });
  });

  // -------------------------------------------------------------------------
  // MirrorPlanStats — counters must describe the planned actions
  // -------------------------------------------------------------------------

  group('MirrorPlanStats', () {
    // One shared pair of directories: a synced file, both kinds of edit, one
    // deletion, and a brand-new file on each side.
    final baseline = {
      'keep.txt': _baseFile('keep.txt', size: 5, modifiedAt: _t0),
      'edited.txt': _baseFile('edited.txt', size: 5, modifiedAt: _t0),
      'gone.txt': _baseFile('gone.txt', size: 5, modifiedAt: _t0),
      'remote-edited.txt': _baseFile(
        'remote-edited.txt',
        size: 5,
        modifiedAt: _t0,
      ),
    };
    final local = {
      'keep.txt': _file('keep.txt', size: 5, modifiedAt: _t0),
      'edited.txt': _file('edited.txt', size: 9, modifiedAt: _t1),
      'remote-edited.txt': _file('remote-edited.txt', size: 5, modifiedAt: _t0),
      'new.txt': _file('new.txt', size: 3, modifiedAt: _t0),
    };
    final remote = {
      'keep.txt': _file('keep.txt', size: 5, modifiedAt: _t0),
      'edited.txt': _file('edited.txt', size: 5, modifiedAt: _t0),
      'remote-edited.txt': _file(
        'remote-edited.txt',
        size: 11,
        modifiedAt: _t2,
      ),
      'gone.txt': _file('gone.txt', size: 5, modifiedAt: _t0),
      'remote-new.txt': _file('remote-new.txt', size: 7, modifiedAt: _t0),
    };

    for (final scenario in [
      (
        direction: SyncDirection.bidirectional,
        uploads: 2,
        downloads: 2,
        deletedRemote: 1,
        deletedLocal: 0,
        unchanged: 1,
        skippedLocalOnly: 0,
        skippedRemoteOnly: 0,
      ),
      (
        direction: SyncDirection.uploadOnly,
        uploads: 3,
        downloads: 0,
        deletedRemote: 1,
        deletedLocal: 0,
        unchanged: 1,
        skippedLocalOnly: 0,
        skippedRemoteOnly: 1,
      ),
      (
        direction: SyncDirection.downloadOnly,
        uploads: 0,
        downloads: 4,
        deletedRemote: 0,
        deletedLocal: 0,
        unchanged: 1,
        skippedLocalOnly: 1,
        skippedRemoteOnly: 0,
      ),
    ]) {
      test('counts every planned action (${scenario.direction.name})', () {
        final plan = _plan(
          local: local,
          remote: remote,
          baseline: baseline,
          direction: scenario.direction,
        );

        expect(plan.stats.uploadCount, scenario.uploads);
        expect(plan.stats.downloadCount, scenario.downloads);
        expect(plan.stats.deleteRemoteCount, scenario.deletedRemote);
        expect(plan.stats.deleteLocalCount, scenario.deletedLocal);
        expect(plan.stats.createDirectoryCount, 0);
        expect(plan.stats.unchangedCount, scenario.unchanged);
        expect(plan.stats.skippedLocalOnlyCount, scenario.skippedLocalOnly);
        expect(plan.stats.skippedRemoteOnlyCount, scenario.skippedRemoteOnly);
        expect(plan.stats.deferredCount, 0);
        expect(plan.conflicts, isEmpty);
        expect(plan.heldDeletions, isNull);
        expect(
          plan.actions,
          hasLength(
            scenario.uploads +
                scenario.downloads +
                scenario.deletedRemote +
                scenario.deletedLocal,
          ),
        );
        _expectStatsMatchActions(plan);
      });
    }

    test('counts the kept actions only when deletions are held', () {
      const planner = MirrorPlanner(
        deletionProtection: MirrorDeletionProtection(
          maxDeletedEntries: 1,
          maxDeletedFraction: 1.0,
          fractionCheckMinimumEntries: 100,
        ),
      );
      final plan = _plan(
        local: {
          'd3.txt': _file('d3.txt', size: 5, modifiedAt: _t0),
          'extra.txt': _file('extra.txt', size: 4, modifiedAt: _t0),
        },
        remote: {
          'd1.txt': _file('d1.txt', size: 5, modifiedAt: _t0),
          'd2.txt': _file('d2.txt', size: 5, modifiedAt: _t0),
          'd3.txt': _file('d3.txt', size: 5, modifiedAt: _t0),
        },
        baseline: {
          'd1.txt': _baseFile('d1.txt', size: 5, modifiedAt: _t0),
          'd2.txt': _baseFile('d2.txt', size: 5, modifiedAt: _t0),
          'd3.txt': _baseFile('d3.txt', size: 5, modifiedAt: _t0),
        },
        planner: planner,
      );

      // d1/d2 were deleted locally (remote deletes held), d3 is unchanged and
      // extra.txt is a new local file.
      expect(plan.heldDeletions!.actions.map((action) => action.relativePath), [
        'd1.txt',
        'd2.txt',
      ]);
      expect(plan.actions.map((action) => action.relativePath), ['extra.txt']);
      expect(plan.stats.uploadCount, 1);
      expect(plan.stats.downloadCount, 0);
      expect(plan.stats.deleteRemoteCount, 0);
      expect(plan.stats.deleteLocalCount, 0);
      expect(plan.stats.createDirectoryCount, 0);
      expect(plan.stats.unchangedCount, 1);
      expect(plan.stats.skippedLocalOnlyCount, 0);
      expect(plan.stats.skippedRemoteOnlyCount, 0);
      _expectStatsMatchActions(plan);
    });
  });

  // -------------------------------------------------------------------------
  // Conflict copy naming (§3)
  // -------------------------------------------------------------------------

  group('conflictCopyPathFor', () {
    test('inserts the suffix before the extension and keeps the directory', () {
      expect(
        conflictCopyPathFor('notes.txt', _now),
        'notes (本机冲突 $_stamp).txt',
      );
      expect(
        conflictCopyPathFor('docs/2026/report.final.pdf', _now),
        'docs/2026/report.final (本机冲突 $_stamp).pdf',
      );
      // Only the last extension is treated as the extension.
      expect(
        conflictCopyPathFor('archive.tar.gz', _now),
        'archive.tar (本机冲突 $_stamp).gz',
      );
      expect(
        conflictCopyPathFor('dir/notes.txt', _now),
        'dir/notes (本机冲突 $_stamp).txt',
      );
    });

    test('handles names without an extension and dotfiles safely', () {
      // No extension: the suffix is appended to the whole name.
      expect(
        conflictCopyPathFor('README', _now),
        'README (本机冲突 $_stamp)',
      );
      expect(
        conflictCopyPathFor('dir/README', _now),
        'dir/README (本机冲突 $_stamp)',
      );
      // Dotfiles: the leading dot is not an extension, so the result stays a
      // visible file instead of becoming `(本机冲突 …).bashrc`.
      expect(
        conflictCopyPathFor('.bashrc', _now),
        '.bashrc (本机冲突 $_stamp)',
      );
      expect(
        conflictCopyPathFor('dir/.env', _now),
        'dir/.env (本机冲突 $_stamp)',
      );
      // Nothing is ever dropped from the original name: the stem survives, and
      // for names without an extension the copy still starts with them.
      for (final path in ['README', '.bashrc', 'dir/.env']) {
        expect(conflictCopyPathFor(path, _now), startsWith(path));
      }
      final notes = conflictCopyPathFor('notes.txt', _now);
      expect(notes, isNot('notes.txt'));
      expect(notes, startsWith('notes ('));
      expect(notes, endsWith('.txt'));
    });

    test('zero pads the stamp and renders local time', () {
      expect(
        conflictCopyPathFor('a.txt', DateTime(2026, 1, 2, 3, 4, 5)),
        'a (本机冲突 2026-01-02 03-04-05).txt',
      );

      final utc = DateTime.utc(2026, 9, 27, 6, 3, 5);
      expect(
        conflictCopyPathFor('a.txt', utc),
        conflictCopyPathFor('a.txt', utc.toLocal()),
      );
    });
  });

  // -------------------------------------------------------------------------
  // A listing that was never read must never become a deletion
  // -------------------------------------------------------------------------

  group('MirrorPlanner listing scope', () {
    test('a deletion whose parent directory was never listed is held', () {
      final local = {'photos/a.jpg': _file('photos/a.jpg', size: 5, modifiedAt: _t0)};
      final baseline = {
        'photos/a.jpg': _baseFile('photos/a.jpg', size: 5, modifiedAt: _t0),
      };

      // The remote side reported nothing for `photos`, but it never listed that
      // directory either: "missing" here only means "unread".
      final plan = _plan(
        local: local,
        baseline: baseline,
        listingScope: MirrorListingScope(
          localDirectories: mirrorScannedDirectories(local.values),
          remoteDirectories: const {'', 'notes'},
        ),
      );

      expect(plan.actions.where((action) => action.isDeletion), isEmpty);
      expect(plan.heldDeletions, isNull);
      expect(plan.heldPaths, ['photos/a.jpg']);
      expect(plan.stats.heldCount, 1);
      expect(
        plan.removedBaselinePaths,
        isEmpty,
        reason: 'a held path keeps its baseline row',
      );
      expect(plan.inSyncPaths, isEmpty);
    });

    test('a directory nobody read is offered for confirmation, not deleted', () {
      final local = {'photos': _dir('photos')};
      final baseline = {'photos': _baseDir('photos')};

      // The remote never listed `photos` itself, so a recursive local delete
      // would take a subtree nobody looked at with it.
      final unconfirmed = _plan(
        local: local,
        baseline: baseline,
        listingScope: MirrorListingScope(
          localDirectories: mirrorScannedDirectories(local.values),
          remoteDirectories: const {''},
        ),
      );

      expect(unconfirmed.actions.where((action) => action.isDeletion), isEmpty);
      expect(unconfirmed.heldDeletions!.paths, {'photos'});
      expect(unconfirmed.heldPaths, isEmpty);
      expect(unconfirmed.removedBaselinePaths, isEmpty);

      // Only the exact confirmed path runs it.
      final confirmed = _plan(
        local: local,
        baseline: baseline,
        listingScope: MirrorListingScope(
          localDirectories: mirrorScannedDirectories(local.values),
          remoteDirectories: const {''},
        ),
        confirmedDeletions: const {'photos'},
      );

      expect(_pathsOf(confirmed, MirrorActionType.deleteLocalEntry), [
        'photos',
      ]);
      expect(confirmed.heldDeletions, isNull);
      expect(confirmed.removedBaselinePaths, ['photos']);
    });

    test('a fully listed location keeps deleting what really disappeared', () {
      final local = {'photos/a.jpg': _file('photos/a.jpg', size: 5, modifiedAt: _t0)};
      final baseline = {
        'photos/a.jpg': _baseFile('photos/a.jpg', size: 5, modifiedAt: _t0),
      };

      final plan = _plan(
        local: local,
        baseline: baseline,
        listingScope: MirrorListingScope(
          localDirectories: mirrorScannedDirectories(local.values),
          remoteDirectories: const {'', 'photos', 'notes'},
        ),
      );

      // `photos` was read and is empty remotely: the local file really is gone
      // on the other side, so the deletion runs (one row is below the fraction
      // minimum).
      expect(_pathsOf(plan, MirrorActionType.deleteLocalEntry), [
        'photos/a.jpg',
      ]);
      expect(plan.heldPaths, isEmpty);
      expect(plan.heldDeletions, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // A file and a directory at the same path can never be "in sync"
  // -------------------------------------------------------------------------

  group('MirrorPlanner kind clash', () {
    test('a local directory against a remote file is a visible conflict', () {
      final local = {
        'clash': _dir('clash'),
        'clash/child.txt': _file('clash/child.txt', size: 5, modifiedAt: _t0),
      };
      final remote = {'clash': _file('clash', size: 9, modifiedAt: _t1)};

      for (final direction in [
        SyncDirection.bidirectional,
        SyncDirection.uploadOnly,
        SyncDirection.downloadOnly,
      ]) {
        final plan = _plan(local: local, remote: remote, direction: direction);

        expect(
          plan.inSyncPaths,
          isEmpty,
          reason: 'a kind clash is never declared in sync ($direction)',
        );
        expect(
          plan.actions,
          isEmpty,
          reason: 'nothing is transferred across the clash ($direction)',
        );
        expect(plan.heldPaths, ['clash', 'clash/child.txt']);
        expect(plan.stats.heldCount, 2);
        expect(plan.conflicts, hasLength(1));
        expect(plan.conflicts.single.relativePath, 'clash');
        expect(plan.conflicts.single.resolution, MirrorConflictResolution.keepBoth);
        expect(plan.removedBaselinePaths, isEmpty);
      }
    });

    test('a remote directory against a local file holds the remote children', () {
      final local = {'clash': _file('clash', size: 4, modifiedAt: _t0)};
      final remote = {
        'clash': _dir('clash'),
        'clash/child.txt': _file('clash/child.txt', size: 5, modifiedAt: _t1),
      };

      final plan = _plan(local: local, remote: remote);

      // Downloading the child would have to write `clash/child.txt` while the
      // local `clash` is a file, so the whole subtree stays untouched.
      expect(plan.actions, isEmpty);
      expect(plan.stats.downloadCount, 0);
      expect(plan.inSyncPaths, isEmpty);
      expect(plan.conflicts.single.relativePath, 'clash');
      expect(plan.heldPaths, ['clash', 'clash/child.txt']);
      expect(plan.stats.heldCount, 2);
    });

    test('a kind clash inside a synced tree holds only its own subtree', () {
      final local = {
        'clash': _dir('clash'),
        'clash/child.txt': _file('clash/child.txt', size: 5, modifiedAt: _t0),
        'other.txt': _file('other.txt', size: 3, modifiedAt: _t0),
      };
      final remote = {
        'clash': _file('clash', size: 9, modifiedAt: _t1),
        'other.txt': _file('other.txt', size: 3, modifiedAt: _t0),
      };

      final plan = _plan(local: local, remote: remote);

      expect(plan.actions, isEmpty);
      expect(plan.inSyncPaths, ['other.txt']);
      expect(plan.stats.unchangedCount, 1);
      expect(plan.heldPaths, ['clash', 'clash/child.txt']);
    });
  });
}
