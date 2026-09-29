import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:velock_sync/dataset_adapters/plain_folder/mirror_models.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_profile.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_service.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

const _profileId = 'plain-1';
const _connectionId = 'cloud';

/// A real folder tree behind a WebDAV-shaped API: `Map<String, List<int>>`
/// files plus a directory set, Depth:1 listings, MKCOL that refuses a missing
/// parent, and a server clock that assigns its own modification times.
class _FakeMirrorRemote implements RemoteObjectStore, RemoteCollectionCreator {
  _FakeMirrorRemote({DateTime Function()? clock})
    : clock = clock ?? _defaultServerClock;

  /// Default server clock: far away from every local file mtime, so a test can
  /// tell "the engine recorded the server metadata" apart from "the two
  /// timestamps happened to match".
  static DateTime _defaultServerClock() => DateTime.utc(2020, 1, 1);

  /// Injectable server clock used by every write.
  final DateTime Function() clock;

  /// Timestamp the server stamps on the next write.
  DateTime get serverTime => clock();

  final Map<String, List<int>> files = <String, List<int>>{};
  final Set<String> directories = <String>{};
  final Map<String, DateTime> fileModifiedAt = <String, DateTime>{};

  int putCalls = 0;
  int readCalls = 0;
  int statCalls = 0;
  int deleteCalls = 0;
  int listCalls = 0;
  int createCollectionCalls = 0;
  final List<String> putKeys = <String>[];
  final List<String> createdCollections = <String>[];

  /// Test seam: when set, every [put] fails with this error.
  Object? putError;

  /// Test seam: when set, every [stat] fails with this error, so a test can
  /// break the post-upload metadata read-back. Clearing it makes the next run
  /// talk to a healthy server again.
  Object? statError;

  /// Test seam: when set, every listing fails with this error, so a test can
  /// break the remote scan of a run.
  Object? listError;

  /// Test seam: when set, every [delete] fails with this error.
  Object? deleteError;

  /// Test seam: when set, a [read] delivers one chunk and then fails, like a
  /// connection dropped in the middle of a download.
  Object? readErrorAfterFirstChunk;

  /// Test seam: the server keeps only this many bytes of every [put] body (a
  /// PUT that was cut short but answered successfully).
  int? truncatePutsTo;

  /// Test seam: keys a listing never returns, like a provider that drops an
  /// href it cannot map. The object is still there and still downloadable.
  final Set<String> hiddenFromListing = <String>{};

  @override
  RemoteCapabilities get capabilities => RemoteCapabilities.unknown;

  /// Stable per content, like a real entity tag.
  String etagFor(List<int> bytes) =>
      '"${bytes.length}-${Object.hashAll(bytes)}"';

  /// Seeds a file that only exists on the remote side, creating its parents
  /// like a server would for an externally uploaded file.
  void addRemoteFile(String key, List<int> bytes, {DateTime? modifiedAt}) {
    _ensureParents(key);
    files[key] = List<int>.of(bytes);
    fileModifiedAt[key] = modifiedAt ?? serverTime;
  }

  /// Simulates somebody editing the file through the NAS directly; the server
  /// stamps a later timestamp than the original write.
  void modifyRemoteFile(String key, List<int> bytes, {DateTime? modifiedAt}) {
    files[key] = List<int>.of(bytes);
    fileModifiedAt[key] = modifiedAt ?? serverTime.add(const Duration(days: 1));
  }

  void addDirectory(String key) {
    _ensureParents(key);
    directories.add(key);
  }

  List<String> get sortedFileKeys => files.keys.toList()..sort();

  @override
  Future<RemoteObjectMetadata?> stat(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) async {
    statCalls++;
    final failure = statError;
    if (failure != null) throw failure;
    final key = _key(logicalKey);
    if (files.containsKey(key)) return _fileMetadata(key);
    if (directories.contains(key)) return _directoryMetadata(key);
    return null;
  }

  @override
  Future<RemoteObjectPage> list({
    String prefix = '',
    String? cursor,
    int limit = 100,
    RemoteOperationCancellation? cancellation,
  }) async {
    listCalls++;
    final failure = listError;
    if (failure != null) throw failure;
    final directory = _key(prefix);
    final items = <RemoteObjectMetadata>[
      for (final key in directories)
        if (_parentOf(key) == directory && !hiddenFromListing.contains(key))
          _directoryMetadata(key),
      for (final key in files.keys)
        if (_parentOf(key) == directory && !hiddenFromListing.contains(key))
          _fileMetadata(key),
    ]..sort((a, b) => a.logicalKey.compareTo(b.logicalKey));
    // Depth:1 returns the direct children only, and this fake never pages.
    return RemoteObjectPage(items: items.take(limit).toList(growable: false));
  }

  @override
  Stream<List<int>> read(
    String logicalKey, {
    int? start,
    int? endInclusive,
    RemoteOperationCancellation? cancellation,
  }) {
    readCalls++;
    final key = _key(logicalKey);
    final bytes = files[key];
    if (bytes == null) {
      return Stream<List<int>>.error(RemoteObjectNotFoundException(key));
    }
    final from = start ?? 0;
    final to = endInclusive == null || endInclusive >= bytes.length
        ? bytes.length
        : endInclusive + 1;
    final chunk = bytes.sublist(from, to);
    final failure = readErrorAfterFirstChunk;
    if (failure != null) {
      return _failingRead(chunk, failure);
    }
    return Stream<List<int>>.value(chunk);
  }

  /// One chunk followed by the connection error of a dropped download.
  static Stream<List<int>> _failingRead(
    List<int> chunk,
    Object failure,
  ) async* {
    if (chunk.isNotEmpty) yield chunk.sublist(0, 1);
    throw failure;
  }

  @override
  Future<RemoteObjectMetadata> put(
    String logicalKey,
    Stream<List<int>> content, {
    required int contentLength,
    bool ifAbsent = false,
    RemoteOperationCancellation? cancellation,
  }) async {
    putCalls++;
    final key = _key(logicalKey);
    putKeys.add(key);
    final bytes = <int>[];
    await for (final chunk in content) {
      bytes.addAll(chunk);
    }
    final failure = putError;
    if (failure != null) throw failure;
    if (bytes.length != contentLength) {
      throw StateError(
        'PUT $key announced $contentLength bytes but sent ${bytes.length}',
      );
    }
    if (ifAbsent && files.containsKey(key)) {
      throw RemoteObjectAlreadyExistsException(key);
    }
    // A real server answers 409 when a path component is an existing object.
    var ancestor = _parentOf(key);
    while (ancestor.isNotEmpty) {
      if (files.containsKey(ancestor)) throw _RemotePathConflict(ancestor);
      ancestor = _parentOf(ancestor);
    }
    _ensureParents(key);
    final truncateTo = truncatePutsTo;
    files[key] = truncateTo == null || truncateTo >= bytes.length
        ? bytes
        : bytes.sublist(0, truncateTo);
    fileModifiedAt[key] = serverTime;
    return _fileMetadata(key);
  }

