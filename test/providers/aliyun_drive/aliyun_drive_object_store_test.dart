import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/providers/aliyun_drive/aliyun_drive_object_store.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';

import '../contracts/aliyun_drive_object_store_contract_fixture.dart';
import '../contracts/object_store_contract.dart';
import '../contracts/stateful_object_store_contract.dart';

void main() {
  runObjectStoreContract(aliyunDriveContractFixture());

  late AliyunContractCloud cloud;
  late StatefulObjectStoreContractFixture fixture;
  late RemoteObjectStore store;

  setUp(() async {
    cloud = AliyunContractCloud();
    fixture = aliyunDriveContractFixture(cloud);
    await fixture.reset();
    store = await fixture.createStore();
  });

  test('an expired upload URL is replaced once and the part resent', () async {
    cloud.intercept = (request) {
      // Every URL handed out by openFile/create has already expired.
      if (request.operation == 'openFile/create') {
        cloud.expiredUrlGeneration = cloud.urlGeneration;
      }
      return null;
    };

    await store.put('blobs/late', Stream.value([1, 2]), contentLength: 2);

    expect(cloud.bytesOf('blobs/late'), [1, 2]);
    expect(
      cloud.requests.where((r) => r.operation == 'openFile/getUploadUrl'),
      hasLength(1),
    );
  });

  test(
    'a same-named file appearing mid-upload is never taken as ours',
    () async {
      cloud.intercept = (request) {
        if (request.operation == 'openFile/complete') {
          cloud.racingWrite('blobs/raced', [9]);
        }
        return null;
      };

      await expectLater(
        store.put('blobs/raced', Stream.value([1]), contentLength: 1),
        throwsA(isA<AliyunDriveException>()),
      );
      expect(cloud.bytesOf('blobs/raced'), [9]);
    },
  );

  test('a create reporting an existing file is a collision', () async {
    cloud.intercept = (request) {
      if (request.operation == 'openFile/create') {
        cloud.racingWrite('blobs/exists', [5]);
      }
      return null;
    };

    await expectLater(
      store.put('blobs/exists', Stream.value([1]), contentLength: 1),
      throwsA(isA<RemoteObjectAlreadyExistsException>()),
    );
    expect(cloud.bytesOf('blobs/exists'), [5]);
  });

  test('folder refs round-trip and reject malformed values', () {
    final ref = AliyunDriveFolderRef.tryParse('drive-1:folder:with:colons');
    expect(ref?.driveId, 'drive-1');
    expect(ref?.fileId, 'folder:with:colons');
    expect(ref?.encode(), 'drive-1:folder:with:colons');
    expect(AliyunDriveFolderRef.tryParse('no-colon'), isNull);
    expect(AliyunDriveFolderRef.tryParse(':x'), isNull);
    expect(AliyunDriveFolderRef.tryParse('x:'), isNull);
  });
}
