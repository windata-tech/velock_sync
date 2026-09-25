import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Models the observed NAS bug: PUT ignores If-None-Match; only MOVE is atomic.
class MemoryWebDavAdapter implements HttpClientAdapter {
  final files = <String, List<int>>{};
  final collections = <String>{};
  final requests = <RequestOptions>[];
  // Fault injection is applied after recording, before normal server semantics.
  Future<ResponseBody?> Function(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  )?
  beforeRequest;
  bool ignoreOverwrite = false;
  bool lieOnConflict = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final injected = await beforeRequest?.call(options, body, cancelFuture);
    if (injected != null) return injected;
    final path = options.uri.path;
    ResponseBody response(int status, [List<int> bytes = const []]) =>
        ResponseBody.fromBytes(
          bytes,
          status,
          headers: {
            'content-length': ['${bytes.length}'],
          },
        );
    switch (options.method) {
      case 'MKCOL':
        return response(collections.add(path) ? 201 : 405);
      case 'PUT':
        files[path] = await body!.expand((b) => b).toList();
        return response(201);
      case 'HEAD':
        return files.containsKey(path) ? response(200) : response(404);
      case 'GET':
        return files.containsKey(path)
            ? response(200, files[path]!)
            : response(404);
      case 'MOVE':
        final destination = Uri.parse(
          options.headers['Destination'] as String,
        ).path;
        if (!files.containsKey(path)) return response(404);
        final exists = files.containsKey(destination);
        if (exists &&
            options.headers['Overwrite'] == 'F' &&
            !ignoreOverwrite &&
            !lieOnConflict) {
          return response(412);
        }
        files[destination] = files.remove(path)!;
        return response(
          lieOnConflict && exists
              ? 412
              : exists
              ? 204
              : 201,
        );
      case 'DELETE':
        files.removeWhere((key, _) => key == path || key.startsWith('$path/'));
        collections.remove(path);
        return response(204);
      default:
        throw StateError('Unexpected request ${options.method}');
    }
  }

  @override
  void close({bool force = false}) {}
}
