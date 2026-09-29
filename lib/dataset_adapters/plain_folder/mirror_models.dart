/// Pure models for the plain (unencrypted) folder mirror engine.
///
/// One sync location binds a user-authorized local folder to a remote folder.
/// The remote side stores the user's real files under their real names, so
/// nothing here involves vaults, keys, batches or signatures.
library;

import 'package:velock_sync/sync_core/model/sync_models.dart';

/// How the two sides are allowed to change each other.
///
/// Reuses the shared [SyncDirection] so the persisted value stays stable.
typedef MirrorDirection = SyncDirection;

/// What happens when both sides changed the same file.
enum MirrorConflictPolicy {
  /// Keep the local version as a conflict copy and take the remote version
  /// (Dropbox / Syncthing behaviour; the default).
  keepBoth,

  /// The local version overwrites the remote file.
  preferLocal,

  /// The remote version overwrites the local file.
  preferRemote,
}

/// How a brand-new location treats files that already exist on both sides.
enum MirrorInitialSyncPolicy { merge, localWins, remoteWins }

/// What a path is on one side of a sync location.
enum MirrorEntryKind { file, directory }

/// One entry as observed on the local or the remote side.
class MirrorEntry {
  const MirrorEntry({
    required this.relativePath,
    required this.kind,
    this.size = 0,
    this.modifiedAt,
    this.etag,
  });

  final String relativePath;
  final MirrorEntryKind kind;

  /// File size in bytes; always 0 for directories.
  final int size;

  /// Last modification time reported by that side (null when unavailable).
  final DateTime? modifiedAt;

  /// Remote entity tag when the provider exposes one.
  final String? etag;

  bool get isDirectory => kind == MirrorEntryKind.directory;
  bool get isFile => kind == MirrorEntryKind.file;

  bool isDescendantOf(String directoryPath) =>
      relativePath.startsWith('$directoryPath/');
}

/// Last known synced state of one path, used as the three-way merge base.
class MirrorBaselineEntry {
  const MirrorBaselineEntry({
    required this.relativePath,
    required this.kind,
    this.localSize = 0,
    this.localModifiedAt,
    this.remoteSize = 0,
    this.remoteModifiedAt,
    this.remoteEtag,
    required this.syncedAt,
  });

  final String relativePath;
  final MirrorEntryKind kind;
  final int localSize;
  final DateTime? localModifiedAt;
  final int remoteSize;
  final DateTime? remoteModifiedAt;
  final String? remoteEtag;
  final DateTime syncedAt;

  /// True when [entry] still looks like the local side recorded at sync time.
  bool matchesLocal(MirrorEntry entry) {
    if (entry.kind != kind) return false;
    if (kind == MirrorEntryKind.directory) return true;
    if (entry.size != localSize) return false;
    return mirrorTimesMatch(entry.modifiedAt, localModifiedAt);
  }

  /// True when [entry] still looks like the remote side recorded at sync time.
  bool matchesRemote(MirrorEntry entry) {
    if (entry.kind != kind) return false;
    if (kind == MirrorEntryKind.directory) return true;
    if (remoteEtag != null && entry.etag != null && remoteEtag == entry.etag) {
      return true;
    }
    if (entry.size != remoteSize) return false;
    return mirrorTimesMatch(entry.modifiedAt, remoteModifiedAt);
  }

  /// Baseline row for a path that just finished syncing in [outcome] state.
  static MirrorBaselineEntry forOutcome({
    required String relativePath,
    required MirrorEntryKind kind,
    required MirrorPathOutcome outcome,
    MirrorEntry? local,
    MirrorEntry? remote,
    required DateTime now,
  }) {
    switch (outcome) {
      case MirrorPathOutcome.uploaded:
        // The remote file now mirrors the local one.
        return MirrorBaselineEntry(
          relativePath: relativePath,
          kind: kind,
          localSize: local?.size ?? 0,
          localModifiedAt: local?.modifiedAt,
          remoteSize: local?.size ?? 0,
          remoteModifiedAt: local?.modifiedAt,
          syncedAt: now,
        );
      case MirrorPathOutcome.downloaded:
        // The local file now mirrors the remote one.
        return MirrorBaselineEntry(
          relativePath: relativePath,
          kind: kind,
          localSize: remote?.size ?? 0,
          localModifiedAt: remote?.modifiedAt,
          remoteSize: remote?.size ?? 0,
          remoteModifiedAt: remote?.modifiedAt,
          remoteEtag: remote?.etag,
          syncedAt: now,
        );
      case MirrorPathOutcome.unchanged:
        return MirrorBaselineEntry(
          relativePath: relativePath,
          kind: kind,
          localSize: local?.size ?? 0,
          localModifiedAt: local?.modifiedAt,
          remoteSize: remote?.size ?? 0,
          remoteModifiedAt: remote?.modifiedAt,
          remoteEtag: remote?.etag,
          syncedAt: now,
        );
      case MirrorPathOutcome.remoteDirectoryCreated:
        return MirrorBaselineEntry(
          relativePath: relativePath,
          kind: MirrorEntryKind.directory,
          syncedAt: now,
        );
      case MirrorPathOutcome.localDirectoryCreated:
        return MirrorBaselineEntry(
          relativePath: relativePath,
          kind: MirrorEntryKind.directory,
          syncedAt: now,
        );
    }
  }
}

