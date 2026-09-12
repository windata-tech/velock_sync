import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/providers/provider_rate_limit_retry.dart';
import 'package:velock_sync/providers/provider_request_exception.dart';
import 'package:velock_sync/providers/webdav/webdav_object_store.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';

import '../contracts/object_store_contract.dart';
import '../contracts/object_store_contract_fixture.dart';

void main() {
  group('WebDavObjectStore', () {
    late _RecordingAdapter adapter;
    late WebDavObjectStore store;

    setUp(() {
      adapter = _RecordingAdapter();
      store = WebDavObjectStore(
        dio: Dio()..httpClientAdapter = adapter,
        baseUri: Uri.parse('https://dav.example.test/root'),
        username: 'alice',
        password: 'secret',
      );
    });

    test(
      'rejects a cancelled operation before issuing a WebDAV request',
      () async {
        final cancellation = RemoteOperationCancellation()..cancel();

        await expectLater(
          store.stat(
            'velock-sync/v1/vault/protocol.json',
            cancellation: cancellation,
          ),
          throwsA(isA<RemoteOperationCancelledException>()),
        );
        expect(adapter.lastOptions, isNull);
      },
    );

    test(
      'maps stat to HEAD without exposing a credential in the logical key',
      () async {
        adapter.response = ResponseBody.fromBytes(
          const [],
          200,
          headers: const {
            'content-length': ['4'],
            'etag': ['"etag-1"'],
            'last-modified': ['Mon, 14 Jul 2026 12:00:00 GMT'],
          },
        );

        final object = await store.stat('velock-sync/v1/vault/protocol.json');

        expect(object!.size, 4);
        expect(adapter.lastOptions!.method, 'HEAD');
        expect(
          adapter.lastOptions!.uri.path,
          '/root/velock-sync/v1/vault/protocol.json',
        );
        expect(
          adapter.lastOptions!.headers['Authorization'],
          startsWith('Basic '),
        );
      },
    );

    test(
      'parses PROPFIND entries and excludes the queried container',
      () async {
        adapter.responseFactory = () => ResponseBody.fromString(
          '''<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/root/velock-sync/</d:href></d:response>
          <d:response><d:href>/root/velock-sync/protocol.json</d:href><d:propstat><d:prop><d:getcontentlength>16</d:getcontentlength><d:getetag>"e"</d:getetag></d:prop></d:propstat></d:response>
          <d:response><d:href>/root/velock-sync/second.json</d:href><d:propstat><d:prop><d:getcontentlength>8</d:getcontentlength></d:prop></d:propstat></d:response>
        </d:multistatus>''',
          207,
        );

        final page = await store.list(prefix: 'velock-sync', limit: 1);
        final secondPage = await store.list(
          prefix: 'velock-sync',
          cursor: page.nextCursor,
          limit: 1,
        );

        expect(adapter.lastOptions!.method, 'PROPFIND');
        expect(adapter.lastOptions!.headers['Depth'], '1');
        expect(page.items.single.logicalKey, 'velock-sync/protocol.json');
        expect(page.items.single.size, 16);
        expect(page.nextCursor, '1');
        expect(secondPage.items.single.logicalKey, 'velock-sync/second.json');
      },
    );

    test('lists a normalized collection prefix with a trailing slash', () async {
      adapter.response = ResponseBody.fromString(
        '''<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/root/velock-sync/v1/vault/devices/source/commits/</d:href></d:response>
          <d:response><d:href>/root/velock-sync/v1/vault/devices/source/commits/00000000000000000001-batch.commit</d:href><d:propstat><d:prop><d:getcontentlength>16</d:getcontentlength></d:prop></d:propstat></d:response>
        </d:multistatus>''',
        207,
      );

      final page = await store.list(
        prefix: 'velock-sync/v1/vault/devices/source/commits/',
      );

      expect(adapter.lastOptions!.uri.path, endsWith('/commits/'));
      expect(
        page.items.single.logicalKey,
        'velock-sync/v1/vault/devices/source/commits/00000000000000000001-batch.commit',
      );
    });

    test(
      'uses conditional create and translates 412 to immutable-object error',
      () async {
        adapter.response = ResponseBody.fromBytes(const [], 412);

        await expectLater(
          store.put(
            'velock-sync/blob',
            Stream.value(<int>[1]),
            contentLength: 1,
            ifAbsent: true,
          ),
          throwsA(isA<RemoteObjectAlreadyExistsException>()),
        );
        expect(adapter.lastOptions!.headers['If-None-Match'], '*');
      },
    );

    test(
      'creates missing parent collections before uploading an object',
      () async {
        adapter.mkcolHandler = (options) async => ResponseBody.fromBytes(
          const [],
          options.uri.path == '/root/velock-sync/v1' ? 405 : 201,
        );
        adapter.handler = (options, body, _) async {
          expect(options.method, 'PUT');
          expect(await _bodyBytes(body), [1]);
          return ResponseBody.fromBytes(const [], 201);
        };

        await store.put(
          'velock-sync/v1/vault/protocol.json',
          Stream.value(<int>[1]),
          contentLength: 1,
        );

        expect(
          adapter.requests
              .map((request) => '${request.method} ${request.uri.path}')
              .toList(),
          [
            'MKCOL /root/velock-sync',
            'MKCOL /root/velock-sync/v1',
            'MKCOL /root/velock-sync/v1/vault',
            'PUT /root/velock-sync/v1/vault/protocol.json',
          ],
        );
      },
    );

    test(
      'treats a WebDAV 409 MKCOL as an existing parent collection',
      () async {
        adapter.mkcolHandler = (options) async =>
            ResponseBody.fromBytes(const [], 409);
        adapter.handler = (options, body, _) async {
          expect(options.method, 'PUT');
          expect(await _bodyBytes(body), [1]);
          return ResponseBody.fromBytes(const [], 201);
        };

        await store.put(
          'velock-sync/v1/vault/protocol.json',
          Stream.value(<int>[1]),
          contentLength: 1,
        );

        expect(
          adapter.requests
              .map((request) => '${request.method} ${request.uri.path}')
              .toList(),
          [
            'MKCOL /root/velock-sync',
            'MKCOL /root/velock-sync/v1',
            'MKCOL /root/velock-sync/v1/vault',
            'PUT /root/velock-sync/v1/vault/protocol.json',
          ],
        );
      },
    );

    test('rejects path traversal before issuing a request', () async {
      await expectLater(store.stat('../secrets'), throwsArgumentError);
      expect(adapter.lastOptions, isNull);
    });

    test(
      'backs off a 429 response before retrying the WebDAV request',
      () async {
        final waits = <Duration>[];
        var calls = 0;
        adapter.responseFactory = () {
          calls++;
          return ResponseBody.fromBytes(
            const [],
            calls == 1 ? 429 : 200,
            headers: calls == 1
                ? const {
                    'retry-after': ['0'],
                  }
                : const {},
          );
        };
        final rateLimitedStore = WebDavObjectStore(
          dio: Dio()..httpClientAdapter = adapter,
          baseUri: Uri.parse('https://dav.example.test/root'),
          username: 'alice',
          password: 'secret',
          rateLimitRetry: ProviderRateLimitRetry(
            sleeper: (delay) async => waits.add(delay),
          ),
        );

        await rateLimitedStore.stat('velock-sync/blob');

        expect(calls, 2);
        expect(waits, [Duration.zero]);
      },
    );

    test(
      'maps a WebDAV permission response to a sanitized provider error',
      () async {
        adapter.response = ResponseBody.fromBytes(const [], 403);

        await expectLater(
          store.stat('velock-sync/blob'),
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
  });

  runObjectStoreContract(_WebDavContractFixture());
}

class _RecordingAdapter implements HttpClientAdapter {
  RequestOptions? lastOptions;
  ResponseBody? response;
  ResponseBody Function()? responseFactory;
  Future<ResponseBody> Function(RequestOptions options)? mkcolHandler;
  Future<ResponseBody> Function(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  )?
  handler;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;
    requests.add(options);
    if (options.method == 'MKCOL') {
      await requestStream?.drain();
      return await mkcolHandler?.call(options) ??
          ResponseBody.fromBytes(const [], 201);
    }
    final configured = handler;
    if (configured != null) {
      return configured(options, requestStream, cancelFuture);
    }
    await requestStream?.drain();
    return responseFactory?.call() ??
        response ??
        ResponseBody.fromBytes(const [], 500);
  }

  @override
  void close({bool force = false}) {}
}

class _WebDavContractFixture implements ObjectStoreContractFixture {
  final _RecordingAdapter _adapter = _RecordingAdapter();
  ProviderRateLimitRetry? _retry;

  @override
  String get providerName => 'webdav';

  @override
  ObjectStoreContractCapabilities get capabilities =>
      const ObjectStoreContractCapabilities(
        supportsResumableUpload: false,
        authorizationMode: ObjectStoreAuthorizationMode.reauthorizationRequired,
      );

  @override
  Map<ObjectStoreContract, ObjectStoreContractCheck> get checks => {
    ObjectStoreContract.zeroByteRoundTrip: _zeroByteRoundTrip,
    ObjectStoreContract.smallObjectRoundTrip: _smallObjectRoundTrip,
    ObjectStoreContract.largeStreamingWrite: _largeStreamingWrite,
    ObjectStoreContract.interruptedImmutableSafeRetry: _immutableSafeRetry,
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
    _adapter
      ..lastOptions = null
      ..response = null
      ..responseFactory = null
      ..mkcolHandler = null
      ..handler = null
      ..requests.clear();
    _retry = null;
  }

  @override
  Future<void> arrange(ObjectStoreContract contract) async {}

  @override
  Future<RemoteObjectStore> createStore() async => WebDavObjectStore(
    dio: Dio()..httpClientAdapter = _adapter,
    baseUri: Uri.parse('https://dav.example.test/root'),
    username: 'alice',
    password: 'contract-password',
    rateLimitRetry: _retry,
  );

  Future<void> _zeroByteRoundTrip(RemoteObjectStore store) async {
    var putSeen = false;
    _adapter.handler = (options, body, _) async {
      if (options.method == 'PUT') {
        putSeen = true;
        expect(await _bodyBytes(body), isEmpty);
        expect(options.headers['Content-Length'], '0');
        expect(options.headers['Content-Type'], 'application/octet-stream');
        return ResponseBody.fromBytes(const [], 201);
      }
      expect(options.method, 'GET');
      return ResponseBody.fromBytes(const [], 200);
    };
    final written = await store.put(
      'blobs/empty',
      Stream.empty(),
      contentLength: 0,
    );
    final read = await store
        .read('blobs/empty')
        .expand((part) => part)
        .toList();
    expect(putSeen, isTrue);
    expect(written.size, 0);
    expect(read, isEmpty);
  }

  Future<void> _smallObjectRoundTrip(RemoteObjectStore store) async {
    const bytes = [1, 2, 3, 4];
    _adapter.handler = (options, body, _) async {
      if (options.method == 'PUT') {
        expect(await _bodyBytes(body), bytes);
        return ResponseBody.fromBytes(const [], 201);
      }
      return ResponseBody.fromBytes(bytes, 200);
    };
    await store.put(
      'blobs/small',
      Stream.value(bytes),
      contentLength: bytes.length,
    );
    expect(
      await store.read('blobs/small').expand((part) => part).toList(),
      bytes,
    );
  }

  Future<void> _largeStreamingWrite(RemoteObjectStore store) async {
    const chunkSize = 64 * 1024;
    final chunks = List<List<int>>.generate(
      33,
      (index) => List<int>.filled(chunkSize, index),
    );
    var maxChunk = 0;
    var total = 0;
    _adapter.handler = (options, body, _) async {
      expect(options.method, 'PUT');
      expect(options.headers['Content-Type'], 'application/octet-stream');
      await for (final chunk in body!) {
        maxChunk = maxChunk < chunk.length ? chunk.length : maxChunk;
        total += chunk.length;
      }
      return ResponseBody.fromBytes(const [], 201);
    };
    await store.put(
      'blobs/streamed',
      Stream<List<int>>.fromIterable(chunks),
      contentLength: chunks.length * chunkSize,
    );
    expect(total, chunks.length * chunkSize);
    expect(maxChunk, lessThan(chunks.length * chunkSize));
  }

  Future<void> _immutableSafeRetry(RemoteObjectStore store) async {
    var attempt = 0;
    _adapter.handler = (options, body, _) async {
      await body?.drain();
      attempt++;
      expect(options.headers['If-None-Match'], '*');
      return ResponseBody.fromBytes(const [], attempt == 1 ? 503 : 412);
    };
    await expectLater(
      store.put(
        'blobs/retry',
        Stream.value([1]),
        contentLength: 1,
        ifAbsent: true,
      ),
      throwsA(isA<ProviderRequestException>()),
    );
    await expectLater(
      store.put(
        'blobs/retry',
        Stream.value([1]),
        contentLength: 1,
        ifAbsent: true,
      ),
      throwsA(isA<RemoteObjectAlreadyExistsException>()),
    );
    expect(attempt, 2);
  }

  Future<void> _immutableCollision(RemoteObjectStore store) async {
    _adapter.handler = (options, body, _) async {
      await body?.drain();
      return ResponseBody.fromBytes(const [], 412);
    };
    await expectLater(
      store.put(
        'blobs/collision',
        Stream.value([9]),
        contentLength: 1,
        ifAbsent: true,
      ),
      throwsA(isA<RemoteObjectAlreadyExistsException>()),
    );
  }

  Future<void> _paginationDeduplication(RemoteObjectStore store) async {
    _adapter.handler = (options, body, _) async {
      await body?.drain();
      return ResponseBody.fromString(
        _webDavPropfindXml(['one.json', 'one.json', 'two.json']),
        207,
      );
    };
    final first = await store.list(prefix: 'blobs', limit: 1);
    final second = await store.list(
      prefix: 'blobs',
      cursor: first.nextCursor,
      limit: 1,
    );
    expect(first.items.single.logicalKey, 'blobs/one.json');
    expect(second.items.single.logicalKey, 'blobs/two.json');
    expect(second.nextCursor, isNull);
  }

  Future<void> _notFoundMapping(RemoteObjectStore store) async {
    _adapter.handler = (options, body, _) async {
      await body?.drain();
      return ResponseBody.fromBytes(const [], 404);
    };
    expect(await store.stat('blobs/missing'), isNull);
    await expectLater(
      store.read('blobs/missing').drain(),
      throwsA(isA<RemoteObjectNotFoundException>()),
    );
  }

  Future<void> _authorizationRecovery(RemoteObjectStore store) async {
    _adapter.handler = (options, body, _) async {
      await body?.drain();
      return ResponseBody.fromString('credential=contract-password', 401);
    };
    await expectLater(
      store.stat('blobs/auth'),
      throwsA(
        isA<ProviderRequestException>().having(
          (error) => error.kind,
          'kind',
          ProviderRequestErrorKind.authenticationRequired,
        ),
      ),
    );
  }

  Future<void> _rateLimitCancellation(RemoteObjectStore _) async {
    final sleeperStarted = Completer<void>();
    final never = Completer<void>();
    _retry = ProviderRateLimitRetry(
      sleeper: (_) {
        sleeperStarted.complete();
        return never.future;
      },
    );
    final store = await createStore();
    _adapter.handler = (options, body, _) async {
      await body?.drain();
      return ResponseBody.fromBytes(
        const [],
        429,
        headers: const {
          'retry-after': ['60'],
        },
      );
    };
    final cancellation = RemoteOperationCancellation();
    final operation = store.stat('blobs/slow', cancellation: cancellation);
    await sleeperStarted.future;
    cancellation.cancel();
    await expectLater(
      operation,
      throwsA(isA<RemoteOperationCancelledException>()),
    );
    expect(_adapter.requests, hasLength(1));
  }

  Future<void> _transferIntegrity(RemoteObjectStore store) async {
    const bytes = [9, 8, 7, 6, 5];
    _adapter.handler = (options, body, _) async {
      if (options.method == 'PUT') {
        expect(await _bodyBytes(body), bytes);
        return ResponseBody.fromBytes(const [], 201);
      }
      return ResponseBody.fromBytes(bytes, 200);
    };
    await store.put(
      'blobs/hash',
      Stream.value(bytes),
      contentLength: bytes.length,
    );
    final received = await store
        .read('blobs/hash')
        .expand((part) => part)
        .toList();
    expect(received, bytes);
    expect(_testDigest(received), _testDigest(bytes));
  }

  Future<void> _unicodeLogicalKey(RemoteObjectStore store) async {
    const key = 'blobs/你好-��.bin';
    _adapter.handler = (options, body, _) async {
      expect(options.uri.path, contains(Uri.encodeComponent('你好-��.bin')));
      await body?.drain();
      return ResponseBody.fromBytes(
        const [],
        options.method == 'PUT' ? 201 : 204,
      );
    };
    await store.put(key, Stream.value([1]), contentLength: 1);
    await store.delete(key);
  }

  Future<void> _idempotentDelete(RemoteObjectStore store) async {
    _adapter.handler = (options, body, _) async {
      await body?.drain();
      return ResponseBody.fromBytes(const [], 404);
    };
    await store.delete('blobs/gone');
    await store.delete('blobs/gone');
  }

  Future<void> _cancellationCleanup(RemoteObjectStore store) async {
    final entered = Completer<void>();
    _adapter.handler = (options, body, cancelFuture) async {
      await body?.drain();
      entered.complete();
      await cancelFuture;
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.cancel,
      );
    };
    final cancellation = RemoteOperationCancellation();
    final operation = store.stat('blobs/cancel', cancellation: cancellation);
    await entered.future;
    cancellation.cancel();
    await expectLater(
      operation,
      throwsA(isA<RemoteOperationCancelledException>()),
    );
  }

  Future<void> _quotaMapping(RemoteObjectStore store) async {
    _adapter.handler = (options, body, _) async {
      await body?.drain();
      return ResponseBody.fromBytes(const [], 507);
    };
    await expectLater(
      store.stat('blobs/quota'),
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
    _adapter.handler = (options, body, _) async {
      await body?.drain();
      return ResponseBody.fromString('password=contract-password', 403);
    };
    try {
      await store.stat('blobs/redacted');
      fail('Expected a provider error');
    } on ProviderRequestException catch (error) {
      expect(error.toString(), isNot(contains('contract-password')));
      expect(error.toString(), isNot(contains('password=')));
    }
  }
}

Future<List<int>> _bodyBytes(Stream<Uint8List>? body) async {
  if (body == null) return const [];
  return body.expand((chunk) => chunk).toList();
}

String _testDigest(List<int> bytes) => bytes.fold<String>(
  'seed',
  (value, byte) => '$value:${byte.toRadixString(16)}',
);

String _webDavPropfindXml(List<String> names) =>
    '''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/root/blobs/</d:href></d:response>
  ${names.map((name) => '<d:response><d:href>/root/blobs/$name</d:href><d:propstat><d:prop><d:getcontentlength>1</d:getcontentlength></d:prop></d:propstat></d:response>').join()}
</d:multistatus>''';
