import 'dart:async';
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

import 'object_store_contract_fixture.dart';

class GoogleDriveObjectStoreContractFixture
    implements ObjectStoreContractFixture {
  GoogleDriveObjectStoreContractFixture();

  final _DriveContractAdapter _adapter = _DriveContractAdapter();
  late ProviderRateLimitRetry _retry;

  @override
  String get providerName => 'google_drive';

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
    return GoogleDriveObjectStore(
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
      parentId: 'root-id',
      dio: dio,
      rateLimitRetry: _retry,
    );
  }

  Future<void> _zeroByteRoundTrip(RemoteObjectStore store) async {
    var uploaded = false;
    _adapter.handler = (options, body, _) async {
      if (_isDriveList(options)) {
        return _json({
          'files': uploaded ? [_file('blobs/zero', size: 0)] : [],
        });
      }
      if (_isUploadSession(options)) return _session();
      if (_isUpload(options)) {
        uploaded = true;
        expect(options.headers['Content-Length'], '0');
        expect(await _body(body), isEmpty);
        return _json(_file('blobs/zero', size: 0), status: 201);
      }
      if (_isMedia(options)) return ResponseBody.fromBytes(const [], 200);
      throw StateError('Unexpected Drive request: ${options.uri}');
    };
    final result = await store.put(
      'blobs/zero',
      const Stream<List<int>>.empty(),
      contentLength: 0,
    );
    expect(result.size, 0);
    expect(
      await store.read('blobs/zero').expand((part) => part).toList(),
      isEmpty,
    );
    expect(uploaded, isTrue);
  }

  Future<void> _smallObjectRoundTrip(RemoteObjectStore store) async {
    const expected = [1, 2, 3];
    _adapter.handler = (options, body, _) async {
      if (_isUploadSession(options)) return _session();
      if (_isUpload(options)) {
        expect(await _body(body), expected);
        return _json(_file('blobs/small', size: expected.length), status: 201);
      }
      if (_isLookup(options)) {
        return _json({
          'files': [_file('blobs/small')],
        });
      }
      if (_isMedia(options)) return ResponseBody.fromBytes(expected, 200);
      throw StateError('Unexpected Drive request: ${options.uri}');
    };
    await store.put(
      'blobs/small',
      Stream.value(expected),
      contentLength: expected.length,
    );
    expect(
      await store.read('blobs/small').expand((part) => part).toList(),
      expected,
    );
  }

  Future<void> _largeStreamingWrite(RemoteObjectStore store) async {
    const chunkSize = 8 * 256 * 1024;
    final payload = List<int>.filled(chunkSize + 1, 7);
    final ranges = <String?>[];
    final transmitted = <int>[];
    _adapter.handler = (options, body, _) async {
      if (_isUploadSession(options)) return _session();
      if (_isUpload(options)) {
        final bytes = await _body(body);
        transmitted.add(bytes.length);
        ranges.add(options.headers['Content-Range'] as String?);
        expect(bytes.length, lessThanOrEqualTo(chunkSize));
        return transmitted.length == 1
            ? _json({}, status: 308)
            : _json(_file('blobs/large', size: payload.length), status: 201);
      }
      throw StateError('Unexpected Drive request: ${options.uri}');
    };
    await store.put(
      'blobs/large',
      Stream.fromIterable([payload.sublist(0, 65536), payload.sublist(65536)]),
      contentLength: payload.length,
    );
    expect(transmitted, [chunkSize, 1]);
    expect(ranges, [
      'bytes 0-${chunkSize - 1}/${payload.length}',
      'bytes $chunkSize-$chunkSize/${payload.length}',
    ]);
  }

  Future<void> _interruptedImmutableSafeRetry(RemoteObjectStore store) async {
    final attempts = <List<int>>[];
    _adapter.handler = (options, body, _) async {
      if (_isUploadSession(options)) return _session();
      if (_isUpload(options)) {
        attempts.add(await _body(body));
        return attempts.length == 1
            ? _json({}, status: 503)
            : _json(_file('blobs/retry', size: 3), status: 201);
      }
      throw StateError('Unexpected Drive request: ${options.uri}');
    };
    await store.put('blobs/retry', Stream.value([4, 5, 6]), contentLength: 3);
    expect(attempts, [
      [4, 5, 6],
      [4, 5, 6],
    ]);
  }

  Future<void> _immutableCollision(RemoteObjectStore store) async {
    _adapter.handler = (options, _, _) async => _json({
      'files': [_file('blobs/existing')],
    });
    await expectLater(
      store.put(
        'blobs/existing',
        Stream.value([1]),
        contentLength: 1,
        ifAbsent: true,
      ),
      throwsA(isA<RemoteObjectAlreadyExistsException>()),
    );
  }

  Future<void> _paginationDeduplication(RemoteObjectStore store) async {
    _adapter.handler = (options, _, _) async {
      if (options.uri.queryParameters['pageToken'] == 'second') {
        return _json({
          'files': [_file('blobs/c'), _file('blobs/a')],
        });
      }
      return _json({
        'nextPageToken': 'second',
        'files': [_file('blobs/b'), _file('blobs/a'), _file('blobs/b')],
      });
    };
    final first = await store.list(prefix: 'blobs/', limit: 10);
    final second = await store.list(
      prefix: 'blobs/',
      cursor: first.nextCursor,
      limit: 10,
    );
    expect(first.items.map((item) => item.logicalKey), ['blobs/a', 'blobs/b']);
    expect(second.items.map((item) => item.logicalKey), ['blobs/a', 'blobs/c']);
    expect(
      {
        ...first.items.map((item) => item.logicalKey),
        ...second.items.map((item) => item.logicalKey),
      },
      {'blobs/a', 'blobs/b', 'blobs/c'},
    );
  }

  Future<void> _notFoundMapping(RemoteObjectStore store) async {
    _adapter.handler = (options, _, _) async => _json({'files': []});
    await expectLater(
      store.read('blobs/missing').drain(),
      throwsA(isA<RemoteObjectNotFoundException>()),
    );
  }

  Future<void> _authorizationRecovery(RemoteObjectStore store) async {
    var driveAttempts = 0;
    var refreshes = 0;
    _adapter.handler = (options, _, _) async {
      if (options.uri.host == 'token.example.test') {
        refreshes++;
        return _json({'access_token': 'renewed', 'expires_in': 3600});
      }
      driveAttempts++;
      return ResponseBody.fromString('', 401);
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
    expect(driveAttempts, 2);
    expect(refreshes, 1);
  }

  Future<void> _rateLimitCancellation(RemoteObjectStore store) async {
    final sleeperStarted = _adapter.context! as Completer<void>;
    _adapter.handler = (options, _, _) async => ResponseBody.fromString(
      '',
      429,
      headers: const {
        'retry-after': ['60'],
      },
    );
    final cancellation = RemoteOperationCancellation();
    final operation = store.list(cancellation: cancellation);
    await sleeperStarted.future;
    cancellation.cancel();
    await expectLater(
      operation,
      throwsA(isA<RemoteOperationCancelledException>()),
    );
    expect(_adapter.requests, hasLength(1));
  }

  Future<void> _transferIntegrity(RemoteObjectStore store) async {
    const expected = [9, 8, 7, 6];
    _adapter.handler = (options, body, _) async {
      if (_isUploadSession(options)) return _session();
      if (_isUpload(options)) {
        expect(await _body(body), expected);
        return _json(
          _file('blobs/integrity', size: expected.length),
          status: 201,
        );
      }
      if (_isLookup(options)) {
        return _json({
          'files': [_file('blobs/integrity')],
        });
      }
      if (_isMedia(options)) return ResponseBody.fromBytes(expected, 200);
      throw StateError('Unexpected Drive request: ${options.uri}');
    };
    await store.put(
      'blobs/integrity',
      Stream.value(expected),
      contentLength: expected.length,
    );
    final read = await store
        .read('blobs/integrity')
        .expand((part) => part)
        .toList();
    expect(_digest(read), _digest(expected));
  }

  Future<void> _unicodeLogicalKey(RemoteObjectStore store) async {
    const key = 'blobs/你好-��.bin';
    _adapter.handler = (options, body, _) async {
      if (_isUploadSession(options)) {
        final metadata = jsonDecode(utf8.decode(await _body(body))) as Map;
        expect(
          metadata['name'],
          'velock-${base64UrlEncode(utf8.encode(key)).replaceAll('=', '')}',
        );
        return _session();
      }
      if (_isUpload(options)) return _json(_file(key, size: 1), status: 201);
      if (_isLookup(options)) {
        return _json({
          'files': [_file(key)],
        });
      }
      if (options.method == 'DELETE') {
        return ResponseBody.fromBytes(const [], 204);
      }
      throw StateError('Unexpected Drive request: ${options.uri}');
    };
    await store.put(key, Stream.value([1]), contentLength: 1);
    await store.delete(key);
  }

  Future<void> _idempotentDelete(RemoteObjectStore store) async {
    _adapter.handler = (options, _, _) async {
      if (_isDriveList(options)) {
        return _json({
          'files': [_file('blobs/gone')],
        });
      }
      if (options.method == 'DELETE') {
        return ResponseBody.fromBytes(const [], 404);
      }
      throw StateError('Unexpected Drive request: ${options.uri}');
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

class _DriveContractAdapter implements HttpClientAdapter {
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
      throw StateError('No Drive contract response arranged.');
    }
    return callback(options, stream, cancelFuture);
  }
}

bool _isDriveList(RequestOptions options) =>
    options.uri.path == '/drive/v3/files' && options.method == 'GET';
bool _isLookup(RequestOptions options) => _isDriveList(options);
bool _isUploadSession(RequestOptions options) =>
    options.uri.path == '/upload/drive/v3/files';
bool _isUpload(RequestOptions options) =>
    options.uri.host == 'upload.example.test';
bool _isMedia(RequestOptions options) =>
    options.uri.path.startsWith('/drive/v3/files/') &&
    options.uri.queryParameters['alt'] == 'media';

Map<String, dynamic> _file(String key, {int size = 3}) => {
  'id': 'file-id',
  'name': 'velock-${base64UrlEncode(utf8.encode(key)).replaceAll('=', '')}',
  'size': '$size',
  'modifiedTime': '2030-01-01T00:00:00Z',
  'md5Checksum': 'contract-hash',
};

Future<ResponseBody> _session() async => ResponseBody.fromString(
  '',
  200,
  headers: const {
    'location': ['https://upload.example.test/session'],
  },
);

Future<ResponseBody> _json(
  Map<String, dynamic> value, {
  int status = 200,
}) async => ResponseBody.fromString(
  jsonEncode(value),
  status,
  headers: const {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

Future<List<int>> _body(Stream<Uint8List>? body) async =>
    body == null ? const [] : body.expand((chunk) => chunk).toList();

String _digest(List<int> bytes) => bytes.join(':');
