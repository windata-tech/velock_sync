import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/mirror_models.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_profile.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/android_document_tree_access.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/apple_security_scoped_folder_access.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_access_authorizer.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_storage.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_location_guard.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/remote_object_store_factory.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/providers/webdav/webdav_object_store.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// Stable failure of a plain folder mirror run.
class PlainFolderSyncException implements SyncFailureException {
  const PlainFolderSyncException(this.syncFailure);

  @override
  final SyncFailure syncFailure;
}

/// Remote folder sizes differ from what one run should pull down just to prove
/// that two files are the same. Anything above the budget stays deferred to a
/// later run instead of producing a conflict copy.
class MirrorVerificationBudget {
  const MirrorVerificationBudget({
    this.maxFileBytes = 64 * 1024 * 1024,
    this.maxTotalBytes = 512 * 1024 * 1024,
    this.maxFiles = 200,
  });

  final int maxFileBytes;
  final int maxTotalBytes;
  final int maxFiles;
}

enum MirrorRunPhase { scanning, comparing, uploading, downloading, deleting, finishing }

class MirrorProgress {
  const MirrorProgress({
    required this.phase,
    this.completed = 0,
    this.total = 0,
    this.currentPath,
  });

  final MirrorRunPhase phase;
  final int completed;
  final int total;
  final String? currentPath;
}

/// Result of one plain mirror run, including what a follow-up run must confirm.
class MirrorRunOutcome {
  const MirrorRunOutcome({
    required this.stats,
    required this.conflicts,
    required this.heldDeletions,
    this.failureCode,
  });

  final MirrorRunStats stats;
  final List<MirrorConflictRecord> conflicts;
  final MirrorHeldDeletions? heldDeletions;
  final String? failureCode;

  int get heldDeletionCount => heldDeletions?.actions.length ?? 0;

  /// The exact paths a user confirmation has to carry to delete what this run
  /// held back (see [PlainFolderSyncService.runConfirmedDeletions]).
  Set<String> get heldDeletionPaths => heldDeletions?.paths ?? const <String>{};
}

typedef PlainFolderRemoteFactory =
    RemoteObjectStore Function({
      required WebDavProtocolModel protocol,
      required String? password,
    });

/// Runs one plain folder location: scan both sides, compare against the local
/// baseline, then copy the differences in the configured direction.
///
/// The engine never deletes anything it has not previously synced, and holds
/// back deletions that exceed the safety threshold until the user confirms.
class PlainFolderSyncService {
  PlainFolderSyncService({
    required SyncStateDatabase database,
    required PlainFolderSyncProfileRepository profiles,
    required ConnectionRepository connections,
    AndroidDocumentTreeAccess? androidDocumentTrees,
    AppleSecurityScopedFolderAccess? appleFolders,
    PlainFolderRemoteFactory? remoteFactory,
    MirrorPlanner? planner,
    MirrorVerificationBudget verificationBudget =
        const MirrorVerificationBudget(),
    Uuid? uuid,
    DateTime Function()? now,
  }) : _database = database,
       _profiles = profiles,
       _connections = connections,
       _androidDocumentTrees =
           androidDocumentTrees ?? MethodChannelAndroidDocumentTreeAccess(),
       _appleFolders =
           appleFolders ?? const MethodChannelAppleSecurityScopedFolderAccess(),
       _remoteFactory = remoteFactory ?? _defaultRemoteFactory,
       _planner = planner ?? const MirrorPlanner(),
       _verificationBudget = verificationBudget,
       _uuid = uuid ?? const Uuid(),
       _now = now ?? DateTime.now;

  final SyncStateDatabase _database;
  final PlainFolderSyncProfileRepository _profiles;
  final ConnectionRepository _connections;
  final AndroidDocumentTreeAccess _androidDocumentTrees;
  final AppleSecurityScopedFolderAccess _appleFolders;
  final PlainFolderRemoteFactory _remoteFactory;
  final MirrorPlanner _planner;
  final MirrorVerificationBudget _verificationBudget;
  final Uuid _uuid;
  final DateTime Function() _now;

  /// Reads the remote folder without writing anything, so the setup wizard can
  /// tell the user what a first sync will do.
  Future<MirrorRemoteSummary> inspectRemote(
    String profileId, {
    RemoteOperationCancellation? cancellation,
  }) async {
    final profile = await _requireProfile(profileId);
    final remote = await _remoteFor(profile);
    final entries = (await _scanRemote(
      remote,
      cancellation: cancellation,
    )).entries;
    var fileCount = 0;
    var directoryCount = 0;
    var totalBytes = 0;
    for (final entry in entries.values) {
      if (entry.isDirectory) {
        directoryCount++;
      } else {
        fileCount++;
        totalBytes += entry.size;
      }
    }
    return MirrorRemoteSummary(
      fileCount: fileCount,
      directoryCount: directoryCount,
      totalBytes: totalBytes,
    );
  }

  /// Checks that the remote folder can be written to, using one bounded probe
  /// file that is removed again. Nothing else is created or deleted.
  Future<void> checkRemoteWritable(
    String profileId, {
    RemoteOperationCancellation? cancellation,
  }) async =>
      _checkRemoteWritable(await _requireProfile(profileId), cancellation: cancellation);

  /// Proves the selected remote folder exists and accepts a write, before a
  /// profile is created or after it was changed.
  Future<void> checkRemoteWritableFor({
    required String connectionId,
    required List<String> remoteRootSegments,
    RemoteOperationCancellation? cancellation,
  }) => _checkRemoteWritable(
    PlainFolderSyncProfile(
      profileId: 'remote-check',
      datasetId: 'remote-check',
      deviceId: 'remote-check',
      displayName: 'remote-check',
      localRootReference: '',
      localDisplayName: 'remote-check',
      connectionId: connectionId,
      remoteRootSegments: remoteRootSegments,
      createdAt: _now().toUtc(),
    ),
    cancellation: cancellation,
  );

