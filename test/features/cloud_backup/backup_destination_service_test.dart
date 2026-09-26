import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/features/cloud_backup/application/backup_destination_service.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';

void main() {
  late _RecordingStore remote;
  late BackupDestinationService service;
  setUp(() {
    remote = _RecordingStore();
    service = BackupDestinationService(
      open: (_) async => remote,
      nextId: () => 'unique-test',
    );
  });
  Future<void> check({
    bool restoring = false,
    List<String> remoteRootSegments = const [],
  }) => service.check(
    connectionId: 'cloud',
    vaultId: 'original-account',
    trustedProducerIds: ['trusted-device'],
    restoring: restoring,
    remoteRootSegments: remoteRootSegments,
  );
  Future<void> seed(String key) =>
      remote.put(key, Stream.value([1, 2]), contentLength: 2);

  test('write/read/delete check preserves existing backup bytes', () async {
    const original = 'velock-sync/v1/original-account/keep.blob';
    await seed(original);
    remote.writes.clear();
    await check();
    expect(remote.writes, ['velock-sync/preflight/unique-test.probe']);
    expect(remote.deletes, remote.writes);
    expect((await remote.list()).items.single.logicalKey, original);
    expect(await remote.read(original).expand((v) => v).toList(), [1, 2]);
  });
  test('collision is never removed or overwritten', () async {
    const key = 'velock-sync/preflight/unique-test.probe';
    await seed(key);
    await expectLater(
      check(),
      throwsA(isA<RemoteObjectAlreadyExistsException>()),
    );
    expect(remote.deletes, isEmpty);
    expect(await remote.read(key).expand((v) => v).toList(), [1, 2]);
  });
  test('failed readback fails closed and cleans only its own probe', () async {
    remote.corrupt = true;
    await expectLater(check(), throwsA(isA<BackupDestinationException>()));
    expect((await remote.list()).items, isEmpty);
    expect(remote.deletes, ['velock-sync/preflight/unique-test.probe']);
  });
  test(
    'oversized readback fails closed and preserves original backup bytes',
    () async {
      const original = 'velock-sync/v1/original-account/keep.blob';
      await seed(original);
      remote.writes.clear();
      remote.oversizedProbeRead = true;

      await expectLater(
        check(),
        throwsA(
          isA<BackupDestinationException>().having(
            (e) => e.code,
            'code',
            'readback_failed',
          ),
        ),
      );

      expect(remote.writes, ['velock-sync/preflight/unique-test.probe']);
      expect(remote.deletes, remote.writes);
      expect((await remote.list()).items.single.logicalKey, original);
      expect(await remote.read(original).expand((v) => v).toList(), [1, 2]);
    },
  );
  test('open timeout fails closed without writes or deletes', () async {
    final pendingOpen = Completer<RemoteObjectStore>();
    service = BackupDestinationService(
      open: (_) => pendingOpen.future,
      nextId: () => 'unique-test',
      timeout: const Duration(milliseconds: 50),
    );

    await expectLater(check(), throwsA(isA<TimeoutException>()));
    expect(remote.writes, isEmpty);
    expect(remote.deletes, isEmpty);
    pendingOpen.complete(remote);
  });
  test('hanging read after put cleans only the created probe', () async {
    const original = 'velock-sync/v1/original-account/keep.blob';
    await seed(original);
    remote.writes.clear();
    final readController = StreamController<List<int>>();
    remote.hangingProbeRead = readController.stream;
    service = BackupDestinationService(
      open: (_) async => remote,
      nextId: () => 'unique-test',
      timeout: const Duration(milliseconds: 50),
    );

    await expectLater(check(), throwsA(isA<TimeoutException>()));

    expect(remote.writes, ['velock-sync/preflight/unique-test.probe']);
    expect(remote.deletes, remote.writes);
    expect((await remote.list()).items.single.logicalKey, original);
    expect(await remote.read(original).expand((v) => v).toList(), [1, 2]);
    await readController.close();
  });
  test(
    'empty restore location is rejected without any writes or deletes',
    () async {
      await expectLater(
        check(restoring: true),
        throwsA(
          isA<BackupDestinationException>().having(
            (e) => e.code,
            'code',
            'backup_not_found',
          ),
        ),
      );
      expect(remote.writes, isEmpty);
      expect(remote.deletes, isEmpty);
    },
  );
  test(
    'unrelated account and untrusted producer do not satisfy restore',
    () async {
      await seed(
        LogicalKeys.commit('other-account', 'trusted-device', 1, 'b1'),
      );
      await seed(
        LogicalKeys.commit('original-account', 'untrusted-device', 1, 'b2'),
      );
      remote.writes.clear();
      await expectLater(
        check(restoring: true),
        throwsA(isA<BackupDestinationException>()),
      );
      expect(remote.writes, isEmpty);
      expect(remote.deletes, isEmpty);
    },
  );
  test('locally trusted account candidate is discovered read-only', () async {
    await seed(
      LogicalKeys.commit('original-account', 'trusted-device', 1, 'b1'),
    );
    remote.writes.clear();
    await check(restoring: true);
    expect(remote.writes, isEmpty);
    expect(remote.deletes, isEmpty);
  });
  test(
    'a checkpoint or partial batch alone cannot masquerade as a backup',
    () async {
      await seed(
        LogicalKeys.checkpointCommit('original-account', 'checkpoint'),
      );
      await seed(
        LogicalKeys.batchEnvelope(
          'original-account',
          'trusted-device',
          1,
          'batch',
        ),
      );
      await expectLater(
        check(restoring: true),
        throwsA(isA<BackupDestinationException>()),
      );
    },
  );
  test('a non-probe path cannot be supplied through a generated id', () async {
    service = BackupDestinationService(
      open: (_) async => remote,
      nextId: () => '../existing',
    );
    await expectLater(check(), throwsA(isA<BackupDestinationException>()));
    expect(remote.writes, isEmpty);
  });

  test('a non-empty scope fails closed without a scoped opener', () async {
    var openCalls = 0;
    service = BackupDestinationService(
      open: (_) async {
        openCalls += 1;
        return remote;
      },
    );

    await expectLater(
      check(remoteRootSegments: const ['folder']),
      throwsA(
        isA<BackupDestinationException>().having(
          (error) => error.code,
          'code',
          'scoped_open_unavailable',
        ),
      ),
    );
    expect(openCalls, 0);
    expect(remote.writes, isEmpty);
  });

  test('preflight and restore both use the scoped opener', () async {
    final scopes = <List<String>>[];
    var unscopedCalls = 0;
    service = BackupDestinationService(
      open: (_) async {
        unscopedCalls += 1;
        return remote;
      },
      openScoped: (_, remoteRootSegments) async {
        scopes.add(List<String>.of(remoteRootSegments));
        return remote;
      },
      nextId: () => 'unique-test',
    );

    await check(remoteRootSegments: const ['folder']);
    expect(scopes, [
      ['folder'],
    ]);
    expect(unscopedCalls, 0);

    await seed(
      LogicalKeys.commit('original-account', 'trusted-device', 1, 'b1'),
    );
    scopes.clear();
    await check(
      restoring: true,
      remoteRootSegments: const ['folder', 'nested'],
    );
    expect(scopes, [
      ['folder', 'nested'],
    ]);
    expect(unscopedCalls, 0);
  });
}

