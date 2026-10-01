import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/providers/oauth/oauth_access_token_provider.dart';
import 'package:velock_sync/providers/one_drive/one_drive_object_store.dart';
import 'package:velock_sync/providers/provider_rate_limit_retry.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';

import 'cloud_tree.dart';
import 'stateful_object_store_contract.dart';

/// Microsoft Graph's OneDrive as a real folder tree: items addressed by ID or
/// by path (`root:/a/b:`, `items/{id}:/a/b:`), simple and session uploads,
/// `conflictBehavior`, folder creation and deletes into the recycle bin.
///
/// [connectionRootId] is the item the connection is rooted at: `root`, or a
/// folder created below the drive root by [useFolderRoot].
class OneDriveTreeCloud extends ContractCloud {
  static const graphHost = 'graph.microsoft.com';
  static const uploadHost = 'upload.example.test';
  static const downloadHost = 'download.example.test';

  final tree = CloudTree(rootId: 'drive-root');
  String connectionRootId = 'root';
  final _sessions = <String, _Session>{};
  int _nextSession = 0;

  /// Graph paths the adapter addressed, decoded, e.g. `root:/a/b:/children`.
  final addressed = <String>[];

  @override
  int get partBytes => 10 * 1024 * 1024;

  @override
  String get createOperation => 'createUploadSession';

  @override
  void reset() {
    super.reset();
    tree.clear();
    _sessions.clear();
    addressed.clear();
    connectionRootId = 'root';
  }

  /// Roots the connection at `/[name]` instead of the drive root, as a folder
  /// picked when the connection was added.
  CloudTreeNode useFolderRoot(String name) {
    final folder = tree.ensureFolders([name]);
    connectionRootId = folder.id;
    return folder;
  }

  String get _rootNodeId =>
      connectionRootId == 'root' ? tree.rootId : connectionRootId;

  @override
  void seed(String key, List<int> bytes, {bool duplicateListing = false}) =>
      tree.writeFile(key, bytes, fromId: _rootNodeId);

  void addFolder(String path) =>
      tree.ensureFolders(path.split('/'), fromId: _rootNodeId);

  @override
  List<int>? bytesOf(String key) =>
      tree.resolve(key.split('/'), fromId: _rootNodeId)?.bytes;

  bool isFolder(String path) =>
      tree.resolve(path.split('/'), fromId: _rootNodeId)?.isFolder ?? false;

  @override
  Future<RemoteObjectStore> createStore({
    required OAuthAccessTokenProvider tokens,
    required Dio dio,
    required ProviderRateLimitRetry retry,
  }) async => OneDriveObjectStore(
    accessTokenProvider: tokens,
    rootItemId: connectionRootId,
    dio: dio,
    rateLimitRetry: retry,
  );

  @override
  CloudRequestKind kindOf(RequestOptions options) => switch (options.uri.host) {
    uploadHost => CloudRequestKind.uploadPart,
    downloadHost => CloudRequestKind.download,
    _ => CloudRequestKind.api,
  };

  @override
  String operationOf(RequestOptions options, CloudRequestKind kind) =>
      '${options.method} ${options.uri.path}';

  @override
  String? tokenOf(CloudRequest request) {
    final header = '${request.options.headers['Authorization'] ?? ''}';
    return header.startsWith('Bearer ') ? header.substring(7) : null;
  }

  @override
  bool requiresToken(CloudRequestKind kind) => kind == CloudRequestKind.api;

  @override
  ResponseBody unauthorised(CloudRequest request) => jsonBody({
    'error': {'code': 'InvalidAuthenticationToken'},
  }, status: 401);

  @override
  ResponseBody rateLimited() => jsonBody({
    'error': {'code': 'activityLimitReached'},
  }, status: 429);

  @override
  ResponseBody quotaExceeded() => jsonBody({
    'error': {'code': 'quotaLimitReached'},
  }, status: 507);

  ResponseBody _error(int status, String code) => jsonBody({
    'error': {'code': code},
  }, status: status);

  @override
  Future<ResponseBody> handle(CloudRequest request) async {
    switch (request.kind) {
      case CloudRequestKind.uploadPart:
        return _receiveChunk(request);
      case CloudRequestKind.download:
        _expectNoToken(request);
        final node = tree.byId(request.options.uri.pathSegments.single);
        if (node == null || node.isFolder) {
          return ResponseBody.fromString('', 404);
        }
        return rangedBody(request.options, node.bytes!);
      case CloudRequestKind.api:
        return _api(request);
    }
  }

  void _expectNoToken(CloudRequest request) => expect(
    request.options.headers.keys.map((key) => key.toLowerCase()),
    isNot(contains('authorization')),
    reason: 'the bearer token must never reach the storage host',
  );

