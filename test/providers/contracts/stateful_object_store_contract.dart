import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/secure_storage/in_memory_credential_store.dart';
import 'package:velock_sync/providers/oauth/oauth_access_token_provider.dart';
import 'package:velock_sync/providers/oauth/oauth_token_bundle.dart';
import 'package:velock_sync/providers/oauth/oauth_token_client.dart';
import 'package:velock_sync/providers/provider_rate_limit_retry.dart';
import 'package:velock_sync/providers/provider_request_exception.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';

import 'object_store_contract_fixture.dart';

/// Which part of a cloud drive's surface a request went to.
enum CloudRequestKind { api, uploadPart, download }

class CloudRequest {
  CloudRequest({
    required this.options,
    required this.kind,
    required this.operation,
    required this.body,
    required this.cancelFuture,
  });

  final RequestOptions options;
  final CloudRequestKind kind;

  /// Provider-specific operation name, such as `openFile/create`.
  final String operation;
  final Uint8List body;
  final Future<void>? cancelFuture;

  /// Blocks until the adapter cancels this request, as a stalled network
  /// connection would. A request sent without a cancel token fails the test,
  /// because it could never be interrupted.
  Future<ResponseBody> hangUntilCancelled() async {
    final cancelled = cancelFuture;
    if (cancelled == null) {
      fail('$operation was sent without a cancel token');
    }
    await cancelled;
    throw DioException(requestOptions: options, type: DioExceptionType.cancel);
  }
}

typedef CloudIntercept = FutureOr<ResponseBody?> Function(CloudRequest request);

/// An in-memory cloud drive that answers the real adapter's HTTP requests
/// with the provider's wire format, so contract checks exercise actual
/// uploads, listings and downloads rather than one scripted reply each.
abstract class ContractCloud implements HttpClientAdapter {
  static const tokenHost = 'token.example.test';

  final requests = <CloudRequest>[];

  /// Part sizes of every upload the drive committed, in order.
  final committedUploads = <List<int>>[];
  int refreshes = 0;
  Set<String> acceptedTokens = {'contract-access', 'renewed'};

  /// Consulted before the drive handles a request; a non-null response
  /// replaces the normal answer (faults, stalls, rate limits).
  CloudIntercept? intercept;

  int get partBytes;

  /// The operation that reserves a new object (where quota is enforced).
  String get createOperation;

  void reset() {
    requests.clear();
    committedUploads.clear();
    refreshes = 0;
    acceptedTokens = {'contract-access', 'renewed'};
    intercept = null;
  }

  /// Stores [bytes] under [key] as if another device had uploaded it. With
  /// [duplicateListing] the object is listed twice.
  void seed(String key, List<int> bytes, {bool duplicateListing = false});

  List<int>? bytesOf(String key);

  Future<RemoteObjectStore> createStore({
    required OAuthAccessTokenProvider tokens,
    required Dio dio,
    required ProviderRateLimitRetry retry,
  });

  /// Checks nothing was left behind after a cancelled operation.
  Future<void> verifyClean() async {}

  CloudRequestKind kindOf(RequestOptions options);
  String operationOf(RequestOptions options, CloudRequestKind kind);
  String? tokenOf(CloudRequest request);
  bool requiresToken(CloudRequestKind kind);
  Future<ResponseBody> handle(CloudRequest request);

  ResponseBody unauthorised(CloudRequest request);
  ResponseBody rateLimited();
  ResponseBody quotaExceeded();

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.host == tokenHost) {
      refreshes++;
      return jsonBody({'access_token': 'renewed', 'expires_in': 3600});
    }
    final body = requestStream == null
        ? Uint8List(0)
        : Uint8List.fromList(await requestStream.expand((c) => c).toList());
    final kind = kindOf(options);
    final request = CloudRequest(
      options: options,
      kind: kind,
      operation: operationOf(options, kind),
      body: body,
      cancelFuture: cancelFuture,
    );
    requests.add(request);
    final replaced = await intercept?.call(request);
    if (replaced != null) return replaced;
    if (requiresToken(kind) && !acceptedTokens.contains(tokenOf(request))) {
      return unauthorised(request);
    }
    return handle(request);
  }
}

