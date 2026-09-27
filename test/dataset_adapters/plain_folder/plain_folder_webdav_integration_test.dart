/// End-to-end check of the plain mirror engine against a REAL WebDAV server.
///
/// The test talks to the local WsgiDAV helper the repository already uses for
/// interactive testing:
///
///   tool/local_webdav/start_local_webdav.sh start
///   flutter test test/dataset_adapters/plain_folder/plain_folder_webdav_integration_test.dart
///
/// It never touches the user's NAS. When the server is not reachable the test
/// reports itself as skipped instead of failing, so the normal suite stays
/// hermetic.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_profile.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_service.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/providers/webdav/webdav_object_store.dart';

const _host = '127.0.0.1';
const _port = 8888;
const _user = 'velock';
const _password = 'velock123';

class _LiveConnections implements ConnectionRepository {
  @override
  Future<ConnectionModel?> getConnectionById(String id) async =>
      ConnectionModel(
        id: id,
        name: '本机 WsgiDAV',
        source: '',
        target: '',
        protocol: WebDavProtocolModel(
          protocolType: WebDavProtocolType.http,
          address: 'http://$_host',
          port: '$_port',
          path: '/',
          username: _user,
          credentialRef: 'live',
        ),
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        status: ConnectionStatus.active,
      );

  @override
  Future<String?> readWebDavPassword(String? credentialRef) async => _password;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<bool> _serverIsUp() async {
  try {
    final response = await Dio().requestUri<String>(
      Uri.parse('http://$_host:$_port/'),
      options: Options(
        method: 'PROPFIND',
        headers: {
          'Depth': '0',
          'Authorization':
              'Basic ${base64Encode(utf8.encode('$_user:$_password'))}',
        },
        responseType: ResponseType.plain,
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    // 207/200 prove the share is readable; 401 still proves the server is up.
    return response.statusCode == 207 ||
        response.statusCode == 200 ||
        response.statusCode == 401;
  } on Object {
    return false;
  }
}

void main() {
  // flutter_test installs a mock HTTP client; this live test needs the real one.
  HttpOverrides.global = null;
  setUpAll(() => HttpOverrides.global = null);

  test('mirrors a real folder tree to and from a live WebDAV server', () async {
    if (!await _serverIsUp()) {
      markTestSkipped('Local WsgiDAV on $_host:$_port is not running.');
      return;
    }

    final database = await SyncStateDatabase.inMemory();
    final profiles = PlainFolderSyncProfileRepository(database);
    final localRoot = await Directory.systemTemp.createTemp('plain-live');
    final scope = 'velock-plain-it-${DateTime.now().microsecondsSinceEpoch}';
    final profileId = 'live-profile';
    final connection = await _LiveConnections().getConnectionById('live');

    WebDavObjectStore store(List<String> segments) {
      final protocol = connection!.protocol as WebDavProtocolModel;
      final uri = Uri.parse('http://$_host:$_port/').replace(
        pathSegments: [
          ...protocol.address
              .replaceFirst('http://$_host', '')
              .split('/')
              .where((segment) => segment.isNotEmpty),
          ...segments,
        ],
      );
      return WebDavObjectStore(
        dio: Dio(),
        baseUri: uri,
        username: _user,
        password: _password,
      );
    }

    Future<void> write(String relativePath, String content) async {
      final file = File('${localRoot.path}/$relativePath');
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
    }

    Future<String?> readRemote(String relativePath) async {
      final stream = store([scope]).read(relativePath);
      final bytes = <int>[];
      await for (final chunk in stream) {
        bytes.addAll(chunk);
      }
      return utf8.decode(bytes);
    }

    // Create the remote folder the user would have selected or created in the
    // wizard; the engine then works inside it.
    await store(const []).createCollection(scope);

    final service = PlainFolderSyncService(
      database: database,
      profiles: profiles,
      connections: _LiveConnections(),
      remoteFactory: ({required protocol, required password}) => store([
        scope,
      ]),
    );

    try {
      await profiles.save(
        PlainFolderSyncProfile(
          profileId: profileId,
          datasetId: 'ds-live',
          deviceId: 'device-live',
          displayName: '本机端到端',
          localRootReference: localRoot.path,
          localDisplayName: 'plain-live',
          connectionId: connection!.id,
          remoteRootSegments: [scope],
          createdAt: DateTime.utc(2026, 9, 27),
        ),
      );

      // 1. First sync uploads the whole tree into a scope that does not exist yet.
      await write('notes/a.txt', 'alpha');
      await write('photos/2026/b.txt', 'beta');
      final first = await service.run(profileId);
      expect(first.stats.uploadedFileCount, 2);
      expect(first.stats.downloadedFileCount, 0);
      expect(await readRemote('notes/a.txt'), 'alpha');
      expect(await readRemote('photos/2026/b.txt'), 'beta');
      expect(
        (await database.readMirrorEntries(profileId)).keys,
        containsAll(<String>['notes/a.txt', 'photos/2026/b.txt']),
      );

      // 2. Nothing changed: a second run transfers nothing at all.
      final second = await service.run(profileId);
      expect(second.stats.changedCount, 0);
      expect(second.stats.conflictCount, 0);

      // 3. A remote change comes back down.
      final remoteScope = store([scope]);
      await remoteScope.put(
        'notes/from-cloud.txt',
        Stream<List<int>>.value(utf8.encode('gamma')),
        contentLength: 5,
      );
      final third = await service.run(profileId);
      expect(third.stats.downloadedFileCount, 1);
      expect(
        await File('${localRoot.path}/notes/from-cloud.txt').readAsString(),
        'gamma',
      );

      // 4. A local edit goes back up, and a local deletion reaches the remote.
      await write('notes/a.txt', 'alpha-v2');
      await File('${localRoot.path}/photos/2026/b.txt').delete();
      final fourth = await service.run(profileId);
      expect(fourth.stats.uploadedFileCount, 1);
      expect(fourth.stats.deletedRemoteCount, 1);
      expect(await readRemote('notes/a.txt'), 'alpha-v2');
      expect(await remoteScope.stat('photos/2026/b.txt'), isNull);

      // 5. Both sides changed the same file: the default policy keeps both.
      await write('notes/a.txt', 'local-version');
      await remoteScope.put(
        'notes/a.txt',
        Stream<List<int>>.value(utf8.encode('remote-version')),
        contentLength: 'remote-version'.length,
      );
      final fifth = await service.run(profileId);
      expect(fifth.stats.conflictCount, 1);
      expect(await readRemote('notes/a.txt'), 'remote-version');
      expect(
        await File('${localRoot.path}/notes/a.txt').readAsString(),
        'remote-version',
      );
      final conflicts = Directory('${localRoot.path}/notes')
          .listSync()
          .whereType<File>()
          .map((file) => file.uri.pathSegments.last)
          .where((name) => name.contains('本机冲突'))
          .toList();
      expect(conflicts, hasLength(1));
      expect(
        await File('${localRoot.path}/notes/${conflicts.single}').readAsString(),
        'local-version',
      );
    } finally {
      // Remove only the scope this test created.
      try {
        await store(const []).delete(scope);
      } on Object {
        // A leftover test folder must not fail an otherwise green run.
      }
      await database.close();
      await localRoot.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