/// File systems and WebDAV servers disagree by a second or two about the same
/// file's timestamp; anything inside this window is treated as unchanged.
const mirrorTimeTolerance = Duration(seconds: 2);

bool mirrorTimesMatch(DateTime? a, DateTime? b) {
  if (a == null || b == null) return a == b;
  return a.toUtc().difference(b.toUtc()).abs() <= mirrorTimeTolerance;
}

/// Parent directory of a mirror path; the mirrored root is the empty string.
String mirrorParentDirectory(String relativePath) {
  final slash = relativePath.lastIndexOf('/');
  return slash < 0 ? '' : relativePath.substring(0, slash);
}

/// Directories a complete recursive scan of [entries] proves were read: the
/// mirrored root, every directory the scan returned, and every ancestor of
/// every entry.
///
/// The local side is scanned recursively, so this is what a
/// [MirrorListingScope] for a local scan must contain.
Set<String> mirrorScannedDirectories(Iterable<MirrorEntry> entries) {
  final directories = <String>{''};
  for (final entry in entries) {
    if (entry.isDirectory) directories.add(entry.relativePath);
    var parent = mirrorParentDirectory(entry.relativePath);
    while (directories.add(parent)) {
      parent = mirrorParentDirectory(parent);
    }
  }
  return directories;
}

/// Which directories one run actually enumerated on each side.
///
/// A directory that was never listed - because the provider silently returned
/// nothing for it (unmounted NAS, renamed folder, mangled hrefs) or because the
/// remote depth cap skipped the subtree - must never be read as "the other side
/// deleted everything inside it". [MirrorPlanner.plan] therefore refuses to
/// delete any path whose parent directory is outside this scope.
class MirrorListingScope {
  const MirrorListingScope({this.localDirectories, this.remoteDirectories});

  /// A caller that enumerated both sides completely (see
  /// [mirrorScannedDirectories]).
  const MirrorListingScope.complete()
    : localDirectories = null,
      remoteDirectories = null;

  /// Directories the local scan proved it read; `null` means "all of them".
  final Set<String>? localDirectories;

  /// Directories the remote listing proved it read; `null` means "all of them".
  final Set<String>? remoteDirectories;

  bool listsLocal(String directoryPath) =>
      localDirectories?.contains(directoryPath) ?? true;

  bool listsRemote(String directoryPath) =>
      remoteDirectories?.contains(directoryPath) ?? true;
}

/// Chronological order of one planned filesystem operation.
enum MirrorActionType {
  createRemoteDirectory,
  createLocalDirectory,
  deleteRemoteEntry,
  deleteLocalEntry,
  uploadFile,
  downloadFile,
}

/// The state both sides are expected to be in once [MirrorAction] finished.
enum MirrorPathOutcome {
  uploaded,
  downloaded,
  unchanged,
  remoteDirectoryCreated,
  localDirectoryCreated,
}

/// One operation the executor must perform against one side.
class MirrorAction {
  const MirrorAction({
    required this.type,
    required this.relativePath,
    required this.outcome,
    this.local,
    this.remote,
    this.conflictCopyPath,
  });

  final MirrorActionType type;
  final String relativePath;
  final MirrorPathOutcome outcome;
  final MirrorEntry? local;
  final MirrorEntry? remote;

  /// Keep-both conflict only: the local file is renamed here before the remote
  /// version is written to [relativePath], so neither version is lost.
  final String? conflictCopyPath;

  bool get isDeletion =>
      type == MirrorActionType.deleteLocalEntry ||
      type == MirrorActionType.deleteRemoteEntry;

  bool get isDirectoryOperation =>
      type == MirrorActionType.createLocalDirectory ||
      type == MirrorActionType.createRemoteDirectory ||
      ((local ?? remote)?.isDirectory ?? false);
}

enum MirrorConflictKind {
  /// Both sides changed the same file since the last successful sync.
  bothModified,

  /// The file appeared on both sides before this location ever synced it.
  bothCreated,

  /// One side deleted the file while the other one modified it.
  deleteVersusModify,
}

enum MirrorConflictResolution {
  /// Local version preserved as a copy, remote version kept at the original
  /// path.
  keepBoth,

  /// The local version is the surviving one.
  preferLocal,

  /// The remote version is the surviving one.
  preferRemote,
}

/// A conflict the planner decided to keep visible instead of silently losing.
class MirrorPlannedConflict {
  const MirrorPlannedConflict({
    required this.relativePath,
    required this.kind,
    required this.resolution,
    this.conflictCopyPath,
  });

