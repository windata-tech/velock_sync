import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/secure_storage/in_memory_credential_store.dart';
import 'package:velock_sync/providers/google_drive/google_drive_object_store.dart';
import 'package:velock_sync/providers/oauth/oauth_access_token_provider.dart';
import 'package:velock_sync/providers/oauth/oauth_token_bundle.dart';
import 'package:velock_sync/providers/oauth/oauth_token_client.dart';
import 'package:velock_sync/providers/provider_rate_limit_retry.dart';
import 'package:velock_sync/providers/provider_request_exception.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';

import '../contracts/google_drive_object_store_contract_fixture.dart';
import '../contracts/object_store_contract.dart';

void main() {
  runObjectStoreContract(GoogleDriveObjectStoreContractFixture());

  test(
    'rejects a cancelled operation before issuing a Drive request',
    () async {
      final credentials = await _store();
      final adapter = _Adapter(
        (_) async => throw StateError('cancelled requests must not reach Dio'),
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final remote = GoogleDriveObjectStore(
        accessTokenProvider: _provider(credentials, dio),
        parentId: 'root-id',
        dio: dio,
      );

      await expectLater(
        remote.list(cancellation: RemoteOperationCancellation()..cancel()),
        throwsA(isA<RemoteOperationCancelledException>()),
      );
    },
  );

  test('lists decoded logical keys and carries the Drive page token', () async {
    final credentials = await _store();
    final adapter = _Adapter((options) async {
      expect(options.headers['Authorization'], 'Bearer access');
      expect(
        options.uri.queryParameters['q'],
        contains("'root-id' in parents"),
      );
      return _json(options, {
        'nextPageToken': 'next-page',
        'files': [
          {
            'id': 'one',
            'name': 'velock-YmxvYnMvYWI',
            'size': '3',
            'modifiedTime': '2030-01-01T00:00:00Z',
            'md5Checksum': 'hash',
          },
          {'id': 'ignored', 'name': 'ordinary-file'},
        ],
      });
    });
    final remote = GoogleDriveObjectStore(
      accessTokenProvider: _provider(
        credentials,
        Dio()..httpClientAdapter = adapter,
      ),
      parentId: 'root-id',
      dio: Dio()..httpClientAdapter = adapter,
    );

    final page = await remote.list(prefix: 'blobs/');
    expect(page.nextCursor, 'next-page');
    expect(page.items.single.logicalKey, 'blobs/ab');
    expect(page.items.single.etag, 'hash');
  });

  test('retries a 401 once with a refreshed bearer token', () async {
    final credentials = await _store();
    var downloadAttempts = 0;
    final adapter = _Adapter((options) async {
      if (options.uri.host == 'token.example.test') {
        return _json(options, {
          'access_token': 'refreshed',
          'expires_in': 3600,
        });
      }
      if (options.uri.path == '/drive/v3/files') {
        return _json(options, {
          'files': [
            {
              'id': 'file-id',
              'name': 'velock-YmxvYnMvYWI',
              'size': '3',
              'modifiedTime': '2030-01-01T00:00:00Z',
            },
          ],
        });
      }
      downloadAttempts++;
      if (downloadAttempts == 1) return ResponseBody.fromString('', 401);
      expect(options.headers['Authorization'], 'Bearer refreshed');
      return ResponseBody.fromBytes([1, 2, 3], 200);
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final remote = GoogleDriveObjectStore(
      accessTokenProvider: _provider(credentials, dio),
      parentId: 'root-id',
      dio: dio,
    );

    expect(await remote.read('blobs/ab').expand((value) => value).toList(), [
      1,
      2,
      3,
    ]);
    expect(downloadAttempts, 2);
  });

  test('rejects existing immutable objects before upload', () async {
    final credentials = await _store();
    final adapter = _Adapter(
      (options) async => _json(options, {
        'files': [
          {
            'id': 'file-id',
            'name': 'velock-YmxvYnMvYWI',
            'size': '3',
            'modifiedTime': '2030-01-01T00:00:00Z',
          },
        ],
      }),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final remote = GoogleDriveObjectStore(
      accessTokenProvider: _provider(credentials, dio),
      parentId: 'root-id',
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
  });

  test('uploads a stream through a Drive resumable session', () async {
    final credentials = await _store();
    final adapter = _Adapter((options) async {
      if (options.uri.path == '/drive/v3/files') {
        return _json(options, {'files': []});
      }
      if (options.uri.path == '/upload/drive/v3/files') {
        expect(options.uri.queryParameters['uploadType'], 'resumable');
        return ResponseBody.fromString(
          '',
          200,
          headers: {
            'location': ['https://upload.example.test/session'],
          },
        );
      }
      expect(options.uri.host, 'upload.example.test');
      expect(options.headers['Content-Length'], '3');
      expect(options.headers['Content-Range'], 'bytes 0-2/3');
      return _json(options, {
        'id': 'file-id',
        'name': 'velock-YmxvYnMvYWI',
        'size': '3',
        'modifiedTime': '2030-01-01T00:00:00Z',
        'md5Checksum': 'hash',
      }, status: 201);
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final remote = GoogleDriveObjectStore(
      accessTokenProvider: _provider(credentials, dio),
      parentId: 'root-id',
      dio: dio,
    );
    final item = await remote.put(
      'blobs/ab',
      Stream.value([1, 2, 3]),
      contentLength: 3,
    );
    expect(item.size, 3);
    expect(item.etag, 'hash');
  });

  test(
    'safely retries the same Drive upload chunk after a server failure',
    () async {
      final credentials = await _store();
      final waits = <Duration>[];
      var uploadAttempts = 0;
      final adapter = _Adapter((options) async {
        if (options.uri.path == '/drive/v3/files') {
          return _json(options, {'files': []});
        }
        if (options.uri.path == '/upload/drive/v3/files') {
          return ResponseBody.fromString(
            '',
            200,
            headers: {
              'location': ['https://upload.example.test/session'],
            },
          );
        }
        uploadAttempts++;
        expect(options.headers['Content-Range'], 'bytes 0-2/3');
        if (uploadAttempts == 1) return _json(options, {}, status: 503);
        return _json(options, {
          'id': 'file-id',
          'name': 'velock-YmxvYnMvYWI',
          'size': '3',
          'modifiedTime': '2030-01-01T00:00:00Z',
          'md5Checksum': 'hash',
        }, status: 201);
      });
      final dio = Dio()..httpClientAdapter = adapter;
      final remote = GoogleDriveObjectStore(
        accessTokenProvider: _provider(credentials, dio),
        parentId: 'root-id',
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
    'uploads a zero-byte Drive object through the resumable session',
    () async {
      final credentials = await _store();
      final adapter = _Adapter((options) async {
        if (options.uri.path == '/drive/v3/files') {
          return _json(options, {'files': []});
        }
        if (options.uri.path == '/upload/drive/v3/files') {
          return ResponseBody.fromString(
            '',
            200,
            headers: {
              'location': ['https://upload.example.test/session'],
            },
          );
        }
        expect(options.headers['Content-Length'], '0');
        expect(options.headers.containsKey('Content-Range'), isFalse);
        return _json(options, {
          'id': 'empty-id',
          'name': 'velock-YmxvYnMvZW1wdHk',
          'size': '0',
          'modifiedTime': '2030-01-01T00:00:00Z',
        }, status: 201);
      });
      final dio = Dio()..httpClientAdapter = adapter;
      final remote = GoogleDriveObjectStore(
        accessTokenProvider: _provider(credentials, dio),
        parentId: 'root-id',
        dio: dio,
      );

      final item = await remote.put(
        'blobs/empty',
        Stream.empty(),
        contentLength: 0,
      );

      expect(item.size, 0);
    },
  );

  test(
    'continues a multi-chunk Drive upload only after a 308 response',
    () async {
      final credentials = await _store();
      final content = Uint8List(8 * 256 * 1024 + 1);
      var chunks = 0;
      final adapter = _Adapter((options) async {
        if (options.uri.path == '/drive/v3/files') {
          return _json(options, {'files': []});
        }
        if (options.uri.path == '/upload/drive/v3/files') {
          return ResponseBody.fromString(
            '',
            200,
            headers: {
              'location': ['https://upload.example.test/session'],
            },
          );
        }
        chunks++;
        if (chunks == 1) {
          expect(options.headers['Content-Range'], 'bytes 0-2097151/2097153');
          return _json(options, {}, status: 308);
        }
        expect(
          options.headers['Content-Range'],
          'bytes 2097152-2097152/2097153',
        );
        return _json(options, {
          'id': 'file-id',
          'name': 'velock-YmxvYnMvYmln',
          'size': '2097153',
          'modifiedTime': '2030-01-01T00:00:00Z',
        }, status: 201);
      });
      final dio = Dio()..httpClientAdapter = adapter;
      final remote = GoogleDriveObjectStore(
        accessTokenProvider: _provider(credentials, dio),
        parentId: 'root-id',
        dio: dio,
      );

      final item = await remote.put(
        'blobs/big',
        Stream.value(content),
        contentLength: content.length,
      );

      expect(item.size, content.length);
      expect(chunks, 2);
    },
  );

  test(
    'round-trips a Unicode logical key and deletes the mapped Drive file',
    () async {
      final credentials = await _store();
      final adapter = _Adapter((options) async {
        if (options.method == 'DELETE') {
          expect(options.uri.path, '/drive/v3/files/file-id');
          return ResponseBody.fromString('', 204);
        }
        return _json(options, {
          'files': [
            {
              'id': 'file-id',
              'name': 'velock-YmxvYnMv5L2g5aW9LnR4dA',
              'size': '3',
              'modifiedTime': '2030-01-01T00:00:00Z',
            },
          ],
        });
      });
      final dio = Dio()..httpClientAdapter = adapter;
      final remote = GoogleDriveObjectStore(
        accessTokenProvider: _provider(credentials, dio),
        parentId: 'root-id',
        dio: dio,
      );

      final page = await remote.list(prefix: 'blobs/');
      await remote.delete('blobs/你好.txt');

      expect(page.items.single.logicalKey, 'blobs/你好.txt');
    },
  );

  test('backs off a Drive 429 response before retrying', () async {
    final credentials = await _store();
    var calls = 0;
    final waits = <Duration>[];
    final adapter = _Adapter((options) async {
      calls++;
      if (calls == 1) {
        return ResponseBody.fromString(
          '',
          429,
          headers: {
            'retry-after': ['0'],
          },
        );
      }
      return _json(options, {'files': []});
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final remote = GoogleDriveObjectStore(
      accessTokenProvider: _provider(credentials, dio),
      parentId: 'root-id',
      dio: dio,
      rateLimitRetry: ProviderRateLimitRetry(
        sleeper: (delay) async => waits.add(delay),
      ),
    );
    expect((await remote.list()).items, isEmpty);
    expect(calls, 2);
    expect(waits, [Duration.zero]);
  });

  test(
    'maps a Drive permission response to a sanitized provider error',
    () async {
      final credentials = await _store();
      final adapter = _Adapter(
        (options) async => ResponseBody.fromString('', 403),
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final remote = GoogleDriveObjectStore(
        accessTokenProvider: _provider(credentials, dio),
        parentId: 'root-id',
        dio: dio,
      );

      await expectLater(
        remote.list(),
        throwsA(
          isA<ProviderRequestException>()
              .having(
                (error) => error.kind,
                'kind',
                ProviderRequestErrorKind.permissionRequired,
              )
              .having((error) => error.retryable, 'retryable', isFalse),
        ),
      );
    },
  );
}

Future<_Credentials> _store() async {
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

OAuthAccessTokenProvider _provider(_Credentials credentials, Dio dio) =>
    OAuthAccessTokenProvider(
      credentialStore: credentials.store,
      tokenClient: OAuthTokenClient(dio: dio, clock: () => DateTime.utc(2030)),
      credentialRef: credentials.ref,
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
  _Adapter(this._handler);
  final Future<ResponseBody> Function(RequestOptions) _handler;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? stream,
    Future<void>? cancelFuture,
  ) => _handler(options);
}

Future<ResponseBody> _json(
  RequestOptions _,
  Map<String, dynamic> value, {
  int status = 200,
}) async => ResponseBody.fromString(
  jsonEncode(value),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);
