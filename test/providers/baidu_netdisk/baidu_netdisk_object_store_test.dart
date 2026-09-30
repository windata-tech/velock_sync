import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/providers/baidu_netdisk/baidu_netdisk_object_store.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';

import '../contracts/baidu_netdisk_object_store_contract_fixture.dart';
import '../contracts/object_store_contract.dart';
import '../contracts/stateful_object_store_contract.dart';

void main() {
  runObjectStoreContract(baiduNetdiskContractFixture());

  late BaiduContractCloud cloud;
  late StatefulObjectStoreContractFixture fixture;
  late RemoteObjectStore store;

  setUp(() async {
    cloud = BaiduContractCloud();
    fixture = baiduNetdiskContractFixture(cloud);
    await fixture.reset();
    store = await fixture.createStore();
  });

  test('a folder that was never created lists as empty', () async {
    final page = await store.list(prefix: 'blobs/');
    expect(page.items, isEmpty);
    expect(await store.stat('blobs/none'), isNull);
  });

  test(
    'an upload Baidu stored under another name is never taken as ours',
    () async {
      cloud.renameOnCreate = true;

      await expectLater(
        store.put('blobs/renamed', Stream.value([1]), contentLength: 1),
        throwsA(isA<BaiduNetdiskException>()),
      );
      expect(cloud.bytesOf('blobs/renamed'), isNull);
      await cloud.verifyClean();
    },
  );

  test('an existing path at create time is a collision', () async {
    cloud.intercept = (request) {
      if (request.operation == 'create') cloud.seed('blobs/raced', [9]);
      return null;
    };

    await expectLater(
      store.put(
        'blobs/raced',
        Stream.value([1]),
        contentLength: 1,
        ifAbsent: true,
      ),
      throwsA(isA<RemoteObjectAlreadyExistsException>()),
    );
    expect(cloud.bytesOf('blobs/raced'), [9]);
    await cloud.verifyClean();
  });

  test('keys Baidu cannot store are rejected before any request', () async {
    for (final key in ['a:b', 'a*b', 'a?b', 'a\u0001b', 'a|b']) {
      await expectLater(
        store.put(key, Stream.value([1]), contentLength: 1),
        throwsA(anything),
        reason: key,
      );
    }
    expect(cloud.requests, isEmpty);
  });

  test('the spool is removed when an upload fails', () async {
    cloud.intercept = (request) =>
        request.operation == 'create' ? cloud.quotaExceeded() : null;

    await expectLater(
      store.put('blobs/full', Stream.value([1, 2, 3]), contentLength: 3),
      throwsA(anything),
    );
    expect(cloud.spools, isNotEmpty);
    await cloud.verifyClean();
  });
}