class _RecordingStore extends InMemoryObjectStore {
  final writes = <String>[];
  final deletes = <String>[];
  bool corrupt = false;
  bool oversizedProbeRead = false;
  Stream<List<int>>? hangingProbeRead;
  @override
  Future<RemoteObjectMetadata> put(
    String key,
    Stream<List<int>> content, {
    required int contentLength,
    bool ifAbsent = false,
    RemoteOperationCancellation? cancellation,
  }) {
    writes.add(key);
    return super.put(
      key,
      content,
      contentLength: contentLength,
      ifAbsent: ifAbsent,
      cancellation: cancellation,
    );
  }

  @override
  Future<void> delete(String key, {RemoteOperationCancellation? cancellation}) {
    deletes.add(key);
    return super.delete(key, cancellation: cancellation);
  }

  @override
  Stream<List<int>> read(
    String key, {
    int? start,
    int? endInclusive,
    RemoteOperationCancellation? cancellation,
  }) {
    if (oversizedProbeRead && key.endsWith('.probe')) {
      return Stream.value(List<int>.filled(256, 0));
    }
    if (hangingProbeRead != null && key.endsWith('.probe')) {
      return hangingProbeRead!;
    }
    return corrupt
        ? Stream.value([42])
        : super.read(
            key,
            start: start,
            endInclusive: endInclusive,
            cancellation: cancellation,
          );
  }
}