ResponseBody jsonBody(
  Map<String, Object?> value, {
  int status = 200,
  Map<String, List<String>> headers = const {},
}) => ResponseBody.fromString(
  jsonEncode(value),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
    ...headers,
  },
);

/// Serves [bytes] honouring a `Range: bytes=a-b` header.
ResponseBody rangedBody(RequestOptions options, List<int> bytes) {
  final range = RegExp(
    r'^bytes=(\d+)-(\d*)$',
  ).firstMatch('${options.headers['Range'] ?? options.headers['range'] ?? ''}');
  if (range == null) return ResponseBody.fromBytes(bytes, 200);
  final start = int.parse(range.group(1)!);
  final end = range.group(2)!.isEmpty
      ? bytes.length - 1
      : int.parse(range.group(2)!);
  return ResponseBody.fromBytes(bytes.sublist(start, end + 1), 206);
}

/// Runs the shared V1 contract against a [ContractCloud]. Neither Baidu
/// Netdisk nor Aliyun Drive keeps an upload session, so resumable upload is
/// declared unavailable and an interrupted upload restarts safely instead.
class StatefulObjectStoreContractFixture implements ObjectStoreContractFixture {
  StatefulObjectStoreContractFixture({
    required this.providerName,
    required this.cloud,
  });

  @override
  final String providerName;
  final ContractCloud cloud;
  late ProviderRateLimitRetry _retry;
  Completer<void>? _sleeperStarted;

  @override
  ObjectStoreContractCapabilities get capabilities =>
      const ObjectStoreContractCapabilities(
        supportsResumableUpload: false,
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
    cloud.reset();
    _sleeperStarted = null;
    _retry = ProviderRateLimitRetry(
      sleeper: (_) async {},
      nextRandomInt: (_) => 0,
    );
  }

  @override
  Future<void> arrange(ObjectStoreContract contract) async {
    if (contract != ObjectStoreContract.rateLimitCancellation) return;
    final started = _sleeperStarted = Completer<void>();
    final never = Completer<void>();
    _retry = ProviderRateLimitRetry(
      sleeper: (_) {
        if (!started.isCompleted) started.complete();
        return never.future;
      },
      nextRandomInt: (_) => 0,
    );
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
    final dio = Dio()..httpClientAdapter = cloud;
    return cloud.createStore(
      tokens: OAuthAccessTokenProvider(
        credentialStore: credentialStore,
        tokenClient: OAuthTokenClient(
          dio: dio,
          clock: () => DateTime.utc(2030),
        ),
        credentialRef: ref,
        clientId: 'contract-client',
        tokenEndpoint: Uri.https(ContractCloud.tokenHost, '/token'),
        clock: () => DateTime.utc(2030),
      ),
      dio: dio,
      retry: _retry,
    );
  }

  static Future<List<int>> _readAll(
    RemoteObjectStore store,
    String key, {
    int? start,
    int? endInclusive,
  }) => store
      .read(key, start: start, endInclusive: endInclusive)
      .expand((part) => part)
      .toList();

  Future<void> _zeroByteRoundTrip(RemoteObjectStore store) async {
    final result = await store.put(
      'blobs/zero',
      const Stream<List<int>>.empty(),
      contentLength: 0,
    );
    expect(result.size, 0);
    expect(cloud.bytesOf('blobs/zero'), isEmpty);
    expect((await store.stat('blobs/zero'))?.size, 0);
    expect(await _readAll(store, 'blobs/zero'), isEmpty);
  }

  Future<void> _smallObjectRoundTrip(RemoteObjectStore store) async {
    const expected = [1, 2, 3];
    await store.put(
      'blobs/small',
      Stream.value(expected),
      contentLength: expected.length,
    );
    expect(cloud.bytesOf('blobs/small'), expected);
    expect(await _readAll(store, 'blobs/small'), expected);
    final listed = await store.list(prefix: 'blobs/');
    expect(listed.items.map((item) => item.logicalKey), ['blobs/small']);
    expect(listed.items.single.size, expected.length);
  }