  Future<void> _checkRemoteWritable(
    PlainFolderSyncProfile profile, {
    RemoteOperationCancellation? cancellation,
  }) async {
    final RemoteObjectStore remote;
    try {
      remote = await _remoteFor(profile);
    } on PlainFolderSyncException {
      rethrow;
    }
    final key = '.velock-sync-probe-${_uuid.v4()}.tmp';
    final bytes = utf8.encode('velock-sync writability probe');
    try {
      try {
        await remote.put(
          key,
          Stream<List<int>>.value(bytes),
          contentLength: bytes.length,
          cancellation: cancellation,
        );
        final stat = await remote.stat(key, cancellation: cancellation);
        if (stat == null || stat.size != bytes.length) {
          throw const PlainFolderSyncException(
            SyncFailure(
              errorCode: 'plain_folder.probe_unreadable',
              category: SyncErrorCategory.userActionRequired,
              retryable: true,
              suggestedAction: '远端位置可以连接，但写入后读回校验失败。请检查账号权限后重试。',
            ),
          );
        }
      } on PlainFolderSyncException {
        rethrow;
      } on Object {
        // A missing folder and a read-only folder look the same here, so the
        // message names both and points at the one action that fixes either.
        throw const PlainFolderSyncException(
          SyncFailure(
            errorCode: 'plain_folder.remote_folder_unwritable',
            category: SyncErrorCategory.permissionRequired,
            retryable: false,
            suggestedAction:
                '远端文件夹不存在或这个账号不能写入。请在详情页重新选择一个真实存在、且可写入的远端文件夹。',
          ),
        );
      }
    } finally {
      try {
        await remote.delete(key, cancellation: cancellation);
      } on Object {
        // The probe is tiny and clearly named; a failed cleanup must not turn a
        // successful write check into a failure.
      }
    }
  }

  /// Runs one location with the default deletion protection.
  ///
  /// [allowDeletions] keeps its old name but approves nothing on its own: a
  /// confirmation only ever applies to the deletions it was shown, and this flag
  /// cannot name them. Use [runConfirmedDeletions] with the paths of the
  /// previous run's [MirrorRunOutcome.heldDeletionPaths] to really delete them.
  Future<MirrorRunOutcome> run(
    String profileId, {
    bool allowDeletions = false,
    void Function(MirrorProgress progress)? onProgress,
    RemoteOperationCancellation? cancellation,
  }) => withVelockLocationGuard(
    _database,
    profileId,
    () => _runUnlocked(
      profileId,
      confirmedDeletions: allowDeletions ? const <String>{} : null,
      onProgress: onProgress,
      cancellation: cancellation,
    ),
  );

  /// Runs one location and performs exactly the deletions the user confirmed.
  ///
  /// The user confirms the paths reported by the previous run
  /// ([MirrorRunOutcome.heldDeletionPaths]). A deletion that is not in
  /// [confirmedPaths] is held again instead of executed, so a plan that grew
  /// between the summary and this run can never delete a path the user never
  /// saw.
  Future<MirrorRunOutcome> runConfirmedDeletions(
    String profileId,
    Set<String> confirmedPaths, {
    void Function(MirrorProgress progress)? onProgress,
    RemoteOperationCancellation? cancellation,
  }) => withVelockLocationGuard(
    _database,
    profileId,
    () => _runUnlocked(
      profileId,
      confirmedDeletions: Set<String>.of(confirmedPaths),
      onProgress: onProgress,
      cancellation: cancellation,
    ),
  );

