import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/providers/webdav/webdav_object_store.dart';

/// Uploads are bounded by progress, not by total duration.
///
/// Dio's `sendTimeout` covers the whole request body. With the five minute
/// value the sync clients use, any single object that needed longer failed on
/// every run and blocked all later batches.
void main() {
  late HttpServer server;
  late List<int> received;

  setUp(() async {
    received = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        await for (final chunk in request) {
          received.addAll(chunk);
        }
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      } on HttpException {
        // The client aborted a stalled upload.
      }
    });
  });

  tearDown(() => server.close(force: true));

  WebDavObjectStore store() => WebDavObjectStore(
    dio: Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
        // Far shorter than the body below takes to send.
        sendTimeout: const Duration(milliseconds: 300),
      ),
    ),
    baseUri: Uri.parse('http://${server.address.host}:${server.port}/dav/'),
    username: null,
    password: null,
    uploadIdleTimeout: const Duration(milliseconds: 400),
  );

  test('a slow but moving upload finishes past the send timeout', () async {
    Stream<List<int>> slowBody() async* {
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        yield [i];
      }
    }

    final metadata = await store().put(
      'slow.bin',
      slowBody(),
      contentLength: 8,
    );

    expect(metadata.size, 8);
    expect(received, [0, 1, 2, 3, 4, 5, 6, 7]);
  });

  test('a stalled upload fails as a timeout', () async {
    final stalled = StreamController<List<int>>();
    addTearDown(stalled.close);
    stalled.add([1]);

    await expectLater(
      store().put('stalled.bin', stalled.stream, contentLength: 4),
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.sendTimeout,
        ),
      ),
    );
  });
}
