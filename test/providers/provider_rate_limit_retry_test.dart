import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/providers/provider_rate_limit_retry.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';

void main() {
  test('honors Retry-After then returns the retried response', () async {
    final waits = <Duration>[];
    var calls = 0;
    final retry = ProviderRateLimitRetry(
      sleeper: (delay) async => waits.add(delay),
    );
    final result = await retry.execute(() async {
      calls++;
      return Response<int>(
        requestOptions: RequestOptions(path: '/'),
        statusCode: calls == 1 ? 429 : 200,
        headers: calls == 1
            ? Headers.fromMap({
                'retry-after': ['2'],
              })
            : Headers(),
      );
    });
    expect(result.statusCode, 200);
    expect(waits, [const Duration(seconds: 2)]);
  });

  test('uses exponential fallback and stops at the retry limit', () async {
    final waits = <Duration>[];
    final retry = ProviderRateLimitRetry(
      maxRetries: 1,
      sleeper: (delay) async => waits.add(delay),
      nextRandomInt: (maxExclusive) => maxExclusive - 1,
    );
    await expectLater(
      retry.execute(
        () async => Response<void>(
          requestOptions: RequestOptions(path: '/'),
          statusCode: 429,
        ),
      ),
      throwsA(isA<ProviderRateLimitedException>()),
    );
    expect(waits, [const Duration(seconds: 1)]);
  });

  test('adds bounded random jitter to exponential fallback delays', () async {
    final waits = <Duration>[];
    var randomCalls = 0;
    final retry = ProviderRateLimitRetry(
      maxRetries: 1,
      sleeper: (delay) async => waits.add(delay),
      nextRandomInt: (maxExclusive) {
        randomCalls++;
        return maxExclusive ~/ 2;
      },
    );

    var calls = 0;
    final result = await retry.execute(() async {
      calls++;
      return Response<void>(
        requestOptions: RequestOptions(path: '/'),
        statusCode: calls == 1 ? 429 : 200,
      );
    });

    expect(result.statusCode, 200);
    expect(randomCalls, 1);
    expect(waits, [const Duration(milliseconds: 500)]);
  });

  test(
    'retries transient server failures only through the explicit API',
    () async {
      final waits = <Duration>[];
      var calls = 0;
      final retry = ProviderRateLimitRetry(
        sleeper: (delay) async => waits.add(delay),
        nextRandomInt: (maxExclusive) => 0,
      );

      final result = await retry.executeTransient(() async {
        calls++;
        return Response<void>(
          requestOptions: RequestOptions(path: '/'),
          statusCode: calls == 1 ? 503 : 200,
        );
      });

      expect(result.statusCode, 200);
      expect(calls, 2);
      expect(waits, [Duration.zero]);
    },
  );

  test('cancels while waiting to retry a rate-limited request', () async {
    final cancellation = RemoteOperationCancellation();
    final waiting = Completer<void>();
    final retry = ProviderRateLimitRetry(
      sleeper: (_) => waiting.future,
      nextRandomInt: (_) => 0,
    );

    final request = retry.execute<void>(
      () async => Response<void>(
        requestOptions: RequestOptions(path: '/'),
        statusCode: 429,
      ),
      whenCancelled: cancellation.whenCancelled,
    );
    await Future<void>.delayed(Duration.zero);
    cancellation.cancel();

    await expectLater(
      request,
      throwsA(isA<RemoteOperationCancelledException>()),
    );
  });
}
