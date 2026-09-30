import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/providers/provider_request_exception.dart';
import 'package:velock_sync/providers/webdav/webdav_auth_race_guard.dart';
import 'package:velock_sync/providers/webdav/webdav_object_store.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';

import 'memory_webdav_adapter.dart';

/// Emulates the measured FN Connect relay behaviour: a request that arrives
/// within 50 ms of another request that is still in flight is rejected with a
/// `401 Basic realm="Restricted"` before it reaches the WebDAV server.
class _RacingRelay {
  _RacingRelay(this.adapter) {
    adapter.beforeRequest = (options, body, cancelFuture) async {
      final arrival = DateTime.now();
      final collides = _inFlight.any(
        (other) => arrival.difference(other).abs() < window,
      );
      _inFlight.add(arrival);
      try {
        await Future<void>.delayed(latency);
        if (!collides) return null;
        rejected++;
        rejectedMethods.add(options.method);
        return ResponseBody.fromString(
          'Not Authorized',
          401,
          headers: {
            'www-authenticate': ['Basic realm="Restricted"'],
            'content-type': ['text/plain'],
          },
        );
      } finally {
        _inFlight.remove(arrival);
      }
    };
  }

  final MemoryWebDavAdapter adapter;
  final window = const Duration(milliseconds: 50);
  final latency = const Duration(milliseconds: 30);
  final _inFlight = <DateTime>[];
  final rejectedMethods = <String>[];
  int rejected = 0;
}

WebDavObjectStore _store(
  MemoryWebDavAdapter adapter, {
  WebDavAuthRaceGuard? guard,
}) => WebDavObjectStore(
  dio: Dio()..httpClientAdapter = adapter,
  baseUri: Uri.parse('https://dav.test/root/'),
  username: 'user',
  password: 'secret',
  authRaceGuard: guard,
);

Future<Object?> _publish(WebDavObjectStore store, String key, int value) async {
  try {
    await store.put(
      key,
      Stream.value([value, value, value]),
      contentLength: 3,
      ifAbsent: true,
    );
    return null;
  } catch (error) {
    return error;
  }
}