  final String relativePath;
  final MirrorConflictKind kind;
  final MirrorConflictResolution resolution;
  final String? conflictCopyPath;
}

class MirrorDeletionProtection {
  const MirrorDeletionProtection({
    this.maxDeletedEntries = 1000,
    this.maxDeletedFraction = 0.2,
    this.fractionCheckMinimumEntries = 5,
  });

  final int maxDeletedEntries;
  final double maxDeletedFraction;

  /// Below this many baseline entries only [maxDeletedEntries] applies, so
  /// deleting one file out of three does not require a confirmation.
  final int fractionCheckMinimumEntries;
}

/// Deletions withheld from one run because they exceeded the safety threshold.
class MirrorHeldDeletions {
  const MirrorHeldDeletions({
    required this.actions,
    required this.knownEntryCount,
    required this.limit,
  });

  final List<MirrorAction> actions;
  final int knownEntryCount;
  final int limit;

  bool get isEmpty => actions.isEmpty;

  /// The exact paths a user confirmation has to carry to execute them: a
  /// confirmation only ever approves the deletions it was shown.
  Set<String> get paths => {for (final action in actions) action.relativePath};
}

class MirrorPlanStats {
  const MirrorPlanStats({
    required this.uploadCount,
    required this.downloadCount,
    required this.deleteRemoteCount,
    required this.deleteLocalCount,
    required this.createDirectoryCount,
    required this.unchangedCount,
    required this.skippedLocalOnlyCount,
    required this.skippedRemoteOnlyCount,
    this.deferredCount = 0,
    this.heldCount = 0,
  });

  final int uploadCount;
  final int downloadCount;
  final int deleteRemoteCount;
  final int deleteLocalCount;
  final int createDirectoryCount;
  final int unchangedCount;
  final int skippedLocalOnlyCount;
  final int skippedRemoteOnlyCount;

  /// Paths left for a later run because their content identity was not
  /// verified yet (bounded per-run verification budget).
  final int deferredCount;

  /// Paths the planner deliberately left alone for safety instead of acting on
  /// them: a file/directory collision and everything below it, plus deletions
  /// whose reporting side was never listed this run. They are not user
  /// confirmable, unlike [MirrorHeldDeletions].
  final int heldCount;
}

/// Complete, deterministic outcome of comparing both sides against the baseline.
class MirrorPlan {
  const MirrorPlan({
    required this.actions,
    required this.conflicts,
    required this.removedBaselinePaths,
    required this.inSyncPaths,
    required this.stats,
    this.heldPaths = const [],
    this.heldDeletions,
  });

  final List<MirrorAction> actions;
  final List<MirrorPlannedConflict> conflicts;

  /// Paths this run *proved* to be in sync on both sides (same size and time,
  /// or verified byte-identical). They still need a baseline row: without one
  /// the next run has no baseline, re-reads the remote file to compare content
  /// again and never converges. Deferred and direction-skipped paths are
  /// deliberately absent: nothing proved them equal.
  final List<String> inSyncPaths;

  /// Paths whose baseline row must be dropped (both sides deleted, or the
  /// surviving side is gone by definition of the action).
  final List<String> removedBaselinePaths;

  /// Paths left untouched on purpose: a file/directory collision plus its whole
  /// subtree, and deletions refused because the reporting side was never
  /// listed. Their baseline rows survive, so nothing is silently forgotten.
  final List<String> heldPaths;

  final MirrorPlanStats stats;
  final MirrorHeldDeletions? heldDeletions;
}

/// Persisted conflict row, used by the location detail and activity surfaces.
class MirrorConflictRecord {
  const MirrorConflictRecord({
    required this.conflictId,
    required this.relativePath,
    required this.kind,
    required this.resolution,
    required this.detectedAt,
  });

  final String conflictId;
  final String relativePath;
  final MirrorConflictKind kind;
  final MirrorConflictResolution resolution;
  final DateTime detectedAt;

  static MirrorConflictKind? parseKind(Object? value) =>
      MirrorConflictKind.values.where((kind) => kind.name == value).firstOrNull;

  static MirrorConflictResolution? parseResolution(Object? value) =>
      MirrorConflictResolution.values
          .where((resolution) => resolution.name == value)
          .firstOrNull;
}

/// Counters for one finished (or failed) plain mirror run.
class MirrorRunStats {
  const MirrorRunStats({
    required this.runId,
    required this.profileId,
    required this.startedAt,
    this.finishedAt,
    this.uploadedFileCount = 0,
    this.downloadedFileCount = 0,
    this.deletedLocalCount = 0,
    this.deletedRemoteCount = 0,
    this.conflictCount = 0,
    this.heldDeletionCount = 0,
    this.skippedCount = 0,
    this.bytesTransferred = 0,
    this.failureCode,
  });

  final String runId;
  final String profileId;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final int uploadedFileCount;
  final int downloadedFileCount;
  final int deletedLocalCount;
  final int deletedRemoteCount;
  final int conflictCount;
  final int heldDeletionCount;
  final int skippedCount;
  final int bytesTransferred;
  final String? failureCode;