  Future<void> _largeStreamingWrite(RemoteObjectStore store) async {
    final size = cloud.partBytes + 1;
    final payload = List<int>.generate(size, (index) => index % 251);
    // Deliberately misaligned source chunks: the adapter must re-cut them
    // into the provider's fixed part size.
    await store.put(
      'blobs/large',
      Stream.fromIterable([payload.sublist(0, 65537), payload.sublist(65537)]),
      contentLength: size,
    );
    expect(cloud.committedUploads.single, [cloud.partBytes, 1]);
    expect(cloud.bytesOf('blobs/large'), payload);
  }

  Future<void> _interruptedImmutableSafeRetry(RemoteObjectStore store) async {
    var failed = false;
    cloud.intercept = (request) {
      if (request.kind != CloudRequestKind.uploadPart || failed) return null;
      failed = true;
      return ResponseBody.fromString('', 503);
    };
    await store.put('blobs/retry', Stream.value([4, 5, 6]), contentLength: 3);
    expect(failed, isTrue);
    expect(
      cloud.requests.where((r) => r.kind == CloudRequestKind.uploadPart),
      hasLength(2),
    );
    expect(cloud.bytesOf('blobs/retry'), [4, 5, 6]);
  }

  Future<void> _immutableCollision(RemoteObjectStore store) async {
    cloud.seed('blobs/existing', [7, 7]);
    await expectLater(
      store.put(
        'blobs/existing',
        Stream.value([1]),
        contentLength: 1,
        ifAbsent: true,
      ),
      throwsA(isA<RemoteObjectAlreadyExistsException>()),
    );
    expect(cloud.bytesOf('blobs/existing'), [7, 7]);
    // Without ifAbsent the same key is replaced, never duplicated.
    await store.put('blobs/existing', Stream.value([9]), contentLength: 1);
    expect(cloud.bytesOf('blobs/existing'), [9]);
    expect(
      (await store.list(prefix: 'blobs/')).items.map((i) => i.logicalKey),
      ['blobs/existing'],
    );
  }

  Future<void> _paginationDeduplication(RemoteObjectStore store) async {
    cloud
      ..seed('blobs/b', [2], duplicateListing: true)
      ..seed('blobs/a', [1], duplicateListing: true)
      ..seed('blobs/c', [3]);
    final seen = <String>{};
    String? cursor;
    var pages = 0;
    do {
      final page = await store.list(prefix: 'blobs/', cursor: cursor, limit: 2);
      final keys = page.items.map((item) => item.logicalKey).toList();
      expect(keys.toSet(), hasLength(keys.length), reason: 'page $pages');
      expect(keys, [...keys]..sort(), reason: 'page $pages');
      seen.addAll(keys);
      cursor = page.nextCursor;
      expect(++pages, lessThan(10), reason: 'listing never ended');
    } while (cursor != null);
    expect(pages, greaterThan(1));
    expect(seen, {'blobs/a', 'blobs/b', 'blobs/c'});
  }

  Future<void> _notFoundMapping(RemoteObjectStore store) async {
    // A folder nothing has been written to yet lists as empty.
    expect((await store.list()).items, isEmpty);
    expect(await store.stat('blobs/missing'), isNull);
    await expectLater(
      store.read('blobs/missing').drain(),
      throwsA(isA<RemoteObjectNotFoundException>()),
    );
  }

  Future<void> _authorizationRecovery(RemoteObjectStore store) async {
    cloud.acceptedTokens = {};
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
    // One refresh and one retry, never a loop.
    expect(cloud.requests, hasLength(2));
    expect(cloud.refreshes, 1);

    cloud.acceptedTokens = {'renewed'};
    cloud.seed('blobs/after-refresh', [1]);
    final page = await store.list(prefix: 'blobs/');
    expect(page.items.map((i) => i.logicalKey), ['blobs/after-refresh']);
    expect(cloud.refreshes, 1);
  }

  Future<void> _rateLimitCancellation(RemoteObjectStore store) async {
    cloud.intercept = (_) => cloud.rateLimited();
    final cancellation = RemoteOperationCancellation();
    final operation = store.list(cancellation: cancellation);
    await _sleeperStarted!.future;
    cancellation.cancel();
    await expectLater(
      operation,
      throwsA(isA<RemoteOperationCancelledException>()),
    );
    expect(cloud.requests, hasLength(1));
  }