  @override
  Future<void> delete(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) async {
    deleteCalls++;
    final failure = deleteError;
    if (failure != null) throw failure;
    final key = _key(logicalKey);
    if (files.remove(key) != null) {
      fileModifiedAt.remove(key);
      return;
    }
    // A collection delete takes its whole subtree with it.
    final prefix = '$key/';
    directories.removeWhere(
      (directory) => directory == key || directory.startsWith(prefix),
    );
    for (final file
        in files.keys.where((file) => file.startsWith(prefix)).toList()) {
      files.remove(file);
      fileModifiedAt.remove(file);
    }
  }

  @override
  Future<void> createCollection(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) async {
    createCollectionCalls++;
    final key = _key(logicalKey);
    final parent = _parentOf(key);
    // MKCOL semantics: a missing parent is rejected, it is never created.
    if (parent.isNotEmpty && !directories.contains(parent)) {
      throw StateError('MKCOL $key rejected: parent collection is missing');
    }
    if (files.containsKey(key)) {
      throw StateError('MKCOL $key rejected: an object already exists');
    }
    createdCollections.add(key);
    directories.add(key);
  }

  RemoteObjectMetadata _fileMetadata(String key) {
    final bytes = files[key]!;
    return RemoteObjectMetadata(
      logicalKey: key,
      size: bytes.length,
      updatedAt: fileModifiedAt[key]!,
      etag: etagFor(bytes),
    );
  }

  RemoteObjectMetadata _directoryMetadata(String key) => RemoteObjectMetadata(
    logicalKey: key,
    size: 0,
    updatedAt: serverTime,
    isDirectory: true,
  );

  void _ensureParents(String key) {
    final parent = _parentOf(key);
    if (parent.isEmpty) return;
    var current = '';
    for (final segment in parent.split('/')) {
      current = current.isEmpty ? segment : '$current/$segment';
      directories.add(current);
    }
  }

  static String _parentOf(String key) {
    final slash = key.lastIndexOf('/');
    return slash < 0 ? '' : key.substring(0, slash);
  }

  static String _key(String value) {
    var key = value;
    while (key.startsWith('/')) {
      key = key.substring(1);
    }
    while (key.endsWith('/')) {
      key = key.substring(0, key.length - 1);
    }
    return key;
  }
}

/// Stands in for the provider conflict a real server answers with when a path
/// component already exists as the other kind (WebDAV: HTTP 409).
class _RemotePathConflict implements SyncFailureException {
  const _RemotePathConflict(this.logicalKey);

  final String logicalKey;

  @override
  String toString() => 'Remote path conflicts with an existing object.';

  @override
  SyncFailure get syncFailure => const SyncFailure(
    errorCode: 'remote.conflict',
    category: SyncErrorCategory.remoteConflict,
    retryable: false,
    suggestedAction: '远端路径与已有对象冲突。',
  );
}

/// Records the planner input the service actually used.
class _CapturingPlanner extends MirrorPlanner {
  Set<String> lastDeferredPaths = const <String>{};
  Set<String> lastIdenticalPaths = const <String>{};
  MirrorListingScope? lastListingScope;
  Set<String>? lastConfirmedDeletions;
  MirrorPlanStats? lastStats;

  @override
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
    Set<String> verifiedIdenticalPaths = const <String>{},
    Set<String> deferredPaths = const <String>{},
  }) {
    final result = super.plan(
      local: local,
      remote: remote,
      baseline: baseline,
      direction: direction,
      conflictPolicy: conflictPolicy,
      now: now,
      initialSyncPolicy: initialSyncPolicy,
      listingScope: listingScope,
      confirmedDeletions: confirmedDeletions,
      verifiedIdenticalPaths: verifiedIdenticalPaths,
      deferredPaths: deferredPaths,
    );
    lastDeferredPaths = deferredPaths;
    lastIdenticalPaths = verifiedIdenticalPaths;
    lastListingScope = listingScope;
    lastConfirmedDeletions = confirmedDeletions;
    lastStats = result.stats;
    return result;
  }
}

class _Connections implements ConnectionRepository {
  String? lastPasswordRef;

  @override
  Future<ConnectionModel?> getConnectionById(String id) async =>
      id == _connectionId ? _connection() : null;