  Future<MirrorRunOutcome> _runUnlocked(
    String profileId, {
    Set<String>? confirmedDeletions,
    void Function(MirrorProgress progress)? onProgress,
    RemoteOperationCancellation? cancellation,
  }) async {
    final startedAt = _now().toUtc();
    final runId = _uuid.v4();
    final profile = await _requireProfile(profileId);
    await _database.startSyncRun(
      runId: runId,
      profileId: profileId,
      startedAt: startedAt,
    );
    final counters = _RunCounters();
    // The held-deletion count of this run's own plan, once it exists. A failure
    // before that point must report the previous honest value instead of zero.
    int? plannedHeldDeletionCount;
    try {
      final connection = await _connections.getConnectionById(
        profile.connectionId,
      );
      if (connection == null) {
        throw const PlainFolderSyncException(
          SyncFailure(
            errorCode: 'plain_folder.connection_missing',
            category: SyncErrorCategory.userActionRequired,
            retryable: false,
            suggestedAction: '这个同步位置使用的远端连接已被删除，请重新选择远端位置。',
          ),
        );
      }
      final remote = await _remoteFor(profile);
      final session = await _openStorage(profile);
      final storage = session.storage;
      try {
        onProgress?.call(const MirrorProgress(phase: MirrorRunPhase.scanning));
        if (!await storage.checkAccess()) {
          throw const PlainFolderSyncException(
            SyncFailure(
              errorCode: 'plain_folder.local_access_lost',
              category: SyncErrorCategory.localAccessLost,
              retryable: false,
              suggestedAction: '本机文件夹的访问权限已失效，请在本机文件夹里重新授权。',
            ),
          );
        }
        final local = await _scanLocal(storage);
        final remoteScan = await _scanRemote(
          remote,
          cancellation: cancellation,
        );
        final remoteEntries = remoteScan.entries;
        final baseline = await _database.readMirrorEntries(profileId);
        _ensureRemoteListingIsTrustworthy(
          local: local,
          remote: remoteEntries,
          baseline: baseline,
          scan: remoteScan,
        );

        onProgress?.call(const MirrorProgress(phase: MirrorRunPhase.comparing));
        final verification = await _verifyAmbiguous(
          local: local,
          remote: remoteEntries,
          baseline: baseline,
          remoteStore: remote,
          storage: storage,
          cancellation: cancellation,
        );

        final plan = _planner.plan(
          local: local,
          remote: remoteEntries,
          baseline: baseline,
          direction: profile.direction,
          conflictPolicy: profile.conflictPolicy,
          initialSyncPolicy: profile.initialSyncPolicy,
          now: _now().toUtc(),
          listingScope: MirrorListingScope(
            localDirectories: mirrorScannedDirectories(local.values),
            remoteDirectories: remoteScan.listedDirectories,
          ),
          confirmedDeletions: confirmedDeletions,
          verifiedIdenticalPaths: verification.identicalPaths,
          deferredPaths: verification.deferredPaths,
        );
        // From here the plan is known, so even a failed run reports the work it
        // really decided to hold back instead of writing zeroes.
        plannedHeldDeletionCount = plan.heldDeletions?.actions.length;
        counters.skippedCount =
            plan.stats.skippedLocalOnlyCount +
            plan.stats.skippedRemoteOnlyCount +
            plan.stats.deferredCount +
            plan.stats.heldCount;

        await _recordInSyncBaselines(
          profile: profile,
          plan: plan,
          local: local,
          remote: remoteEntries,
          baseline: baseline,
        );

        await _apply(
          profile: profile,
          plan: plan,
          storage: storage,
          remote: remote,
          counters: counters,
          onProgress: onProgress,
          cancellation: cancellation,
        );

        await _database.recordMirrorConflicts(
          profileId,
          plan.conflicts,
          detectedAt: _now().toUtc(),
        );
        await _database.trimMirrorConflicts(profileId);

        counters.conflictCount = plan.conflicts.length;
        counters.heldDeletionCount = plannedHeldDeletionCount ?? 0;

        final stats = counters.toStats(
          runId: runId,
          profileId: profileId,
          startedAt: startedAt,
          finishedAt: _now().toUtc(),
        );
        await _database.saveMirrorRunStats(stats);
        await _database.finishSyncRun(
          runId: runId,
          state: 'completed',
          completedAt: _now().toUtc(),
        );
        return MirrorRunOutcome(
          stats: stats,
          conflicts: await _database.readMirrorConflicts(profileId, limit: 20),
          heldDeletions: plan.heldDeletions,
        );
      } finally {
        await session.release();
      }
    } on Object catch (error, stackTrace) {
      final failure = SyncFailureClassifier.classify(error);
      // A failed run must not clear the "deletions are waiting for confirmation"
      // state: when this run never reached a plan, the previous count is still
      // the honest one.
      counters.heldDeletionCount =
          plannedHeldDeletionCount ??
          await _previousHeldDeletionCount(profileId);
      final stats = counters.toStats(
        runId: runId,
        profileId: profileId,
        startedAt: startedAt,
        finishedAt: _now().toUtc(),
        failureCode: failure.errorCode,
      );
      await _database.saveMirrorRunStats(stats);
      await _database.finishSyncRun(
        runId: runId,
        state: 'failed',
        completedAt: _now().toUtc(),
        failure: failure,
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Held-deletion count of the last finished run of this location.
  Future<int> _previousHeldDeletionCount(String profileId) async {
    try {
      final previous = await _database.readLatestMirrorRunStats(profileId);
      return previous?.heldDeletionCount ?? 0;
    } on Object {
      // A missing history is not a reason to fail: zero is all that is known.
      return 0;
    }
  }

  /// Refuses to plan against a remote listing that cannot be trusted.
  ///
  /// A renamed folder, a NAS that is not mounted and a provider that drops the
  /// PROPFIND response all look exactly like "the remote side is empty"; reading
  /// that as deletions would wipe the user's local files. The planner cannot
  /// tell such a listing apart from a fixture that simply lists fewer paths, so
  /// this refusal lives here, where the scan really happened. A subtree the depth
  /// cap skipped is just as invisible and stops the run too.
  void _ensureRemoteListingIsTrustworthy({
    required Map<String, MirrorEntry> local,
    required Map<String, MirrorEntry> remote,
    required Map<String, MirrorBaselineEntry> baseline,
    required _RemoteScanResult scan,
  }) {
    if (remote.isEmpty && local.isNotEmpty && baseline.isNotEmpty) {
      throw _remoteFolderMissing();
    }
    if (scan.truncatedDirectories.isEmpty) return;
    bool knowsContent(String directory) =>
        local.keys.any(
          (path) => path == directory || path.startsWith('$directory/'),
        ) ||
        baseline.keys.any(
          (path) => path == directory || path.startsWith('$directory/'),
        );
    if (!scan.truncatedDirectories.any(knowsContent)) return;
    throw const PlainFolderSyncException(
      SyncFailure(
        errorCode: 'plain_folder.remote_too_deep',
        category: SyncErrorCategory.userActionRequired,
        retryable: false,
        suggestedAction: '远端文件夹层级太深，这次同步读不完整。请选择一个层级更浅的远端文件夹。',
      ),
    );
  }

  /// The remote folder this location mirrors is gone or unreadable.
  ///
  /// One stable code for both the store's PROPFIND 404 and an empty listing that
  /// contradicts a baseline: either way nothing was deleted, and the user has to
  /// check the remote folder before another run.
  static PlainFolderSyncException _remoteFolderMissing() =>
      const PlainFolderSyncException(
        SyncFailure(
          errorCode: 'plain_folder.remote_folder_missing',
          category: SyncErrorCategory.userActionRequired,
          retryable: true,
          suggestedAction:
              '远端文件夹空了或读不到内容。为避免误删本机文件，本次同步没有删除任何东西。请确认远端文件夹还在、账号仍可访问，然后重试。',
        ),
      );

  Future<PlainFolderSyncProfile> _requireProfile(String profileId) async {
    final profile = await _profiles.read(profileId);
    if (profile == null) {
      throw const PlainFolderSyncException(
        SyncFailure(
          errorCode: 'plain_folder.profile_missing',
          category: SyncErrorCategory.userActionRequired,
          retryable: false,
          suggestedAction: '这个同步位置已不存在。',
        ),
      );
    }
    if (!profile.isActive) {
      throw const PlainFolderSyncException(
        SyncFailure(
          errorCode: 'plain_folder.profile_paused',
          category: SyncErrorCategory.userActionRequired,
          retryable: false,
          suggestedAction: '这个同步位置已暂停，恢复后才能同步。',
        ),
      );
    }
    return profile;
  }

  Future<Map<String, MirrorEntry>> _scanLocal(
    SelectedFolderStorage storage,
  ) async {
    final entries = <String, MirrorEntry>{};
    await for (final entry in storage.listRecursively()) {
      if (isSelectedFolderIgnoredPath(entry.relativePath)) continue;
      if (isMirrorInternalPath(entry.relativePath)) continue;
      entries[entry.relativePath] = MirrorEntry(
        relativePath: entry.relativePath,
        kind: entry.type == FolderEntryType.directory
            ? MirrorEntryKind.directory
            : MirrorEntryKind.file,
        size: entry.size ?? 0,
        modifiedAt: entry.modifiedAt,
      );
    }
    return entries;
  }

  /// Depth-first listing of the remote folder. Directories are visited after
  /// their parent so callers can recreate the same tree locally.
  ///
  /// The result also records which directories were really read and which ones
  /// the depth cap skipped: a deletion is only trustworthy for a path whose
  /// parent directory appears in [RemoteObjectStore.list] results.
  Future<_RemoteScanResult> _scanRemote(
    RemoteObjectStore remote, {
    RemoteOperationCancellation? cancellation,
  }) async {
    final entries = <String, MirrorEntry>{};
    final pending = <String>[''];
    final visited = <String>{};
    // The mirrored folder itself is always listed first; every other entry is
    // added once its own listing came back.
    final listedDirectories = <String>{''};
    final truncatedDirectories = <String>[];
    while (pending.isNotEmpty) {
      final directory = pending.removeLast();
      if (!visited.add(directory)) continue;
      if (_depth(directory) > mirrorMaximumDirectoryDepth) {
        // Everything below this directory is invisible to this run, so the
        // caller must treat its contents as unknown rather than deleted.
        truncatedDirectories.add(directory);
        continue;
      }
      String? cursor;
      do {
        final RemoteObjectPage page;
        try {
          page = await remote.list(
            prefix: directory,
            cursor: cursor,
            limit: 500,
            cancellation: cancellation,
          );
        } on RemoteObjectNotFoundException {
          // The store reports a PROPFIND 404 instead of an empty page: the
          // folder this location mirrors is gone (unmounted, renamed, moved).
          throw _remoteFolderMissing();
        }
        listedDirectories.add(directory);
        for (final item in page.items) {
          final path = _normaliseRemoteKey(item.logicalKey);
          if (path.isEmpty) continue;
          if (isMirrorInternalPath(path)) continue;
          entries[path] = MirrorEntry(
            relativePath: path,
            kind: item.isDirectory
                ? MirrorEntryKind.directory
                : MirrorEntryKind.file,
            size: item.size,
            modifiedAt: item.updatedAt,
            etag: item.etag,
          );
          if (item.isDirectory) pending.add(path);
        }
        cursor = page.nextCursor;
        if (entries.length > mirrorMaximumRemoteEntries) {
          throw const PlainFolderSyncException(
            SyncFailure(
              errorCode: 'plain_folder.remote_too_large',
              category: SyncErrorCategory.userActionRequired,
              retryable: false,
              suggestedAction: '远端文件夹内容过多，已停止本次同步。请选择一个更具体的远端文件夹。',
            ),
          );
        }
      } while (cursor != null);
    }
    return _RemoteScanResult(
      entries: entries,
      listedDirectories: listedDirectories,
      truncatedDirectories: truncatedDirectories,
    );
  }

  /// WebDAV stores may echo the queried prefix; the mirror keys are always
  /// relative paths without a leading or trailing slash.
  static String _normaliseRemoteKey(String logicalKey) {
    var value = logicalKey;
    while (value.startsWith('/')) {
      value = value.substring(1);
    }
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  /// Proves that files which exist on both sides are really the same file.
  ///
  /// Only ambiguous pairs (same size, different timestamp, no baseline) are
  /// read back, and only inside a per-run budget: the rest is deferred so a
  /// large first sync neither downloads everything nor invents conflict copies.
  Future<_VerificationResult> _verifyAmbiguous({
    required Map<String, MirrorEntry> local,
    required Map<String, MirrorEntry> remote,
    required Map<String, MirrorBaselineEntry> baseline,
    required RemoteObjectStore remoteStore,
    required SelectedFolderStorage storage,
    required RemoteOperationCancellation? cancellation,
  }) async {
    final identical = <String>{};
    final deferred = <String>{};
    var budgetBytes = _verificationBudget.maxTotalBytes;
    var budgetFiles = _verificationBudget.maxFiles;
    for (final entry in local.entries) {
      final path = entry.key;
      final localEntry = entry.value;
      final remoteEntry = remote[path];
      if (localEntry.isDirectory || remoteEntry == null) continue;
      if (remoteEntry.isDirectory) continue;
      if (baseline.containsKey(path)) continue;
      if (localEntry.size != remoteEntry.size) continue;
      if (mirrorTimesMatch(localEntry.modifiedAt, remoteEntry.modifiedAt)) {
        continue;
      }
      if (localEntry.size > _verificationBudget.maxFileBytes ||
          budgetFiles < 1 ||
          localEntry.size > budgetBytes) {
        deferred.add(path);
        continue;
      }
      budgetFiles--;
      budgetBytes -= localEntry.size;
      final localDigest = await _localDigest(storage, path);
      final remoteDigest = await _remoteDigest(
        remoteStore,
        path,
        cancellation: cancellation,
      );
      if (localDigest != null &&
          remoteDigest != null &&
          localDigest == remoteDigest) {
        identical.add(path);
      }
    }
    return _VerificationResult(identicalPaths: identical, deferredPaths: deferred);
  }

  Future<String?> _localDigest(
    SelectedFolderStorage storage,
    String relativePath,
  ) async {
    try {
      final digest = await sha256.bind(storage.file(relativePath).openRead()).first;
      return digest.toString();
    } on Object {
      return null;
    }
  }

  Future<String?> _remoteDigest(
    RemoteObjectStore remote,
    String relativePath, {
    required RemoteOperationCancellation? cancellation,
  }) async {
    try {
      final digest = await sha256
          .bind(remote.read(relativePath, cancellation: cancellation))
          .first;
      return digest.toString();
    } on Object {
      return null;
    }
  }

  Future<void> _apply({
    required PlainFolderSyncProfile profile,
    required MirrorPlan plan,
    required SelectedFolderStorage storage,
    required RemoteObjectStore remote,
    required _RunCounters counters,
    required void Function(MirrorProgress progress)? onProgress,
    required RemoteOperationCancellation? cancellation,
  }) async {
    final now = _now().toUtc();
    final directories = plan.actions
        .where(
          (action) =>
              action.type == MirrorActionType.createRemoteDirectory ||
              action.type == MirrorActionType.createLocalDirectory,
        )
        .toList()
      ..sort((a, b) => _depth(a.relativePath).compareTo(_depth(b.relativePath)));
    final deletions = plan.actions.where((action) => action.isDeletion).toList()
      ..sort((a, b) => _depth(b.relativePath).compareTo(_depth(a.relativePath)));
    final uploads = plan.actions
        .where((action) => action.type == MirrorActionType.uploadFile)
        .toList();
    final downloads = plan.actions
        .where((action) => action.type == MirrorActionType.downloadFile)
        .toList();

    for (final action in directories) {
      cancellation?.throwIfCancelled();
      switch (action.type) {
        case MirrorActionType.createRemoteDirectory:
          await _createRemoteDirectory(remote, action, cancellation);
          counters.createdDirectoryCount++;
          await _database.upsertMirrorEntries(profile.profileId, [
            MirrorBaselineEntry(
              relativePath: action.relativePath,
              kind: MirrorEntryKind.directory,
              syncedAt: now,
            ),
          ]);
        case MirrorActionType.createLocalDirectory:
          await storage.createDirectory(action.relativePath);
          counters.createdDirectoryCount++;
          await _database.upsertMirrorEntries(profile.profileId, [
            MirrorBaselineEntry(
              relativePath: action.relativePath,
              kind: MirrorEntryKind.directory,
              syncedAt: now,
            ),
          ]);
        default:
          break;
      }
    }

    onProgress?.call(
      MirrorProgress(
        phase: MirrorRunPhase.deleting,
        total: deletions.length,
      ),
    );
    for (var index = 0; index < deletions.length; index++) {
      final action = deletions[index];
      cancellation?.throwIfCancelled();
      onProgress?.call(
        MirrorProgress(
          phase: MirrorRunPhase.deleting,
          completed: index,
          total: deletions.length,
          currentPath: action.relativePath,
        ),
      );
      switch (action.type) {
        case MirrorActionType.deleteRemoteEntry:
          await _remoteWrite(
            () => remote.delete(action.relativePath, cancellation: cancellation),
          );
          counters.deletedRemoteCount++;
        case MirrorActionType.deleteLocalEntry:
          await storage.delete(action.relativePath);
          counters.deletedLocalCount++;
        default:
          break;
      }
      await _database.deleteMirrorEntries(profile.profileId, [
        action.relativePath,
      ]);
    }

    onProgress?.call(
      MirrorProgress(phase: MirrorRunPhase.uploading, total: uploads.length),
    );
    final downloadedPaths = <String>[];
    for (var index = 0; index < uploads.length; index++) {
      final action = uploads[index];
      cancellation?.throwIfCancelled();
      onProgress?.call(
        MirrorProgress(
          phase: MirrorRunPhase.uploading,
          completed: index,
          total: uploads.length,
          currentPath: action.relativePath,
        ),
      );
      final metadata = await _upload(
        remote: remote,
        storage: storage,
        action: action,
        counters: counters,
        cancellation: cancellation,
      );
      await _recordBaselineAfterUpload(
        profile: profile,
        action: action,
        remoteEntry: metadata,
        now: now,
      );
    }

    onProgress?.call(
      MirrorProgress(phase: MirrorRunPhase.downloading, total: downloads.length),
    );
    for (var index = 0; index < downloads.length; index++) {
      final action = downloads[index];
      cancellation?.throwIfCancelled();
      onProgress?.call(
        MirrorProgress(
          phase: MirrorRunPhase.downloading,
          completed: index,
          total: downloads.length,
          currentPath: action.relativePath,
        ),
      );
      final conflictCopyPath = action.conflictCopyPath;
      if (conflictCopyPath != null && action.local != null) {
        // Keep-both: the local version survives under a conflict name before
        // the remote version takes the original path.
        await _copyLocal(
          storage: storage,
          from: action.relativePath,
          to: conflictCopyPath,
        );
      }
      await _download(
        remote: remote,
        storage: storage,
        action: action,
        counters: counters,
        cancellation: cancellation,
      );
      downloadedPaths.add(action.relativePath);
    }

    for (final path in plan.removedBaselinePaths) {
      await _database.deleteMirrorEntries(profile.profileId, [path]);
    }

    if (downloadedPaths.isNotEmpty) {
      Map<String, MirrorEntry>? rescanned;
      try {
        rescanned = await _scanLocal(storage);
      } on Object {
        rescanned = null;
      }
      for (final path in downloadedPaths) {
        final localEntry = rescanned?[path];
        final remoteEntry = plan.actions
            .where((action) => action.relativePath == path)
            .map((action) => action.remote)
            .whereType<MirrorEntry>()
            .firstOrNull;
        if (remoteEntry == null) continue;
        await _database.upsertMirrorEntries(profile.profileId, [
          MirrorBaselineEntry(
            relativePath: path,
            kind: MirrorEntryKind.file,
            localSize: localEntry?.size ?? remoteEntry.size,
            localModifiedAt: localEntry?.modifiedAt ?? remoteEntry.modifiedAt,
            remoteSize: remoteEntry.size,
            remoteModifiedAt: remoteEntry.modifiedAt,
            remoteEtag: remoteEntry.etag,
            syncedAt: _now().toUtc(),
          ),
        ]);
      }
    }

    onProgress?.call(const MirrorProgress(phase: MirrorRunPhase.finishing));
  }

  /// Writes the baseline for paths this run proved to be in sync.
  ///
  /// A path the planner left alone (same size and time on both sides, or
  /// verified byte-identical) must get a row too: without it the next run has
  /// no baseline, re-reads the remote file to compare content again and can
  /// never converge.
  Future<void> _recordInSyncBaselines({
    required PlainFolderSyncProfile profile,
    required MirrorPlan plan,
    required Map<String, MirrorEntry> local,
    required Map<String, MirrorEntry> remote,
    required Map<String, MirrorBaselineEntry> baseline,
  }) async {
    final now = _now().toUtc();
    final rows = <MirrorBaselineEntry>[];
    for (final path in plan.inSyncPaths) {
      final localEntry = local[path];
      final remoteEntry = remote[path];
      if (localEntry == null || remoteEntry == null) continue;
      final existing = baseline[path];
      if (existing != null &&
          existing.kind == localEntry.kind &&
          existing.matchesLocal(localEntry) &&
          existing.matchesRemote(remoteEntry)) {
        continue;
      }
      rows.add(
        MirrorBaselineEntry.forOutcome(
          relativePath: path,
          kind: localEntry.kind,
          outcome: MirrorPathOutcome.unchanged,
          local: localEntry,
          remote: remoteEntry,
          now: now,
        ),
      );
    }
    if (rows.isNotEmpty) {
      await _database.upsertMirrorEntries(profile.profileId, rows);
    }
  }

  /// Runs one remote write, naming the real problem when the folder is gone or
  /// read-only instead of surfacing a provider status code.
  Future<T> _remoteWrite<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on PlainFolderSyncException {
      rethrow;
    } on Object catch (error) {
      final failure = error is SyncFailureException ? error.syncFailure : null;
      final category = failure?.category;
      // A sign-in failure keeps its own code (`provider.http.401`): telling the
      // user the folder is missing or read-only sends them to re-pick a folder
      // that was fine, and never mentions the password that actually failed.
      if (category == SyncErrorCategory.remoteConflict ||
          category == SyncErrorCategory.permissionRequired) {
        throw const PlainFolderSyncException(
          SyncFailure(
            errorCode: 'plain_folder.remote_folder_unwritable',
            category: SyncErrorCategory.permissionRequired,
            retryable: false,
            suggestedAction:
                '远端文件夹不存在或这个账号不能写入。请在详情页重新选择一个真实存在、且可写入的远端文件夹。',
          ),
        );
      }
      rethrow;
    }
  }

  Future<void> _createRemoteDirectory(
    RemoteObjectStore remote,
    MirrorAction action,
    RemoteOperationCancellation? cancellation,
  ) async {
    final creator = remote is RemoteCollectionCreator
        ? remote as RemoteCollectionCreator
        : null;
    if (creator == null) {
      throw const PlainFolderSyncException(
        SyncFailure(
          errorCode: 'plain_folder.remote_unsupported',
          category: SyncErrorCategory.unsupportedProtocol,
          retryable: false,
          suggestedAction: '这个远端不支持创建文件夹，暂时不能在远端保留空目录。',
        ),
      );
    }
    await _remoteWrite(
      () => creator.createCollection(
        action.relativePath,
        cancellation: cancellation,
      ),
    );
  }

  /// Uploads one file and proves the remote object really holds the local size.
  ///
  /// A server that keeps a truncated body (connection dropped mid-PUT) would
  /// otherwise become the baseline, and a later run would either call it
  /// unchanged or download the truncated copy over the good local file. The
  /// partial object is removed again so the next run re-uploads it.
  ///
  /// Returns the remote metadata for the baseline, or `null` when the server
  /// would not report it back: [_recordBaselineAfterUpload] then writes no row
  /// at all.
  Future<RemoteObjectMetadata?> _upload({
    required RemoteObjectStore remote,
    required SelectedFolderStorage storage,
    required MirrorAction action,
    required _RunCounters counters,
    required RemoteOperationCancellation? cancellation,
  }) async {
    final source = storage.file(action.relativePath);
    final length = await source.length();
    await _remoteWrite(
      () => remote.put(
        action.relativePath,
        source.openRead(),
        contentLength: length,
        cancellation: cancellation,
      ),
    );
    final metadata = await _statRemote(
      remote,
      action.relativePath,
      cancellation: cancellation,
    );
    if (metadata != null && metadata.size != length) {
      await _discardPartialUpload(
        remote,
        action.relativePath,
        cancellation: cancellation,
      );
      throw const PlainFolderSyncException(
        SyncFailure(
          errorCode: 'plain_folder.upload_incomplete',
          category: SyncErrorCategory.integrityFailure,
          retryable: true,
          suggestedAction: '上传没有完整写进远端（远端对象比本机文件小）。这次同步已停止，请重试。',
        ),
      );
    }
    // Only a finished transfer counts, and an upload the server stored
    // incompletely is not reported as moved bytes.
    counters.uploadedFileCount++;
    counters.bytesTransferred += length;
    return metadata;
  }

  /// Reads remote metadata without deciding what a missing answer means.
  Future<RemoteObjectMetadata?> _statRemote(
    RemoteObjectStore remote,
    String relativePath, {
    required RemoteOperationCancellation? cancellation,
  }) async {
    try {
      return await remote.stat(relativePath, cancellation: cancellation);
    } on Object {
      return null;
    }
  }

  /// Removes an object the server stored incompletely, best effort: the upload
  /// failure is what the user has to see, so a failed cleanup never replaces it.
  Future<void> _discardPartialUpload(
    RemoteObjectStore remote,
    String relativePath, {
    required RemoteOperationCancellation? cancellation,
  }) async {
    try {
      await remote.delete(relativePath, cancellation: cancellation);
    } on Object {
      // The next run re-uploads the path either way.
    }
  }

  Future<void> _download({
    required RemoteObjectStore remote,
    required SelectedFolderStorage storage,
    required MirrorAction action,
    required _RunCounters counters,
    required RemoteOperationCancellation? cancellation,
  }) async {
    final stream = remote.read(action.relativePath, cancellation: cancellation);
    var received = 0;
    final measured = stream.map((chunk) {
      received += chunk.length;
      return chunk;
    });
    final streaming = storage is StreamingSelectedFolderStorage
        ? storage as StreamingSelectedFolderStorage
        : null;
    if (streaming != null) {
      await streaming.writeFileFromStream(action.relativePath, measured);
    } else {
      final bytes = <int>[];
      await for (final chunk in measured) {
        bytes.addAll(chunk);
      }
      await storage.writeFileAtomically(action.relativePath, bytes);
    }
    // Only a finished transfer may inflate the run's counters: a failed
    // download must never report bytes it did not move.
    counters.downloadedFileCount++;
    counters.bytesTransferred += received;
  }

  /// Preserves a conflicted local version under its conflict name.
  Future<void> _copyLocal({
    required SelectedFolderStorage storage,
    required String from,
    required String to,
  }) async {
    final stream = storage.file(from).openRead();
    final streaming = storage is StreamingSelectedFolderStorage
        ? storage as StreamingSelectedFolderStorage
        : null;
    if (streaming != null) {
      await streaming.writeFileFromStream(to, stream);
      return;
    }
    final bytes = <int>[];
    await for (final chunk in stream) {
      bytes.addAll(chunk);
    }
    await storage.writeFileAtomically(to, bytes);
  }

  /// Records the baseline of one uploaded file from the metadata the verifying
  /// read-back returned.
  ///
  /// The server assigns its own timestamp, and recording the local one would
  /// make the next run download the file it just uploaded.
  Future<void> _recordBaselineAfterUpload({
    required PlainFolderSyncProfile profile,
    required MirrorAction action,
    required RemoteObjectMetadata? remoteEntry,
    required DateTime now,
  }) async {
    if (remoteEntry == null) {
      // Without the remote's own timestamp a fabricated row would make the
      // next run treat the upload as a remote change and download it back.
      // Leaving no row is safe: the next run proves the two files identical by
      // content and records the baseline then.
      return;
    }
    final localEntry = action.local;
    await _database.upsertMirrorEntries(profile.profileId, [
      MirrorBaselineEntry(
        relativePath: action.relativePath,
        kind: MirrorEntryKind.file,
        localSize: localEntry?.size ?? 0,
        localModifiedAt: localEntry?.modifiedAt,
        remoteSize: remoteEntry.size,
        remoteModifiedAt: remoteEntry.updatedAt,
        remoteEtag: remoteEntry.etag,
        syncedAt: now,
      ),
    ]);
  }

  Future<SelectedFolderStorageSession> _openStorage(
    PlainFolderSyncProfile profile,
  ) async {
    switch (profile.accessKind) {
      case FolderAccessKind.localPath:
        return SelectedFolderStorageSession(
          LocalSelectedFolderStorage(Directory(profile.localRootReference)),
        );
      case FolderAccessKind.androidDocumentTree:
        return SelectedFolderStorageSession(
          AndroidDocumentTreeStorage(
            treeUri: profile.localRootReference,
            access: _androidDocumentTrees,
          ),
        );
      case FolderAccessKind.appleSecurityScopedBookmark:
        final session = await _appleFolders.acquireOrReportLostAccess(profile.localRootReference);
        return SelectedFolderStorageSession(
          LocalSelectedFolderStorage(Directory(session.path)),
          onRelease: () => _appleFolders.release(session.token),
        );
    }
  }

  /// Plain file sync is WebDAV-only: the other providers expose an object API
  /// without real file names, which cannot mirror a user folder.
  Future<RemoteObjectStore> _remoteFor(PlainFolderSyncProfile profile) async {
    final connection = await _connections.getConnectionById(
      profile.connectionId,
    );
    if (connection == null) {
      throw const PlainFolderSyncException(
        SyncFailure(
          errorCode: 'plain_folder.connection_missing',
          category: SyncErrorCategory.userActionRequired,
          retryable: false,
          suggestedAction: '这个同步位置使用的远端连接已被删除，请重新选择远端位置。',
        ),
      );
    }
    final scopedProtocol = RemoteObjectStoreFactory.scopeProtocol(
      connection.protocol,
      profile.remoteRootSegments,
    );
    return switch (scopedProtocol) {
      WebDavProtocolModel(:final credentialRef) => _remoteFactory(
        protocol: scopedProtocol,
        password: await _connections.readWebDavPassword(credentialRef),
      ),
      OAuthProtocolModel() => throw const PlainFolderSyncException(
        SyncFailure(
          errorCode: 'plain_folder.remote_unsupported',
          category: SyncErrorCategory.unsupportedProtocol,
          retryable: false,
          suggestedAction: '文件夹同步目前只支持 WebDAV（NAS）。云盘连接暂不支持。',
        ),
      ),
    };
  }

  static RemoteObjectStore _defaultRemoteFactory({
    required WebDavProtocolModel protocol,
    required String? password,
  }) => WebDavObjectStore(
    // A stalled socket must fail the run, not hang it: see the shared factory.
    dio: Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(minutes: 5),
        sendTimeout: const Duration(minutes: 5),
      ),
    ),
    baseUri: _webDavUri(protocol),
    username: protocol.username,
    password: password,
  );

  static Uri _webDavUri(WebDavProtocolModel protocol) {
    final address = Uri.tryParse(protocol.address);
    final port = int.tryParse(protocol.port);
    if (address == null || !address.hasAuthority || port == null || port < 1) {
      throw ArgumentError.value(protocol.address, 'protocol', 'is invalid');
    }
    final segments = <String>[
      ...address.pathSegments.where((segment) => segment.isNotEmpty),
      ...?Uri.tryParse(protocol.path ?? '')?.pathSegments.where(
        (segment) => segment.isNotEmpty && segment != '.' && segment != '..',
      ),
    ];
    return address.replace(
      scheme: protocol.protocolType.name,
      port: port,
      pathSegments: segments,
      query: null,
      fragment: null,
    );
  }

  static int _depth(String path) => '/'.allMatches(path).length;
}

/// Upper bounds that keep one run bounded even against a hostile or looping
/// remote tree.
const mirrorMaximumDirectoryDepth = 64;
const mirrorMaximumRemoteEntries = 500000;

/// Names this engine owns and must never mirror in either direction.
bool isMirrorInternalPath(String relativePath) {
  for (final segment in relativePath.split('/')) {
    if (segment.isEmpty) continue;
    if (segment == '.velock-sync' || segment == '.velock-sync-tmp') return true;
    if (segment.startsWith('.velock-sync-probe')) return true;
    if (segment.startsWith('.velock-tmp-')) return true;
    if (segment.endsWith('.velock-tmp')) return true;
  }
  return false;
}

/// Remote folder summary shown before the first sync of a new location.
class MirrorRemoteSummary {
  const MirrorRemoteSummary({
    required this.fileCount,
    required this.directoryCount,
    required this.totalBytes,
  });

