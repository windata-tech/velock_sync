import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/providers/google_drive/google_drive_object_store.dart';
import 'package:velock_sync/providers/oauth/oauth_access_token_provider.dart';
import 'package:velock_sync/providers/provider_rate_limit_retry.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';

import 'cloud_tree.dart';
import 'stateful_object_store_contract.dart';

/// Google Drive v3 as a real folder tree: items addressed only by ID, names
/// that need not be unique in a folder, `q` searches by parent and name,
/// resumable uploads (POST to create, PATCH to replace), Google Docs with no
/// content, and the trash.
///
/// [connectionRootId] is `root` (My Drive) or a folder picked when the
/// connection was added ([useFolderRoot]).
class GoogleTreeCloud extends ContractCloud {
  static const host = 'www.googleapis.com';
  static const folderType = 'application/vnd.google-apps.folder';
  static const docType = 'application/vnd.google-apps.document';

  final tree = CloudTree(rootId: 'my-drive');
  String connectionRootId = 'root';
  final _sessions = <String, _Session>{};
  int _nextSession = 0;

  /// Searches the adapter ran, as `(parent ID, name or null)`.
  final searches = <(String, String?)>[];

  @override
  int get partBytes => 8 * 256 * 1024;

  @override
  String get createOperation => 'POST /upload/drive/v3/files';

  @override
  void reset() {
    super.reset();
    tree.clear();
    _sessions.clear();
    searches.clear();
    connectionRootId = 'root';
  }

  CloudTreeNode useFolderRoot(String name) {
    final folder = tree.ensureFolders([name]);
    connectionRootId = folder.id;
    return folder;
  }

  String get _rootNodeId =>
      connectionRootId == 'root' ? tree.rootId : connectionRootId;

  String _nodeId(String id) => id == 'root' ? tree.rootId : id;

  @override
  void seed(String key, List<int> bytes, {bool duplicateListing = false}) =>
      tree.writeFile(key, bytes, fromId: _rootNodeId);

  void addFolder(String path) =>
      tree.ensureFolders(path.split('/'), fromId: _rootNodeId);

  /// Adds another item called like the last part of [path], next to any
  /// that already exists: Drive allows that.
  CloudTreeNode addDuplicate(String path, {List<int>? bytes, String? type}) {
    final segments = path.split('/');
    final parent = tree.ensureFolders(
      segments.sublist(0, segments.length - 1),
      fromId: _rootNodeId,
    );
    return tree.add(parent.id, segments.last, bytes: bytes)..mimeType = type;
  }

  /// A Google Doc: listed by Drive, but with no downloadable content.
  CloudTreeNode addDoc(String path) =>
      addDuplicate(path, bytes: const [], type: docType);

  CloudTreeNode? nodeAt(String path) =>
      tree.resolve(path.split('/'), fromId: _rootNodeId);

  @override
  List<int>? bytesOf(String key) => nodeAt(key)?.bytes;

  bool isFolder(String path) => nodeAt(path)?.isFolder ?? false;

  List<String> namesIn([String path = '']) => [
    for (final node in tree.childrenOf(
      (path.isEmpty ? tree.byId(_rootNodeId) : nodeAt(path))!.id,
    ))
      node.name,
  ];

  @override
  Future<RemoteObjectStore> createStore({
    required OAuthAccessTokenProvider tokens,
    required Dio dio,
    required ProviderRateLimitRetry retry,
  }) async => GoogleDriveObjectStore(
    accessTokenProvider: tokens,
    parentId: connectionRootId,
    dio: dio,
    rateLimitRetry: retry,
  );

  @override
  CloudRequestKind kindOf(RequestOptions options) {
    if (options.uri.queryParameters.containsKey('upload_id')) {
      return CloudRequestKind.uploadPart;
    }
    if (options.uri.queryParameters['alt'] == 'media') {
      return CloudRequestKind.download;
    }
    return CloudRequestKind.api;
  }

  @override
  String operationOf(RequestOptions options, CloudRequestKind kind) =>
      '${options.method} ${options.uri.path}';

  @override
  String? tokenOf(CloudRequest request) {
    final header = '${request.options.headers['Authorization'] ?? ''}';
    return header.startsWith('Bearer ') ? header.substring(7) : null;
  }

  @override
  bool requiresToken(CloudRequestKind kind) => true;

  @override
  ResponseBody unauthorised(CloudRequest request) => _error(401, 'authError');

  @override
  ResponseBody rateLimited() => _error(429, 'rateLimitExceeded');

  @override
  ResponseBody quotaExceeded() => _error(403, 'storageQuotaExceeded');

  ResponseBody _error(int status, String reason) => jsonBody({
    'error': {
      'code': status,
      'errors': [
        {'reason': reason},
      ],
    },
  }, status: status);

