import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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

import 'object_store_contract_fixture.dart';

class OneDriveObjectStoreContractFixture implements ObjectStoreContractFixture {
  static const _chunkBytes = 10 * 1024 * 1024;
  final _OneDriveContractAdapter _adapter = _OneDriveContractAdapter();
  late ProviderRateLimitRetry _retry;

  @override
  String get providerName => 'one_drive';

  @override
  ObjectStoreContractCapabilities get capabilities =>
      const ObjectStoreContractCapabilities(
        supportsResumableUpload: true,
        authorizationMode: ObjectStoreAuthorizationMode.oauthRefresh,
      );

  @override
  late final Map<ObjectStoreContract, ObjectStoreContractCheck> checks = {
    ObjectStoreContract.zeroByteRoundTrip: _zeroByteRoundTrip,
    ObjectStoreContract.smallObjectRoundTrip: _smallObjectRoundTrip,
    ObjectStoreContract.largeStreamingWrite: _largeStreamingWrite,
    ObjectStoreContract.interruptedImmutableSafeRetry:
        _interruptedImmutableSafeRetry,
    ObjectStoreContract.immutableCollision: _immutableCollision,
    ObjectStoreContract.paginationDeduplication: _paginationDeduplication,
    ObjectStoreContract.notFoundMapping: _notFoundMapping,
    ObjectStoreContract.authorizationRecovery: _authorizationRecovery,
    ObjectStoreContract.rateLimitCancellation: _rateLimitCancellation,
    ObjectStoreContract.transferIntegrity: _transferIntegrity,
    ObjectStoreContract.unicodeLogicalKey: _unicodeLogicalKey,
    ObjectStoreContract.idempotentDelete: _idempotentDelete,
    ObjectStoreContract.cancellationCleanup: _cancellationCleanup,
    ObjectStoreContract.quotaMapping: _quotaMapping,
    ObjectStoreContract.traversalRejection: _traversalRejection,
    ObjectStoreContract.redactedErrors: _redactedErrors,
  };

  @override
  Future<void> reset() async {
    _adapter.reset();
    _retry = ProviderRateLimitRetry(
      sleeper: (_) async {},
      nextRandomInt: (_) => 0,
    );
  }

  @override
  Future<void> arrange(ObjectStoreContract contract) async {
    if (contract != ObjectStoreContract.rateLimitCancellation) return;
    final sleeperStarted = Completer<void>();
    final never = Completer<void>();
    _retry = ProviderRateLimitRetry(
      sleeper: (_) {
        sleeperStarted.complete();
        return never.future;
      },
      nextRandomInt: (_) => 0,
    );
    _adapter.context = sleeperStarted;
  }

  @override
  Future<RemoteObjectStore> createStore() async {
    final credentialStore = InMemoryCredentialStore();
    final ref = await credentialStore.writeOAuthTokens(
      OAuthTokenBundle(
        accessToken: 'contract-access',
        refreshToken: 'contract-refresh',
        expiresAt: DateTime.utc(2031),
      ),
    );
    final dio = Dio()..httpClientAdapter = _adapter;
    return OneDriveObjectStore(
      accessTokenProvider: OAuthAccessTokenProvider(
        credentialStore: credentialStore,
        tokenClient: OAuthTokenClient(
          dio: dio,
          clock: () => DateTime.utc(2030),
        ),
        credentialRef: ref,
        clientId: 'contract-client',
        tokenEndpoint: Uri.parse('https://token.example.test/token'),
        clock: () => DateTime.utc(2030),
      ),
      rootItemId: 'root-id',
      dio: dio,
      rateLimitRetry: _retry,
    );
  }

  Future<void> _zeroByteRoundTrip(RemoteObjectStore store) async {
    var uploaded = false;
    _adapter.handler = (options, body, _) async {
      if (_isGraphList(options)) {
        return _json({
          'value': uploaded
              ? [_item('blobs/zero', id: 'zero-id', size: 0, download: true)]
              : [],
        });
      }
      if (_isZeroContentUpload(options)) {
        uploaded = true;
        expect(options.headers['Content-Length'], '0');
        expect(await _body(body), isEmpty);
        return _json(_item('blobs/zero', id: 'zero-id', size: 0), status: 201);
      }
      if (_isDownload(options)) return ResponseBody.fromBytes(const [], 200);
      throw StateError('Unexpected OneDrive request: ${options.uri}');
    };
    final result = await store.put(
      'blobs/zero',
      const Stream<List<int>>.empty(),
      contentLength: 0,
    );
    expect(result.size, 0);
    expect(
      await store.read('blobs/zero').expand((chunk) => chunk).toList(),
      isEmpty,
    );
  }