  bool get didFail => failureCode != null;

  int get changedCount =>
      uploadedFileCount +
      downloadedFileCount +
      deletedLocalCount +
      deletedRemoteCount;
}

/// Compares local, remote and baseline state into one executable plan.
///
/// This class performs no I/O: callers supply both sides and the persisted
/// baseline, and can unit-test every direction/conflict combination.
class MirrorPlanner {
  const MirrorPlanner({
    this.deletionProtection = const MirrorDeletionProtection(),
  });

  final MirrorDeletionProtection deletionProtection;

  MirrorPlan plan({
    required Map<String, MirrorEntry> local,
    required Map<String, MirrorEntry> remote,
    required Map<String, MirrorBaselineEntry> baseline,
    required MirrorDirection direction,
    required MirrorConflictPolicy conflictPolicy,
    required DateTime now,
    MirrorInitialSyncPolicy initialSyncPolicy = MirrorInitialSyncPolicy.merge,
    MirrorListingScope listingScope = const MirrorListingScope.complete(),
    Set<String>? confirmedDeletions,
    Set<String> verifiedIdenticalPaths = const {},
    Set<String> deferredPaths = const {},
  }) {
    final paths = <String>{
      ...local.keys,
      ...remote.keys,
      ...baseline.keys,
    }.toList()..sort();

    // A path that is a file on one side and a directory on the other can never
    // converge: the children of the directory collide with the other kind, and
    // servers answer that transfer with a folder-level conflict error. It is
    // reported as a visible conflict and its whole subtree is left alone rather
    // than declared "unchanged" and left to fail later.
    final kindClashes = <String>{
      for (final path in paths)
        if (local[path] != null &&
            remote[path] != null &&
            local[path]!.kind != remote[path]!.kind)
          path,
    };

    final actions = <MirrorAction>[];
    final conflicts = <MirrorPlannedConflict>[];
    final removedBaselinePaths = <String>[];
    final inSyncPaths = <String>[];
    final heldPaths = <String>[];
    var unchanged = 0;
    var skippedLocalOnly = 0;
    var skippedRemoteOnly = 0;
    var deferred = 0;

    for (final path in paths) {
      if (deferredPaths.contains(path)) {
        deferred++;
        continue;
      }
      final clashRoot = _kindClashRoot(path, kindClashes);
      if (clashRoot != null) {
        if (clashRoot == path) {
          conflicts.add(
            MirrorPlannedConflict(
              relativePath: path,
              kind: MirrorConflictKind.bothModified,
              resolution: MirrorConflictResolution.keepBoth,
            ),
          );
        }
        heldPaths.add(path);
        continue;
      }
      final localEntry = local[path];
      final remoteEntry = remote[path];
      final base = baseline[path];
      final isDirectory =
          localEntry?.isDirectory == true ||
          remoteEntry?.isDirectory == true ||
          base?.kind == MirrorEntryKind.directory;

      final result = isDirectory
          ? _planDirectory(
              path: path,
              local: localEntry,
              remote: remoteEntry,
              baseline: base,
              direction: direction,
              allLocal: local,
              allRemote: remote,
            )
          : _planFile(
              path: path,
              local: localEntry,
              remote: remoteEntry,
              baseline: base,
              direction: direction,
              conflictPolicy: conflictPolicy,
              initialSyncPolicy: initialSyncPolicy,
              now: now,
              identical: verifiedIdenticalPaths.contains(path),
            );

      actions.addAll(result.actions);
      conflicts.addAll(result.conflicts);
      removedBaselinePaths.addAll(result.removedBaselinePaths);
      if (result.unchanged && localEntry != null && remoteEntry != null) {
        inSyncPaths.add(path);
      }
      unchanged += result.unchanged ? 1 : 0;
      skippedLocalOnly += result.skippedLocalOnly ? 1 : 0;
      skippedRemoteOnly += result.skippedRemoteOnly ? 1 : 0;
    }

    final guard = _guardDeletions(actions, listingScope);
    final held = _heldDeletions(
      actions: guard.actions,
      baseline: baseline,
      confirmedDeletions: confirmedDeletions,
      unreadDirectories: guard.unreadDirectories,
    );
    heldPaths.addAll(guard.unlistedPaths);
    // A withheld deletion keeps its baseline row: dropping it would make the
    // next run treat the file as brand new and download it again, silently
    // undoing the user's deletion instead of asking about it.
    final refusedPaths = <String>{
      ...guard.unlistedPaths,
      ...?held?.actions.map((action) => action.relativePath),
    };
    final kept = refusedPaths.isEmpty
        ? actions
        : actions
              .where((action) => !refusedPaths.contains(action.relativePath))
              .toList(growable: false);
    final effectiveRemovedBaselinePaths = refusedPaths.isEmpty
        ? removedBaselinePaths
        : removedBaselinePaths
              .where((path) => !refusedPaths.contains(path))
              .toList(growable: false);

    return MirrorPlan(
      actions: List.unmodifiable(kept),
      conflicts: List.unmodifiable(conflicts),
      removedBaselinePaths: List.unmodifiable(effectiveRemovedBaselinePaths),
      inSyncPaths: List.unmodifiable(inSyncPaths),
      heldPaths: List.unmodifiable(heldPaths),
      stats: MirrorPlanStats(
        uploadCount: _count(kept, MirrorActionType.uploadFile),
        downloadCount: _count(kept, MirrorActionType.downloadFile),
        deleteRemoteCount: _count(kept, MirrorActionType.deleteRemoteEntry),
        deleteLocalCount: _count(kept, MirrorActionType.deleteLocalEntry),
        createDirectoryCount:
            _count(kept, MirrorActionType.createRemoteDirectory) +
            _count(kept, MirrorActionType.createLocalDirectory),
        unchangedCount: unchanged,
        skippedLocalOnlyCount: skippedLocalOnly,
        skippedRemoteOnlyCount: skippedRemoteOnly,
        deferredCount: deferred,
        heldCount: heldPaths.length,
      ),
      heldDeletions: held,
    );
  }

