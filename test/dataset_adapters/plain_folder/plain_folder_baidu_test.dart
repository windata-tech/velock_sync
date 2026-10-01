import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_profile.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_service.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/providers/baidu_netdisk/baidu_netdisk_object_store.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

import '../../providers/contracts/baidu_netdisk_object_store_contract_fixture.dart';

const _profileId = 'plain-baidu';
const _baiduId = 'baidu';
const _googleId = 'google';

class _Connections implements ConnectionRepository {
  @override
  Future<ConnectionModel?> getConnectionById(String id) async => switch (id) {
    _baiduId => _oauth(
      _baiduId,
      RemoteProviderType.baiduNetdisk,
      '/apps/Velock Sync',
    ),
    _googleId => _oauth(
      _googleId,
      RemoteProviderType.googleDrive,
      'appDataFolder',
    ),
    _ => null,
  };

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ConnectionModel _oauth(String id, RemoteProviderType type, String rootId) =>
    ConnectionModel(
      id: id,
      name: id,
      source: 'source',
      target: 'target',
      protocol: ProtocolModel.oauth(
        providerType: type,
        clientId: 'client',
        credentialRef: 'cred-$id',
        rootId: rootId,
      ),
      createdAt: DateTime.utc(2026, 10, 1),
      updatedAt: DateTime.utc(2026, 10, 1),
      status: ConnectionStatus.active,
    );

/// Plain file sync on Baidu Netdisk, end to end against the stateful fake
/// Baidu cloud: real paths, folders, uploads, downloads and deletions.
void main() {
  late SyncStateDatabase database;
  late PlainFolderSyncProfileRepository profiles;
  late Directory localRoot;
  late BaiduContractCloud cloud;
  late BaiduNetdiskMirrorStore mirror;
  final scopedRoots = <String>[];
  const scopedRoot = '/apps/Velock Sync/联调';

  setUp(() async {
    database = await SyncStateDatabase.inMemory();
    profiles = PlainFolderSyncProfileRepository(database);
    localRoot = await Directory.systemTemp.createTemp('velock-plain-baidu-');
    cloud = BaiduContractCloud();
    final fixture = baiduNetdiskContractFixture(cloud);
    await fixture.reset();
    mirror = (await fixture.createStore() as BaiduNetdiskObjectStore)
        .asMirror();
    cloud.addDirectory(BaiduContractCloud.rootPath);
    scopedRoots.clear();
  });

  tearDown(() async {
    await database.close();
    if (await localRoot.exists()) await localRoot.delete(recursive: true);
  });

  PlainFolderSyncService service() => PlainFolderSyncService(
    database: database,
    profiles: profiles,
    connections: _Connections(),
    oauthRemoteFactory: (protocol, segments) {
      scopedRoots.add([protocol.rootId, ...segments].join('/'));
      return mirror;
    },
  );

  Future<void> saveProfile(String connectionId) => profiles.save(
    PlainFolderSyncProfile(
      profileId: _profileId,
      datasetId: 'dataset-1',
      deviceId: 'device-1',
      displayName: 'Documents',
      localRootReference: localRoot.path,
      localDisplayName: 'documents',
      connectionId: connectionId,
      // The fake's root is `/apps/Velock Sync/联调`.
      remoteRootSegments: const ['联调'],
      createdAt: DateTime.utc(2026, 10, 1),
    ),
  );

  Future<void> writeLocal(String relativePath, String text) async {
    final file = File(p.join(localRoot.path, relativePath));
    await file.parent.create(recursive: true);
    await file.writeAsString(text, flush: true);
    await file.setLastModified(DateTime.utc(2026, 10, 1, 9));
  }

  test('uploads, downloads and deletes real files on Baidu', () async {
    await saveProfile(_baiduId);
    await writeLocal('readme.txt', 'hello');
    await writeLocal('notes/today.txt', 'today');
    cloud.seed('from-cloud.txt', utf8.encode('remote'));

    final first = await service().run(_profileId);

    expect(scopedRoots, everyElement(scopedRoot));
    expect(BaiduContractCloud.rootPath, scopedRoot);
    expect(first.stats.uploadedFileCount, 2);
    expect(first.stats.downloadedFileCount, 1);
    expect(utf8.decode(cloud.bytesOf('readme.txt')!), 'hello');
    expect(utf8.decode(cloud.bytesOf('notes/today.txt')!), 'today');
    expect(
      await File(p.join(localRoot.path, 'from-cloud.txt')).readAsString(),
      'remote',
    );

    // A second run with nothing changed moves nothing.
    final idle = await service().run(_profileId);
    expect(idle.stats.uploadedFileCount, 0);
    expect(idle.stats.downloadedFileCount, 0);

    await File(p.join(localRoot.path, 'readme.txt')).delete();
    final third = await service().run(_profileId);
    expect(third.stats.deletedRemoteCount, 1);
    expect(cloud.bytesOf('readme.txt'), isNull);
    expect(utf8.decode(cloud.bytesOf('notes/today.txt')!), 'today');
    await cloud.verifyClean();
  });

  test('a cloud drive without real paths is refused', () async {
    await saveProfile(_googleId);
    await writeLocal('readme.txt', 'hello');

    await expectLater(
      service().run(_profileId),
      throwsA(
        isA<PlainFolderSyncException>().having(
          (error) => error.syncFailure.errorCode,
          'errorCode',
          'plain_folder.remote_unsupported',
        ),
      ),
    );
    expect(scopedRoots, isEmpty);
  });
}