  Future<void> _smallObjectRoundTrip(RemoteObjectStore store) async {
    const bytes = [1, 2, 3];
    var uploaded = false;
    _adapter.handler = (options, body, _) async {
      if (_isGraphList(options)) {
        return _json({
          'value': uploaded
              ? [
                  _item(
                    'blobs/small',
                    id: 'small-id',
                    size: bytes.length,
                    download: true,
                  ),
                ]
              : [],
        });
      }
      if (_isUploadSession(options)) return _uploadSession();
      if (_isUploadChunk(options)) {
        uploaded = true;
        expect(options.headers['Content-Range'], 'bytes 0-2/3');
        expect(await _body(body), bytes);
        return _json(
          _item('blobs/small', id: 'small-id', size: bytes.length),
          status: 201,
        );
      }
      if (_isDownload(options)) return ResponseBody.fromBytes(bytes, 200);
      throw StateError('Unexpected OneDrive request: ${options.uri}');
    };
    final result = await store.put(
      'blobs/small',
      Stream.value(bytes),
      contentLength: bytes.length,
    );
    expect(result.size, bytes.length);
    expect(
      await store.read('blobs/small').expand((chunk) => chunk).toList(),
      bytes,
    );
  }

  Future<void> _largeStreamingWrite(RemoteObjectStore store) async {
    final bytes = Uint8List(_chunkBytes + 1);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = i % 251;
    }
    final observedLengths = <int>[];
    _adapter.handler = (options, body, _) async {
      if (_isGraphList(options)) return _json({'value': []});
      if (_isUploadSession(options)) return _uploadSession();
      if (_isUploadChunk(options)) {
        final uploaded = await _body(body);
        observedLengths.add(uploaded.length);
        final start = observedLengths.length == 1 ? 0 : _chunkBytes;
        final end = start + uploaded.length - 1;
        expect(
          options.headers['Content-Range'],
          'bytes $start-$end/${bytes.length}',
        );
        return observedLengths.length == 1
            ? _json({}, status: 202)
            : _json(_item('blobs/large', size: bytes.length), status: 201);
      }
      throw StateError('Unexpected OneDrive request: ${options.uri}');
    };
    final source = Stream<List<int>>.multi((controller) {
      controller
        ..add(bytes.sublist(0, 1024))
        ..add(bytes.sublist(1024, _chunkBytes + 1))
        ..close();
    });
    final result = await store.put(
      'blobs/large',
      source,
      contentLength: bytes.length,
    );
    expect(result.size, bytes.length);
    expect(observedLengths, [_chunkBytes, 1]);
  }

  Future<void> _interruptedImmutableSafeRetry(RemoteObjectStore store) async {
    var attempts = 0;
    _adapter.handler = (options, body, _) async {
      if (_isGraphList(options)) return _json({'value': []});
      if (_isUploadSession(options)) return _uploadSession();
      if (_isUploadChunk(options)) {
        attempts++;
        expect(options.headers['Content-Range'], 'bytes 0-2/3');
        expect(await _body(body), [7, 8, 9]);
        return attempts == 1
            ? _json({}, status: 503)
            : _json(_item('blobs/retry', size: 3), status: 201);
      }
      throw StateError('Unexpected OneDrive request: ${options.uri}');
    };
    await store.put(
      'blobs/retry',
      Stream.value([7, 8, 9]),
      contentLength: 3,
      ifAbsent: true,
    );
    expect(attempts, 2);
  }

  Future<void> _immutableCollision(RemoteObjectStore store) async {
    _adapter.handler = (options, _, _) async {
      if (_isGraphList(options)) {
        return _json({
          'value': [_item('blobs/existing')],
        });
      }
      throw StateError('Unexpected OneDrive request: ${options.uri}');
    };
    await expectLater(
      store.put(
        'blobs/existing',
        Stream.value([1]),
        contentLength: 1,
        ifAbsent: true,
      ),
      throwsA(isA<RemoteObjectAlreadyExistsException>()),
    );
    expect(_adapter.requests.where(_isUploadSession).toList(), isEmpty);
  }

  Future<void> _paginationDeduplication(RemoteObjectStore store) async {
    _adapter.handler = (options, _, _) async {
      expect(options.uri.queryParameters[r'$top'], '10');
      return _json({
        '@odata.nextLink': 'https://graph.microsoft.com/v1.0/next',
        'value': [
          _item('blobs/z'),
          _item('blobs/a'),
          _item('blobs/a', id: 'duplicate-id'),
          _item('other/outside'),
        ],
      });
    };
    final page = await store.list(prefix: 'blobs/', limit: 10);
    expect(page.items.map((item) => item.logicalKey), ['blobs/a', 'blobs/z']);
    expect(page.nextCursor, 'https://graph.microsoft.com/v1.0/next');
  }

  Future<void> _notFoundMapping(RemoteObjectStore store) async {
    _adapter.handler = (options, _, _) async {
      if (_isGraphList(options)) return _json({'value': []});
      throw StateError('Unexpected OneDrive request: ${options.uri}');
    };
    await expectLater(
      store.read('blobs/missing').drain(),
      throwsA(isA<RemoteObjectNotFoundException>()),
    );
  }

  Future<void> _authorizationRecovery(RemoteObjectStore store) async {
    var graphCalls = 0;
    var tokenCalls = 0;
    _adapter.handler = (options, _, _) async {
      if (options.uri.host == 'token.example.test') {
        tokenCalls++;
        return _json({
          'access_token': 'refreshed-access',
          'refresh_token': 'contract-refresh',
          'expires_in': 3600,
        });
      }
      if (_isGraphList(options)) {
        graphCalls++;
        return _json({}, status: 401);
      }
      throw StateError('Unexpected OneDrive request: ${options.uri}');
    };
    await expectLater(
      store.list(),
      throwsA(
        isA<ProviderRequestException>().having(
          (error) => error.kind,
          'kind',
          ProviderRequestErrorKind.authenticationRequired,
        ),
      ),
    );
    expect(graphCalls, 2);
    expect(tokenCalls, 1);
  }

  Future<void> _rateLimitCancellation(RemoteObjectStore store) async {
    final sleeperStarted = _adapter.context! as Completer<void>;
    _adapter.handler = (options, _, _) async {
      if (_isGraphList(options)) {
        return _json(
          {},
          status: 429,
          headers: const {
            'retry-after': ['5'],
          },
        );
      }
      throw StateError('Unexpected OneDrive request: ${options.uri}');
    };
    final cancellation = RemoteOperationCancellation();
    final operation = store.list(cancellation: cancellation);
    await sleeperStarted.future;
    cancellation.cancel();
    await expectLater(
      operation,
      throwsA(isA<RemoteOperationCancelledException>()),
    );
    expect(_adapter.requests.where(_isGraphList).length, 1);
  }

  Future<void> _transferIntegrity(RemoteObjectStore store) async {
    final bytes = Uint8List.fromList([0, 31, 2, 255, 8, 13]);
    var uploaded = false;
    _adapter.handler = (options, body, _) async {
      if (_isGraphList(options)) {
        return _json({
          'value': uploaded
              ? [_item('blobs/integrity', size: bytes.length, download: true)]
              : [],
        });
      }
      if (_isUploadSession(options)) return _uploadSession();
      if (_isUploadChunk(options)) {
        uploaded = true;
        expect(await _body(body), bytes);
        return _json(_item('blobs/integrity', size: bytes.length), status: 201);
      }
      if (_isDownload(options)) return ResponseBody.fromBytes(bytes, 200);
      throw StateError('Unexpected OneDrive request: ${options.uri}');
    };
    await store.put(
      'blobs/integrity',
      Stream.value(bytes),
      contentLength: bytes.length,
    );
    final downloaded = await store
        .read('blobs/integrity')
        .expand((chunk) => chunk)
        .toList();
    expect(_digest(downloaded), _digest(bytes));
  }

  Future<void> _unicodeLogicalKey(RemoteObjectStore store) async {
    const key = 'blobs/你好-��.bin';
    var uploaded = false;
    _adapter.handler = (options, body, _) async {
      if (_isGraphList(options)) {
        return _json({
          'value': uploaded ? [_item(key, id: 'unicode-id')] : [],
        });
      }
      if (_isUploadSession(options)) {
        expect(options.uri.path, contains(_encodedName(key)));
        return _uploadSession();
      }
      if (_isUploadChunk(options)) {
        uploaded = true;
        expect(await _body(body), [1]);
        return _json(_item(key, id: 'unicode-id', size: 1), status: 201);
      }
      if (options.method == 'DELETE') {
        expect(options.uri.path, '/v1.0/me/drive/items/unicode-id');
        return ResponseBody.fromBytes(const [], 204);
      }
      throw StateError('Unexpected OneDrive request: ${options.uri}');
    };
    await store.put(key, Stream.value([1]), contentLength: 1);
    await store.delete(key);
  }

  Future<void> _idempotentDelete(RemoteObjectStore store) async {
    _adapter.handler = (options, _, _) async {
      if (_isGraphList(options)) {
        return _json({
          'value': [_item('blobs/gone')],
        });
      }
      if (options.method == 'DELETE') {
        return ResponseBody.fromBytes(const [], 404);
      }
      throw StateError('Unexpected OneDrive request: ${options.uri}');
    };
    await store.delete('blobs/gone');
    await store.delete('blobs/gone');
  }

  Future<void> _cancellationCleanup(RemoteObjectStore store) async {
    final entered = Completer<void>();
    _adapter.handler = (options, _, cancelFuture) async {
      entered.complete();
      await cancelFuture;
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.cancel,
      );
    };
    final cancellation = RemoteOperationCancellation();
    final operation = store.list(cancellation: cancellation);
    await entered.future;
    cancellation.cancel();
    await expectLater(
      operation,
      throwsA(isA<RemoteOperationCancelledException>()),
    );
  }

  Future<void> _quotaMapping(RemoteObjectStore store) async {
    _adapter.handler = (options, _, _) async =>
        ResponseBody.fromString('', 507);
    await expectLater(
      store.list(),
      throwsA(
        isA<ProviderRequestException>().having(
          (error) => error.kind,
          'kind',
          ProviderRequestErrorKind.quotaExceeded,
        ),
      ),
    );
  }

  Future<void> _traversalRejection(RemoteObjectStore store) async {
    await expectLater(store.stat('../secret'), throwsArgumentError);
    expect(_adapter.requests, isEmpty);
  }

  Future<void> _redactedErrors(RemoteObjectStore store) async {
    _adapter.handler = (options, _, _) async => ResponseBody.fromString(
      'refresh_token=do-not-log-contract-secret',
      403,
    );
    try {
      await store.list();
      fail('Expected a provider error');
    } on ProviderRequestException catch (error) {
      expect(error.toString(), isNot(contains('do-not-log-contract-secret')));
      expect(error.toString(), isNot(contains('refresh_token=')));
    }
  }
}