  static int _count(List<MirrorAction> actions, MirrorActionType type) =>
      actions.where((action) => action.type == type).length;

  /// The clashing path itself, or the collision this [path] sits below.
  static String? _kindClashRoot(String path, Set<String> kindClashes) {
    if (kindClashes.contains(path)) return path;
    var parent = mirrorParentDirectory(path);
    while (parent.isNotEmpty) {
      if (kindClashes.contains(parent)) return parent;
      parent = mirrorParentDirectory(parent);
    }
    return null;
  }

  /// Keeps only the deletions that may actually run.
  ///
  /// A deletion is only trusted when the side that reports the entry missing
  /// was really listed this run: a listing that silently came back empty
  /// (unmounted NAS, renamed folder, mangled hrefs) or a subtree the remote
  /// depth cap skipped must never be read as "the other side deleted this".
  ///
  /// Two kinds of refusal come out of this:
  /// * [unlistedPaths]: the parent directory was never read, so nothing is known
  ///   about that subtree. These are skipped, not offered for confirmation.
  /// * [unreadDirectories]: a directory the reporting side never read the
  ///   contents of. A recursive delete would take a whole subtree with it, so it
  ///   is offered for confirmation by exact path instead of running silently.
  static _DeletionGuard _guardDeletions(
    List<MirrorAction> actions,
    MirrorListingScope listingScope,
  ) {
    final executable = <MirrorAction>[];
    final unlisted = <String>[];
    final unreadDirectories = <MirrorAction>[];
    for (final action in actions) {
      if (!action.isDeletion) {
        executable.add(action);
        continue;
      }
      final path = action.relativePath;
      final parent = mirrorParentDirectory(path);
      final reportingSideListedParent =
          action.type == MirrorActionType.deleteRemoteEntry
          ? listingScope.listsLocal(parent)
          : listingScope.listsRemote(parent);
      if (!reportingSideListedParent) {
        unlisted.add(path);
        continue;
      }
      final deleted = action.local ?? action.remote;
      if (deleted != null && deleted.isDirectory) {
        final reportingSideReadDirectory =
            action.type == MirrorActionType.deleteRemoteEntry
            ? listingScope.listsLocal(path)
            : listingScope.listsRemote(path);
        if (!reportingSideReadDirectory) {
          unreadDirectories.add(action);
          continue;
        }
      }
      executable.add(action);
    }
    return _DeletionGuard(
      actions: executable,
      unlistedPaths: unlisted,
      unreadDirectories: unreadDirectories,
    );
  }

