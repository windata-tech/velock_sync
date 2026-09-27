import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/providers/webdav/webdav_object_store.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';

import 'memory_webdav_adapter.dart';

void main() {
  const encodedBasePath =
      '/%E5%85%B1%E4%BA%AB%20%E7%9B%AE%E5%BD%95/base%20'
      '%E5%AD%90%E8%B7%AF%E5%BE%84/';
  // A logical key is a DECODED relative path: `#`, `?`, `%` and spaces are
  // ordinary name characters here and must be escaped exactly once on the way
  // out. (The store used to pass keys through `Uri.resolve`, which treated `#`
  // as a fragment and silently wrote to a different object.)
  const logicalKey = '对象 名称 已转义#?%';
  const encodedKey =
      '%E5%AF%B9%E8%B1%A1%20%E5%90%8D%E7%A7%B0%20'
      '%E5%B7%B2%E8%BD%AC%E4%B9%89%23%3F%25';
  const expectedTarget = '$encodedBasePath$encodedKey';

  late MemoryWebDavAdapter adapter;
  late WebDavObjectStore store;
  late int absoluteDestinationRequests;

  setUp(() {
    adapter = MemoryWebDavAdapter();
    absoluteDestinationRequests = 0;
    store = WebDavObjectStore(
      dio: Dio()..httpClientAdapter = adapter,
      baseUri: Uri.parse('https://dav.test/共享 目录/base 子路径/'),
      username: 'user',
      password: 'secret',
    );
  });

  Future<ResponseBody?> rejectAbsoluteDestinations(
    RequestOptions options,
    Stream<Uint8List>? _,
    Future<void>? _,
  ) async {
    if (options.method != 'MOVE') return null;
    final destination = Uri.parse(options.headers['Destination'] as String);
    if (destination.hasScheme || destination.hasAuthority) {
      absoluteDestinationRequests++;
      return ResponseBody.fromBytes(const [], 502);
    }
    return null;
  }

  test(
    'path-absolute Destination works through an authority-rejecting proxy',
    () async {
      adapter.beforeRequest = rejectAbsoluteDestinations;

      final result = await store.put(
        logicalKey,
        Stream.value([1, 2, 3]),
        contentLength: 3,
        ifAbsent: true,
      );

      expect(result.logicalKey, logicalKey);
      expect(await store.read(logicalKey).expand((part) => part).toList(), [
        1,
        2,
        3,
      ]);
      expect(adapter.files, {
        expectedTarget: [1, 2, 3],
      });
      expect(absoluteDestinationRequests, 0);

      final moves = adapter.requests
          .where((request) => request.method == 'MOVE')
          .toList();
      final destinations = moves
          .map((request) => request.headers['Destination'] as String)
          .toList();
      expect(destinations, hasLength(3));
      expect(destinations, contains(expectedTarget));
      expect(
        destinations.where((destination) => destination.endsWith('/target')),
        hasLength(1),
      );
      expect(
        destinations.where((destination) => destination.endsWith('/published')),
        hasLength(1),
      );
      for (final destination in destinations) {
        final parsed = Uri.parse(destination);
        expect(destination, startsWith('/'));
        expect(destination, isNot(startsWith('//')));
        expect(parsed.hasScheme, isFalse);
        expect(parsed.hasAuthority, isFalse);
        expect(parsed.fragment, isEmpty);
      }

      final publish = moves.singleWhere(
        (request) => request.headers['Destination'] == expectedTarget,
      );
      expect(publish.uri.path, startsWith('$encodedBasePath.velock-upload-'));
      expect(adapter.files.containsKey(publish.uri.path), isFalse);
      expect(
        adapter.requests.where(
          (request) =>
              request.method == 'PUT' && request.uri.path == expectedTarget,
        ),
        isEmpty,
      );
      expect(adapter.collections, isEmpty);

      expect(expectedTarget, contains('%E5%AF%B9'));
      expect(expectedTarget, contains('%20'));
      expect(expectedTarget, contains('%23'));
      expect(expectedTarget, contains('%3F'));
      expect(expectedTarget, contains('%25'));
      for (final doubleEncoded in ['%2520', '%2523', '%253F', '%2525']) {
        expect(expectedTarget, isNot(contains(doubleEncoded)));
      }
    },
  );

  test('path-absolute collision preserves existing bytes', () async {
    adapter
      ..files[expectedTarget] = [7, 8, 9]
      ..beforeRequest = rejectAbsoluteDestinations;

    await expectLater(
      store.put(
        logicalKey,
        Stream.value([1, 2, 3]),
        contentLength: 3,
        ifAbsent: true,
      ),
      throwsA(isA<RemoteObjectAlreadyExistsException>()),
    );

    expect(adapter.files, {
      expectedTarget: [7, 8, 9],
    });
    expect(absoluteDestinationRequests, 0);
    final publishes = adapter.requests.where(
      (request) =>
          request.method == 'MOVE' &&
          request.headers['Destination'] == expectedTarget,
    );
    expect(publishes, hasLength(1));
    expect(publishes.single.headers['Overwrite'], 'F');
    expect(
      adapter.requests.where(
        (request) =>
            request.method == 'PUT' && request.uri.path == expectedTarget,
      ),
      isEmpty,
    );
    expect(adapter.collections, isEmpty);
  });

  test('a question mark is part of the name, never a query', () async {
    // A logical key is a decoded relative path produced by a directory listing.
    // `?` in a file name must therefore be escaped (`%3F`) and stay inside the
    // path: treating it as a query separator wrote such files to a different
    // object than the one they were listed under.
    const key = 'query 对象?x=one%26two';
    const expected =
        '${encodedBasePath}query%20%E5%AF%B9%E8%B1%A1%3Fx=one%2526two';
    adapter.beforeRequest = rejectAbsoluteDestinations;

    await store.put(
      key,
      Stream.value([4, 5]),
      contentLength: 2,
      ifAbsent: true,
    );

    final publish = adapter.requests.singleWhere(
      (request) =>
          request.method == 'MOVE' &&
          request.headers['Destination'] == expected,
    );
    final destination = requestDestination(publish);
    expect(destination.path, expected);
    expect(destination.hasQuery, isFalse);
    expect(destination.fragment, isEmpty);
    expect(destination.hasScheme, isFalse);
    expect(destination.hasAuthority, isFalse);
    expect(absoluteDestinationRequests, 0);
    expect(adapter.files, {
      destination.path: [4, 5],
    });
  });

  test('204 from path-absolute MOVE is never treated as publication', () async {
    const key = 'no-204';
    const expected = '${encodedBasePath}no-204';
    adapter.beforeRequest = (options, _, _) async {
      if (options.method == 'MOVE' &&
          options.headers['Destination'] == expected) {
        return ResponseBody.fromBytes(const [], 204);
      }
      return null;
    };

    await expectLater(
      store.put(key, Stream.value([6]), contentLength: 1, ifAbsent: true),
      throwsUnsupportedError,
    );

    expect(adapter.files, isEmpty);
    expect(adapter.collections, isEmpty);
    expect(
      adapter.requests.where(
        (request) => request.method == 'PUT' && request.uri.path == expected,
      ),
      isEmpty,
    );
  });
}

Uri requestDestination(RequestOptions request) =>
    Uri.parse(request.headers['Destination'] as String);