  @override
  Future<String?> readWebDavPassword(String? credentialRef) async {
    lastPasswordRef = credentialRef;
    return 'secret';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ConnectionModel _connection() => ConnectionModel(
  id: _connectionId,
  name: '我的 NAS',
  source: 'source',
  target: 'target',
  protocol: const ProtocolModel.webDav(
    protocolType: WebDavProtocolType.https,
    address: 'https://nas.invalid/base',
    port: '443',
    path: '/entry',
    credentialRef: 'cred-1',
  ),
  createdAt: DateTime.utc(2026, 9, 27),
  updatedAt: DateTime.utc(2026, 9, 27),
  status: ConnectionStatus.active,
);

void main() {
  late SyncStateDatabase database;
  late PlainFolderSyncProfileRepository profiles;
  late _Connections connections;
  late Directory localRoot;
  late _FakeMirrorRemote remote;
  late DateTime clockNow;

  setUp(() async {
    database = await SyncStateDatabase.inMemory();
    profiles = PlainFolderSyncProfileRepository(database);
    connections = _Connections();
    localRoot = await Directory.systemTemp.createTemp('velock-plain-folder-');
    remote = _FakeMirrorRemote(clock: () => DateTime.utc(2020, 1, 1));
    clockNow = DateTime.utc(2026, 9, 27, 12);
  });

  tearDown(() async {
    await database.close();
    if (await localRoot.exists()) await localRoot.delete(recursive: true);
  });

  /// Monotonic clock so `sync_runs.started_at` orders runs deterministically.
  DateTime tick() => clockNow = clockNow.add(const Duration(minutes: 1));

  PlainFolderSyncService service({
    MirrorVerificationBudget verificationBudget =
        const MirrorVerificationBudget(),
    MirrorPlanner? planner,
  }) => PlainFolderSyncService(
    database: database,
    profiles: profiles,
    connections: connections,
    remoteFactory: ({required protocol, required password}) => remote,
    verificationBudget: verificationBudget,
    planner: planner,
    now: tick,
  );

  Future<void> saveProfile({
    MirrorDirection direction = MirrorDirection.bidirectional,
    MirrorConflictPolicy conflictPolicy = MirrorConflictPolicy.keepBoth,
    MirrorInitialSyncPolicy initialSyncPolicy = MirrorInitialSyncPolicy.merge,
  }) => profiles.save(
    PlainFolderSyncProfile(
      profileId: _profileId,
      datasetId: 'dataset-1',
      deviceId: 'device-1',
      displayName: 'Documents',
      localRootReference: localRoot.path,
      localDisplayName: 'documents',
      connectionId: _connectionId,
      direction: direction,
      conflictPolicy: conflictPolicy,
      initialSyncPolicy: initialSyncPolicy,
      createdAt: DateTime.utc(2026, 9, 27),
    ),
  );

  Future<void> writeLocal(
    String relativePath,
    List<int> bytes, {
    DateTime? modifiedAt,
  }) async {
    final file = File(p.join(localRoot.path, relativePath));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    await file.setLastModified(modifiedAt ?? DateTime.utc(2026, 9, 27, 9));
  }

  Future<List<int>> readLocal(String relativePath) =>
      File(p.join(localRoot.path, relativePath)).readAsBytes();

  Future<bool> existsLocal(String relativePath) =>
      File(p.join(localRoot.path, relativePath)).exists();

  Future<void> deleteLocal(String relativePath) =>
      File(p.join(localRoot.path, relativePath)).delete();

  /// Relative paths of every local file whose name contains [needle].
  Future<List<String>> localFilesNamed(String needle) async {
    final matches = <String>[];
    await for (final entity in localRoot.list(recursive: true)) {
      if (entity is! File) continue;
      final relative = p.relative(entity.path, from: localRoot.path);
      if (p.basename(relative).contains(needle)) matches.add(relative);
    }
    matches.sort();
    return matches;
  }

  test(
    'first sync uploads every local file into nested directories and records the file baseline',
    () async {
      await saveProfile();
      final readme = utf8.encode('readme body');
      final today = utf8.encode('today notes');
      final old = utf8.encode('archived notes');
      await writeLocal('readme.txt', readme);
      await writeLocal('notes/today.txt', today);
      await writeLocal('notes/archive/old.txt', old);

      final outcome = await service().run(_profileId);

      // Remote tree mirrors the local one, including the directories.
      expect(remote.sortedFileKeys, <String>[
        'notes/archive/old.txt',
        'notes/today.txt',
        'readme.txt',
      ]);
      expect(remote.files['notes/archive/old.txt'], old);
      expect(
        remote.directories,
        containsAll(<String>['notes', 'notes/archive']),
      );
      expect(remote.putCalls, 3);
      expect(outcome.stats.uploadedFileCount, 3);
      expect(outcome.stats.downloadedFileCount, 0);
      expect(outcome.stats.changedCount, 3);
      expect(outcome.heldDeletions, isNull);

      final run = await database.latestSyncRun(_profileId);
      expect(run!.state, 'completed');
      expect(run.completedAt, isNotNull);

      final stats = await database.readLatestMirrorRunStats(_profileId);
      expect(stats!.uploadedFileCount, 3);
      expect(stats.downloadedFileCount, 0);
      expect(stats.failureCode, isNull);

      final baseline = await database.readMirrorEntries(_profileId);
      expect(baseline.keys, <String>[
        'notes',
        'notes/archive',
        'notes/archive/old.txt',
        'notes/today.txt',
        'readme.txt',
      ]);
      final row = baseline['notes/today.txt']!;
      expect(row.kind, MirrorEntryKind.file);
      expect(row.localSize, today.length);
      expect(row.remoteSize, today.length);
      // The baseline stores what the server reported back, not the local mtime.
      expect(row.remoteModifiedAt, remote.serverTime);
      expect(row.remoteEtag, remote.etagFor(today));
      expect(baseline['notes']!.kind, MirrorEntryKind.directory);
      expect(baseline['notes/archive']!.kind, MirrorEntryKind.directory);
    },
  );

  test(
    'a second run with nothing changed transfers nothing even though the server keeps its own clock',
    () async {
      await saveProfile();
      await writeLocal(
        'readme.txt',
        utf8.encode('readme body'),
        modifiedAt: DateTime.utc(2026, 9, 27, 9),
      );
      await writeLocal(
        'notes/today.txt',
        utf8.encode('today notes'),
        modifiedAt: DateTime.utc(2026, 9, 27, 9, 30),
      );

      await service().run(_profileId);
      final putCallsAfterFirstRun = remote.putCalls;
      final readCallsAfterFirstRun = remote.readCalls;
      final deleteCallsAfterFirstRun = remote.deleteCalls;
      final collectionsAfterFirstRun = remote.createCollectionCalls;

      final second = await service().run(_profileId);

      expect(second.stats.uploadedFileCount, 0);
      expect(second.stats.downloadedFileCount, 0);
      expect(second.stats.deletedLocalCount, 0);
      expect(second.stats.deletedRemoteCount, 0);
      expect(second.stats.changedCount, 0);
      expect(second.conflicts, isEmpty);
      expect(remote.putCalls, putCallsAfterFirstRun);
      expect(remote.readCalls, readCallsAfterFirstRun);
      expect(remote.deleteCalls, deleteCallsAfterFirstRun);
      expect(remote.createCollectionCalls, collectionsAfterFirstRun);
      expect(remote.files, hasLength(2));

      // The two timestamps really are far apart: the run stays quiet because
      // the baseline recorded the server's metadata, not because of the
      // comparison tolerance.
      final row = (await database.readMirrorEntries(_profileId))['readme.txt']!;
      expect(row.remoteModifiedAt, isNot(row.localModifiedAt));
      expect(
        mirrorTimesMatch(row.localModifiedAt, row.remoteModifiedAt),
        isFalse,
        reason: 'the server assigned its own timestamp outside the tolerance',
      );
      expect(remote.files['readme.txt'], utf8.encode('readme body'));
    },
  );

  test(
    'a file that exists only remotely is downloaded with identical bytes',
    () async {
      await saveProfile();
      final bytes = utf8.encode('photo body');
      remote.addRemoteFile(
        'photos/beach.jpg',
        bytes,
        modifiedAt: DateTime.utc(2020, 6, 1),
      );

      final outcome = await service().run(_profileId);

      expect(outcome.stats.downloadedFileCount, 1);
      expect(outcome.stats.uploadedFileCount, 0);
      expect(outcome.stats.deletedLocalCount, 0);
      expect(await readLocal('photos/beach.jpg'), bytes);
      expect(
        await Directory(p.join(localRoot.path, 'photos')).exists(),
        isTrue,
        reason: 'the remote directory is recreated locally',
      );
      expect(remote.readCalls, 1);
      expect(remote.putCalls, 0);

      final baseline = await database.readMirrorEntries(_profileId);
      expect(baseline['photos']!.kind, MirrorEntryKind.directory);
      expect(baseline['photos/beach.jpg']!.remoteSize, bytes.length);
      expect(baseline['photos/beach.jpg']!.remoteEtag, remote.etagFor(bytes));
    },
  );

  test('a locally modified file is uploaded to the remote side', () async {
    await saveProfile();
    final original = utf8.encode('version one');
    await writeLocal(
      'report.txt',
      original,
      modifiedAt: DateTime.utc(2026, 9, 27, 9),
    );
    await service().run(_profileId);
    expect(remote.files['report.txt'], original);
    final putCallsAfterFirstRun = remote.putCalls;

    final edited = utf8.encode('version two, and longer');
    await writeLocal(
      'report.txt',
      edited,
      modifiedAt: DateTime.utc(2026, 9, 27, 11),
    );

    final outcome = await service().run(_profileId);

    expect(outcome.stats.uploadedFileCount, 1);
    expect(outcome.stats.downloadedFileCount, 0);
    expect(remote.putCalls, putCallsAfterFirstRun + 1);
    expect(remote.files['report.txt'], edited);
    expect(
      remote.readCalls,
      0,
      reason: 'an upload never reads the remote file',
    );
    expect(await readLocal('report.txt'), edited);
  });

  test('a remotely modified file is downloaded to the local side', () async {
    await saveProfile();
    await writeLocal(
      'draft.txt',
      utf8.encode('shared draft'),
      modifiedAt: DateTime.utc(2026, 9, 27, 9),
    );
    await service().run(_profileId);
    final putCallsAfterFirstRun = remote.putCalls;

    final remoteEdit = utf8.encode('edited on the NAS');
    remote.modifyRemoteFile('draft.txt', remoteEdit);

    final outcome = await service().run(_profileId);

    expect(outcome.stats.downloadedFileCount, 1);
    expect(outcome.stats.uploadedFileCount, 0);
    expect(await readLocal('draft.txt'), remoteEdit);
    expect(remote.putCalls, putCallsAfterFirstRun);
    expect(remote.readCalls, 1);
  });

  test(
    'a file changed on both sides keeps both versions and records one keepBoth conflict',
    () async {
      await saveProfile();
      await writeLocal(
        'notes.txt',
        utf8.encode('base'),
        modifiedAt: DateTime.utc(2026, 9, 27, 9),
      );
      await service().run(_profileId);

      final localEdit = utf8.encode('local edit, a bit longer');
      final remoteEdit = utf8.encode('remote edit!');
      await writeLocal(
        'notes.txt',
        localEdit,
        modifiedAt: DateTime.utc(2026, 9, 27, 11),
      );
      remote.modifyRemoteFile('notes.txt', remoteEdit);

      final outcome = await service().run(_profileId);

      // The remote version wins the original path, the local version survives
      // beside it: nothing is lost.
      expect(await readLocal('notes.txt'), remoteEdit);
      expect(remote.files['notes.txt'], remoteEdit);
      final copies = await localFilesNamed('本机冲突');
      expect(copies, hasLength(1));
      expect(copies.single, startsWith('notes (本机冲突'));
      expect(copies.single, endsWith(').txt'));
      expect(await readLocal(copies.single), localEdit);

      final conflicts = await database.readMirrorConflicts(_profileId);
      expect(conflicts, hasLength(1));
      expect(conflicts.single.relativePath, 'notes.txt');
      expect(conflicts.single.kind, MirrorConflictKind.bothModified);
      expect(conflicts.single.resolution, MirrorConflictResolution.keepBoth);
      expect(outcome.stats.conflictCount, 1);
      expect(outcome.stats.downloadedFileCount, 1);
      expect(
        remote.putCalls,
        1,
        reason: 'the conflict is resolved by a download',
      );
    },
  );

  test(
    'a locally deleted file is deleted remotely and loses its baseline row',
    () async {
      await saveProfile();
      await writeLocal(
        'gone.txt',
        utf8.encode('delete me'),
        modifiedAt: DateTime.utc(2026, 9, 27, 9),
      );
      await writeLocal(
        'keep.txt',
        utf8.encode('keep me'),
        modifiedAt: DateTime.utc(2026, 9, 27, 9),
      );
      await service().run(_profileId);

      await deleteLocal('gone.txt');
      final outcome = await service().run(_profileId);

      expect(outcome.stats.deletedRemoteCount, 1);
      expect(outcome.heldDeletions, isNull);
      expect(remote.deleteCalls, 1);
      expect(remote.files.containsKey('gone.txt'), isFalse);
      expect(remote.files.containsKey('keep.txt'), isTrue);
      expect(await existsLocal('gone.txt'), isFalse);

      final baseline = await database.readMirrorEntries(_profileId);
      expect(baseline.containsKey('gone.txt'), isFalse);
      expect(baseline.containsKey('keep.txt'), isTrue);
      expect(baseline, hasLength(1));
    },
  );

  test(
    'deletion protection holds 6 of 10 deletions and reports them instead of deleting',
    () async {
      await saveProfile();
      for (var index = 1; index <= 10; index++) {
        await writeLocal(
          'f${index.toString().padLeft(2, '0')}.txt',
          utf8.encode('file $index'),
          modifiedAt: DateTime.utc(2026, 9, 27, 9),
        );
      }
      await service().run(_profileId);
      expect(remote.files, hasLength(10));
      expect(await database.readMirrorEntries(_profileId), hasLength(10));

      for (var index = 1; index <= 6; index++) {
        await deleteLocal('f${index.toString().padLeft(2, '0')}.txt');
      }

      final held = await service().run(_profileId);

      expect(held.heldDeletions, isNotNull);
      expect(held.heldDeletionCount, 6);
      expect(held.heldDeletions!.knownEntryCount, 10);
      expect(held.heldDeletions!.limit, 2, reason: '20% of a 10 row baseline');
      expect(held.stats.heldDeletionCount, 6);
      expect(held.stats.deletedRemoteCount, 0);
      expect(remote.deleteCalls, 0, reason: 'nothing is deleted while held');
      expect(remote.files, hasLength(10));
      expect((await database.latestSyncRun(_profileId))!.state, 'completed');

      // A withheld deletion keeps its baseline row (design §4.4): dropping it
      // would make the confirmed rerun treat the remote copy as a brand new
      // remote-only file and download it again, silently undoing the deletion.
      final afterHeld = await database.readMirrorEntries(_profileId);
      expect(afterHeld, hasLength(10));
      expect(afterHeld.containsKey('f01.txt'), isTrue);

      final confirmed = await service().runConfirmedDeletions(
        _profileId,
        held.heldDeletionPaths,
      );

      expect(confirmed.heldDeletions, isNull);
      expect(confirmed.stats.deletedRemoteCount, 6);
      expect(confirmed.stats.downloadedFileCount, 0);
      expect(remote.deleteCalls, 6);
      expect(remote.sortedFileKeys, <String>[
        'f07.txt',
        'f08.txt',
        'f09.txt',
        'f10.txt',
      ]);
      for (var index = 1; index <= 6; index++) {
        expect(
          await existsLocal('f${index.toString().padLeft(2, '0')}.txt'),
          isFalse,
          reason: 'the confirmed deletion is never undone by a download',
        );
      }
      expect(await database.readMirrorEntries(_profileId), hasLength(4));
    },
  );

  test(
    'uploadOnly uploads local files and propagates local deletions but leaves remote-only files alone',
    () async {
      await saveProfile(direction: MirrorDirection.uploadOnly);
      await writeLocal(
        'local-a.txt',
        utf8.encode('a'),
        modifiedAt: DateTime.utc(2026, 9, 27, 9),
      );
      await service().run(_profileId);
      expect(remote.files.containsKey('local-a.txt'), isTrue);

      await deleteLocal('local-a.txt');
      await writeLocal(
        'local-b.txt',
        utf8.encode('b'),
        modifiedAt: DateTime.utc(2026, 9, 27, 10),
      );
      remote.addRemoteFile(
        'remote-c.txt',
        utf8.encode('c'),
        modifiedAt: DateTime.utc(2020, 3, 3),
      );

      final outcome = await service().run(_profileId);

      expect(
        remote.files.containsKey('local-a.txt'),
        isFalse,
        reason: 'a local delete is propagated to the remote side',
      );
      expect(remote.files['local-b.txt'], utf8.encode('b'));
      expect(
        remote.files.containsKey('remote-c.txt'),
        isTrue,
        reason: 'uploadOnly never deletes a remote-only file',
      );
      expect(
        await existsLocal('remote-c.txt'),
        isFalse,
        reason: 'uploadOnly never downloads a remote-only file',
      );
      expect(outcome.stats.uploadedFileCount, 1);
      expect(outcome.stats.deletedRemoteCount, 1);
      expect(outcome.stats.downloadedFileCount, 0);
      expect(outcome.stats.deletedLocalCount, 0);
      expect(
        outcome.stats.skippedCount,
        1,
        reason: 'the remote-only file is skipped',
      );
      expect(remote.readCalls, 0);
    },
  );

  test(
    'downloadOnly reverts a locally modified file and leaves a local-only file untouched',
    () async {
      await saveProfile(direction: MirrorDirection.downloadOnly);
      // The remote side is the only source of truth, so the first run pulls the
      // file down and establishes the baseline the later revert compares to.
      final remoteVersion = utf8.encode('remote truth');
      remote.addRemoteFile(
        'shared.txt',
        remoteVersion,
        modifiedAt: DateTime.utc(2020, 2, 2),
      );
      await service().run(_profileId);
      expect(await readLocal('shared.txt'), remoteVersion);
      expect(remote.putCalls, 0);

      await writeLocal(
        'shared.txt',
        utf8.encode('local rewrite that must be reverted'),
        modifiedAt: DateTime.utc(2026, 9, 27, 11),
      );
      final localOnly = utf8.encode('never synced locally');
      await writeLocal(
        'draft-local.txt',
        localOnly,
        modifiedAt: DateTime.utc(2026, 9, 27, 11),
      );

      final outcome = await service().run(_profileId);

      expect(await readLocal('shared.txt'), remoteVersion);
      expect(outcome.stats.downloadedFileCount, 1);
      expect(outcome.stats.uploadedFileCount, 0);
      expect(remote.putCalls, 0, reason: 'downloadOnly never uploads');
      expect(
        await existsLocal('draft-local.txt'),
        isTrue,
        reason: 'a local-only file is not deleted by downloadOnly',
      );
      expect(await readLocal('draft-local.txt'), localOnly);
      expect(remote.files.containsKey('draft-local.txt'), isFalse);
      expect(outcome.stats.skippedCount, 1);
      expect(outcome.stats.deletedLocalCount, 0);
    },
  );

  test(
    'checkRemoteWritable writes and removes exactly one probe file',
    () async {
      await saveProfile();

      await service().checkRemoteWritable(_profileId);

      expect(remote.putCalls, 1);
      expect(remote.deleteCalls, 1);
      expect(remote.readCalls, 0, reason: 'the probe is verified with stat');
      expect(remote.putKeys, hasLength(1));
      expect(remote.putKeys.single, contains('.velock-sync-probe'));
      expect(remote.putKeys.single, endsWith('.tmp'));
      expect(
        remote.files.keys.where((key) => key.contains('.velock-sync-probe')),
        isEmpty,
        reason: 'the probe never stays behind',
      );
      expect(remote.files, isEmpty);
      expect(remote.directories, isEmpty);
      expect(connections.lastPasswordRef, 'cred-1');
    },
  );

  test(
    'a failing upload rethrows and records a failed run with its failure code',
    () async {
      await saveProfile();
      await writeLocal(
        'broken.txt',
        utf8.encode('payload'),
        modifiedAt: DateTime.utc(2026, 9, 27, 9),
      );
      remote.putError = const RemoteObjectNotFoundException('broken.txt');

      await expectLater(
        service().run(_profileId),
        throwsA(isA<RemoteObjectNotFoundException>()),
      );

      final run = await database.latestSyncRun(_profileId);
      expect(run!.state, 'failed');
      expect(run.errorCode, 'remote.object_not_found');
      expect(run.completedAt, isNotNull);

      final stats = await database.readLatestMirrorRunStats(_profileId);
      expect(stats, isNotNull);
      expect(stats!.failureCode, isNotNull);
      expect(stats.failureCode, 'remote.object_not_found');
      expect(stats.uploadedFileCount, 0);
      expect(remote.files, isEmpty);
      expect(
        await existsLocal('broken.txt'),
        isTrue,
        reason: 'a failed upload never touches the local source',
      );
    },
  );

  test('empty directories are mirrored in both directions', () async {
    await saveProfile();
    await Directory(p.join(localRoot.path, 'empty-local')).create();
    remote.addDirectory('empty-remote');

    final outcome = await service().run(_profileId);

    expect(remote.directories, contains('empty-local'));
    expect(remote.createdCollections, <String>['empty-local']);
    expect(
      await Directory(p.join(localRoot.path, 'empty-remote')).exists(),
      isTrue,
      reason: 'the remote-only empty directory is recreated locally',
    );
    expect(outcome.stats.uploadedFileCount, 0);
    expect(outcome.stats.downloadedFileCount, 0);

    final baseline = await database.readMirrorEntries(_profileId);
    expect(baseline.keys, <String>['empty-local', 'empty-remote']);
    expect(baseline['empty-local']!.kind, MirrorEntryKind.directory);
    expect(baseline['empty-remote']!.kind, MirrorEntryKind.directory);
  });

  test(
    'a zero-file verification budget defers an ambiguous pair instead of inventing a conflict copy',
    () async {
      await saveProfile();
      final localBytes = utf8.encode('AAAA');
      final remoteBytes = utf8.encode('BBBB');
      await writeLocal(
        'ambiguous.bin',
        localBytes,
        modifiedAt: DateTime.utc(2026, 9, 27, 9),
      );
      remote.addRemoteFile(
        'ambiguous.bin',
        remoteBytes,
        modifiedAt: DateTime.utc(2020, 1, 1),
      );

      final planner = _CapturingPlanner();
      final outcome = await service(
        verificationBudget: const MirrorVerificationBudget(maxFiles: 0),
        planner: planner,
      ).run(_profileId);

      expect(planner.lastDeferredPaths, contains('ambiguous.bin'));
      expect(planner.lastStats!.deferredCount, greaterThanOrEqualTo(1));
      expect(outcome.stats.skippedCount, greaterThanOrEqualTo(1));
      expect(outcome.conflicts, isEmpty);
      expect(outcome.stats.conflictCount, 0);
      expect(remote.readCalls, 0, reason: 'a deferred pair is not read back');
      expect(remote.putCalls, 0);
      expect(await readLocal('ambiguous.bin'), localBytes);
      expect(remote.files['ambiguous.bin'], remoteBytes);
      expect(await localFilesNamed('本机冲突'), isEmpty);
      expect(await database.readMirrorConflicts(_profileId), isEmpty);

      // A deferral delays the decision, it does not drop it: the next run with
      // a normal budget reads both sides and resolves the pair.
      final second = await service().run(_profileId);
      expect(second.stats.conflictCount, 1);
      expect(await readLocal('ambiguous.bin'), remoteBytes);
      final copies = await localFilesNamed('本机冲突');
      expect(copies, hasLength(1));
      expect(await readLocal(copies.single), localBytes);
    },
  );

  test(
    'a verified identical pair is baselined once and is not re-read',
    () async {
      await saveProfile();
      // Identical bytes with timestamps far apart: only a content read can
      // prove that this pair is already in sync.
      final bytes = utf8.encode('the same bytes on both sides');
      final remoteModifiedAt = DateTime.utc(2020, 1, 1);
      await writeLocal(
        'parity.txt',
        bytes,
        modifiedAt: DateTime.utc(2026, 9, 27, 9),
      );
      remote.addRemoteFile('parity.txt', bytes, modifiedAt: remoteModifiedAt);

      final first = await service().run(_profileId);

      expect(
        remote.readCalls,
        1,
        reason: 'the far-apart timestamps force one content verification',
      );
      expect(first.stats.uploadedFileCount, 0);
      expect(first.stats.downloadedFileCount, 0);
      expect(first.stats.changedCount, 0);
      expect(first.conflicts, isEmpty);
      expect(first.stats.conflictCount, 0);
      expect(remote.putCalls, 0);
      expect(
        await localFilesNamed('本机冲突'),
        isEmpty,
        reason: 'a proven-identical pair is not a conflict',
      );

      // The proof is finished work: the run must record the baseline from the
      // remote's own metadata instead of leaving the path without a row.
      final baseline = await database.readMirrorEntries(_profileId);
      final row = baseline['parity.txt']!;
      expect(row.kind, MirrorEntryKind.file);
      expect(row.remoteSize, bytes.length);
      expect(row.remoteModifiedAt, remoteModifiedAt);
      expect(row.remoteEtag, isNotNull);
      expect(row.remoteEtag, remote.etagFor(bytes));
      expect(remote.fileModifiedAt['parity.txt'], remoteModifiedAt);

      final putCallsAfterFirstRun = remote.putCalls;
      final readCallsAfterFirstRun = remote.readCalls;

      final second = await service().run(_profileId);

      expect(second.stats.uploadedFileCount, 0);
      expect(second.stats.downloadedFileCount, 0);
      expect(
        remote.readCalls,
        readCallsAfterFirstRun,
        reason: 'a baselined pair is never re-verified forever',
      );
      expect(remote.putCalls, putCallsAfterFirstRun);
      expect(await readLocal('parity.txt'), bytes);
      expect(remote.files['parity.txt'], bytes);

      // Mirror image of the same defect: a deferred pair was never *proven*
      // equal, so that run must not baseline it as if it had been.
      final deferredBytes = utf8.encode('deferred but identical');
      await writeLocal(
        'deferred.txt',
        deferredBytes,
        modifiedAt: DateTime.utc(2026, 9, 27, 9),
      );
      remote.addRemoteFile(
        'deferred.txt',
        deferredBytes,
        modifiedAt: DateTime.utc(2020, 1, 1),
      );

      final deferred = await service(
        verificationBudget: const MirrorVerificationBudget(maxFiles: 0),
      ).run(_profileId);

      expect(deferred.stats.skippedCount, greaterThanOrEqualTo(1));
      expect(remote.readCalls, readCallsAfterFirstRun);
      expect(
        (await database.readMirrorEntries(
          _profileId,
        )).containsKey('deferred.txt'),
        isFalse,
        reason: 'a deferred pair was never proven equal, so it gets no row',
      );
    },
  );

  test(
    'a failed remote stat after upload does not fabricate a baseline and does not re-download',
    () async {
      await saveProfile();
      final bytes = utf8.encode('uploaded once, never pulled back');
      final localFile = File(p.join(localRoot.path, 'report.txt'));
      await writeLocal(
        'report.txt',
        bytes,
        modifiedAt: DateTime.utc(2026, 9, 27, 9),
      );
      final localModifiedAtBeforeRun = await localFile.lastModified();

      // The server accepts the upload but the metadata read-back fails, so the
      // engine never learns the remote timestamp or etag.
      remote.statError = const RemoteObjectNotFoundException('report.txt');

      final first = await service().run(_profileId);

      expect(remote.putKeys, <String>['report.txt']);
      expect(remote.putCalls, 1);
      expect(first.stats.uploadedFileCount, 1);
      expect(
        remote.statCalls,
        1,
        reason: 'the read-back after the upload was attempted and failed',
      );
      expect((await database.latestSyncRun(_profileId))!.state, 'completed');
      expect(
        await database.readMirrorEntries(_profileId),
        isEmpty,
        reason: 'the local metadata must never be stored as the remote one',
      );

      // Healthy server again: the run must prove the pair identical by content
      // instead of downloading back the file it just uploaded.
      remote.statError = null;
      final readCallsAfterFirstRun = remote.readCalls;

      final second = await service().run(_profileId);

      expect(
        second.stats.downloadedFileCount,
        0,
        reason: 'the upload must not come back as a download',
      );
      expect(second.stats.uploadedFileCount, 0);
      expect(second.stats.changedCount, 0);
      expect(remote.putCalls, 1);
      expect(
        remote.readCalls,
        readCallsAfterFirstRun + 1,
        reason: 'identity is proven by one content read, never by a download',
      );
      expect(await readLocal('report.txt'), bytes);
      expect(
        await localFile.lastModified(),
        localModifiedAtBeforeRun,
        reason: 'no download rewrote the local file',
      );

      // Only now, with the remote metadata known, does the pair get its row.
      final row = (await database.readMirrorEntries(_profileId))['report.txt']!;
      expect(row.kind, MirrorEntryKind.file);
      expect(row.remoteSize, bytes.length);
      expect(row.remoteModifiedAt, remote.fileModifiedAt['report.txt']);
      expect(row.remoteEtag, remote.etagFor(bytes));

      // The row makes the location converge: another run transfers nothing.
      final readCallsAfterSecondRun = remote.readCalls;
      final third = await service().run(_profileId);

      expect(third.stats.uploadedFileCount, 0);
      expect(third.stats.downloadedFileCount, 0);
      expect(remote.readCalls, readCallsAfterSecondRun);
      expect(await readLocal('report.txt'), bytes);
      expect(await localFile.lastModified(), localModifiedAtBeforeRun);
    },
  );

  test(
    'a truncated upload fails the run, leaves no baseline and is re-uploaded',
    () async {
      await saveProfile();
      final bytes = utf8.encode('a body the server only kept a part of');
      await writeLocal(
        'report.txt',
        bytes,
        modifiedAt: DateTime.utc(2026, 9, 27, 9),
      );
      // The PUT is answered with success, but the server kept a shorter body:
      // exactly what a connection dropped mid-PUT leaves behind.
      remote.truncatePutsTo = 4;

      await expectLater(
        service().run(_profileId),
        throwsA(
          isA<PlainFolderSyncException>().having(
            (error) => error.syncFailure.errorCode,
            'errorCode',
            'plain_folder.upload_incomplete',
          ),
        ),
      );

      expect(remote.putCalls, 1);
      expect(
        await database.readMirrorEntries(_profileId),
        isEmpty,
        reason: 'a truncated object must never become the baseline',
      );
      final run = await database.latestSyncRun(_profileId);
      expect(run!.state, 'failed');
      expect(run.errorCode, 'plain_folder.upload_incomplete');
      final stats = await database.readLatestMirrorRunStats(_profileId);
      expect(stats!.failureCode, 'plain_folder.upload_incomplete');
      expect(stats.uploadedFileCount, 0);
      expect(stats.bytesTransferred, 0, reason: 'the upload never finished');
      expect(
        remote.files.containsKey('report.txt'),
        isFalse,
        reason: 'the partial object is removed so the next run re-uploads',
      );
      expect(await existsLocal('report.txt'), isTrue);

      // Healthy server again: the next run plans the same upload again and
      // records the baseline from the verified metadata.
      remote.truncatePutsTo = null;
      final second = await service().run(_profileId);

      expect(remote.putCalls, 2, reason: 'the second run re-uploads the file');
      expect(second.stats.uploadedFileCount, 1);
      expect(remote.files['report.txt'], bytes);
      final row = (await database.readMirrorEntries(_profileId))['report.txt']!;
      expect(row.remoteSize, bytes.length);
      expect(row.remoteEtag, remote.etagFor(bytes));
    },
  );

  test(
    'a truncated upload whose cleanup fails still reports the upload failure',
    () async {
      await saveProfile();
      await writeLocal(
        'report.txt',
        utf8.encode('another body that was cut short'),
        modifiedAt: DateTime.utc(2026, 9, 27, 9),
      );
      remote.truncatePutsTo = 3;
      remote.deleteError = StateError('cleanup refused');

      await expectLater(
        service().run(_profileId),
        throwsA(
          isA<PlainFolderSyncException>().having(
            (error) => error.syncFailure.errorCode,
            'errorCode',
            'plain_folder.upload_incomplete',
          ),
        ),
      );

      expect(
        remote.files.containsKey('report.txt'),
        isTrue,
        reason: 'the cleanup is best effort: a failed delete cannot undo it',
      );
      expect(
        (await database.latestSyncRun(_profileId))!.errorCode,
        'plain_folder.upload_incomplete',
        reason: 'the failed cleanup never masks the real failure',
      );
      expect(await database.readMirrorEntries(_profileId), isEmpty);
    },
  );

  test('a failed download reports no bytes it never moved', () async {
    await saveProfile();
    final bytes = utf8.encode('remote photo body');
    remote.addRemoteFile(
      'photo.jpg',
      bytes,
      modifiedAt: DateTime.utc(2020, 1, 1),
    );
    // The connection drops after the first chunk.
    remote.readErrorAfterFirstChunk = StateError('connection dropped');

    await expectLater(service().run(_profileId), throwsA(anything));

    final stats = await database.readLatestMirrorRunStats(_profileId);
    expect(stats!.failureCode, isNotNull);
    expect(stats.downloadedFileCount, 0);
    expect(
      stats.bytesTransferred,
      0,
      reason: 'a failed transfer must not report bytes it never moved',
    );
    expect(await existsLocal('photo.jpg'), isFalse);

    // The same file with a healthy connection is counted for real.
    remote.readErrorAfterFirstChunk = null;
    final second = await service().run(_profileId);

    expect(second.stats.downloadedFileCount, 1);
    expect(second.stats.bytesTransferred, bytes.length);
    expect(await readLocal('photo.jpg'), bytes);
  });

  test('a failed run keeps the pending held-deletion count', () async {
    await saveProfile();
    for (var index = 1; index <= 10; index++) {
      await writeLocal(
        'f${index.toString().padLeft(2, '0')}.txt',
        utf8.encode('file $index'),
        modifiedAt: DateTime.utc(2026, 9, 27, 9),
      );
    }
    await service().run(_profileId);
    for (var index = 1; index <= 6; index++) {
      await deleteLocal('f${index.toString().padLeft(2, '0')}.txt');
    }
    final held = await service().run(_profileId);
    expect(held.heldDeletionCount, 6);
    expect(
      (await database.readLatestMirrorRunStats(_profileId))!.heldDeletionCount,
      6,
    );

    // The next run cannot even read the remote folder, so it fails before the
    // deletion phase: the deletions waiting for confirmation must survive.
    remote.listError = StateError('nas offline');
    await expectLater(service().run(_profileId), throwsA(anything));

    final failed = await database.readLatestMirrorRunStats(_profileId);
    expect(failed!.failureCode, isNotNull);
    expect(
      failed.heldDeletionCount,
      6,
      reason: 'a failed run must not clear a pending confirmation',
    );
    expect((await database.latestSyncRun(_profileId))!.state, 'failed');

    // The state is honest, not stuck: the healthy rerun reports the same six.
    remote.listError = null;
    final rerun = await service().run(_profileId);
    expect(rerun.heldDeletionCount, 6);
  });

  test(
    'an empty remote listing with a baseline never deletes local files',
    () async {
      await saveProfile();
      await writeLocal(
        'keep-a.txt',
        utf8.encode('a'),
        modifiedAt: DateTime.utc(2026, 9, 27, 9),
      );
      await writeLocal(
        'keep-b.txt',
        utf8.encode('b'),
        modifiedAt: DateTime.utc(2026, 9, 27, 9),
      );
      await service().run(_profileId);
      expect(await database.readMirrorEntries(_profileId), hasLength(2));

      // The share is unmounted / the folder was renamed: the root listing simply
      // comes back with nothing, and the old code read that as "delete everything
      // locally" because two baseline rows are below the fraction minimum.
      remote.files.clear();
      remote.directories.clear();

      await expectLater(
        service().run(_profileId),
        throwsA(
          isA<PlainFolderSyncException>().having(
            (error) => error.syncFailure.errorCode,
            'errorCode',
            'plain_folder.remote_folder_missing',
          ),
        ),
      );

      expect(remote.deleteCalls, 0);
      expect(await existsLocal('keep-a.txt'), isTrue);
      expect(await existsLocal('keep-b.txt'), isTrue);
      expect(
        await database.readMirrorEntries(_profileId),
        hasLength(2),
        reason: 'the baseline survives an unreadable remote folder',
      );
      expect((await database.latestSyncRun(_profileId))!.state, 'failed');
    },
  );

  test(
    'a store 404 while listing becomes the missing remote folder code',
    () async {
      await saveProfile();
      await writeLocal(
        'a.txt',
        utf8.encode('a'),
        modifiedAt: DateTime.utc(2026, 9, 27, 9),
      );
      // The store no longer turns a PROPFIND 404 into an empty page.
      remote.listError = const RemoteObjectNotFoundException('');

      await expectLater(
        service().run(_profileId),
        throwsA(
          isA<PlainFolderSyncException>().having(
            (error) => error.syncFailure.errorCode,
            'errorCode',
            'plain_folder.remote_folder_missing',
          ),
        ),
      );
      expect(remote.deleteCalls, 0);
      expect(await existsLocal('a.txt'), isTrue);
    },
  );

  test(
    'a directory the remote never listed cannot take the local folder',
    () async {
      await saveProfile();
      await writeLocal(
        'photos/a.jpg',
        utf8.encode('beach'),
        modifiedAt: DateTime.utc(2026, 9, 27, 9),
      );
      await writeLocal(
        'notes/b.txt',
        utf8.encode('note'),
        modifiedAt: DateTime.utc(2026, 9, 27, 9),
      );
      await service().run(_profileId);
      expect(remote.files, hasLength(2));

      // A provider that drops the href of one directory: the folder and its file
      // are still there, but this run never saw them. Reading that as a deletion
      // would recursively remove the local folder.
      remote.hiddenFromListing.add('photos');
      final planner = _CapturingPlanner();

      final outcome = await service(planner: planner).run(_profileId);

      expect(planner.lastListingScope!.listsRemote('photos'), isFalse);
      expect(outcome.stats.deletedLocalCount, 0);
      expect(
        outcome.stats.skippedCount,
        greaterThanOrEqualTo(1),
        reason: 'the file under the unread directory is reported as skipped',
      );
      expect(
        outcome.heldDeletionPaths,
        contains('photos'),
        reason: 'a recursive folder delete needs an explicit confirmation',
      );
      expect(await existsLocal('photos/a.jpg'), isTrue);
      expect(await readLocal('photos/a.jpg'), utf8.encode('beach'));
      expect(remote.files.containsKey('photos/a.jpg'), isTrue);
      final baseline = await database.readMirrorEntries(_profileId);
      expect(baseline.containsKey('photos'), isTrue);
      expect(baseline.containsKey('photos/a.jpg'), isTrue);
      expect((await database.latestSyncRun(_profileId))!.state, 'completed');

      // Confirming the folder path is what really deletes it.
      final confirmed = await service().runConfirmedDeletions(
        _profileId,
        outcome.heldDeletionPaths,
      );

      expect(confirmed.stats.deletedLocalCount, 1);
      expect(
        await Directory(p.join(localRoot.path, 'photos')).exists(),
        isFalse,
      );
      expect(remote.files.containsKey('notes/b.txt'), isTrue);
    },
  );

  test('only the confirmed deletions run and the rest is held again', () async {
    await saveProfile();
    for (var index = 1; index <= 10; index++) {
      await writeLocal(
        'f${index.toString().padLeft(2, '0')}.txt',
        utf8.encode('file $index'),
        modifiedAt: DateTime.utc(2026, 9, 27, 9),
      );
    }
    await service().run(_profileId);
    for (var index = 1; index <= 6; index++) {
      await deleteLocal('f${index.toString().padLeft(2, '0')}.txt');
    }
    final held = await service().run(_profileId);
    expect(held.heldDeletionPaths, hasLength(6));

    // The legacy flag cannot name the paths the user was shown, so it approves
    // nothing at all.
    final legacy = await service().run(_profileId, allowDeletions: true);
    expect(legacy.stats.deletedRemoteCount, 0);
    expect(remote.deleteCalls, 0);
    expect(legacy.heldDeletionCount, 6);

    // Three of the six paths are confirmed: exactly those three are deleted and
    // the other three stay held with their baseline rows.
    final confirmedPaths = held.heldDeletionPaths.toList()..sort();
    final partial = await service().runConfirmedDeletions(
      _profileId,
      confirmedPaths.take(3).toSet(),
    );

    expect(partial.stats.deletedRemoteCount, 3);
    expect(remote.deleteCalls, 3);
    expect(partial.heldDeletionPaths, confirmedPaths.skip(3).toSet());
    final baseline = await database.readMirrorEntries(_profileId);
    for (final path in confirmedPaths.take(3)) {
      expect(baseline.containsKey(path), isFalse);
    }
    for (final path in confirmedPaths.skip(3)) {
      expect(baseline.containsKey(path), isTrue);
    }

    final rest = await service().runConfirmedDeletions(
      _profileId,
      partial.heldDeletionPaths,
    );
    expect(rest.stats.deletedRemoteCount, 3);
    expect(rest.heldDeletions, isNull);
    expect(remote.sortedFileKeys, ['f07.txt', 'f08.txt', 'f09.txt', 'f10.txt']);
  });

  test(
    'a file on one side and a directory on the other is a visible conflict',
    () async {
      await saveProfile();
      await writeLocal(
        'clash/child.txt',
        utf8.encode('child'),
        modifiedAt: DateTime.utc(2026, 9, 27, 9),
      );
      // The two sides disagree about what `clash` is. Transferring the child
      // would collide with the remote file, which servers answer with a
      // folder-level 409.
      remote.addRemoteFile(
        'clash',
        utf8.encode('a file where the local side has a folder'),
        modifiedAt: DateTime.utc(2020, 1, 1),
      );

      final outcome = await service().run(_profileId);

      expect(
        outcome.stats.uploadedFileCount,
        0,
        reason: 'nothing is transferred across a kind clash',
      );
      expect(remote.putCalls, 0);
      expect(remote.files['clash'], isNotNull);
      expect(await existsLocal('clash/child.txt'), isTrue);
      expect(await readLocal('clash/child.txt'), utf8.encode('child'));
      final conflicts = await database.readMirrorConflicts(_profileId);
      expect(conflicts, hasLength(1));
      expect(conflicts.single.relativePath, 'clash');
      expect(outcome.stats.conflictCount, 1);
      expect(
        (await database.latestSyncRun(_profileId))!.state,
        'completed',
        reason: 'a per-path kind clash never fails the whole run',
      );
      expect(
        await database.readMirrorEntries(_profileId),
        isEmpty,
        reason: 'a clash is never recorded as in sync',
      );
    },
  );
}
