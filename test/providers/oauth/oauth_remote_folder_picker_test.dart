import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/secure_storage/in_memory_credential_store.dart';
import 'package:velock_sync/providers/oauth/oauth_remote_folder_picker.dart';
import 'package:velock_sync/providers/oauth/oauth_remote_target_factory.dart';
import 'package:velock_sync/providers/oauth/oauth_token_bundle.dart';
import 'package:velock_sync/providers/provider_rate_limit_retry.dart';
import 'package:velock_sync/providers/provider_request_exception.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

void main() {
  test('lists Google folders visible to the OAuth application', () async {
    final credentials = await _credentials();
    final adapter = _Adapter((options) async {
      expect(options.uri.path, '/drive/v3/files');
      expect(
        options.uri.queryParameters['q'],
        contains("'parent-id' in parents"),
      );
      expect(options.headers['Authorization'], 'Bearer access');
      return _json({
        'nextPageToken': 'next',
        'files': [
          {'id': 'folder-1', 'name': 'Documents'},
        ],
      });
    });
    final picker = OAuthRemoteFolderPicker(
      credentialStore: credentials.store,
      dio: Dio()..httpClientAdapter = adapter,
    );

    final page = await picker.listFolders(
      target: OAuthRemoteTargetConfig(
        providerType: RemoteProviderType.googleDrive,
        clientId: 'client',
        credentialRef: credentials.ref,
        rootId: 'unused',
      ),
      parentId: 'parent-id',
    );

    expect(page.items.single.id, 'folder-1');
    expect(page.items.single.name, 'Documents');
    expect(page.nextCursor, 'next');
  });

  test('lists OneDrive folders from root and a selected child', () async {
    final credentials = await _credentials();
    final requestedPaths = <String>[];
    final adapter = _Adapter((options) async {
      requestedPaths.add(options.uri.path);
      return _json({
        'value': [
          {'id': 'folder-1', 'name': 'Projects', 'folder': {}},
          {'id': 'file-1', 'name': 'ignore.txt', 'file': {}},
        ],
      });
    });
    final picker = OAuthRemoteFolderPicker(
      credentialStore: credentials.store,
      dio: Dio()..httpClientAdapter = adapter,
    );
    final target = OAuthRemoteTargetConfig(
      providerType: RemoteProviderType.oneDrive,
      clientId: 'client',
      credentialRef: credentials.ref,
      rootId: 'unused',
    );

    expect(
      (await picker.listFolders(target: target)).items.single.name,
      'Projects',
    );
    expect(
      (await picker.listFolders(
        target: target,
        parentId: 'folder-1',
      )).items.single.id,
      'folder-1',
    );
    expect(requestedPaths, [
      '/v1.0/me/drive/root/children',
      '/v1.0/me/drive/items/folder-1/children',
    ]);
  });

  test(
    'loads every Google folder page and retries a transient response',
    () async {
      final credentials = await _credentials();
      var requests = 0;
      final picker = OAuthRemoteFolderPicker(
        credentialStore: credentials.store,
        rateLimitRetry: ProviderRateLimitRetry(
          sleeper: (_) async {},
          nextRandomInt: (_) => 0,
        ),
        dio: Dio()
          ..httpClientAdapter = _Adapter((options) async {
            requests++;
            if (requests == 1) return ResponseBody.fromString('', 503);
            if (options.uri.queryParameters['pageToken'] == 'next') {
              return _json({
                'files': [
                  {'id': 'folder-2', 'name': 'Two'},
                ],
              });
            }
            return _json({
              'nextPageToken': 'next',
              'files': [
                {'id': 'folder-1', 'name': 'One'},
              ],
            });
          }),
      );

      final folders = await picker.listAllFolders(
        target: OAuthRemoteTargetConfig(
          providerType: RemoteProviderType.googleDrive,
          clientId: 'client',
          credentialRef: credentials.ref,
          rootId: 'unused',
        ),
      );

      expect(folders.map((folder) => folder.id), ['folder-1', 'folder-2']);
      expect(requests, 3);
    },
  );

  test(
    'maps folder-list permission failures without provider payloads',
    () async {
      final credentials = await _credentials();
      final picker = OAuthRemoteFolderPicker(
        credentialStore: credentials.store,
        dio: Dio()
          ..httpClientAdapter = _Adapter(
            (_) async => ResponseBody.fromString('', 403),
          ),
      );

      await expectLater(
        picker.listFolders(
          target: OAuthRemoteTargetConfig(
            providerType: RemoteProviderType.oneDrive,
            clientId: 'client',
            credentialRef: credentials.ref,
            rootId: 'unused',
          ),
        ),
        throwsA(
          isA<ProviderRequestException>().having(
            (error) => error.kind,
            'kind',
            ProviderRequestErrorKind.permissionRequired,
          ),
        ),
      );
    },
  );
}

Future<_Credentials> _credentials() async {
  final store = InMemoryCredentialStore();
  final ref = await store.writeOAuthTokens(
    OAuthTokenBundle(
      accessToken: 'access',
      refreshToken: 'refresh',
      expiresAt: DateTime.utc(2031),
    ),
  );
  return _Credentials(store, ref);
}

class _Credentials {
  const _Credentials(this.store, this.ref);
  final InMemoryCredentialStore store;
  final String ref;
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions) handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? stream,
    Future<void>? cancelFuture,
  ) => handler(options);
}

Future<ResponseBody> _json(Map<String, dynamic> value) async =>
    ResponseBody.fromString(
      jsonEncode(value),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
