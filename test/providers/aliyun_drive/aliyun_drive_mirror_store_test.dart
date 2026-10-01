import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/providers/aliyun_drive/aliyun_drive_object_store.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';

import '../contracts/aliyun_tree_cloud.dart';
import '../contracts/stateful_object_store_contract.dart';

/// The plain file-sync mirror walks real folders one level at a time, so
/// Aliyun Drive has to answer like a folder tree with the user's own names
/// rather than the flat, encoded-name object store used for Velock backups.
void main() {
  late AliyunTreeCloud cloud;
  late StatefulObjectStoreContractFixture fixture;

  setUp(() async {
    cloud = AliyunTreeCloud();
    fixture = StatefulObjectStoreContractFixture(
      providerName: 'aliyun_tree',
      cloud: cloud,
    );
    await fixture.reset();
  });

  Future<AliyunDriveMirrorStore> mirror({
    List<String> scope = const [],
  }) async => (await fixture.createStore() as AliyunDriveObjectStore).asMirror(
    scope: scope,
  );

  test('lists only the direct children, folders included', () async {
    cloud
      ..seed('a.txt', [1])
      ..seed('docs/b.txt', [2, 2])
      ..seed('docs/deep/c.txt', [3])
      ..addFolder('empty');
    final store = await mirror();

    final root = await store.list(limit: 500);
    expect(
      {for (final item in root.items) item.logicalKey: item.isDirectory},
      {'a.txt': false, 'docs': true, 'empty': true},
    );
    final docs = await store.list(prefix: 'docs', limit: 500);
    expect(
      {for (final item in docs.items) item.logicalKey: item.isDirectory},
      {'docs/b.txt': false, 'docs/deep': true},
    );
    final file = docs.items.firstWhere((i) => !i.isDirectory);
    expect(file.size, 2);
    expect(file.etag, isNotNull);
  });

  test('pages through a large folder', () async {
    for (var i = 0; i < 5; i++) {
      cloud.seed('f$i.txt', [i]);
    }
    final store = await mirror();
    final keys = <String>[];
    String? cursor;
    do {
      final page = await store.list(cursor: cursor, limit: 2);
      keys.addAll(page.items.map((i) => i.logicalKey));
      cursor = page.nextCursor;
    } while (cursor != null);
    expect(keys..sort(), ['f0.txt', 'f1.txt', 'f2.txt', 'f3.txt', 'f4.txt']);
  });

  test('a missing folder is an error, never an empty listing', () async {
    cloud.seed('file.txt', [1]);
    final store = await mirror();
    await expectLater(
      store.list(prefix: 'gone'),
      throwsA(isA<RemoteObjectNotFoundException>()),
    );
    // A file is not a folder either.
    await expectLater(
      store.list(prefix: 'file.txt'),
      throwsA(isA<RemoteObjectNotFoundException>()),
    );
  });

  test('a picked root folder that was removed is an error too', () async {
    final store = await mirror();
    cloud.tree.remove(
      cloud.tree.byId(cloud.connectionRootId)!,
      toRecycleBin: false,
    );
    await expectLater(store.list(), throwsA(anything));
  });

  test('creates one folder and accepts one that already exists', () async {
    final store = await mirror();
    await store.createCollection('new');
    expect(cloud.isFolder('new'), isTrue);
    await store.createCollection('new');
    expect(cloud.namesIn(), ['new']);
    expect((await store.stat('new'))!.isDirectory, isTrue);
  });

  test('a file in the way of a folder or a missing parent fails', () async {
    cloud.seed('taken', [1]);
    final store = await mirror();
    await expectLater(store.createCollection('taken'), throwsA(anything));
    await expectLater(store.createCollection('no/such'), throwsA(anything));
    expect(cloud.bytesOf('taken'), [1]);
    expect(cloud.namesIn(), ['taken']);
  });

  test('deletes a folder with its contents into the recycle bin', () async {
    cloud.seed('old/x.txt', [1]);
    final store = await mirror();
    await store.delete('old');
    expect(cloud.bytesOf('old/x.txt'), isNull);
    expect(cloud.tree.recycled, ['/同步盘/old']);
    expect(cloud.operations, isNot(contains('openFile/delete')));
    await store.delete('old');
  });

  test('round-trips a file through put, stat and read', () async {
    cloud.addFolder('docs');
    final store = await mirror();
    await store.put('docs/n.txt', Stream.value([7, 8]), contentLength: 2);
    final meta = await store.stat('docs/n.txt');
    expect(meta!.size, 2);
    expect(meta.isDirectory, isFalse);
    expect(await store.read('docs/n.txt').expand((chunk) => chunk).toList(), [
      7,
      8,
    ]);
    expect(await store.read('docs/n.txt', start: 1).expand((c) => c).toList(), [
      8,
    ]);
  });

  test(
    'a file in a missing folder is refused, not put somewhere else',
    () async {
      final store = await mirror();
      await expectLater(
        store.put('nowhere/n.txt', Stream.value([1]), contentLength: 1),
        throwsA(anything),
      );
      expect(cloud.namesIn(), isEmpty);
    },
  );

  test(
    'replaces a file: new content first, old one to the recycle bin',
    () async {
      cloud.seed('n.txt', [1]);
      final store = await mirror();

      await store.put('n.txt', Stream.value([2, 2]), contentLength: 2);

      expect(cloud.bytesOf('n.txt'), [2, 2]);
      expect(cloud.namesIn(), ['n.txt']);
      expect(cloud.tree.recycled, ['/同步盘/n.txt']);
      final order = cloud.operations;
      expect(
        order.indexOf('openFile/complete'),
        lessThan(order.indexOf('openFile/recyclebin/trash')),
      );
      expect(
        order.indexOf('openFile/recyclebin/trash'),
        lessThan(order.indexOf('openFile/update')),
      );
    },
  );

  test('a replacement that fails mid-upload keeps the old file', () async {
    cloud
      ..seed('n.txt', [1])
      ..failUploadsNamed = '.velock-tmp-';
    final store = await mirror();

    await expectLater(
      store.put('n.txt', Stream.value([2, 2]), contentLength: 2),
      throwsA(anything),
    );

    expect(cloud.bytesOf('n.txt'), [1]);
    expect(cloud.tree.recycled, isEmpty);
    expect(cloud.namesIn(), ['n.txt']);
  });

  test('ifAbsent refuses to replace', () async {
    cloud.seed('n.txt', [1]);
    final store = await mirror();
    await expectLater(
      store.put('n.txt', Stream.value([3]), contentLength: 1, ifAbsent: true),
      throwsA(isA<RemoteObjectAlreadyExistsException>()),
    );
    expect(cloud.bytesOf('n.txt'), [1]);
  });

  test('a scope below the picked folder addresses the right place', () async {
    cloud.seed('照片/2026/a.jpg', [9]);
    final store = await mirror(scope: ['照片']);

    expect((await store.list()).items.single.logicalKey, '2026');
    await store.put('2026/b.jpg', Stream.value([8]), contentLength: 1);
    expect(cloud.bytesOf('照片/2026/b.jpg'), [8]);
  });

  test('works at the drive root as well', () async {
    cloud.useDriveRoot();
    final store = await mirror();
    await store.createCollection('顶层');
    await store.put('顶层/a.txt', Stream.value([1]), contentLength: 1);
    expect(cloud.tree.resolve(['顶层', 'a.txt'])!.bytes, [1]);
  });

  test('a name with a control character fails with that name', () async {
    final store = await mirror();
    Object? error;
    try {
      await store.put('a\u0001b.txt', Stream.value([1]), contentLength: 1);
    } on Object catch (e) {
      error = e;
    }
    expect(error, isA<SyncFailureException>());
    expect(
      (error! as SyncFailureException).syncFailure.errorCode,
      'provider.aliyun.unsupported_name',
    );
    expect(cloud.requests, isEmpty);
  });
}