  @override
  Future<ResponseBody> handle(CloudRequest request) async {
    final options = request.options;
    final uri = options.uri;
    expect(uri.host, host);
    switch (request.kind) {
      case CloudRequestKind.uploadPart:
        return _receiveChunk(request);
      case CloudRequestKind.download:
        final node = tree.byId(uri.pathSegments.last);
        if (node == null || node.isFolder || node.mimeType != null) {
          return _error(404, 'notFound');
        }
        return rangedBody(options, node.bytes!);
      case CloudRequestKind.api:
        break;
    }
    final segments = uri.pathSegments;
    final upload = segments.first == 'upload';
    final rest = segments.skip(upload ? 4 : 3).toList();
    expect(segments.take(upload ? 4 : 3), [
      if (upload) 'upload',
      'drive',
      'v3',
      'files',
    ]);
    final body = request.body.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(utf8.decode(request.body)) as Map<String, dynamic>;
    switch ((options.method, upload, rest.length)) {
      case ('GET', false, 0):
        return _search(uri);
      case ('GET', false, 1):
        final node = tree.byId(_nodeId(rest.single));
        return node == null ? _error(404, 'notFound') : jsonBody(_json(node));
      case ('POST', false, 0):
        expect(body['mimeType'], folderType);
        final parent = tree.byId(_nodeId((body['parents'] as List).single));
        if (parent == null || !parent.isFolder) return _error(404, 'notFound');
        // Drive happily makes a second folder of the same name.
        return jsonBody(_json(tree.add(parent.id, body['name'] as String)));
      case ('PATCH', false, 1):
        final node = tree.byId(rest.single);
        if (node == null) return _error(404, 'notFound');
        expect(body, {'trashed': true});
        tree.remove(node, toRecycleBin: true);
        return jsonBody({'id': node.id});
      case ('POST', true, 0):
        expect(uri.queryParameters['uploadType'], 'resumable');
        final parentId = _nodeId((body['parents'] as List).single as String);
        if (tree.byId(parentId)?.isFolder != true) {
          return _error(404, 'notFound');
        }
        return _openSession(_Session.create(parentId, body['name'] as String));
      case ('PATCH', true, 1):
        expect(uri.queryParameters['uploadType'], 'resumable');
        final node = tree.byId(rest.single);
        if (node == null || node.isFolder) return _error(404, 'notFound');
        return _openSession(_Session.replace(node.id));
    }
    return _error(400, 'badRequest');
  }

  static final _query = RegExp(
    r"^'((?:[^'\\]|\\.)*)' in parents(?: and name = '((?:[^'\\]|\\.)*)')? and trashed = false$",
  );

  static String _unescape(String value) =>
      value.replaceAllMapped(RegExp(r'\\(.)'), (m) => m.group(1)!);

  ResponseBody _search(Uri uri) {
    expect(uri.queryParameters['spaces'], 'drive');
    final match = _query.firstMatch(uri.queryParameters['q']!);
    expect(
      match,
      isNotNull,
      reason: 'unexpected q: ${uri.queryParameters['q']}',
    );
    final parentId = _nodeId(_unescape(match!.group(1)!));
    final name = match.group(2) == null ? null : _unescape(match.group(2)!);
    searches.add((parentId, name));
    // A deleted parent simply has no children.
    final children = [
      for (final node in tree.all)
        if (node.parentId == parentId && (name == null || node.name == name))
          node,
    ]..sort((a, b) => a.name.compareTo(b.name));
    final size = int.parse(uri.queryParameters['pageSize'] ?? '100');
    final start = int.parse(uri.queryParameters['pageToken'] ?? '0');
    final end = (start + size).clamp(0, children.length);
    return jsonBody({
      'files': [for (final node in children.sublist(start, end)) _json(node)],
      if (end < children.length) 'nextPageToken': '$end',
    });
  }

  ResponseBody _openSession(_Session session) {
    final id = 'session-${_nextSession++}';
    _sessions[id] = session;
    return ResponseBody.fromString(
      '',
      200,
      headers: {
        'location': [
          'https://$host/upload/drive/v3/files?uploadType=resumable&upload_id=$id',
        ],
      },
    );
  }

  ResponseBody _receiveChunk(CloudRequest request) {
    expect(request.options.method, 'PUT');
    final id = request.options.uri.queryParameters['upload_id']!;
    final session = _sessions[id];
    if (session == null) return _error(404, 'notFound');
    final range = '${request.options.headers['Content-Range'] ?? ''}';
    var total = 0;
    if (range.isNotEmpty) {
      final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(range)!;
      expect(int.parse(match.group(1)!), session.received.length);
      total = int.parse(match.group(3)!);
    }
    session.received.addAll(request.body);
    if (session.received.length < total) {
      return ResponseBody.fromString('', 308);
    }
    _sessions.remove(id);
    committedUploads.add([session.received.length]);
    final CloudTreeNode node;
    if (session.fileId != null) {
      node = tree.byId(session.fileId!)!
        ..bytes = session.received
        ..version += 1;
    } else {
      node = tree.add(
        session.parentId!,
        session.name!,
        bytes: session.received,
      );
    }
    return jsonBody(_json(node));
  }

  Map<String, Object?> _json(CloudTreeNode node) => {
    'id': node.id == tree.rootId ? 'root' : node.id,
    'name': node.name,
    'mimeType': node.isFolder
        ? folderType
        : node.mimeType ?? 'application/octet-stream',
    if (!node.isFolder && node.mimeType == null) ...{
      'size': '${node.bytes!.length}',
      'md5Checksum': md5.convert(node.bytes!).toString(),
    },
    'version': '${node.version}',
    'modifiedTime': node.updatedAt.toIso8601String(),
    'trashed': false,
  };
}

class _Session {
  _Session.create(String this.parentId, String this.name) : fileId = null;
  _Session.replace(String this.fileId) : parentId = null, name = null;

  final String? parentId;
  final String? name;
  final String? fileId;
  final received = <int>[];
}
