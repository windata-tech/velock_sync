import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/secure_storage/in_memory_credential_store.dart';
import 'package:velock_sync/providers/one_drive/one_drive_object_store.dart';
import 'package:velock_sync/providers/oauth/oauth_access_token_provider.dart';
import 'package:velock_sync/providers/oauth/oauth_token_bundle.dart';
import 'package:velock_sync/providers/oauth/oauth_token_client.dart';
import 'package:velock_sync/providers/provider_rate_limit_retry.dart';
import 'package:velock_sync/providers/provider_request_exception.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import '../contracts/object_store_contract.dart';
import '../contracts/one_drive_object_store_contract_fixture.dart';

void main() {
  runObjectStoreContract(OneDriveObjectStoreContractFixture());

  test(
    'rejects a cancelled operation before issuing a Graph request',
    () async {
      final credentials = await _credentials();
      final adapter = _Adapter(
        (_) async => throw StateError('cancelled requests must not reach Dio'),
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final remote = OneDriveObjectStore(
        accessTokenProvider: _provider(credentials, dio),
        rootItemId: 'root-id',
        dio: dio,
      );

      await expectLater(
        remote.list(cancellation: RemoteOperationCancellation()..cancel()),
        throwsA(isA<RemoteOperationCancelledException>()),
      );
    },
  );

  test('lists encoded files and preserves Graph nextLink pagination', () async {
    final credentials = await _credentials();
    final adapter = _Adapter((options) async {
      expect(options.headers['Authorization'], 'Bearer access');
      return _json({
        '@odata.nextLink': 'https://graph.microsoft.com/v1.0/next',
        'value': [
          {
            'id': 'item-id',
            'name': 'velock-YmxvYnMvYWI',
            'size': 3,
            'lastModifiedDateTime': '2030-01-01T00:00:00Z',
            'eTag': 'tag',
            'file': {},
          },
          {'id': 'folder', 'name': 'folder', 'folder': {}},
        ],
      });
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final remote = OneDriveObjectStore(
      accessTokenProvider: _provider(credentials, dio),
      rootItemId: 'root-id',
      dio: dio,
    );

    final page = await remote.list(prefix: 'blobs/');
    expect(page.nextCursor, 'https://graph.microsoft.com/v1.0/next');
    expect(page.items.single.logicalKey, 'blobs/ab');
    expect(page.items.single.etag, 'tag');
  });

  test(
    'fails an immutable upload before opening a Graph upload session',
    () async {
      final credentials = await _credentials();
      final adapter = _Adapter(
        (options) async => _json({
          'value': [
            {
              'id': 'item-id',
              'name': 'velock-YmxvYnMvYWI',
              'size': 3,
              'lastModifiedDateTime': '2030-01-01T00:00:00Z',
              'file': {},
            },
          ],
        }),
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final remote = OneDriveObjectStore(
        accessTokenProvider: _provider(credentials, dio),
        rootItemId: 'root-id',
        dio: dio,
      );
      await expectLater(
        remote.put(
          'blobs/ab',
          Stream.value([1, 2, 3]),
          contentLength: 3,
          ifAbsent: true,
        ),
        throwsA(isA<RemoteObjectAlreadyExistsException>()),
      );
    },
  );

  test(
    'uploads a zero-byte object through the Graph content endpoint',
    () async {
      final credentials = await _credentials();
      final adapter = _Adapter((options) async {
        if (options.method == 'GET') return _json({'value': []});
        expect(options.uri.path, endsWith(':/content'));
        expect(options.headers['Content-Length'], '0');
        return _json({
          'id': 'empty-id',
          'name': 'velock-YmxvYnMvZW1wdHk',
          'size': 0,
          'lastModifiedDateTime': '2030-01-01T00:00:00Z',
          'eTag': 'empty-tag',
        }, status: 201);
      });
      final dio = Dio()..httpClientAdapter = adapter;
      final remote = OneDriveObjectStore(
        accessTokenProvider: _provider(credentials, dio),
        rootItemId: 'root-id',
        dio: dio,
      );
      final item = await remote.put(
        'blobs/empty',
        Stream.empty(),
        contentLength: 0,
      );
      expect(item.size, 0);
      expect(item.etag, 'empty-tag');
    },
  );

  test(
    'uploads a stream through a Graph upload session with a byte range',
    () async {
      final credentials = await _credentials();
      final adapter = _Adapter((options) async {
        if (options.method == 'GET') return _json({'value': []});
        if (options.method == 'POST') {
          expect(options.uri.path, endsWith(':/createUploadSession'));
          return _json({'uploadUrl': 'https://upload.example.test/session'});
        }
        expect(options.uri.host, 'upload.example.test');
        expect(options.headers['Content-Range'], 'bytes 0-2/3');
        return _json({
          'id': 'file-id',
          'name': 'velock-YmxvYnMvYWI',
          'size': 3,
          'lastModifiedDateTime': '2030-01-01T00:00:00Z',
          'eTag': 'tag',
        }, status: 201);
      });
      final dio = Dio()..httpClientAdapter = adapter;
      final remote = OneDriveObjectStore(
        accessTokenProvider: _provider(credentials, dio),
        rootItemId: 'root-id',
        dio: dio,
      );
      final item = await remote.put(
        'blobs/ab',
        Stream.value([1, 2, 3]),
        contentLength: 3,
      );
      expect(item.logicalKey, 'blobs/ab');
      expect(item.size, 3);
    },
  );

  test(
    'safely retries the same Graph upload chunk after a server failure',
    () async {
      final credentials = await _credentials();
      final waits = <Duration>[];
      var uploadAttempts = 0;
      final adapter = _Adapter((options) async {
        if (options.method == 'GET') return _json({'value': []});
        if (options.method == 'POST') {
          return _json({'uploadUrl': 'https://upload.example.test/session'});
        }
        uploadAttempts++;
        expect(options.headers['Content-Range'], 'bytes 0-2/3');
        if (uploadAttempts == 1) return _json({}, status: 503);
        return _json({
          'id': 'file-id',
          'name': 'velock-YmxvYnMvYWI',
          'size': 3,
          'lastModifiedDateTime': '2030-01-01T00:00:00Z',
        }, status: 201);
      });
      final dio = Dio()..httpClientAdapter = adapter;
      final remote = OneDriveObjectStore(
        accessTokenProvider: _provider(credentials, dio),
        rootItemId: 'root-id',
        dio: dio,
        rateLimitRetry: ProviderRateLimitRetry(
          sleeper: (delay) async => waits.add(delay),
          nextRandomInt: (maxExclusive) => 0,
        ),
      );

      final item = await remote.put(
        'blobs/ab',
        Stream.value([1, 2, 3]),
        contentLength: 3,
      );

      expect(item.size, 3);
      expect(uploadAttempts, 2);
      expect(waits, [Duration.zero]);
    },
  );

  test(
    'round-trips a Unicode logical key and deletes the mapped Graph item',
    () async {
      final credentials = await _credentials();
      final adapter = _Adapter((options) async {
        if (options.method == 'DELETE') {
          expect(options.uri.path, '/v1.0/me/drive/items/item-id');
          return ResponseBody.fromString('', 204);
        }
        return _json({
          'value': [
            {
              'id': 'item-id',
              'name': 'velock-YmxvYnMv5L2g5aW9LnR4dA',
              'size': 3,
              'lastModifiedDateTime': '2030-01-01T00:00:00Z',
              'file': {},
            },
          ],
        });
      });
      final dio = Dio()..httpClientAdapter = adapter;
      final remote = OneDriveObjectStore(
        accessTokenProvider: _provider(credentials, dio),
        rootItemId: 'root-id',
        dio: dio,
      );

      final page = await remote.list(prefix: 'blobs/');
      await remote.delete('blobs/你好.txt');

      expect(page.items.single.logicalKey, 'blobs/你好.txt');
    },
  );

  test('backs off a Graph 429 response before retrying', () async {
    final credentials = await _credentials();
    final waits = <Duration>[];
    var calls = 0;
    final adapter = _Adapter((options) async {
      calls++;
      return calls == 1
          ? _json(
              {},
              status: 429,
              headers: const {
                'retry-after': ['0'],
              },
            )
          : _json({'value': []});
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final remote = OneDriveObjectStore(
      accessTokenProvider: _provider(credentials, dio),
      rootItemId: 'root-id',
      dio: dio,
      rateLimitRetry: ProviderRateLimitRetry(
        sleeper: (delay) async => waits.add(delay),
      ),
    );

    final page = await remote.list();

    expect(page.items, isEmpty);
    expect(calls, 2);
    expect(waits, [Duration.zero]);
  });

  test('maps a Graph server response to a retryable provider error', () async {
    final credentials = await _credentials();
    final adapter = _Adapter(
      (options) async => ResponseBody.fromString('', 503),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final remote = OneDriveObjectStore(
      accessTokenProvider: _provider(credentials, dio),
      rootItemId: 'root-id',
      dio: dio,
    );

    await expectLater(
      remote.list(),
      throwsA(
        isA<ProviderRequestException>()
            .having(
              (error) => error.kind,
              'kind',
              ProviderRequestErrorKind.transient,
            )
            .having((error) => error.retryable, 'retryable', isTrue),
      ),
    );
  });
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

OAuthAccessTokenProvider _provider(_Credentials value, Dio dio) =>
    OAuthAccessTokenProvider(
      credentialStore: value.store,
      tokenClient: OAuthTokenClient(dio: dio, clock: () => DateTime.utc(2030)),
      credentialRef: value.ref,
      clientId: 'client',
      tokenEndpoint: Uri.parse('https://token.example.test/token'),
      clock: () => DateTime.utc(2030),
    );

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

Future<ResponseBody> _json(
  Map<String, dynamic> data, {
  int status = 200,
  Map<String, List<String>> headers = const {},
}) async => ResponseBody.fromString(
  jsonEncode(data),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
    ...headers,
  },
);