class _OneDriveContractAdapter implements HttpClientAdapter {
  Future<ResponseBody> Function(
    RequestOptions,
    Stream<Uint8List>?,
    Future<void>?,
  )?
  handler;
  final requests = <RequestOptions>[];
  Object? context;

  void reset() {
    handler = null;
    requests.clear();
    context = null;
  }

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    final callback = handler;
    if (callback == null) {
      throw StateError('No OneDrive contract response arranged.');
    }
    return callback(options, stream, cancelFuture);
  }
}

bool _isGraphList(RequestOptions options) =>
    options.method == 'GET' &&
    options.uri.host == 'graph.microsoft.com' &&
    options.uri.path.endsWith('/children');
bool _isZeroContentUpload(RequestOptions options) =>
    options.method == 'PUT' &&
    options.uri.host == 'graph.microsoft.com' &&
    options.uri.path.endsWith('/content');
bool _isUploadSession(RequestOptions options) =>
    options.method == 'POST' &&
    options.uri.host == 'graph.microsoft.com' &&
    options.uri.path.endsWith('/createUploadSession');
bool _isUploadChunk(RequestOptions options) =>
    options.method == 'PUT' && options.uri.host == 'upload.example.test';
bool _isDownload(RequestOptions options) =>
    options.method == 'GET' && options.uri.host == 'download.example.test';

Map<String, dynamic> _item(
  String key, {
  String id = 'item-id',
  int size = 3,
  bool download = false,
}) => {
  'id': id,
  'name': _encodedName(key),
  'size': size,
  'lastModifiedDateTime': '2030-01-01T00:00:00Z',
  'eTag': 'contract-etag',
  'file': {},
  if (download)
    '@microsoft.graph.downloadUrl': 'https://download.example.test/file',
};

String _encodedName(String key) =>
    'velock-${base64UrlEncode(utf8.encode(key)).replaceAll('=', '')}';

Future<ResponseBody> _uploadSession() async =>
    _json({'uploadUrl': 'https://upload.example.test/session'});

Future<ResponseBody> _json(
  Map<String, dynamic> value, {
  int status = 200,
  Map<String, List<String>> headers = const {},
}) async => ResponseBody.fromString(
  jsonEncode(value),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
    ...headers,
  },
);

Future<List<int>> _body(Stream<Uint8List>? body) async =>
    body == null ? const [] : body.expand((chunk) => chunk).toList();

String _digest(List<int> bytes) => bytes.join(':');