  /// Directories are only deleted when nothing survives inside them on the
  /// other side, so a parent delete can never take unrelated children with it.
  _PathPlan _planDirectory({
    required String path,
    required MirrorEntry? local,
    required MirrorEntry? remote,
    required MirrorBaselineEntry? baseline,
    required MirrorDirection direction,
    required Map<String, MirrorEntry> allLocal,
    required Map<String, MirrorEntry> allRemote,
  }) {
    if (baseline == null) {
      if (local != null && remote != null) {
        return const _PathPlan(unchanged: true);
      }
      if (local != null) {
        if (direction == MirrorDirection.downloadOnly) {
          return const _PathPlan(skippedLocalOnly: true);
        }
        return _PathPlan(
          actions: [
            MirrorAction(
              type: MirrorActionType.createRemoteDirectory,
              relativePath: path,
              outcome: MirrorPathOutcome.remoteDirectoryCreated,
              local: local,
            ),
          ],
        );
      }
      if (remote != null) {
        if (direction == MirrorDirection.uploadOnly) {
          return const _PathPlan(skippedRemoteOnly: true);
        }
        return _PathPlan(
          actions: [
            MirrorAction(
              type: MirrorActionType.createLocalDirectory,
              relativePath: path,
              outcome: MirrorPathOutcome.localDirectoryCreated,
              remote: remote,
            ),
          ],
        );
      }
      return const _PathPlan();
    }

    if (local != null && remote != null) {
      return const _PathPlan(unchanged: true);
    }

    if (local != null && remote == null) {
      // The remote directory is gone.
      if (direction == MirrorDirection.uploadOnly) {
        return _PathPlan(
          actions: [
            MirrorAction(
              type: MirrorActionType.createRemoteDirectory,
              relativePath: path,
              outcome: MirrorPathOutcome.remoteDirectoryCreated,
              local: local,
            ),
          ],
        );
      }
      if (_hasSurvivingChildren(allRemote, path)) {
        return const _PathPlan(unchanged: true);
      }
      return _PathPlan(
        actions: [
          MirrorAction(
            type: MirrorActionType.deleteLocalEntry,
            relativePath: path,
            outcome: MirrorPathOutcome.unchanged,
            local: local,
          ),
        ],
        removedBaselinePaths: [path],
      );
    }

    if (local == null && remote != null) {
      // The local directory is gone.
      if (direction == MirrorDirection.downloadOnly) {
        return _PathPlan(
          actions: [
            MirrorAction(
              type: MirrorActionType.createLocalDirectory,
              relativePath: path,
              outcome: MirrorPathOutcome.localDirectoryCreated,
              remote: remote,
            ),
          ],
        );
      }
      if (_hasSurvivingChildren(allLocal, path)) {
        return const _PathPlan(unchanged: true);
      }
      return _PathPlan(
        actions: [
          MirrorAction(
            type: MirrorActionType.deleteRemoteEntry,
            relativePath: path,
            outcome: MirrorPathOutcome.unchanged,
            remote: remote,
          ),
        ],
        removedBaselinePaths: [path],
      );
    }

    // Both sides deleted the directory.
    return _PathPlan(removedBaselinePaths: [path]);
  }

  bool _hasSurvivingChildren(Map<String, MirrorEntry> side, String path) =>
      side.keys.any((key) => key.startsWith('$path/'));

  _PathPlan _planFile({
    required String path,
    required MirrorEntry? local,
    required MirrorEntry? remote,
    required MirrorBaselineEntry? baseline,
    required MirrorDirection direction,
    required MirrorConflictPolicy conflictPolicy,
    required MirrorInitialSyncPolicy initialSyncPolicy,
    required DateTime now,
    required bool identical,
  }) {
    if (baseline == null) {
      if (local != null && remote != null) {
        final sameContent =
            identical ||
            (local.size == remote.size &&
                mirrorTimesMatch(local.modifiedAt, remote.modifiedAt));
        if (sameContent) return const _PathPlan(unchanged: true);
        switch (direction) {
          case MirrorDirection.uploadOnly:
            return _upload(path, local, remote);
          case MirrorDirection.downloadOnly:
            return _download(path, local, remote);
          case MirrorDirection.bidirectional:
            switch (initialSyncPolicy) {
              case MirrorInitialSyncPolicy.localWins:
                return _upload(path, local, remote);
              case MirrorInitialSyncPolicy.remoteWins:
                return _download(path, local, remote);
              case MirrorInitialSyncPolicy.merge:
                return _conflict(
                  path: path,
                  kind: MirrorConflictKind.bothCreated,
                  policy: conflictPolicy,
                  local: local,
                  remote: remote,
                  now: now,
                );
            }
        }
      }
      if (local != null) {
        if (direction == MirrorDirection.downloadOnly) {
          return const _PathPlan(skippedLocalOnly: true);
        }
        return _upload(path, local, null);
      }
      if (remote != null) {
        if (direction == MirrorDirection.uploadOnly) {
          return const _PathPlan(skippedRemoteOnly: true);
        }
        return _download(path, null, remote);
      }
      return const _PathPlan();
    }

    if (local == null && remote == null) {
      return _PathPlan(removedBaselinePaths: [path]);
    }

    final localUnchanged = local != null && baseline.matchesLocal(local);
    final remoteUnchanged = remote != null && baseline.matchesRemote(remote);

    if (local != null && remote != null) {
      if (localUnchanged && remoteUnchanged) {
        return const _PathPlan(unchanged: true);
      }
      if (!localUnchanged && remoteUnchanged) {
        return switch (direction) {
          // The local side is the only source of truth for an upload-only
          // location; a download-only location reverts the local change.
          MirrorDirection.bidirectional ||
          MirrorDirection.uploadOnly => _upload(path, local, remote),
          MirrorDirection.downloadOnly => _download(path, local, remote),
        };
      }
      if (localUnchanged && !remoteUnchanged) {
        return switch (direction) {
          MirrorDirection.bidirectional ||
          MirrorDirection.downloadOnly => _download(path, local, remote),
          MirrorDirection.uploadOnly => _upload(path, local, remote),
        };
      }
      return switch (direction) {
        MirrorDirection.uploadOnly => _upload(path, local, remote),
        MirrorDirection.downloadOnly => _download(path, local, remote),
        MirrorDirection.bidirectional => _conflict(
          path: path,
          kind: MirrorConflictKind.bothModified,
          policy: conflictPolicy,
          local: local,
          remote: remote,
          now: now,
        ),
      };
    }

    if (local != null && remote == null) {
      // Deleted remotely; the local file may have changed since the baseline.
      return switch (direction) {
        MirrorDirection.uploadOnly => _upload(path, local, null),
        MirrorDirection.downloadOnly => _deleteLocal(path, local),
        MirrorDirection.bidirectional =>
          localUnchanged
              ? _deleteLocal(path, local)
              : _restoreRemote(
                  path: path,
                  local: local,
                  now: now,
                  baseline: baseline,
                ),
      };
    }

    // Deleted locally; the remote file may have changed since the baseline.
    final remoteEntry = remote;
    if (remoteEntry == null) return const _PathPlan();
    return switch (direction) {
      MirrorDirection.downloadOnly => _download(path, null, remoteEntry),
      MirrorDirection.uploadOnly => _deleteRemote(path, remoteEntry),
      MirrorDirection.bidirectional =>
        remoteUnchanged
            ? _deleteRemote(path, remoteEntry)
            : _restoreLocal(
                path: path,
                remote: remoteEntry,
                now: now,
                baseline: baseline,
              ),
    };
  }

