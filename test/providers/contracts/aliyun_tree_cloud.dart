import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/providers/aliyun_drive/aliyun_drive_object_store.dart';
import 'package:velock_sync/providers/oauth/oauth_access_token_provider.dart';
import 'package:velock_sync/providers/provider_rate_limit_retry.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';

import 'cloud_tree.dart';
import 'stateful_object_store_contract.dart';

/// Aliyun Drive's open platform as a real folder tree: `get_by_path`, listing
/// by parent ID, `check_name_mode: refuse` on create and rename, part uploads
/// to pre-signed URLs, and the recycle bin.
///
/// The connection is rooted at `/同步盘` (a picked folder) unless
/// [useDriveRoot] is called.
class AliyunTreeCloud extends ContractCloud {
  static const driveId = 'drive-1';
  static const apiHost = 'openapi.alipan.com';
  static const uploadHost = 'upload.example.test';
  static const downloadHost = 'download.example.test';

  final tree = CloudTree(rootId: 'root');
  late String connectionRootId;
  final _uploads = <String, _Upload>{};
  int _nextUpload = 0;

  /// Fails the part upload of any file whose name starts with this, as a
  /// dropped connection would.
  String? failUploadsNamed;

  AliyunTreeCloud() {
    _pickFolderRoot();
  }

  void _pickFolderRoot() {
    connectionRootId = tree.ensureFolders(['同步盘']).id;
  }

  void useDriveRoot() => connectionRootId = 'root';

  String get rootIdForStore =>
      connectionRootId == 'root' ? 'root' : '$driveId:$connectionRootId';

  @override
  int get partBytes => 8 * 1024 * 1024;

  @override
  String get createOperation => 'openFile/create';

  @override
  void reset() {
    super.reset();
    tree.clear();
    _uploads.clear();
    failUploadsNamed = null;
    _pickFolderRoot();
  }

  @override
  void seed(String key, List<int> bytes, {bool duplicateListing = false}) =>
      tree.writeFile(key, bytes, fromId: connectionRootId);

  void addFolder(String path) =>
      tree.ensureFolders(path.split('/'), fromId: connectionRootId);

  @override
  List<int>? bytesOf(String key) =>
      tree.resolve(key.split('/'), fromId: connectionRootId)?.bytes;

  bool isFolder(String path) =>
      tree.resolve(path.split('/'), fromId: connectionRootId)?.isFolder ??
      false;

  /// Names directly inside [path] (the connection root when empty).
  List<String> namesIn([String path = '']) => [
    for (final node in tree.childrenOf(
      (path.isEmpty
              ? tree.byId(connectionRootId)
              : tree.resolve(path.split('/'), fromId: connectionRootId))!
          .id,
    ))
      node.name,
  ];

