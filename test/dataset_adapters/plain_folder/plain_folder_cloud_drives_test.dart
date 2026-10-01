import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_profile.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_service.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/secure_storage/in_memory_credential_store.dart';
import 'package:velock_sync/providers/aliyun_drive/aliyun_drive_object_store.dart';
import 'package:velock_sync/providers/google_drive/google_drive_object_store.dart';
import 'package:velock_sync/providers/oauth/oauth_access_token_provider.dart';
import 'package:velock_sync/providers/oauth/oauth_token_bundle.dart';
import 'package:velock_sync/providers/oauth/oauth_token_client.dart';
import 'package:velock_sync/providers/one_drive/one_drive_object_store.dart';
import 'package:velock_sync/providers/provider_rate_limit_retry.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

import '../../providers/contracts/aliyun_tree_cloud.dart';
import '../../providers/contracts/google_tree_cloud.dart';
import '../../providers/contracts/one_drive_tree_cloud.dart';
import '../../providers/contracts/stateful_object_store_contract.dart';

const _profileId = 'plain-cloud';
const _connectionId = 'cloud';

/// A drive under test: its fake cloud, the connection's root and how the
/// production code builds a store for it.
class _Drive {
  _Drive(this.type, this.cloud, this.rootId, this.build);

  final RemoteProviderType type;
  final ContractCloud cloud;
  final String Function() rootId;
  final RemoteObjectStore Function(
    OAuthAccessTokenProvider tokens,
    Dio dio,
    String rootId,
  )
  build;
}

/// Hands out stores the way the app does: from the saved protocol, so the
/// folder scope is applied by the production mirror factory.
class _Connections implements ConnectionRepository {
  _Connections(this.drive, this.tokens);

  final _Drive drive;
  final OAuthAccessTokenProvider tokens;

  /// Google Drive connections made for file sync carry full Drive access.
  bool fullDriveAccess = true;

  @override
  Future<ConnectionModel?> getConnectionById(String id) async =>
      id != _connectionId
      ? null
      : ConnectionModel(
          id: id,
          name: id,
          source: 'source',
          target: 'target',
          protocol: ProtocolModel.oauth(
            providerType: drive.type,
            clientId: 'client',
            credentialRef: 'cred',
            rootId: drive.rootId(),
            fullDriveAccess:
                fullDriveAccess && drive.type == RemoteProviderType.googleDrive,
          ),
          createdAt: DateTime.utc(2026, 10, 1),
          updatedAt: DateTime.utc(2026, 10, 1),
          status: ConnectionStatus.active,
        );

