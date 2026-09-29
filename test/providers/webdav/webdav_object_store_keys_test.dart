/// Names that are legal on disk must survive the trip to WebDAV intact.
///
/// `Uri.resolve('a#b.png')` treats `#` as a fragment marker and `?` as a query,
/// so such a file used to be written to (and deleted at) a DIFFERENT remote
/// path — two such names collided on one object. Keys are now encoded segment
/// by segment, and a missing collection is reported instead of being reported
/// as an empty one (which the mirror would read as "the user deleted
/// everything remotely").
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/providers/webdav/webdav_object_store.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';

import 'memory_webdav_adapter.dart';

final _baseUri = Uri.parse('https://nas.local:5006/share/sync/');

/// Records what the store actually requested and answers like a small server.
class _RecordingAdapter extends MemoryWebDavAdapter {
  _RecordingAdapter({this.missing = false});

  /// When true every PROPFIND answers 404, i.e. the folder does not exist.
  bool missing;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) async {
    if (missing && options.method == 'PROPFIND') {
      requests.add(options);
      return ResponseBody.fromBytes(
        const <int>[],
        404,
        headers: const {
          'content-length': ['0'],
        },
      );
    }
    return super.fetch(options, body, cancelFuture);
  }
}

WebDavObjectStore _store(_RecordingAdapter adapter) => WebDavObjectStore(
  dio: Dio()..httpClientAdapter = adapter,
  baseUri: _baseUri,
  username: 'user',
  password: 'secret',
);

void main() {
  test('a name containing # or ? keeps its own remote path', () async {
    final adapter = _RecordingAdapter();
    final store = _store(adapter);

    await store.put(
      'reports/a#b.txt',
      Stream.value(Uint8List.fromList([1])),
      contentLength: 1,
    );
    await store.put(
      'reports/q?x.txt',
      Stream.value(Uint8List.fromList([1])),
      contentLength: 1,
    );

    final puts = adapter.requests
        .where((request) => request.method == 'PUT')
        .map((request) => request.uri)
        .toList();
    expect(puts, hasLength(2));
    // Two different files, two different objects — and no fragment/query.
    expect(puts[0].fragment, isEmpty);
    expect(puts[1].fragment, isEmpty);
    expect(puts[0].query, isEmpty);
    expect(puts[1].query, isEmpty);
    expect(puts[0].pathSegments.last, 'a#b.txt');
    expect(puts[1].pathSegments.last, 'q?x.txt');
    expect(puts[0].path, isNot(puts[1].path));
  });

  test('a missing collection is not reported as an empty one', () async {
    final adapter = _RecordingAdapter(missing: true);
    final store = _store(adapter);

    await expectLater(
      store.list(prefix: ''),
      throwsA(isA<RemoteObjectNotFoundException>()),
    );
  });

  test('a unicode name is sent percent-encoded exactly once', () async {
    final adapter = _RecordingAdapter();
    final store = _store(adapter);

    await store.put(
      '照片/旅行 2026.jpg',
      Stream.value(Uint8List.fromList([1])),
      contentLength: 1,
    );

    final uri = adapter.requests.last.uri;
    // The raw path carries the percent-escapes exactly once, and decoding it
    // returns the original name — no double encoding, no lost characters.
    expect(uri.path, contains('%E7%85%A7%E7%89%87'));
    expect(uri.path, contains('%E6%97%85%E8%A1%8C%202026.jpg'));
    expect(uri.path, isNot(contains('%25E7%85%A7')));
    expect(Uri.decodeFull(uri.path), contains('照片/旅行 2026.jpg'));
  });
}