  @override
  Future<RemoteObjectStore> createStore({
    required OAuthAccessTokenProvider tokens,
    required Dio dio,
    required ProviderRateLimitRetry retry,
  }) async => AliyunDriveObjectStore(
    accessTokenProvider: tokens,
    rootId: rootIdForStore,
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
      kind == CloudRequestKind.api
      ? options.uri.path.replaceFirst('/adrive/v1.0/', '')
      : kind.name;

  @override
  String? tokenOf(CloudRequest request) {
    final header = '${request.options.headers['Authorization'] ?? ''}';
    return header.startsWith('Bearer ') ? header.substring(7) : null;
  }

  @override
  bool requiresToken(CloudRequestKind kind) => kind == CloudRequestKind.api;

  @override
  ResponseBody unauthorised(CloudRequest request) =>
      jsonBody({'code': 'AccessTokenInvalid'}, status: 401);

  @override
  ResponseBody rateLimited() =>
      jsonBody({'code': 'TooManyRequests'}, status: 429);

  @override
  ResponseBody quotaExceeded() =>
      jsonBody({'code': 'QuotaExhausted.Drive'}, status: 400);

  ResponseBody _notFound() =>
      jsonBody({'code': 'NotFound.File', 'message': 'not found'}, status: 404);

  /// The calls the adapter made, in order (`openFile/list`, ...).
  List<String> get operations => [
    for (final request in requests)
      if (request.kind == CloudRequestKind.api) request.operation,
  ];

  @override
  Future<ResponseBody> handle(CloudRequest request) async {
    switch (request.kind) {
      case CloudRequestKind.uploadPart:
        _expectNoToken(request);
        final upload = _uploads[request.options.uri.pathSegments.first];
        if (upload == null) return ResponseBody.fromString('', 404);
        final failing = failUploadsNamed;
        if (failing != null && upload.name.startsWith(failing)) {
          return ResponseBody.fromString('broken', 500);
        }
        upload.received.addAll(request.body);
        return ResponseBody.fromString('', 200);
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
    final body = request.body.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(utf8.decode(request.body)) as Map<String, dynamic>;
    if (body.containsKey('drive_id') && body['drive_id'] != driveId) {
      return _notFound();
    }
    CloudTreeNode? byId(String key) {
      final id = body[key];
      return id is String ? tree.byId(id) : null;
    }

    switch (request.operation) {
      case 'user/getDriveInfo':
        return jsonBody({'default_drive_id': driveId});
      case 'openFile/get':
        final node = byId('file_id');
        return node == null ? _notFound() : jsonBody(_json(node));
      case 'openFile/get_by_path':
        final path = body['file_path'] as String;
        expect(path, startsWith('/'));
        final node = tree.resolve(path.substring(1).split('/'));
        return node == null ? _notFound() : jsonBody(_json(node));
      case 'openFile/list':
        final parent = byId('parent_file_id');
        if (parent == null || !parent.isFolder) return _notFound();
        final limit = body['limit'] as int;
        expect(limit, lessThanOrEqualTo(100));
        final children = [
          for (final node in tree.childrenOf(parent.id))
            if (body['type'] == null ||
                body['type'] == (node.isFolder ? 'folder' : 'file'))
              node,
        ];
        final start = int.parse('${body['marker'] ?? '0'}');
        final end = (start + limit).clamp(0, children.length);
        return jsonBody({
          'items': [
            for (final node in children.sublist(start, end)) _json(node),
          ],
          'next_marker': end < children.length ? '$end' : '',
        });
      case 'openFile/create':
        expect(body['check_name_mode'], 'refuse');
        final parent = byId('parent_file_id');
        if (parent == null || !parent.isFolder) return _notFound();
        final name = body['name'] as String;
        final existing = tree.child(parent.id, name);
        if (existing != null) {
          return jsonBody({..._json(existing), 'exist': true});
        }
        if (body['type'] == 'folder') {
          final folder = tree.add(parent.id, name);
          return jsonBody({
            'drive_id': driveId,
            'file_id': folder.id,
            'parent_file_id': parent.id,
            'file_name': name,
            'type': 'folder',
          });
        }
        final uploadId = 'upload-${_nextUpload++}';
        _uploads[uploadId] = _Upload(parent.id, name);
        return jsonBody({
          'file_id': 'pending-$uploadId',
          'upload_id': uploadId,
          'part_info_list': [
            for (final part in body['part_info_list'] as List)
              {
                'part_number': (part as Map)['part_number'],
                'upload_url':
                    'https://$uploadHost/$uploadId/${part['part_number']}',
              },
          ],
        });
      case 'openFile/complete':
        final upload = _uploads.remove(body['upload_id']);
        if (upload == null) return _notFound();
        var name = upload.name;
        if (tree.child(upload.parentId, name) != null) name = '$name(1)';
        committedUploads.add([upload.received.length]);
        final node = tree.add(upload.parentId, name, bytes: upload.received);
        return jsonBody(_json(node));
      case 'openFile/update':
        expect(body['check_name_mode'], 'refuse');
        final node = byId('file_id');
        if (node == null) return _notFound();
        final name = body['name'] as String;
        final clash = tree.child(node.parentId!, name);
        if (clash != null && clash.id != node.id) {
          return jsonBody({'code': 'AlreadyExist.File'}, status: 409);
        }
        node.name = name;
        return jsonBody(_json(node));
      case 'openFile/recyclebin/trash':
        final node = byId('file_id');
        if (node == null) return _notFound();
        tree.remove(node, toRecycleBin: true);
        return jsonBody({'drive_id': driveId, 'file_id': node.id});
      case 'openFile/delete':
        final node = byId('file_id');
        if (node == null) return _notFound();
        tree.remove(node, toRecycleBin: false);
        return jsonBody({'drive_id': driveId, 'file_id': node.id});
      case 'openFile/getDownloadUrl':
        final node = byId('file_id');
        if (node == null) return _notFound();
        return jsonBody({'url': 'https://$downloadHost/${node.id}'});
    }
    return jsonBody({'code': 'NotSupported'}, status: 400);
  }

  Map<String, Object?> _json(CloudTreeNode node) => {
    'drive_id': driveId,
    'file_id': node.id,
    'parent_file_id': node.parentId ?? 'root',
    'name': node.name,
    'type': node.isFolder ? 'folder' : 'file',
    if (!node.isFolder) 'size': node.bytes!.length,
    'updated_at': node.updatedAt.toIso8601String(),
    if (!node.isFolder)
      'content_hash': sha1.convert(node.bytes!).toString().toUpperCase(),
  };
}

class _Upload {
  _Upload(this.parentId, this.name);

  final String parentId;
  final String name;
  final received = <int>[];
}