  @override
  RemoteObjectStore createOAuthRemote(OAuthProtocolModel protocol) => drive
      .build(tokens, Dio()..httpClientAdapter = drive.cloud, protocol.rootId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ProviderRateLimitRetry _retry() =>
    ProviderRateLimitRetry(sleeper: (_) async {}, nextRandomInt: (_) => 0);

/// Plain file sync on OneDrive, Aliyun Drive and Google Drive, end to end against stateful
/// fake clouds: real names and folders, uploads, downloads, replacements and
/// deletions, all through the production mirror factory and scope.
void main() {
  final oneDrive = OneDriveTreeCloud();
  final aliyun = AliyunTreeCloud();
  final google = GoogleTreeCloud();
  final drives = [
    _Drive(
      RemoteProviderType.oneDrive,
      oneDrive,
      () => oneDrive.connectionRootId,
      (tokens, dio, rootId) => OneDriveObjectStore(
        accessTokenProvider: tokens,
        rootItemId: rootId,
        dio: dio,
        rateLimitRetry: _retry(),
      ),
    ),
    _Drive(
      RemoteProviderType.aliyunDrive,
      aliyun,
      () => aliyun.rootIdForStore,
      (tokens, dio, rootId) => AliyunDriveObjectStore(
        accessTokenProvider: tokens,
        rootId: rootId,
        dio: dio,
        rateLimitRetry: _retry(),
      ),
    ),
    _Drive(
      RemoteProviderType.googleDrive,
      google,
      () => google.connectionRootId,
      (tokens, dio, rootId) => GoogleDriveObjectStore(
        accessTokenProvider: tokens,
        parentId: rootId,
        dio: dio,
        rateLimitRetry: _retry(),
      ),
    ),
  ];

  for (final drive in drives) {
    group(drive.type.name, () {
      late SyncStateDatabase database;
      late PlainFolderSyncProfileRepository profiles;
      late Directory localRoot;
      late _Connections connections;

      setUp(() async {
        drive.cloud.reset();
        if (drive.cloud case final OneDriveTreeCloud cloud) {
          cloud.useFolderRoot('同步盘');
        }
        database = await SyncStateDatabase.inMemory();
        profiles = PlainFolderSyncProfileRepository(database);
        localRoot = await Directory.systemTemp.createTemp(
          'velock-plain-cloud-',
        );
        final credentials = InMemoryCredentialStore();
        final ref = await credentials.writeOAuthTokens(
          OAuthTokenBundle(
            accessToken: 'contract-access',
            refreshToken: 'refresh',
            expiresAt: DateTime.utc(2031),
          ),
        );
        connections = _Connections(
          drive,
          OAuthAccessTokenProvider(
            credentialStore: credentials,
            tokenClient: OAuthTokenClient(
              dio: Dio()..httpClientAdapter = drive.cloud,
              clock: () => DateTime.utc(2030),
            ),
            credentialRef: ref,
            clientId: 'client',
            tokenEndpoint: Uri.https(ContractCloud.tokenHost, '/token'),
            clock: () => DateTime.utc(2030),
          ),
        );
        await profiles.save(
          PlainFolderSyncProfile(
            profileId: _profileId,
            datasetId: 'dataset-1',
            deviceId: 'device-1',
            displayName: 'Documents',
            localRootReference: localRoot.path,
            localDisplayName: 'documents',
            connectionId: _connectionId,
            remoteRootSegments: const ['联调'],
            createdAt: DateTime.utc(2026, 10, 1),
          ),
        );
      });

      tearDown(() async {
        await database.close();
        if (await localRoot.exists()) await localRoot.delete(recursive: true);
      });

      PlainFolderSyncService service() => PlainFolderSyncService(
        database: database,
        profiles: profiles,
        connections: connections,
      );

      Future<void> writeLocal(String relativePath, String text) async {
        final file = File(p.join(localRoot.path, relativePath));
        await file.parent.create(recursive: true);
        await file.writeAsString(text, flush: true);
        await file.setLastModified(DateTime.utc(2026, 10, 1, 9));
      }

      String? remoteText(String path) {
        final bytes = drive.cloud.bytesOf('联调/$path');
        return bytes == null ? null : utf8.decode(bytes);
      }

      test('uploads, downloads, replaces and deletes real files', () async {
        drive.cloud.seed('联调/from-cloud.txt', utf8.encode('remote'));
        await writeLocal('readme.txt', 'hello');
        await writeLocal('notes/today.txt', 'today');

        final first = await service().run(_profileId);
        expect(first.stats.uploadedFileCount, 2);
        expect(first.stats.downloadedFileCount, 1);
        expect(remoteText('readme.txt'), 'hello');
        expect(remoteText('notes/today.txt'), 'today');
        expect(
          await File(p.join(localRoot.path, 'from-cloud.txt')).readAsString(),
          'remote',
        );

        // A second run with nothing changed moves nothing.
        final idle = await service().run(_profileId);
        expect(idle.stats.uploadedFileCount, 0);
        expect(idle.stats.downloadedFileCount, 0);

        // An edited file replaces the remote copy and then settles.
        final edited = File(p.join(localRoot.path, 'readme.txt'));
        await edited.writeAsString('hello again', flush: true);
        await edited.setLastModified(DateTime.utc(2026, 10, 2, 9));
        final replaced = await service().run(_profileId);
        expect(replaced.stats.uploadedFileCount, 1);
        expect(remoteText('readme.txt'), 'hello again');
        final settled = await service().run(_profileId);
        expect(settled.stats.uploadedFileCount, 0);
        expect(settled.stats.downloadedFileCount, 0);

        await edited.delete();
        final third = await service().run(_profileId);
        expect(third.stats.deletedRemoteCount, 1);
        expect(remoteText('readme.txt'), isNull);
        expect(remoteText('notes/today.txt'), 'today');
      });

      test('a remote folder that is gone fails instead of emptying', () async {
        await writeLocal('readme.txt', 'hello');
        await expectLater(
          service().run(_profileId),
          throwsA(
            isA<PlainFolderSyncException>().having(
              (error) => error.syncFailure.errorCode,
              'errorCode',
              'plain_folder.remote_folder_missing',
            ),
          ),
        );
        expect(drive.cloud.bytesOf('联调/readme.txt'), isNull);
      });

      test('the write check passes in an existing folder', () async {
        drive.cloud.seed('联调/keep.txt', [1]);
        await service().checkRemoteWritableFor(
          connectionId: _connectionId,
          remoteRootSegments: const ['联调'],
        );
        // The probe cleaned up after itself.
        expect(drive.cloud.bytesOf('联调/keep.txt'), [1]);
      });

      if (drive.cloud case final GoogleTreeCloud cloud) {
        test('two files of one name stop the run, nothing is lost', () async {
          cloud
            ..seed('联调/报告.txt', utf8.encode('one'))
            ..addDuplicate('联调/报告.txt', bytes: utf8.encode('two'));
          await writeLocal('mine.txt', 'mine');
          Object? error;
          try {
            await service().run(_profileId);
          } on Object catch (e) {
            error = e;
          }
          expect(error, isA<SyncFailureException>());
          expect(
            (error! as SyncFailureException).syncFailure.errorCode,
            'provider.google.duplicate_name',
          );
          expect(cloud.namesIn('联调'), ['报告.txt', '报告.txt']);
          expect(
            await File(p.join(localRoot.path, 'mine.txt')).readAsString(),
            'mine',
          );
          expect(cloud.tree.recycled, isEmpty);
        });

        test('Google Docs in the folder are left alone', () async {
          cloud
            ..seed('联调/a.txt', utf8.encode('a'))
            ..addDoc('联调/会议纪要');
          final result = await service().run(_profileId);
          expect(result.stats.downloadedFileCount, 1);
          expect(
            await Directory(
              localRoot.path,
            ).list().map((entry) => p.basename(entry.path)).toList(),
            ['a.txt'],
          );
          expect(cloud.namesIn('联调'), ['a.txt', '会议纪要']);
        });

        test('a backup connection without full access is refused', () async {
          cloud.seed('联调/a.txt', [1]);
          connections.fullDriveAccess = false;
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
          expect(cloud.requests, isEmpty);
        });
      }
    });
  }
}