  ResponseBody _api(CloudRequest request) {
    final uri = request.options.uri;
    // Graph decodes each path segment on its own; Uri does the same.
    final segments = uri.pathSegments;
    expect(segments.take(3), ['v1.0', 'me', 'drive']);
    var rest = segments.skip(3).toList();
    String baseId;
    if (rest.first == 'root' || rest.first == 'root:') {
      baseId = tree.rootId;
    } else {
      expect(rest.first, 'items');
      rest = rest.skip(1).toList();
      final id = rest.first.endsWith(':')
          ? rest.first.substring(0, rest.first.length - 1)
          : rest.first;
      baseId = id == 'root' ? tree.rootId : id;
      if (tree.byId(baseId) == null) return _error(404, 'itemNotFound');
    }
    final pathSegments = <String>[];
    var suffix = <String>[];
    if (rest.first.endsWith(':')) {
      // `{base}:/a/b:/suffix`
      var index = 1;
      for (; index < rest.length; index++) {
        final segment = rest[index];
        if (segment.endsWith(':')) {
          pathSegments.add(segment.substring(0, segment.length - 1));
          index++;
          break;
        }
        pathSegments.add(segment);
      }
      suffix = rest.sublist(index);
    } else {
      suffix = rest.sublist(1);
    }
    addressed.add(
      [
        pathSegments.isEmpty ? '' : ':/${pathSegments.join('/')}:',
        if (suffix.isNotEmpty) '/${suffix.join('/')}',
      ].join(),
    );
    final target = tree.resolve(pathSegments, fromId: baseId);
    final method = request.options.method;
    final operation = suffix.isEmpty ? '' : suffix.join('/');

    switch ((method, operation)) {
      case ('GET', ''):
        if (target == null) return _error(404, 'itemNotFound');
        return jsonBody(_json(target, uri.queryParameters[r'$select']));
      case ('GET', 'children'):
        if (target == null || !target.isFolder) {
          return _error(404, 'itemNotFound');
        }
        return _children(target, uri);
      case ('DELETE', ''):
        if (target == null) return _error(404, 'itemNotFound');
        tree.remove(target, toRecycleBin: true);
        return ResponseBody.fromString('', 204);
      case ('POST', 'children'):
        if (target == null || !target.isFolder) {
          return _error(404, 'itemNotFound');
        }
        final body = jsonDecode(utf8.decode(request.body)) as Map;
        expect(body['folder'], isA<Map>());
        expect(body['@microsoft.graph.conflictBehavior'], 'fail');
        final name = body['name'] as String;
        if (tree.child(target.id, name) != null) {
          return _error(409, 'nameAlreadyExists');
        }
        return jsonBody(_json(tree.add(target.id, name), null), status: 201);
      case ('PUT', 'content'):
        return _simpleUpload(
          baseId,
          pathSegments,
          request.body,
          uri.queryParameters['@microsoft.graph.conflictBehavior'],
        );
      case ('POST', 'createUploadSession'):
        final body = jsonDecode(utf8.decode(request.body)) as Map;
        final behavior =
            (body['item'] as Map)['@microsoft.graph.conflictBehavior'];
        if (behavior == 'fail' && target != null) {
          return _error(409, 'nameAlreadyExists');
        }
        final id = 'session-${_nextSession++}';
        _sessions[id] = _Session(baseId, pathSegments, '$behavior');
        return jsonBody({'uploadUrl': 'https://$uploadHost/$id'});
    }
    return _error(400, 'invalidRequest');
  }

  ResponseBody _children(CloudTreeNode folder, Uri uri) {
    final children = tree.childrenOf(folder.id);
    final top = int.parse(uri.queryParameters[r'$top'] ?? '200');
    final start = int.parse(uri.queryParameters[r'$skiptoken'] ?? '0');
    final end = (start + top).clamp(0, children.length);
    return jsonBody({
      'value': [
        for (final node in children.sublist(start, end))
          _json(node, uri.queryParameters[r'$select']),
      ],
      if (end < children.length)
        '@odata.nextLink': uri
            .replace(
              queryParameters: {...uri.queryParameters, r'$skiptoken': '$end'},
            )
            .toString(),
    });
  }

  ResponseBody _simpleUpload(
    String baseId,
    List<String> path,
    List<int> bytes,
    String? behavior,
  ) {
    final parent = tree.resolve(
      path.sublist(0, path.length - 1),
      fromId: baseId,
    );
    if (parent == null || !parent.isFolder) return _error(404, 'itemNotFound');
    final existing = tree.child(parent.id, path.last);
    if (existing != null) {
      if (behavior == 'fail' || existing.isFolder) {
        return _error(409, 'nameAlreadyExists');
      }
      existing
        ..bytes = bytes
        ..version += 1;
      committedUploads.add([bytes.length]);
      return jsonBody(_json(existing, null));
    }
    committedUploads.add([bytes.length]);
    return jsonBody(
      _json(tree.add(parent.id, path.last, bytes: bytes), null),
      status: 201,
    );
  }

  ResponseBody _receiveChunk(CloudRequest request) {
    _expectNoToken(request);
    final session = _sessions[request.options.uri.pathSegments.single];
    if (session == null) return ResponseBody.fromString('', 404);
    final range = RegExp(
      r'^bytes (\d+)-(\d+)/(\d+)$',
    ).firstMatch('${request.options.headers['Content-Range']}')!;
    expect(int.parse(range.group(1)!), session.received.length);
    session.received.addAll(request.body);
    if (session.received.length < int.parse(range.group(3)!)) {
      return jsonBody({'nextExpectedRanges': []}, status: 202);
    }
    _sessions.remove(request.options.uri.pathSegments.single);
    return _simpleUpload(
      session.baseId,
      session.path,
      session.received,
      session.behavior,
    );
  }

  Map<String, Object?> _json(CloudTreeNode node, String? select) => {
    'id': node.id,
    'name': node.name,
    'size': node.bytes?.length ?? 0,
    'lastModifiedDateTime': node.updatedAt.toIso8601String(),
    'eTag': '"{${node.id}},${node.version}"',
    'cTag': '"c:{${node.id}},${node.version}"',
    if (node.isFolder)
      'folder': {'childCount': tree.childrenOf(node.id).length}
    else
      'file': {'mimeType': 'application/octet-stream'},
    if (!node.isFolder &&
        (select?.contains('@microsoft.graph.downloadUrl') ?? false))
      '@microsoft.graph.downloadUrl': 'https://$downloadHost/${node.id}',
  };
}

class _Session {
  _Session(this.baseId, this.path, this.behavior);

  final String baseId;
  final List<String> path;
  final String behavior;
  final received = <int>[];
}
