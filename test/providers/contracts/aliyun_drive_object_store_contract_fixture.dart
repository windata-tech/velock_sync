import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/providers/aliyun_drive/aliyun_drive_object_store.dart';
import 'package:velock_sync/providers/oauth/oauth_access_token_provider.dart';
import 'package:velock_sync/providers/provider_rate_limit_retry.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';

import 'stateful_object_store_contract.dart';

StatefulObjectStoreContractFixture aliyunDriveContractFixture([
  AliyunContractCloud? cloud,
]) => StatefulObjectStoreContractFixture(
  providerName: 'aliyun_drive',
  cloud: cloud ?? AliyunContractCloud(),
);

class _AliyunFile {
  _AliyunFile({required this.id, required this.name, required this.bytes})
    : updatedAt = DateTime.utc(2030, 1, 1, 12);

  final String id;
  final String name;
  final List<int> bytes;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => {
    'drive_id': AliyunContractCloud.driveId,
    'file_id': id,
    'parent_file_id': AliyunContractCloud.folderId,
    'type': 'file',
    'name': name,
    'size': bytes.length,
    'updated_at': updatedAt.toIso8601String(),
    'content_hash': sha1.convert(bytes).toString().toUpperCase(),
  };
}

class _AliyunUpload {
  _AliyunUpload({
    required this.fileId,
    required this.name,
    required this.parts,
  });

  final String fileId;
  final String name;
  final int parts;
  final received = <int, List<int>>{};
}

/// Aliyun Drive open platform (openapi.alipan.com) with one chosen folder,
/// `/apps/Velock 备份`, so the adapter must walk up parents to find its path.
class AliyunContractCloud extends ContractCloud {
  static const driveId = 'drive-1';
  static const folderId = 'folder-1';
  static const apiHost = 'openapi.alipan.com';
  static const uploadHost = 'upload.example.test';
  static const downloadHost = 'download.example.test';
  static const folderPath = '/apps/Velock 备份';

  static const _folders = {
    folderId: {'name': 'Velock 备份', 'parent': 'folder-0'},
    'folder-0': {'name': 'apps', 'parent': 'root'},
  };

  /// Files in the chosen folder by name, in creation order. Duplicate names
  /// can exist on Aliyun; [_duplicates] lists names shown twice.
  final _files = <String, _AliyunFile>{};
  final _duplicates = <String>{};
  final _uploads = <String, _AliyunUpload>{};
  int _nextId = 0;

  /// Upload URLs issued before this generation answer 403, as expired
  /// pre-signed URLs do.
  int urlGeneration = 0;
  int expiredUrlGeneration = -1;

  @override
  int get partBytes => 8 * 1024 * 1024;

  @override
  String get createOperation => 'openFile/create';

  @override
  void reset() {
    super.reset();
    _files.clear();
    _duplicates.clear();
    _uploads.clear();
    urlGeneration = 0;
    expiredUrlGeneration = -1;
  }

  static String nameFor(String key) =>
      'velock-${base64UrlEncode(utf8.encode(key)).replaceAll('=', '')}';

  @override
  void seed(String key, List<int> bytes, {bool duplicateListing = false}) {
    final name = nameFor(key);
    _files[name] = _AliyunFile(
      id: 'file-${_nextId++}',
      name: name,
      bytes: bytes,
    );
    if (duplicateListing) _duplicates.add(name);
  }

  @override
  List<int>? bytesOf(String key) => _files[nameFor(key)]?.bytes;

  /// Upload sessions that were started but never completed.
  int get openUploads => _uploads.length;