  final int fileCount;
  final int directoryCount;
  final int totalBytes;

  bool get isEmpty => fileCount == 0 && directoryCount == 0;
}

class SelectedFolderStorageSession {
  SelectedFolderStorageSession(this.storage, {Future<void> Function()? onRelease})
    : _onRelease = onRelease;

  final SelectedFolderStorage storage;
  final Future<void> Function()? _onRelease;
  bool _released = false;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _onRelease?.call();
  }
}

class _VerificationResult {
  const _VerificationResult({
    required this.identicalPaths,
    required this.deferredPaths,
  });

  final Set<String> identicalPaths;
  final Set<String> deferredPaths;
}

/// One remote scan: the entries plus what this run is allowed to trust about
/// the listing that produced them.
class _RemoteScanResult {
  const _RemoteScanResult({
    required this.entries,
    required this.listedDirectories,
    required this.truncatedDirectories,
  });

  final Map<String, MirrorEntry> entries;

  /// Every directory this scan really read, the mirrored root included.
  final Set<String> listedDirectories;

  /// Directories the depth cap refused to read: everything below them is
  /// invisible to this run.
  final List<String> truncatedDirectories;
}

class _RunCounters {
  int uploadedFileCount = 0;
  int downloadedFileCount = 0;
  int deletedLocalCount = 0;
  int deletedRemoteCount = 0;
  int createdDirectoryCount = 0;
  int conflictCount = 0;
  int heldDeletionCount = 0;
  int skippedCount = 0;
  int bytesTransferred = 0;

  MirrorRunStats toStats({
    required String runId,
    required String profileId,
    required DateTime startedAt,
    required DateTime finishedAt,
    String? failureCode,
  }) => MirrorRunStats(
    runId: runId,
    profileId: profileId,
    startedAt: startedAt,
    finishedAt: finishedAt,
    uploadedFileCount: uploadedFileCount,
    downloadedFileCount: downloadedFileCount,
    deletedLocalCount: deletedLocalCount,
    deletedRemoteCount: deletedRemoteCount,
    conflictCount: conflictCount,
    heldDeletionCount: heldDeletionCount,
    skippedCount: skippedCount,
    bytesTransferred: bytesTransferred,
    failureCode: failureCode,
  );
}
