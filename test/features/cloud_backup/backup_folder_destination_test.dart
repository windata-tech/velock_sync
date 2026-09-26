import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/features/cloud_backup/application/backup_destination_service.dart';
import 'package:velock_sync/features/cloud_backup/application/webdav_backup_folder_browser.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/remote_object_store_factory.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/providers/webdav/webdav_object_store.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';

import '../../providers/webdav/memory_webdav_adapter.dart';

void main() {
  test(
    'read-only NAS entrance fails, but browsing to the shared folder enables the same production preflight',
    () async {
      final adapter = MemoryWebDavAdapter();
      const folders = ['共享 文件夹', '备份 100%'];
      const protocol = WebDavProtocolModel(
        protocolType: WebDavProtocolType.https,
        address: 'https://nas.test',
        port: '443',
        path: '/',
      );
      final scoped =
          RemoteObjectStoreFactory.scopeProtocol(protocol, folders)
              as WebDavProtocolModel;
      final scopedRoot = RemoteObjectStoreFactory.webDavUri(scoped);
      final writablePrefix = '${scopedRoot.path}/';
      adapter.beforeRequest = (request, body, cancel) async {
        if (request.method == 'MKCOL' &&
            !request.uri.path.startsWith(writablePrefix)) {
          return ResponseBody.fromString('', 405);
        }
        if (request.method == 'PROPFIND') {
          final current = request.uri.pathSegments
              .where((s) => s.isNotEmpty)
              .toList();
          final next = current.isEmpty ? folders[0] : folders[1];
          final href = request.uri
              .replace(pathSegments: [...current, next, ''])
              .path;
          return ResponseBody.fromString(
            '<d:multistatus xmlns:d="DAV:"><d:response><d:href>$href</d:href>'
            '<d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>'
            '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>',
            207,
          );
        }
        return null;
      };
      WebDavObjectStore remote(List<String> selected) {
        final scoped =
            RemoteObjectStoreFactory.scopeProtocol(protocol, selected)
                as WebDavProtocolModel;
        return WebDavObjectStore(
          dio: Dio()..httpClientAdapter = adapter,
          baseUri: RemoteObjectStoreFactory.webDavUri(scoped),
          username: null,
          password: null,
        );
      }

      final service = BackupDestinationService(
        open: (_) async => remote(const []),
        openScoped: (_, selected) async => remote(selected),
        nextId: () => 'folder-regression',
      );
      Future<void> check(List<String> selected) => service.check(
        connectionId: 'nas',
        vaultId: 'vault',
        trustedProducerIds: ['producer'],
        restoring: false,
        remoteRootSegments: selected,
      );
      await expectLater(
        check(const []),
        throwsA(
          isA<SyncFailureException>().having(
            (error) => error.syncFailure.errorCode,
            'error',
            'provider.webdav.collection_not_writable',
          ),
        ),
      );
      expect(adapter.files, isEmpty);
      expect(adapter.requests.where((r) => r.method == 'PUT'), isEmpty);

      final browser = WebDavBackupFolderBrowser(
        connections: _Connections(),
        dio: Dio()..httpClientAdapter = adapter,
      );
      final shares = await browser.list(protocol: protocol);
      final subfolders = await browser.list(
        protocol: protocol,
        relativeSegments: [shares.single.name],
      );
      final selected = [shares.single.name, subfolders.single.name];
      expect(selected, folders);
      final beforeCheck = adapter.requests.length;
      await check(selected);
      final writes = adapter.requests
          .skip(beforeCheck)
          .where(
            (r) => const {'PUT', 'MKCOL', 'MOVE', 'DELETE'}.contains(r.method),
          );
      expect(writes, isNotEmpty);
      expect(
        writes.every((r) => r.uri.path.startsWith(writablePrefix)),
        isTrue,
      );
      expect(
        adapter.files,
        isEmpty,
        reason: 'preflight and atomicity probes clean up only their own files',
      );
      expect(
        protocol.path,
        '/',
        reason: 'existing connection is never retargeted',
      );
    },
  );
}

class _Connections implements ConnectionRepository {
  @override
  Future<String?> readWebDavPassword(String? credentialRef) async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