  _PathPlan _upload(String path, MirrorEntry local, MirrorEntry? remote) =>
      _PathPlan(
        actions: [
          MirrorAction(
            type: MirrorActionType.uploadFile,
            relativePath: path,
            outcome: MirrorPathOutcome.uploaded,
            local: local,
            remote: remote,
          ),
        ],
      );

  _PathPlan _download(String path, MirrorEntry? local, MirrorEntry remote) =>
      _PathPlan(
        actions: [
          MirrorAction(
            type: MirrorActionType.downloadFile,
            relativePath: path,
            outcome: MirrorPathOutcome.downloaded,
            local: local,
            remote: remote,
          ),
        ],
      );

  _PathPlan _deleteLocal(String path, MirrorEntry local) => _PathPlan(
    actions: [
      MirrorAction(
        type: MirrorActionType.deleteLocalEntry,
        relativePath: path,
        outcome: MirrorPathOutcome.unchanged,
        local: local,
      ),
    ],
    removedBaselinePaths: [path],
  );

  _PathPlan _deleteRemote(String path, MirrorEntry remote) => _PathPlan(
    actions: [
      MirrorAction(
        type: MirrorActionType.deleteRemoteEntry,
        relativePath: path,
        outcome: MirrorPathOutcome.unchanged,
        remote: remote,
      ),
    ],
    removedBaselinePaths: [path],
  );

  /// The remote copy is gone but the local file changed: the modification wins
  /// so nothing is lost, and the event stays visible as a conflict.
  _PathPlan _restoreRemote({
    required String path,
    required MirrorEntry local,
    required DateTime now,
    required MirrorBaselineEntry baseline,
  }) => _PathPlan(
    actions: [
      MirrorAction(
        type: MirrorActionType.uploadFile,
        relativePath: path,
        outcome: MirrorPathOutcome.uploaded,
        local: local,
      ),
    ],
    conflicts: [
      MirrorPlannedConflict(
        relativePath: path,
        kind: MirrorConflictKind.deleteVersusModify,
        resolution: MirrorConflictResolution.preferLocal,
      ),
    ],
  );

  /// The local copy is gone but the remote file changed: restore it locally and
  /// keep the event visible as a conflict.
  _PathPlan _restoreLocal({
    required String path,
    required MirrorEntry remote,
    required DateTime now,
    required MirrorBaselineEntry baseline,
  }) => _PathPlan(
    actions: [
      MirrorAction(
        type: MirrorActionType.downloadFile,
        relativePath: path,
        outcome: MirrorPathOutcome.downloaded,
        remote: remote,
      ),
    ],
    conflicts: [
      MirrorPlannedConflict(
        relativePath: path,
        kind: MirrorConflictKind.deleteVersusModify,
        resolution: MirrorConflictResolution.preferRemote,
      ),
    ],
  );

