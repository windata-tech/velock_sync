import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/providers/one_drive/one_drive_object_store.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';

import '../contracts/one_drive_tree_cloud.dart';
import '../contracts/stateful_object_store_contract.dart';

/// The plain file-sync mirror walks real folders one level at a time, so
/// OneDrive has to answer like a folder tree with the user's own names rather
/// than the flat, encoded-name object store used for Velock backups.
void main() {
  late OneDriveTreeCloud cloud;
  late StatefulObjectStoreContractFixture fixture;

  setUp(() async {
    cloud = OneDriveTreeCloud();
    fixture = StatefulObjectStoreContractFixture(
      providerName: 'one_drive_tree',
      cloud: cloud,
    );
    await fixture.reset();
  });

  Future<OneDriveMirrorStore> mirror({List<String> scope = const []}) async =>
      (await fixture.createStore() as OneDriveObjectStore).asMirror(
        scope: scope,
      );

  test('lists only the direct children, folders included', () async {
    cloud
      ..seed('a.txt', [1])
      ..seed('docs/b.txt', [2, 2])
      ..seed('docs/deep/c.txt', [3])
      ..addFolder('empty');
    final store = await mirror();

    final root = await store.list();
    expect(
      {for (final item in root.items) item.logicalKey: item.isDirectory},
      {'a.txt': false, 'docs': true, 'empty': true},
    );
    final docs = await store.list(prefix: 'docs');
    expect(
      {for (final item in docs.items) item.logicalKey: item.isDirectory},
      {'docs/b.txt': false, 'docs/deep': true},
    );
    expect(docs.items.firstWhere((i) => !i.isDirectory).size, 2);
    // Folders carry no tag: theirs change whenever anything inside does.
    expect(docs.items.firstWhere((i) => i.isDirectory).etag, isNull);
    expect(cloud.addressed, [':/children'.substring(1), ':/docs:/children']);
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

  test('a cursor that points away from Graph is refused', () async {
    final store = await mirror();
    await expectLater(
      store.list(cursor: 'https://evil.example.test/steal'),
      throwsArgumentError,
    );
    expect(cloud.requests, isEmpty);
  });

  test('a missing folder is an error, never an empty listing', () async {
    final store = await mirror();
    await expectLater(
      store.list(prefix: 'gone'),
      throwsA(isA<RemoteObjectNotFoundException>()),
    );
  });

  test('creates one folder and accepts one that already exists', () async {
    final store = await mirror();
    await store.createCollection('new');
    expect(cloud.isFolder('new'), isTrue);
    await store.createCollection('new');
    expect((await store.stat('new'))!.isDirectory, isTrue);
  });

  test('a file in the way of a folder or a missing parent fails', () async {
    cloud.seed('taken', [1]);
    final store = await mirror();
    await expectLater(store.createCollection('taken'), throwsA(anything));
    await expectLater(store.createCollection('no/such'), throwsA(anything));
    expect(cloud.bytesOf('taken'), [1]);
    expect(cloud.isFolder('no'), isFalse);
  });

  test('deletes a folder with its contents into the recycle bin', () async {
    cloud.seed('old/x.txt', [1]);
    final store = await mirror();
    await store.delete('old');
    expect(cloud.bytesOf('old/x.txt'), isNull);
    expect(cloud.tree.recycled, ['/old']);
    await expectLater(
      store.list(prefix: 'old'),
      throwsA(isA<RemoteObjectNotFoundException>()),
    );
    // Deleting it again is a successful no-op.
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
  });

  test('replaces a file in place, and ifAbsent refuses to', () async {
    cloud.seed('n.txt', [1]);
    final store = await mirror();
    final before = (await store.stat('n.txt'))!.etag;

    await store.put('n.txt', Stream.value([2, 2]), contentLength: 2);
    expect(cloud.bytesOf('n.txt'), [2, 2]);
    expect((await store.stat('n.txt'))!.etag, isNot(before));

    await expectLater(
      store.put('n.txt', Stream.value([3]), contentLength: 1, ifAbsent: true),
      throwsA(isA<RemoteObjectAlreadyExistsException>()),
    );
    expect(cloud.bytesOf('n.txt'), [2, 2]);
  });

  test('a large file goes through an upload session', () async {
    final store = await mirror();
    final bytes = List<int>.generate(5 * 1024 * 1024, (i) => i % 251);
    await store.put(
      'big.bin',
      Stream.value(bytes),
      contentLength: bytes.length,
    );
    expect(cloud.bytesOf('big.bin'), bytes);
    expect(
      cloud.requests.where(
        (r) => r.operation.endsWith('/big.bin:/createUploadSession'),
      ),
      hasLength(1),
    );
  });

  test('names keep #, %, spaces and Chinese as part of the name', () async {
    final store = await mirror();
    const name = '报告 #1 100%.txt';
    await store.put(name, Stream.value([1]), contentLength: 1);
    expect(cloud.bytesOf(name), [1]);
    expect((await store.list()).items.single.logicalKey, name);
  });

  test('a scope and a picked root folder address the right place', () async {
    cloud.useFolderRoot('同步');
    cloud.seed('照片/2026/a.jpg', [9]);
    final store = await mirror(scope: ['照片']);

    final page = await store.list();
    expect(page.items.single.logicalKey, '2026');
    await store.put('2026/b.jpg', Stream.value([8]), contentLength: 1);
    expect(cloud.bytesOf('照片/2026/b.jpg'), [8]);
    expect(
      cloud.requests.every(
        (r) =>
            r.kind != CloudRequestKind.api ||
            r.options.uri.path.contains('/items/${cloud.connectionRootId}'),
      ),
      isTrue,
    );
  });

  test('a name OneDrive cannot store fails with that name', () async {
    final store = await mirror();
    Object? error;
    try {
      await store.put('a:b.txt', Stream.value([1]), contentLength: 1);
    } on Object catch (e) {
      error = e;
    }
    expect(error, isA<SyncFailureException>());
    final failure = (error! as SyncFailureException).syncFailure;
    expect(failure.errorCode, 'provider.onedrive.unsupported_name');
    expect(failure.suggestedAction, contains('a:b.txt'));
    expect(cloud.requests, isEmpty);
  });
}
