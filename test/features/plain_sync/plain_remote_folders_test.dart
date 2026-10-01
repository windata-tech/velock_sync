import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/features/cloud_backup/application/webdav_backup_folder_browser.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/features/plain_sync/state/plain_remote_folders.dart';
import 'package:velock_sync/infrastructure/secure_storage/in_memory_credential_store.dart';
import 'package:velock_sync/providers/baidu_netdisk/baidu_netdisk_object_store.dart';
import 'package:velock_sync/providers/oauth/oauth_access_token_provider.dart';
import 'package:velock_sync/providers/oauth/oauth_token_bundle.dart';
import 'package:velock_sync/providers/oauth/oauth_token_client.dart';
import 'package:velock_sync/providers/provider_rate_limit_retry.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

import '../../providers/contracts/baidu_netdisk_object_store_contract_fixture.dart';
import '../../providers/contracts/stateful_object_store_contract.dart';

/// Hands out Baidu stores rooted wherever the scoped protocol says, all talking
/// to the same stateful fake cloud.
class _Connections implements ConnectionRepository {
  _Connections(this.cloud, this.tokens);

  final BaiduContractCloud cloud;
  final OAuthAccessTokenProvider tokens;
  final roots = <String>[];

  @override
  RemoteObjectStore createOAuthRemote(OAuthProtocolModel protocol) {
    roots.add(protocol.rootId);
    return BaiduNetdiskObjectStore(
      accessTokenProvider: tokens,
      rootPath: protocol.rootId,
      dio: Dio()..httpClientAdapter = cloud,
      rateLimitRetry: ProviderRateLimitRetry(
        sleeper: (_) async {},
        nextRandomInt: (_) => 0,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ConnectionModel _connection(RemoteProviderType type, String rootId) =>
    ConnectionModel(
      id: type.name,
      name: type.name,
      source: 'source',
      target: 'target',
      protocol: ProtocolModel.oauth(
        providerType: type,
        clientId: 'client',
        credentialRef: 'cred',
        rootId: rootId,
      ),
      createdAt: DateTime.utc(2026, 10, 1),
      updatedAt: DateTime.utc(2026, 10, 1),
      status: ConnectionStatus.active,
    );

void main() {
  late BaiduContractCloud cloud;
  late _Connections connections;
  late PlainRemoteFolders folders;
  const root = '/apps/Velock Sync';
  final baidu = _connection(RemoteProviderType.baiduNetdisk, root);

  setUp(() async {
    cloud = BaiduContractCloud()..reset();
    final credentials = InMemoryCredentialStore();
    final ref = await credentials.writeOAuthTokens(
      OAuthTokenBundle(
        accessToken: 'access',
        refreshToken: 'refresh',
        expiresAt: DateTime.utc(2031),
      ),
    );
    final tokens = OAuthAccessTokenProvider(
      credentialStore: credentials,
      tokenClient: OAuthTokenClient(
        dio: Dio()..httpClientAdapter = cloud,
        clock: () => DateTime.utc(2030),
      ),
      credentialRef: ref,
      clientId: 'client',
      tokenEndpoint: Uri.https(ContractCloud.tokenHost, '/token'),
      clock: () => DateTime.utc(2030),
    );
    connections = _Connections(cloud, tokens);
    folders = PlainRemoteFolders(
      connections: connections,
      webDavLoader: ({required protocol, required relativeSegments}) =>
          throw StateError('not WebDAV'),
      webDavCreator:
          ({required protocol, required relativeSegments, required name}) =>
              throw StateError('not WebDAV'),
    );
  });

  testWidgets('shows where the folders of each drive start', (tester) async {
    await tester.pumpWidget(
      Localizations(
        locale: const Locale('zh'),
        delegates: const [DefaultWidgetsLocalizations.delegate],
        child: const SizedBox(),
      ),
    );
    final context = tester.element(find.byType(SizedBox));
    expect(folders.basePath(context, baidu), root);
    // OneDrive and Aliyun root at a folder ID whose name is not at hand.
    expect(
      folders.basePath(
        context,
        _connection(RemoteProviderType.oneDrive, 'root'),
      ),
      'OneDrive',
    );
    expect(
      folders.basePath(
        context,
        _connection(RemoteProviderType.aliyunDrive, 'drive-1:folder-1'),
      ),
      '阿里云盘/…',
    );
  });

  test('lists only folders, one level, under the chosen path', () async {
    cloud
      ..addDirectory('$root/照片/2026')
      ..addDirectory('$root/文档');
    List<String> names(List<WebDavBackupFolder> list) => [
      for (final folder in list) folder.name,
    ];

    expect(names(await folders.list(baidu, const [])), ['文档', '照片']);
    expect(names(await folders.list(baidu, const ['照片'])), ['2026']);
    expect(connections.roots, [root, '$root/照片']);
  });

  test('a missing app folder lists as empty, not as a failure', () async {
    expect(await folders.list(baidu, const []), isEmpty);
  });

  test('creates exactly one folder inside the chosen parent', () async {
    cloud.addDirectory('$root/照片');

    await folders.create(baidu, const ['照片'], '手机');

    expect(cloud.directories, contains('$root/照片/手机'));
    expect(
      [
        for (final f in await folders.list(baidu, const ['照片'])) f.name,
      ],
      ['手机'],
    );
  });

  test('a cloud drive without real paths is refused', () async {
    final drive = _connection(RemoteProviderType.googleDrive, 'appDataFolder');
    await expectLater(folders.list(drive, const []), throwsArgumentError);
    expect(connections.roots, isEmpty);
  });
}