  _PathPlan _conflict({
    required String path,
    required MirrorConflictKind kind,
    required MirrorConflictPolicy policy,
    required MirrorEntry local,
    required MirrorEntry remote,
    required DateTime now,
  }) {
    switch (policy) {
      case MirrorConflictPolicy.preferLocal:
        return _PathPlan(
          actions: [
            MirrorAction(
              type: MirrorActionType.uploadFile,
              relativePath: path,
              outcome: MirrorPathOutcome.uploaded,
              local: local,
              remote: remote,
            ),
          ],
          conflicts: [
            MirrorPlannedConflict(
              relativePath: path,
              kind: kind,
              resolution: MirrorConflictResolution.preferLocal,
            ),
          ],
        );
      case MirrorConflictPolicy.preferRemote:
        return _PathPlan(
          actions: [
            MirrorAction(
              type: MirrorActionType.downloadFile,
              relativePath: path,
              outcome: MirrorPathOutcome.downloaded,
              local: local,
              remote: remote,
            ),
          ],
          conflicts: [
            MirrorPlannedConflict(
              relativePath: path,
              kind: kind,
              resolution: MirrorConflictResolution.preferRemote,
            ),
          ],
        );
      case MirrorConflictPolicy.keepBoth:
        final copyPath = conflictCopyPathFor(path, now);
        return _PathPlan(
          actions: [
            MirrorAction(
              type: MirrorActionType.downloadFile,
              relativePath: path,
              outcome: MirrorPathOutcome.downloaded,
              local: local,
              remote: remote,
              conflictCopyPath: copyPath,
            ),
          ],
          conflicts: [
            MirrorPlannedConflict(
              relativePath: path,
              kind: kind,
              resolution: MirrorConflictResolution.keepBoth,
              conflictCopyPath: copyPath,
            ),
          ],
        );
    }
  }

  MirrorHeldDeletions? _heldDeletions({
    required List<MirrorAction> actions,
    required Map<String, MirrorBaselineEntry> baseline,
    required Set<String>? confirmedDeletions,
    required List<MirrorAction> unreadDirectories,
  }) {
    final deletions = actions.where((action) => action.isDeletion).toList();
    final combined = <MirrorAction>[...deletions, ...unreadDirectories];
    if (combined.isEmpty) return null;
    final fractionLimit =
        baseline.length >= deletionProtection.fractionCheckMinimumEntries
        ? (baseline.length * deletionProtection.maxDeletedFraction).ceil()
        : deletionProtection.maxDeletedEntries;
    final limit = fractionLimit < deletionProtection.maxDeletedEntries
        ? fractionLimit
        : deletionProtection.maxDeletedEntries;
    if (confirmedDeletions != null) {
      // The user confirmed exact paths in a previous summary. Only those run;
      // a plan that grew since then is held again instead of deleting paths the
      // user never saw.
      final unconfirmed = combined
          .where((action) => !confirmedDeletions.contains(action.relativePath))
          .toList(growable: false);
      if (unconfirmed.isEmpty) return null;
      return MirrorHeldDeletions(
        actions: List.unmodifiable(unconfirmed),
        knownEntryCount: baseline.length,
        limit: limit,
      );
    }
    if (deletions.length <= limit) {
      if (unreadDirectories.isEmpty) return null;
      return MirrorHeldDeletions(
        actions: List.unmodifiable(unreadDirectories),
        knownEntryCount: baseline.length,
        limit: limit,
      );
    }
    return MirrorHeldDeletions(
      actions: List.unmodifiable(combined),
      knownEntryCount: baseline.length,
      limit: limit,
    );
  }
}

/// Name used to preserve the local version of a conflicted file.
///
/// Mirrors the market convention (Dropbox "conflicted copy", Syncthing
/// `.sync-conflict-<date>-<device>`): the original name stays valid and the
/// preserved copy is obvious to a human browsing the folder.
String conflictCopyPathFor(String relativePath, DateTime now) {
  final slash = relativePath.lastIndexOf('/');
  final directory = slash < 0 ? '' : relativePath.substring(0, slash + 1);
  final name = slash < 0 ? relativePath : relativePath.substring(slash + 1);
  final dot = name.lastIndexOf('.');
  final stem = dot <= 0 ? name : name.substring(0, dot);
  final extension = dot <= 0 ? '' : name.substring(dot);
  final stamp = _conflictStamp(now.toLocal());
  return '$directory$stem (本机冲突 $stamp)$extension';
}

String _conflictStamp(DateTime value) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}-${two(value.minute)}-${two(value.second)}';
}

class _PathPlan {
  const _PathPlan({
    this.actions = const [],
    this.conflicts = const [],
    this.removedBaselinePaths = const [],
    this.unchanged = false,
    this.skippedLocalOnly = false,
    this.skippedRemoteOnly = false,
  });

  final List<MirrorAction> actions;
  final List<MirrorPlannedConflict> conflicts;
  final List<String> removedBaselinePaths;
  final bool unchanged;
  final bool skippedLocalOnly;
  final bool skippedRemoteOnly;
}

/// Result of [MirrorPlanner._guardDeletions]: what may run, and which deletions
/// were refused because the reporting side was never read.
class _DeletionGuard {
  const _DeletionGuard({
    required this.actions,
    required this.unlistedPaths,
    required this.unreadDirectories,
  });

  /// Deletions that may run.
  final List<MirrorAction> actions;

  /// Deletions skipped because their parent directory was never listed: nothing
  /// is known about that subtree, so they are not offered for confirmation.
  final List<String> unlistedPaths;

  /// Directory deletions whose contents the reporting side never read. They are
  /// offered for confirmation by exact path instead of running recursively.
  final List<MirrorAction> unreadDirectories;
}