  @override
  Future<RemoteObjectStore> createStore({
    required OAuthAccessTokenProvider tokens,
    required Dio dio,
    required ProviderRateLimitRetry retry,
  }) async => AliyunDriveObjectStore(
    accessTokenProvider: tokens,
    rootId: '$driveId:$folderId',
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

  // Pre-signed storage URLs carry their own signature.
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

  @override
  Future<ResponseBody> handle(CloudRequest request) async {
    return switch (request.kind) {
      CloudRequestKind.uploadPart => _receivePart(request),
      CloudRequestKind.download => _download(request),
      CloudRequestKind.api => _api(request),
    };
  }

  ResponseBody _api(CloudRequest request) {
    final body = request.body.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(utf8.decode(request.body)) as Map<String, dynamic>;
    if (body.containsKey('drive_id') && body['drive_id'] != driveId) {
      return _notFound();
    }
    switch (request.operation) {
      case 'user/getDriveInfo':
        return jsonBody({'default_drive_id': driveId});
      case 'openFile/get':
        final folder = _folders[body['file_id']];
        if (folder == null) return _notFound();
        return jsonBody({
          'type': 'folder',
          'file_id': body['file_id'],
          'name': folder['name'],
          'parent_file_id': folder['parent'],
        });
      case 'openFile/get_by_path':
        final path = body['file_path'] as String;
        if (!path.startsWith('$folderPath/')) return _notFound();
        final file = _files[path.substring(folderPath.length + 1)];
        return file == null ? _notFound() : jsonBody(file.toJson());
      case 'openFile/list':
        return _list(body);
      case 'openFile/create':
        return _create(body);
      case 'openFile/getUploadUrl':
        final upload = _uploads[body['upload_id']];
        if (upload == null) return _notFound();
        urlGeneration++;
        return jsonBody({
          'part_info_list': _partUrls(body['upload_id'], upload),
        });
      case 'openFile/complete':
        return _complete(body);
      case 'openFile/getDownloadUrl':
        final file = _byId(body['file_id']);
        if (file == null) return _notFound();
        return jsonBody({'url': 'https://$downloadHost/${file.id}?sig=x'});
      case 'openFile/delete':
        final file = _byId(body['file_id']);
        if (file == null) return _notFound();
        _files.remove(file.name);
        return jsonBody({'file_id': file.id});
    }
    return jsonBody({'code': 'NotSupported'}, status: 400);
  }

  _AliyunFile? _byId(Object? id) {
    for (final file in _files.values) {
      if (file.id == id) return file;
    }
    return null;
  }

  ResponseBody _list(Map<String, dynamic> body) {
    if (body['parent_file_id'] != folderId) return jsonBody({'items': []});
    final names = _files.keys.toList()..sort();
    final entries = [
      for (final name in names) ...[
        _files[name]!.toJson(),
        if (_duplicates.contains(name)) _files[name]!.toJson(),
      ],
    ];
    final start = int.parse('${body['marker'] ?? '0'}');
    final limit = body['limit'] as int;
    final end = (start + limit).clamp(0, entries.length);
    return jsonBody({
      'items': entries.sublist(start, end),
      'next_marker': end < entries.length ? '$end' : '',
    });
  }

  ResponseBody _create(Map<String, dynamic> body) {
    expect(body['check_name_mode'], 'refuse');
    final name = body['name'] as String;
    final existing = _files[name];
    if (existing != null) {
      return jsonBody({...existing.toJson(), 'exist': true});
    }
    final uploadId = 'upload-${_nextId++}';
    final upload = _uploads[uploadId] = _AliyunUpload(
      fileId: 'file-${_nextId++}',
      name: name,
      parts: (body['part_info_list'] as List).length,
    );
    return jsonBody({
      'file_id': upload.fileId,
      'upload_id': uploadId,
      'part_info_list': _partUrls(uploadId, upload),
    });
  }

  List<Map<String, Object?>> _partUrls(
    Object? uploadId,
    _AliyunUpload upload,
  ) => [
    for (var part = 1; part <= upload.parts; part++)
      {
        'part_number': part,
        'upload_url': 'https://$uploadHost/$uploadId/$part?gen=$urlGeneration',
      },
  ];

  ResponseBody _receivePart(CloudRequest request) {
    expect(
      request.options.headers.keys.map((k) => k.toLowerCase()),
      isNot(contains('authorization')),
      reason: 'the bearer token must never reach the storage host',
    );
    final segments = request.options.uri.pathSegments;
    final upload = _uploads[segments[0]];
    if (upload == null) return ResponseBody.fromString('', 404);
    final generation = int.parse(request.options.uri.queryParameters['gen']!);
    if (generation <= expiredUrlGeneration) {
      return ResponseBody.fromString('<Error>AccessDenied</Error>', 403);
    }
    final part = int.parse(segments[1]);
    if (upload.received.containsKey(part)) {
      return ResponseBody.fromString('PartAlreadyExist', 409);
    }
    upload.received[part] = request.body;
    return ResponseBody.fromString('', 200);
  }

  ResponseBody _complete(Map<String, dynamic> body) {
    final upload = _uploads.remove(body['upload_id']);
    if (upload == null) return _notFound();
    final parts = [for (var p = 1; p <= upload.parts; p++) upload.received[p]];
    if (parts.any((part) => part == null)) {
      return jsonBody({'code': 'PartNotSequential'}, status: 400);
    }
    if (_files.containsKey(upload.name)) {
      // `refuse` was checked when the session started; a racing writer
      // would make Aliyun store this upload under a new name.
      final renamed = '${upload.name}(1)';
      final file = _files[renamed] = _AliyunFile(
        id: upload.fileId,
        name: renamed,
        bytes: [for (final part in parts) ...part!],
      );
      return jsonBody(file.toJson());
    }
    committedUploads.add([for (final part in parts) part!.length]);
    final file = _files[upload.name] = _AliyunFile(
      id: upload.fileId,
      name: upload.name,
      bytes: Uint8List.fromList([for (final part in parts) ...part!]),
    );
    return jsonBody(file.toJson());
  }

  ResponseBody _download(CloudRequest request) {
    expect(
      request.options.headers.keys.map((k) => k.toLowerCase()),
      isNot(contains('authorization')),
      reason: 'the bearer token must never reach the storage host',
    );
    final file = _byId(request.options.uri.pathSegments.single);
    if (file == null) return ResponseBody.fromString('', 404);
    return rangedBody(request.options, file.bytes);
  }

  /// Lets a test add a same-named file between the adapter's check and its
  /// upload completing.
  void racingWrite(String key, List<int> bytes) => seed(key, bytes);
}
