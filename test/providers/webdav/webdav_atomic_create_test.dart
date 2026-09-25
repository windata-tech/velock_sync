import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/providers/webdav/webdav_object_store.dart';
import 'package:velock_sync/providers/provider_request_exception.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';

import 'memory_webdav_adapter.dart';

void main() {
  late MemoryWebDavAdapter adapter;
  late WebDavObjectStore store;
  setUp(() {
    adapter = MemoryWebDavAdapter();
    store = WebDavObjectStore(
      dio: Dio()..httpClientAdapter = adapter,
      baseUri: Uri.parse('https://dav.test/root/'),
      username: 'user',
      password: 'secret',
    );
  });
  Future<void> create(String key, List<int> bytes) async {
    await store.put(
      key,
      Stream.value(bytes),
      contentLength: bytes.length,
      ifAbsent: true,
    );
  }

  test('NAS ignoring If-None-Match cannot overwrite immutable bytes', () async {
    adapter.files['/root/object'] = [1, 2, 3];
    await expectLater(
      create('object', [0]),
      throwsA(isA<RemoteObjectAlreadyExistsException>()),
    );
    expect(adapter.files['/root/object'], [1, 2, 3]);
    expect(
      adapter.requests.where(
        (r) => r.method == 'PUT' && r.uri.path == '/root/object',
      ),
      isEmpty,
    );
    expect(adapter.files.keys, ['/root/object']);
  });
  test(
    'server ignoring Overwrite is rejected before touching real target',
    () async {
      adapter.ignoreOverwrite = true;
      adapter.files['/root/object'] = [1, 2, 3];
      await expectLater(create('object', [0]), throwsUnsupportedError);
      expect(adapter.files['/root/object'], [1, 2, 3]);
      expect(adapter.files.keys, ['/root/object']);
      expect(
        adapter.requests.any((r) => r.uri.path == '/root/object'),
        isFalse,
      );
    },
  );
  test('lying 412 that overwrites probe also fails closed', () async {
    adapter.lieOnConflict = true;
    await expectLater(create('object', [0]), throwsUnsupportedError);
    expect(adapter.files, isEmpty);
  });
  test(
    'probe is shared once; payload remains streamed and temporary data is removed',
    () async {
      await create('one', [1]);
      await create('two', [2]);
      expect(adapter.files, {
        '/root/one': [1],
        '/root/two': [2],
      });
      expect(
        adapter.requests.where(
          (r) => r.method == 'MKCOL' && r.uri.path.contains('.velock-probe-'),
        ),
        hasLength(1),
      );
    },
  );
  test('concurrent immutable creates have exactly one winner', () async {
    final results = await Future.wait(
      List.generate(4, (i) async {
        try {
          await create('race', [i]);
          return i;
        } on RemoteObjectAlreadyExistsException {
          return -1;
        }
      }),
    );
    final winners = results.where((i) => i >= 0).toList();
    expect(winners, hasLength(1));
    expect(adapter.files['/root/race'], winners);
    expect(adapter.files.length, 1);
    expect(_probeReservations(adapter), hasLength(1));
    expect(adapter.collections, isEmpty);
  });
  test('stream failure cannot publish or retain a partial target', () async {
    await expectLater(
      store.put(
        'broken',
        Stream<List<int>>.error(StateError('stream failed')),
        contentLength: 1,
        ifAbsent: true,
      ),
      throwsA(anything),
    );
    expect(adapter.files, isEmpty);
    expect(adapter.collections, isEmpty);
  });
  test(
    '429 consumes an immutable upload stream only once and never publishes',
    () async {
      var subscriptions = 0;
      late final StreamController<List<int>> controller;
      controller = StreamController<List<int>>(
        onListen: () {
          subscriptions++;
          controller.add([1, 2]);
          controller.add([3, 4]);
          unawaited(controller.close());
        },
      );
      var uploadAttempts = 0;
      adapter.beforeRequest = (options, body, _) async {
        if (options.method == 'PUT' &&
            options.uri.path.contains('.velock-upload-')) {
          uploadAttempts++;
          expect(options.headers['Content-Length'], '4');
          expect(await body!.expand((part) => part).toList(), [1, 2, 3, 4]);
          return ResponseBody.fromBytes(
            [],
            429,
            headers: {
              'retry-after': ['0'],
            },
          );
        }
        return null;
      };
      expect(controller.stream.isBroadcast, isFalse);
      await expectLater(
        store.put(
          'limited',
          controller.stream,
          contentLength: 4,
          ifAbsent: true,
        ),
        throwsA(
          isA<ProviderRequestException>().having(
            (e) => e.statusCode,
            'status',
            429,
          ),
        ),
      );
      expect(subscriptions, 1);
      expect(uploadAttempts, 1);
      expect(adapter.files, isEmpty);
      expect(adapter.collections, isEmpty);
      expect(
        adapter.requests.where(
          (r) => r.method == 'MOVE' && r.uri.path.contains('.velock-upload-'),
        ),
        isEmpty,
      );
    },
  );

  test('cancelling one probe waiter does not cancel another writer', () async {
    final probeEntered = Completer<void>();
    final releaseProbe = Completer<void>();
    addTearDown(() {
      if (!releaseProbe.isCompleted) releaseProbe.complete();
    });
    adapter.beforeRequest = (options, _, _) async {
      if (options.method == 'MKCOL' &&
          options.uri.path.contains('.velock-probe-')) {
        if (!probeEntered.isCompleted) probeEntered.complete();
        await releaseProbe.future;
      }
      return null;
    };
    final cancellation = RemoteOperationCancellation();
    var cancelledStreamSubscriptions = 0;
    final cancelled = store.put(
      'cancelled',
      Stream<List<int>>.multi((controller) {
        cancelledStreamSubscriptions++;
        controller.add([9]);
        controller.close();
      }),
      contentLength: 1,
      ifAbsent: true,
      cancellation: cancellation,
    );
    final cancelledCheck = expectLater(
      cancelled,
      throwsA(isA<RemoteOperationCancelledException>()),
    );
    await probeEntered.future;
    final survivor = create('survivor', [1, 2]);
    cancellation.cancel();
    await cancelledCheck.timeout(const Duration(seconds: 5));
    expect(cancelledStreamSubscriptions, 0);
    releaseProbe.complete();
    await survivor;
    await create('later', [3]);
    expect(_probeReservations(adapter), hasLength(1));
    expect(adapter.files, {
      '/root/survivor': [1, 2],
      '/root/later': [3],
    });
    expect(adapter.collections, isEmpty);
  });

  test(
    'failed shared probe rejects every writer without consuming payloads',
    () async {
      adapter.ignoreOverwrite = true;
      var subscriptions = 0;
      final checks = List.generate(
        4,
        (index) => expectLater(
          store.put(
            'object-$index',
            Stream<List<int>>.multi((controller) {
              subscriptions++;
              controller.add([index]);
              controller.close();
            }),
            contentLength: 1,
            ifAbsent: true,
          ),
          throwsUnsupportedError,
        ),
      );
      await Future.wait(checks);
      expect(subscriptions, 0);
      expect(_probeReservations(adapter), hasLength(1));
      expect(
        adapter.requests.where((r) => r.uri.path.contains('.velock-upload-')),
        isEmpty,
      );
      expect(adapter.files, isEmpty);
      expect(adapter.collections, isEmpty);
    },
  );

  test(
    'cancellation during upload removes partial private bytes without publishing',
    () async {
      final uploadEntered = Completer<void>();
      adapter.beforeRequest = (options, body, cancelFuture) async {
        if (options.method == 'PUT' &&
            options.uri.path.contains('.velock-upload-')) {
          final bytes = await body!.expand((part) => part).toList();
          adapter.files[options.uri.path] = bytes.take(1).toList();
          uploadEntered.complete();
          await cancelFuture;
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.cancel,
          );
        }
        return null;
      };
      final cancellation = RemoteOperationCancellation();
      final check = expectLater(
        store.put(
          'cancelled',
          Stream.value([1, 2, 3]),
          contentLength: 3,
          ifAbsent: true,
          cancellation: cancellation,
        ),
        throwsA(isA<RemoteOperationCancelledException>()),
      );
      await uploadEntered.future;
      cancellation.cancel();
      await check;
      expect(adapter.files, isEmpty);
      expect(adapter.collections, isEmpty);
      expect(
        adapter.requests.where(
          (r) => r.method == 'MOVE' && r.uri.path.contains('.velock-upload-'),
        ),
        isEmpty,
      );
      final cleanup = adapter.requests.where(
        (r) => r.method == 'DELETE' && r.uri.path.contains('.velock-upload-'),
      );
      expect(cleanup, hasLength(1));
      expect(cleanup.single.cancelToken?.isCancelled ?? false, isFalse);
    },
  );

  for (final statusCode in [405, 409]) {
    test(
      'MKCOL $statusCode for upload collection is classified as not writable '
      'without touching unowned data',
      () async {
        String? unowned;
        adapter.beforeRequest = (options, _, _) async {
          if (options.method == 'MKCOL' &&
              options.uri.path.contains('.velock-upload-')) {
            unowned = options.uri.path;
            adapter.collections.add(unowned!);
            adapter.files['$unowned/foreign'] = [7, 8];
            return ResponseBody.fromBytes([], statusCode);
          }
          return null;
        };
        final errorMatcher = allOf(
          isNot(isA<UnsupportedError>()),
          isA<SyncFailureException>()
              .having(
                (e) => e.syncFailure.errorCode,
                'code',
                'provider.webdav.collection_not_writable',
              )
              .having(
                (e) => e.syncFailure.category,
                'category',
                SyncErrorCategory.userActionRequired,
              )
              .having((e) => e.syncFailure.retryable, 'retryable', isTrue)
              .having(
                (e) => e.syncFailure.providerStatusCode,
                'providerStatus',
                statusCode,
              ),
        );
        await expectLater(create('object', [0]), throwsA(errorMatcher));
        expect(unowned, isNotNull);
        expect(adapter.files, {
          '$unowned/foreign': [7, 8],
        });
        expect(adapter.collections, {unowned});
        final requestsInUnownedCollection = adapter.requests.where(
          (r) =>
              (r.uri.path == unowned || r.uri.path.startsWith('$unowned/')) &&
              r.method != 'MKCOL',
        );
        expect(requestsInUnownedCollection, isEmpty);
      },
    );
  }

  test(
    'transient probe failure is cleaned and same instance can probe again',
    () async {
      var failed = false;
      var subscriptions = 0;
      adapter.beforeRequest = (options, _, _) async {
        if (!failed &&
            options.method == 'MOVE' &&
            options.uri.path.contains('.velock-probe-')) {
          failed = true;
          // Fail after probe bytes exist, so cleanup is verified too.
          expect(adapter.files.length, 2);
          return ResponseBody.fromBytes([], 503);
        }
        return null;
      };
      final content = Stream<List<int>>.multi((controller) {
        subscriptions++;
        controller.add([4, 5, 6]);
        controller.close();
      });
      await expectLater(
        store.put('recovered', content, contentLength: 3, ifAbsent: true),
        throwsA(
          isA<ProviderRequestException>().having(
            (e) => e.statusCode,
            'status',
            503,
          ),
        ),
      );
      expect(failed, isTrue);
      expect(subscriptions, 0);
      expect(adapter.files, isEmpty);
      expect(adapter.collections, isEmpty);
      expect(_probeReservations(adapter), hasLength(1));
      expect(
        adapter.requests.where((r) => r.uri.path.contains('.velock-upload-')),
        isEmpty,
      );

      final result = await store.put(
        'recovered',
        content,
        contentLength: 3,
        ifAbsent: true,
      );
      expect(result.logicalKey, 'recovered');
      expect(result.size, 3);
      expect(subscriptions, 1);
      expect(await store.read('recovered').expand((p) => p).toList(), [
        4,
        5,
        6,
      ]);
      await create('later', [7]);
      expect(_probeReservations(adapter), hasLength(2));
      expect(adapter.files, {
        '/root/recovered': [4, 5, 6],
        '/root/later': [7],
      });
      expect(adapter.collections, isEmpty);
      expect(
        adapter.requests.where(
          (r) => r.method == 'PUT' && r.uri.path == '/root/recovered',
        ),
        isEmpty,
      );
    },
  );

  test(
    'unsupported MOVE stays fail-closed with an actionable structured error',
    () async {
      var unsupported = true;
      adapter.beforeRequest = (options, _, _) async {
        if (unsupported && options.method == 'MOVE') {
          return ResponseBody.fromBytes([], 405);
        }
        return null;
      };
      final errorMatcher = allOf(
        isA<UnsupportedError>(),
        isA<SyncFailureException>()
            .having(
              (e) => e.syncFailure.errorCode,
              'code',
              'provider.webdav.atomic_create_unsupported',
            )
            .having((e) => e.syncFailure.retryable, 'retryable', isFalse)
            .having((e) => e.syncFailure.suggestedAction, 'action', isNotEmpty),
      );
      await expectLater(create('object', [0]), throwsA(errorMatcher));
      // A changed server must not bypass a failed capability check on this store.
      unsupported = false;
      await expectLater(create('object', [1]), throwsA(errorMatcher));
      expect(_probeReservations(adapter), hasLength(1));
      expect(
        adapter.requests.where((r) => r.uri.path.contains('.velock-upload-')),
        isEmpty,
      );
      expect(adapter.files, isEmpty);
      expect(adapter.collections, isEmpty);
    },
  );

  test('cancelled write sends no requests', () async {
    final cancellation = RemoteOperationCancellation()..cancel();
    await expectLater(
      store.put(
        'object',
        Stream.value([1]),
        contentLength: 1,
        ifAbsent: true,
        cancellation: cancellation,
      ),
      throwsA(isA<RemoteOperationCancelledException>()),
    );
    expect(adapter.requests, isEmpty);
  });
}

Iterable<RequestOptions> _probeReservations(MemoryWebDavAdapter adapter) =>
    adapter.requests.where(
      (r) => r.method == 'MKCOL' && r.uri.path.contains('.velock-probe-'),
    );