  Future<void> _transferIntegrity(RemoteObjectStore store) async {
    final expected = List<int>.generate(1000, (i) => (i * 37 + 11) % 256);
    final written = await store.put(
      'blobs/integrity',
      Stream.fromIterable([expected.sublist(0, 333), expected.sublist(333)]),
      contentLength: expected.length,
    );
    expect(written.size, expected.length);
    expect(await _readAll(store, 'blobs/integrity'), expected);
    expect(
      await _readAll(store, 'blobs/integrity', start: 10, endInclusive: 19),
      expected.sublist(10, 20),
    );
    final metadata = await store.stat('blobs/integrity');
    expect(metadata?.size, expected.length);
    expect(metadata?.etag, isNotNull);
  }

  Future<void> _unicodeLogicalKey(RemoteObjectStore store) async {
    const key = 'blobs/你好-😀 空格.bin';
    await store.put(key, Stream.value([1]), contentLength: 1);
    expect(cloud.bytesOf(key), [1]);
    expect(
      (await store.list(prefix: 'blobs/')).items.map((i) => i.logicalKey),
      [key],
    );
    expect(await _readAll(store, key), [1]);
    await store.delete(key);
    expect(cloud.bytesOf(key), isNull);
    expect(await store.stat(key), isNull);
  }

  Future<void> _idempotentDelete(RemoteObjectStore store) async {
    cloud.seed('blobs/gone', [1]);
    await store.delete('blobs/gone');
    expect(cloud.bytesOf('blobs/gone'), isNull);
    await store.delete('blobs/gone');
    await store.delete('blobs/never-existed');
  }

  Future<void> _cancellationCleanup(RemoteObjectStore store) async {
    var entered = Completer<void>();
    cloud.intercept = (request) {
      entered.complete();
      return request.hangUntilCancelled();
    };
    var cancellation = RemoteOperationCancellation();
    final listing = store.list(cancellation: cancellation);
    await entered.future;
    cancellation.cancel();
    await expectLater(
      listing,
      throwsA(isA<RemoteOperationCancelledException>()),
    );

    // A stalled upload is abandoned without committing a partial object.
    entered = Completer<void>();
    cloud.intercept = (request) {
      if (request.kind != CloudRequestKind.uploadPart) return null;
      entered.complete();
      return request.hangUntilCancelled();
    };
    cancellation = RemoteOperationCancellation();
    final upload = store.put(
      'blobs/cancelled',
      Stream.value([1, 2, 3]),
      contentLength: 3,
      cancellation: cancellation,
    );
    await entered.future;
    cancellation.cancel();
    await expectLater(
      upload,
      throwsA(isA<RemoteOperationCancelledException>()),
    );
    expect(cloud.bytesOf('blobs/cancelled'), isNull);
    await cloud.verifyClean();
  }

  Future<void> _quotaMapping(RemoteObjectStore store) async {
    cloud.intercept = (request) => request.operation == cloud.createOperation
        ? cloud.quotaExceeded()
        : null;
    await expectLater(
      store.put('blobs/full', Stream.value([1]), contentLength: 1),
      throwsA(
        isA<ProviderRequestException>().having(
          (error) => error.kind,
          'kind',
          ProviderRequestErrorKind.quotaExceeded,
        ),
      ),
    );
    expect(cloud.bytesOf('blobs/full'), isNull);
    await cloud.verifyClean();
  }

  Future<void> _traversalRejection(RemoteObjectStore store) async {
    await expectLater(store.stat('../secret'), throwsArgumentError);
    await expectLater(
      store.put('blobs/../secret', Stream.value([1]), contentLength: 1),
      throwsArgumentError,
    );
    await expectLater(store.delete('/absolute'), throwsArgumentError);
    await expectLater(store.read('blobs//x').drain(), throwsArgumentError);
    expect(cloud.requests, isEmpty);
  }

  Future<void> _redactedErrors(RemoteObjectStore store) async {
    cloud.intercept = (_) => ResponseBody.fromString(
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
