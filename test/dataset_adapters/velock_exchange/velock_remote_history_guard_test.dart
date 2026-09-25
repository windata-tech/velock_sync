import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_remote_history_guard.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';

String _commit(int sequence, [String? batch]) =>
    LogicalKeys.commit('vault', 'producer', sequence, batch ?? 'b$sequence');

RemoteObjectPage _page(List<String> keys, [String? cursor]) => RemoteObjectPage(
  items: keys
      .map(
        (key) => RemoteObjectMetadata(
          logicalKey: key,
          size: 0,
          updatedAt: DateTime.utc(2026),
        ),
      )
      .toList(),
  nextCursor: cursor,
);

Future<void> _verify(_ListingRemote remote, [int through = 6]) =>
    verifyVelockRemoteHistory(
      remote: remote,
      vaultId: 'vault',
      producerDeviceId: 'producer',
      requiredThroughSequence: through,
    );

final _incomplete = isA<SyncFailureException>()
    .having(
      (e) => e.syncFailure.errorCode,
      'code',
      'remote.velock_history_incomplete',
    )
    .having(
      (e) => e.syncFailure.category,
      'category',
      SyncErrorCategory.userActionRequired,
    )
    .having((e) => e.syncFailure.retryable, 'retryable', false)
    .having(
      (e) => e.syncFailure.suggestedAction,
      'action',
      '远端缺少历史备份，同步未完成。请连接原来的完整备份目录；不要删除旧备份或重置同步数据。',
    )
    .having(
      (e) => e.toString(),
      'safe message',
      'Remote Velock history is incomplete.',
    );

void main() {
  for (final entry in <String, List<int>>{
    'empty': [],
    'only sequence 6, missing 1': [6],
    'interior hole': [1, 2, 4, 5, 6],
    'missing tail': [1, 2, 3, 4, 5],
  }.entries) {
    test('rejects ${entry.key}', () async {
      final remote = _ListingRemote(
        (_) => _page(entry.value.map(_commit).toList()),
      );
      await expectLater(_verify(remote), throwsA(_incomplete));
    });
  }

  test(
    'complete unordered history uses only one list, no stats or reads',
    () async {
      final remote = _ListingRemote(
        (_) => _page([6, 2, 4, 1, 5, 3, 7].map(_commit).toList()),
      );
      await _verify(remote);
      expect(remote.calls, 1);
    },
  );

  test('paginates including empty filtered pages and opaque cursors', () async {
    final pages = [
      _page([_commit(2)], 'opaque-a'),
      _page([], 'opaque-b'),
      _page([_commit(1)]),
    ];
    final remote = _ListingRemote((i) => pages[i]);
    await _verify(remote, 2);
    expect(remote.cursors, [null, 'opaque-a', 'opaque-b']);
  });

  test(
    'rejects duplicate sequence across pages after complete coverage',
    () async {
      final remote = _ListingRemote(
        (i) => i == 0
            ? _page([_commit(1)], 'next')
            : _page([_commit(1, 'different')]),
      );
      await expectLater(_verify(remote, 1), throwsA(_incomplete));
    },
  );

  test('rejects repeated identical key too', () async {
    final remote = _ListingRemote((_) => _page([_commit(1), _commit(1)]));
    await expectLater(_verify(remote, 1), throwsA(_incomplete));
  });

  final unrelated = [
    LogicalKeys.checkpointCommit('vault', 'checkpoint'),
    LogicalKeys.commit('other', 'producer', 1, 'b'),
    LogicalKeys.commit('vault', 'other', 1, 'b'),
    '${LogicalKeys.deviceCommitsPrefix('vault', 'producer')}1-b.commit',
    '${_commit(1)}.tmp',
    '${_commit(1)}\n',
    '${LogicalKeys.deviceCommitsPrefix('vault', 'producer')}00000000000000000001-sub/b.commit',
  ];
  test(
    'checkpoint/unrelated names cannot prove history (including GC)',
    () async {
      await expectLater(
        _verify(_ListingRemote((_) => _page(unrelated)), 1),
        throwsA(_incomplete),
      );
    },
  );
  test('ignores unrelated names alongside valid commits', () async {
    await _verify(_ListingRemote((_) => _page([...unrelated, _commit(1)])), 1);
  });

  test('rejects cursor cycles even when coverage is complete', () async {
    final remote = _ListingRemote(
      (i) => _page(i == 0 ? [_commit(1)] : [], i.isEven ? 'a' : 'b'),
    );
    await expectLater(_verify(remote, 1), throwsA(_incomplete));
    expect(remote.calls, 3);
  });
  test('rejects empty continuation cursor', () async {
    await expectLater(
      _verify(_ListingRemote((_) => _page([], ''))),
      throwsA(_incomplete),
    );
  });
  test('bounds empty pages with distinct cursors', () async {
    final remote = _ListingRemote((i) => _page([], 'cursor-$i'));
    await expectLater(_verify(remote), throwsA(_incomplete));
    expect(remote.calls, 1000);
  });
  test('bounds total listed items including unrelated objects', () async {
    final keys = List.filled(1000, 'unrelated');
    final remote = _ListingRemote((i) => _page(keys, 'cursor-$i'));
    await expectLater(_verify(remote), throwsA(_incomplete));
    expect(remote.calls, 101);
  });
  test('rejects oversized provider page', () async {
    final remote = _ListingRemote((_) => _page(List.filled(1001, 'unrelated')));
    await expectLater(_verify(remote), throwsA(_incomplete));
    expect(remote.calls, 1);
  });
  test(
    'zero is no-op; invalid/unprovable boundaries fail without I/O',
    () async {
      final remote = _ListingRemote((_) => throw StateError('unexpected list'));
      await _verify(remote, 0);
      for (final boundary in [-1, 100001]) {
        await expectLater(_verify(remote, boundary), throwsA(_incomplete));
      }
      expect(remote.calls, 0);
    },
  );
  test('invalid identity produces no identifier in failure', () async {
    final remote = _ListingRemote((_) => throw StateError('unexpected list'));
    await expectLater(
      verifyVelockRemoteHistory(
        remote: remote,
        vaultId: 'secret/invalid',
        producerDeviceId: 'producer',
        requiredThroughSequence: 1,
      ),
      throwsA(_incomplete),
    );
    expect(remote.calls, 0);
  });
  test(
    'operational errors propagate rather than masquerading as missing history',
    () async {
      const error = RemoteOperationCancelledException();
      await expectLater(
        _verify(_ListingRemote((_) => throw error)),
        throwsA(same(error)),
      );
    },
  );
  test('large complete history is page-linear, not N stats', () async {
    final remote = _ListingRemote(
      (i) => _page(
        List.generate(1000, (j) => _commit(i * 1000 + j + 1)),
        i == 9 ? null : 'page-${i + 1}',
      ),
    );
    await _verify(remote, 10000);
    expect(remote.calls, 10);
  });
}

/// Any operation except list fails the test, including stat/read/write/delete.
class _ListingRemote implements RemoteObjectStore {
  _ListingRemote(this.page);
  final RemoteObjectPage Function(int) page;
  int calls = 0;
  final cursors = <String?>[];

  @override
  Future<RemoteObjectPage> list({
    String prefix = '',
    String? cursor,
    int limit = 100,
    RemoteOperationCancellation? cancellation,
  }) async {
    expect(prefix, LogicalKeys.deviceCommitsPrefix('vault', 'producer'));
    expect(limit, 1000);
    cursors.add(cursor);
    return page(calls++);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Guard must use list only.');
}