void main() {
  setUp(WebDavAuthRaceGuard.resetForTesting);

  group('over a relay that rejects near-simultaneous requests', () {
    test(
      'the emulated relay does reject unguarded concurrent uploads',
      () async {
        // Control: without pacing or retries the relay emulation must bite,
        // otherwise the tests below would prove nothing.
        final adapter = MemoryWebDavAdapter();
        _RacingRelay(adapter);
        final store = _store(
          adapter,
          guard: WebDavAuthRaceGuard(
            startGap: Duration.zero,
            provenRetries: 0,
            unprovenRetries: 0,
          ),
        );

        final errors = await Future.wait([
          for (var i = 0; i < 4; i++) _publish(store, 'race/object-$i', i),
        ]);

        expect(
          errors.whereType<ProviderRequestException>().map((e) => e.statusCode),
          contains(401),
        );
      },
    );

    test(
      'four racing uploads to one key: one wins, none fail with 401',
      () async {
        final adapter = MemoryWebDavAdapter();
        final relay = _RacingRelay(adapter);
        final store = _store(adapter);

        final errors = await Future.wait([
          for (var i = 0; i < 4; i++) _publish(store, 'race.bin', i),
        ]);

        expect(errors.where((e) => e == null), hasLength(1));
        expect(
          errors.whereType<Object>(),
          everyElement(isA<RemoteObjectAlreadyExistsException>()),
        );
        final winner = adapter.files['/root/race.bin']!;
        expect(winner.toSet(), hasLength(1));
        // A rejected upload body is never replayed.
        expect(relay.rejectedMethods, isNot(contains('PUT')));
      },
    );

    test('eight concurrent uploads to distinct keys all publish', () async {
      final adapter = MemoryWebDavAdapter();
      final relay = _RacingRelay(adapter);
      final store = _store(adapter);

      final errors = await Future.wait([
        for (var i = 0; i < 8; i++) _publish(store, 'batch/object-$i', i),
      ]);

      expect(errors, everyElement(isNull));
      for (var i = 0; i < 8; i++) {
        expect(adapter.files['/root/batch/object-$i'], [i, i, i]);
      }
      expect(relay.rejectedMethods, isNot(contains('PUT')));
    });

    test('parallel listings recover from spurious 401s', () async {
      final adapter = MemoryWebDavAdapter();
      adapter.collections.add('/root/');
      final relay = _RacingRelay(adapter);
      // Distinct store instances share the per-endpoint guard.
      final pages = await Future.wait([
        for (var i = 0; i < 6; i++) _store(adapter).stat('missing-$i'),
      ]);

      expect(pages, everyElement(isNull));
      expect(relay.rejected, lessThanOrEqualTo(6));
    });
  });

  group('a genuine 401 is not hammered', () {
    MemoryWebDavAdapter alwaysUnauthorized() =>
        MemoryWebDavAdapter()
          ..beforeRequest = (options, body, cancelFuture) async =>
              ResponseBody.fromString('Not Authorized', 401);

    test('an unproven account gets exactly one retry', () async {
      final adapter = alwaysUnauthorized();

      await expectLater(
        _store(adapter).stat('object'),
        throwsA(
          isA<ProviderRequestException>().having(
            (e) => e.statusCode,
            'statusCode',
            401,
          ),
        ),
      );
      expect(adapter.requests, hasLength(2));
    });

    test('a proven account gets at most three retries', () async {
      final adapter = MemoryWebDavAdapter();
      final store = _store(adapter);
      expect(await store.stat('object'), isNull);
      adapter.requests.clear();
      adapter.beforeRequest = (options, body, cancelFuture) async =>
          ResponseBody.fromString('Not Authorized', 401);

      await expectLater(
        store.stat('object'),
        throwsA(isA<ProviderRequestException>()),
      );
      expect(adapter.requests, hasLength(4));
    });

    test('a caller upload stream is never replayed after 401', () async {
      final adapter = MemoryWebDavAdapter();
      adapter.beforeRequest = (options, body, cancelFuture) async =>
          options.method == 'PUT'
          ? ResponseBody.fromString('Not Authorized', 401)
          : null;

      await expectLater(
        _store(
          adapter,
        ).put('folder/plain.txt', Stream.value([1, 2, 3]), contentLength: 3),
        throwsA(
          isA<ProviderRequestException>().having(
            (e) => e.statusCode,
            'statusCode',
            401,
          ),
        ),
      );
      expect(adapter.requests.where((r) => r.method == 'PUT'), hasLength(1));
    });
  });

  group('pacing', () {
    late DateTime now;
    late List<Duration> sleeps;
    late WebDavAuthRaceGuard guard;

    setUp(() {
      now = DateTime.utc(2026, 9, 30);
      sleeps = [];
      guard = WebDavAuthRaceGuard(
        clock: () => now,
        sleeper: (delay) async {
          sleeps.add(delay);
          now = now.add(delay);
        },
      );
    });

    test('a start waits while the previous request is unanswered', () async {
      final first = Completer<void>();
      final firstRun = guard.paced(() => first.future);
      await Future<void>.delayed(Duration.zero);
      now = now.add(const Duration(milliseconds: 50));

      await guard.paced(() async {});

      expect(sleeps, [const Duration(milliseconds: 150)]);
      first.complete();
      await firstRun;
    });

    test('an answered request does not delay the next start', () async {
      await guard.paced(() async {});
      await guard.paced(() async {});
      await guard.paced(() async {});

      expect(sleeps, isEmpty);
    });

    test('a failed request still releases its slot', () async {
      await expectLater(
        guard.paced<void>(() async => throw StateError('boom')),
        throwsStateError,
      );
      await guard.paced(() async {});

      expect(sleeps, isEmpty);
    });

    test('guards are shared per endpoint and account only', () {
      final a = WebDavAuthRaceGuard.forEndpoint(
        Uri.parse('https://dav.test/a/'),
        username: 'u',
        password: 'p',
      );
      expect(
        WebDavAuthRaceGuard.forEndpoint(
          Uri.parse('https://dav.test:443/b/'),
          username: 'u',
          password: 'p',
        ),
        same(a),
      );
      expect(
        WebDavAuthRaceGuard.forEndpoint(
          Uri.parse('https://dav.test/a/'),
          username: 'u',
          password: 'other',
        ),
        isNot(same(a)),
      );
      expect(
        WebDavAuthRaceGuard.forEndpoint(
          Uri.parse('https://other.test/a/'),
          username: 'u',
          password: 'p',
        ),
        isNot(same(a)),
      );
    });
  });
}
