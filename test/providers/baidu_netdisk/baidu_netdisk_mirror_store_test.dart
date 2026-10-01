import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/providers/baidu_netdisk/baidu_netdisk_object_store.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';

import '../contracts/baidu_netdisk_object_store_contract_fixture.dart';

/// The plain file-sync mirror walks real folders one level at a time, so
/// Baidu has to answer like a folder tree rather than a flat object store.
void main() {
  late BaiduContractCloud cloud;
  late BaiduNetdiskMirrorStore mirror;

  setUp(() async {
    cloud = BaiduContractCloud();
    final fixture = baiduNetdiskContractFixture(cloud);
    await fixture.reset();
    final store = await fixture.createStore() as BaiduNetdiskObjectStore;
    mirror = store.asMirror();
    cloud.addDirectory(BaiduContractCloud.rootPath);
  });

  test('lists only the direct children, folders included', () async {
    cloud.seed('a.txt', [1]);
    cloud.seed('docs/b.txt', [2, 2]);
    cloud.seed('docs/deep/c.txt', [3]);
    cloud.addDirectory('${BaiduContractCloud.rootPath}/empty');

    final root = await mirror.list();
    expect(
      {for (final item in root.items) item.logicalKey: item.isDirectory},
      {'a.txt': false, 'docs': true, 'empty': true},
    );
    final docs = await mirror.list(prefix: 'docs');
    expect(
      {for (final item in docs.items) item.logicalKey: item.isDirectory},
      {'docs/b.txt': false, 'docs/deep': true},
    );
    expect(docs.items.firstWhere((i) => !i.isDirectory).size, 2);
  });

  test('pages through a large folder', () async {
    for (var i = 0; i < 5; i++) {
      cloud.seed('f$i.txt', [i]);
    }
    final keys = <String>[];
    String? cursor;
    do {
      final page = await mirror.list(cursor: cursor, limit: 2);
      keys.addAll(page.items.map((i) => i.logicalKey));
      cursor = page.nextCursor;
    } while (cursor != null);
    expect(keys..sort(), ['f0.txt', 'f1.txt', 'f2.txt', 'f3.txt', 'f4.txt']);
  });

  test('a missing folder is an error, never an empty listing', () async {
    await expectLater(
      mirror.list(prefix: 'gone'),
      throwsA(isA<RemoteObjectNotFoundException>()),
    );
  });

  test('creates one folder and accepts one that already exists', () async {
    await mirror.createCollection('new');
    expect(cloud.directories, contains('${BaiduContractCloud.rootPath}/new'));
    await mirror.createCollection('new');
    expect((await mirror.stat('new'))!.isDirectory, isTrue);
  });

  test('a file in the way of a folder is a conflict', () async {
    cloud.seed('taken', [1]);
    await expectLater(mirror.createCollection('taken'), throwsA(anything));
    expect(cloud.bytesOf('taken'), [1]);
  });

  test('deletes a folder with its contents', () async {
    cloud.seed('old/x.txt', [1]);
    await mirror.delete('old');
    expect(cloud.bytesOf('old/x.txt'), isNull);
    expect(
      cloud.directories,
      isNot(contains('${BaiduContractCloud.rootPath}/old')),
    );
    await expectLater(
      mirror.list(prefix: 'old'),
      throwsA(isA<RemoteObjectNotFoundException>()),
    );
  });

  test('round-trips a file through put, stat and read', () async {
    await mirror.put('docs/n.txt', Stream.value([7, 8]), contentLength: 2);
    final meta = await mirror.stat('docs/n.txt');
    expect(meta!.size, 2);
    expect(meta.isDirectory, isFalse);
    expect(await mirror.read('docs/n.txt').expand((chunk) => chunk).toList(), [
      7,
      8,
    ]);
    await cloud.verifyClean();
  });

  test('a name Baidu cannot store fails with that name', () async {
    Object? error;
    try {
      await mirror.put('a:b.txt', Stream.value([1]), contentLength: 1);
    } on Object catch (e) {
      error = e;
    }
    expect(error, isA<SyncFailureException>());
    final failure = (error! as SyncFailureException).syncFailure;
    expect(failure.errorCode, 'provider.baidu.unsupported_name');
    expect(failure.suggestedAction, contains('a:b.txt'));
    expect(cloud.requests, isEmpty);
  });
}
