import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/providers/google_drive/google_drive_object_store.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';

import '../contracts/google_tree_cloud.dart';
import '../contracts/stateful_object_store_contract.dart';

/// File sync on Google Drive: real folders with the user's own names, found
/// one level at a time by ID, where a folder may hold several items with
/// the same name and Google Docs have no content.
void main() {
  late GoogleTreeCloud cloud;
  late StatefulObjectStoreContractFixture fixture;

  setUp(() async {
    cloud = GoogleTreeCloud();
    fixture = StatefulObjectStoreContractFixture(
      providerName: 'google_tree',
      cloud: cloud,
    );
    await fixture.reset();
  });

  Future<GoogleDriveMirrorStore> mirror({
    List<String> scope = const [],
  }) async => (await fixture.createStore() as GoogleDriveObjectStore).asMirror(
    scope: scope,
  );

  String? failureCode(Object? error) =>
      error is SyncFailureException ? error.syncFailure.errorCode : null;

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
    expect(docs.items.firstWhere((i) => i.isDirectory).etag, isNull);
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
    await expectLater(
      store.list(prefix: 'file.txt'),
      throwsA(isA<RemoteObjectNotFoundException>()),
    );
  });

  test('a picked root folder that was deleted is an error too', () async {
    final picked = cloud.useFolderRoot('同步');
    final store = await mirror();
    cloud.tree.remove(picked, toRecycleBin: true);
    // Drive answers a children query on it with nothing at all.
    await expectLater(
      store.list(),
      throwsA(isA<RemoteObjectNotFoundException>()),
    );
  });

  test('two items with one name stop the listing', () async {
    cloud
      ..seed('docs/报告.pdf', [1])
      ..addDuplicate('docs/报告.pdf', bytes: [2]);
    final store = await mirror();
    Object? error;
    try {
      await store.list(prefix: 'docs', limit: 500);
    } on Object catch (e) {
      error = e;
    }
    expect(failureCode(error), 'provider.google.duplicate_name');
    expect(
      (error! as SyncFailureException).syncFailure.suggestedAction,
      contains('docs/报告.pdf'),
    );
  });

  test('duplicates split across pages are found as well', () async {
    cloud
      ..seed('a.txt', [1])
      ..addDuplicate('a.txt', bytes: [2])
      ..seed('b.txt', [3]);
    final store = await mirror();
    final page = await store.list(limit: 1);
    await expectLater(
      store.list(cursor: page.nextCursor, limit: 1),
      throwsA(
        predicate((e) => failureCode(e) == 'provider.google.duplicate_name'),
      ),
    );
  });

  test('a file and a folder with one name are duplicates', () async {
    cloud
      ..addFolder('x')
      ..addDuplicate('x', bytes: [1]);
    final store = await mirror();
    await expectLater(
      store.list(limit: 500),
      throwsA(
        predicate((e) => failureCode(e) == 'provider.google.duplicate_name'),
      ),
    );
    await expectLater(
      store.stat('x'),
      throwsA(
        predicate((e) => failureCode(e) == 'provider.google.duplicate_name'),
      ),
    );
  });

  test('Google Docs are skipped, even two of one name', () async {
    cloud
      ..seed('a.txt', [1])
      ..addDoc('笔记')
      ..addDoc('笔记');
    final store = await mirror();
    final page = await store.list(limit: 500);
    expect(page.items.map((i) => i.logicalKey), ['a.txt']);
    expect(await store.stat('笔记'), isNull);
    // ...but a real file cannot be put next to a Doc of the same name.
    await expectLater(
      store.put('笔记', Stream.value([1]), contentLength: 1),
      throwsA(
        predicate((e) => failureCode(e) == 'provider.google.duplicate_name'),
      ),
    );
  });

  test('a file next to a Google Doc of its name is a duplicate', () async {
    cloud
      ..seed('计划', [1])
      ..addDoc('计划');
    final store = await mirror();
    await expectLater(
      store.list(limit: 500),
      throwsA(
        predicate((e) => failureCode(e) == 'provider.google.duplicate_name'),
      ),
    );
  });

  test('round-trips a file through put, stat and read', () async {
    cloud.addFolder('docs');
    final store = await mirror();
    await store.put('docs/n.txt', Stream.value([7, 8]), contentLength: 2);
    final meta = await store.stat('docs/n.txt');
    expect(meta!.size, 2);
    expect(meta.isDirectory, isFalse);
    expect(await store.read('docs/n.txt').expand((c) => c).toList(), [7, 8]);
    expect(await store.read('docs/n.txt', start: 1).expand((c) => c).toList(), [
      8,
    ]);
  });

  test('replaces a file in place instead of adding a second one', () async {
    cloud.seed('n.txt', [1]);
    final id = cloud.nodeAt('n.txt')!.id;
    final store = await mirror();
    final before = (await store.stat('n.txt'))!.etag;

    await store.put('n.txt', Stream.value([2, 2]), contentLength: 2);

    expect(cloud.namesIn(), ['n.txt']);
    expect(cloud.nodeAt('n.txt')!.id, id);
    expect(cloud.bytesOf('n.txt'), [2, 2]);
    expect((await store.stat('n.txt'))!.etag, isNot(before));
    expect(
      cloud.requests.map((r) => r.operation),
      contains('PATCH /upload/drive/v3/files/$id'),
    );
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

  test('never writes into a missing folder or over a folder', () async {
    cloud.addFolder('taken');
    final store = await mirror();
    await expectLater(
      store.put('nowhere/n.txt', Stream.value([1]), contentLength: 1),
      throwsA(anything),
    );
    await expectLater(
      store.put('taken', Stream.value([1]), contentLength: 1),
      throwsA(anything),
    );
    expect(cloud.namesIn(), ['taken']);
    expect(cloud.isFolder('taken'), isTrue);
  });

  test('a large file goes up in chunks', () async {
    final store = await mirror();
    final bytes = List<int>.generate(5 * 1024 * 1024, (i) => i % 251);
    await store.put(
      'big.bin',
      Stream.value(bytes),
      contentLength: bytes.length,
    );
    expect(cloud.bytesOf('big.bin'), bytes);
    expect(
      cloud.requests.where((r) => r.kind == CloudRequestKind.uploadPart),
      hasLength(3),
    );
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

  test('deletes a folder with its contents into the trash', () async {
    cloud.seed('old/x.txt', [1]);
    final store = await mirror();
    await store.list(limit: 500);
    await store.delete('old');
    expect(cloud.bytesOf('old/x.txt'), isNull);
    expect(cloud.tree.recycled, ['/old']);
    // Its cached ID is forgotten: the folder is missing now.
    await expectLater(
      store.list(prefix: 'old'),
      throwsA(isA<RemoteObjectNotFoundException>()),
    );
    await store.delete('old');
  });

  test('a duplicate is never deleted at random', () async {
    cloud
      ..seed('a.txt', [1])
      ..addDuplicate('a.txt', bytes: [2]);
    final store = await mirror();
    await expectLater(
      store.delete('a.txt'),
      throwsA(
        predicate((e) => failureCode(e) == 'provider.google.duplicate_name'),
      ),
    );
    expect(cloud.tree.recycled, isEmpty);
  });

  test('names keep quotes, backslashes and Chinese', () async {
    final store = await mirror();
    const name = r"it's 报告 #1 a\b.txt";
    await store.put(name, Stream.value([1]), contentLength: 1);
    expect(cloud.bytesOf(name), [1]);
    expect((await store.stat(name))!.size, 1);
    expect((await store.list()).items.single.logicalKey, name);
  });

  test('a scope and a picked root folder address the right place', () async {
    cloud.useFolderRoot('同步');
    cloud.seed('照片/2026/a.jpg', [9]);
    final store = await mirror(scope: ['照片']);

    expect((await store.list()).items.single.logicalKey, '2026');
    await store.put('2026/b.jpg', Stream.value([8]), contentLength: 1);
    expect(cloud.bytesOf('照片/2026/b.jpg'), [8]);
    expect(cloud.tree.resolve(['照片']), isNull);
  });

  test('resolved folders are reused within a run', () async {
    cloud.seed('a/b/c.txt', [1]);
    final store = await mirror();
    await store.stat('a/b/c.txt');
    final first = cloud.searches.length;
    await store.stat('a/b/c.txt');
    // Only the file itself is looked up again.
    expect(cloud.searches.length - first, 1);
  });

  test('the hidden app folder is never a mirror', () async {
    cloud.connectionRootId = 'appDataFolder';
    final store = await fixture.createStore() as GoogleDriveObjectStore;
    expect(store.asMirror, throwsStateError);
  });
}
