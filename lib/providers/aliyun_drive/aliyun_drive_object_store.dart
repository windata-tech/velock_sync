import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:velock_sync/providers/oauth/oauth_access_token_provider.dart';
import 'package:velock_sync/providers/provider_cancellation.dart';
import 'package:velock_sync/providers/provider_rate_limit_retry.dart';
import 'package:velock_sync/providers/provider_request_exception.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// Where an Aliyun Drive folder lives: the drive and the folder's file ID.
///
/// Persisted as `driveId:fileId`; the bare value `root` means "the root of
/// the account's default drive", resolved on first use.
class AliyunDriveFolderRef {
  const AliyunDriveFolderRef({required this.driveId, required this.fileId});

  final String driveId;
  final String fileId;

  static AliyunDriveFolderRef? tryParse(String value) {
    final at = value.indexOf(':');
    if (at <= 0 || at == value.length - 1) return null;
    return AliyunDriveFolderRef(
      driveId: value.substring(0, at),
      fileId: value.substring(at + 1),
    );
  }

  String encode() => '$driveId:$fileId';
}

/// Aliyun Drive open platform (openapi.alipan.com) object storage.
///
/// Like Google Drive, objects are flat files beneath one folder, named with a
/// reversible encoding of the logical key. Aliyun allows duplicate names, so
/// every create uses `check_name_mode: refuse` and never `ignore`.
class AliyunDriveObjectStore implements RemoteObjectStore {
  AliyunDriveObjectStore({
    required OAuthAccessTokenProvider accessTokenProvider,
    required this.rootId,
    Dio? dio,
    ProviderRateLimitRetry? rateLimitRetry,
  }) : _accessTokenProvider = accessTokenProvider,
       _dio = dio ?? Dio(),
       _rateLimitRetry = rateLimitRetry ?? ProviderRateLimitRetry();

  static const _host = 'openapi.alipan.com';
  static const _partBytes = 8 * 1024 * 1024;
  static const _pageSize = 100;

  final OAuthAccessTokenProvider _accessTokenProvider;
  final Dio _dio;
  final ProviderRateLimitRetry _rateLimitRetry;

  /// `root` or an encoded [AliyunDriveFolderRef].
  final String rootId;

  Future<({AliyunDriveFolderRef folder, String path})>? _root;

  @override
  final RemoteCapabilities capabilities = const RemoteCapabilities(
    supportsConditionalCreate: false,
    supportsConditionalUpdate: false,
    supportsRangeDownload: true,
    supportsResumableUpload: false,
    supportsServerHash: true,
    supportsTrash: false,
    supportsHiddenAppFolder: false,
    hasStrongListConsistency: false,
    recommendedChunkBytes: _partBytes,
  );

  @override
  Future<RemoteObjectMetadata?> stat(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    _validateKey(logicalKey);
    final file = await _find(logicalKey, cancellation: cancellation);
    return file == null ? null : _metadata(logicalKey, file);
  }

  @override
  Future<RemoteObjectPage> list({
    String prefix = '',
    String? cursor,
    int limit = 100,
    RemoteOperationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    if (limit < 1 || limit > 1000) throw ArgumentError.value(limit, 'limit');
    final root = await _resolveRoot(cancellation);
    final data = await _call('openFile/list', {
      'drive_id': root.folder.driveId,
      'parent_file_id': root.folder.fileId,
      'limit': limit > _pageSize ? _pageSize : limit,
      'marker': ?cursor,
      'type': 'file',
      'order_by': 'name',
      'order_direction': 'ASC',
    }, cancellation: cancellation);
    final itemsByKey = <String, RemoteObjectMetadata>{};
    for (final item in _items(data['items'])) {
      if (item['type'] != 'file') continue;
      final name = item['name'];
      if (name is! String) continue;
      final key = _keyFromName(name);
      if (key == null || !key.startsWith(prefix)) continue;
      itemsByKey.putIfAbsent(key, () => _metadata(key, item));
    }
    final items = itemsByKey.values.toList()
      ..sort((a, b) => a.logicalKey.compareTo(b.logicalKey));
    final next = data['next_marker'];
    return RemoteObjectPage(
      items: items,
      nextCursor: next is String && next.isNotEmpty ? next : null,
    );
  }

  @override
  Stream<List<int>> read(
    String logicalKey, {
    int? start,
    int? endInclusive,
    RemoteOperationCancellation? cancellation,
  }) async* {
    cancellation?.throwIfCancelled();
    _validateKey(logicalKey);
    final file = await _find(logicalKey, cancellation: cancellation);
    if (file == null) throw RemoteObjectNotFoundException(logicalKey);
    final link = await _call(
      'openFile/getDownloadUrl',
      {'drive_id': file['drive_id'], 'file_id': file['file_id']},
      acceptNotFound: true,
      cancellation: cancellation,
    );
    final url = link['url'];
    if (url is! String || url.isEmpty) {
      throw RemoteObjectNotFoundException(logicalKey);
    }
    // The download URL is pre-signed; sending the bearer token to the storage
    // host would leak it outside the API domain.
    final response = await _send<ResponseBody>(
      () => _dio.getUri<ResponseBody>(
        Uri.parse(url),
        options: Options(
          responseType: ResponseType.stream,
          validateStatus: (status) => status != null && status < 600,
          headers: {
            if (start != null || endInclusive != null)
              'Range': 'bytes=${start ?? 0}-${endInclusive ?? ''}',
          },
        ),
        cancelToken: dioCancelTokenFor(cancellation),
      ),
      cancellation: cancellation,
    );
    final status = response.statusCode ?? 500;
    if (status == 404) throw RemoteObjectNotFoundException(logicalKey);
    if (status != 200 && status != 206) {
      await response.data?.stream.drain<void>();
      throw ProviderRequestException.fromStatus(status);
    }
    yield* response.data!.stream;
  }

  @override
  Future<RemoteObjectMetadata> put(
    String logicalKey,
    Stream<List<int>> content, {
    required int contentLength,
    bool ifAbsent = false,
    RemoteOperationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    _validateKey(logicalKey);
    if (contentLength < 0) {
      throw ArgumentError.value(contentLength, 'contentLength');
    }
    final existing = await _find(logicalKey, cancellation: cancellation);
    if (existing != null) {
      if (ifAbsent) throw RemoteObjectAlreadyExistsException(logicalKey);
      await _deleteFile(existing, cancellation: cancellation);
    }
    final root = await _resolveRoot(cancellation);
    final partCount = contentLength == 0
        ? 1
        : (contentLength + _partBytes - 1) ~/ _partBytes;
    final created = await _call(
      'openFile/create',
      {
        'drive_id': root.folder.driveId,
        'parent_file_id': root.folder.fileId,
        'name': _name(logicalKey),
        'type': 'file',
        'check_name_mode': 'refuse',
        'size': contentLength,
        'part_info_list': [
          for (var part = 1; part <= partCount; part++) {'part_number': part},
        ],
      },
      acceptConflict: true,
      cancellation: cancellation,
    );
    if (created['exist'] == true || created['_status'] == 409) {
      throw RemoteObjectAlreadyExistsException(logicalKey);
    }
    final fileId = created['file_id'];
    final uploadId = created['upload_id'];
    if (fileId is! String || uploadId is! String) {
      throw const AliyunDriveException('Missing upload session.');
    }
    var urls = _uploadUrls(created['part_info_list']);
    var offset = 0;
    var part = 1;
    Future<void> send(Uint8List chunk) async {
      if (part > partCount) {
        throw ArgumentError.value(
          content,
          'content',
          'exceeds declared length',
        );
      }
      var url = urls[part];
      for (var attempt = 0; ; attempt++) {
        if (url == null) {
          throw const AliyunDriveException('Missing upload URL.');
        }
        final target = url;
        final response = await _send<Object?>(
          () => _dio.putUri<Object?>(
            Uri.parse(target),
            data: Stream<List<int>>.value(chunk),
            options: Options(
              // The pre-signed URL is signed without a content type; the
              // bearer token is never sent to the storage host.
              headers: {Headers.contentLengthHeader: '${chunk.length}'},
              validateStatus: (status) => status != null && status < 600,
            ),
            cancelToken: dioCancelTokenFor(cancellation),
          ),
          retryServerErrors: true,
          cancellation: cancellation,
        );
        final status = response.statusCode ?? 500;
        // 409 means this part already arrived during an earlier attempt.
        if ((status >= 200 && status < 300) || status == 409) break;
        if (status == 403 && attempt == 0) {
          // Upload URLs expire; ask for fresh ones and resend this part.
          final refreshed = await _call('openFile/getUploadUrl', {
            'drive_id': root.folder.driveId,
            'file_id': fileId,
            'upload_id': uploadId,
            'part_info_list': [
              for (var p = 1; p <= partCount; p++) {'part_number': p},
            ],
          }, cancellation: cancellation);
          urls = _uploadUrls(refreshed['part_info_list']);
          url = urls[part];
          continue;
        }
        throw ProviderRequestException.fromStatus(status);
      }
      offset += chunk.length;
      part++;
    }

    if (contentLength == 0) {
      await send(Uint8List(0));
    } else {
      await for (final chunk in _chunks(content)) {
        cancellation?.throwIfCancelled();
        if (offset + chunk.length > contentLength) {
          throw ArgumentError.value(
            content,
            'content',
            'exceeds declared length',
          );
        }
        await send(chunk);
      }
    }
    if (offset != contentLength) {
      throw const AliyunDriveException(
        'Upload ended before all bytes were sent.',
      );
    }
    final completed = await _call('openFile/complete', {
      'drive_id': root.folder.driveId,
      'file_id': fileId,
      'upload_id': uploadId,
    }, cancellation: cancellation);
    if (completed['name'] is String && completed['name'] != _name(logicalKey)) {
      throw const AliyunDriveException('Upload was stored under a new name.');
    }
    return _metadata(logicalKey, completed);
  }

  @override
  Future<void> delete(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    _validateKey(logicalKey);
    final file = await _find(logicalKey, cancellation: cancellation);
    if (file == null) return;
    await _deleteFile(file, cancellation: cancellation);
  }

  Future<void> _deleteFile(
    Map<String, dynamic> file, {
    RemoteOperationCancellation? cancellation,
  }) async {
    // Deleting a previously removed immutable object is a successful no-op.
    await _call(
      'openFile/delete',
      {'drive_id': file['drive_id'], 'file_id': file['file_id']},
      acceptNotFound: true,
      cancellation: cancellation,
    );
  }

  /// Lists the folders directly inside [parentId] (an encoded folder ref, or
  /// null for the default drive root) for the location picker. Returned IDs
  /// are encoded [AliyunDriveFolderRef]s.
  Future<({List<({String id, String name})> folders, String? nextCursor})>
  listChildFolders({String? parentId, String? cursor}) async {
    final parent = parentId == null || parentId == 'root'
        ? AliyunDriveFolderRef(
            driveId: await _defaultDriveId(null),
            fileId: 'root',
          )
        : AliyunDriveFolderRef.tryParse(parentId) ??
              (throw ArgumentError.value(parentId, 'parentId'));
    final data = await _call('openFile/list', {
      'drive_id': parent.driveId,
      'parent_file_id': parent.fileId,
      'limit': _pageSize,
      'marker': ?cursor,
      'type': 'folder',
      'order_by': 'name',
      'order_direction': 'ASC',
    }, retryServerErrors: true);
    final folders = <({String id, String name})>[];
    for (final item in _items(data['items'])) {
      final id = item['file_id'];
      final name = item['name'];
      if (item['type'] == 'folder' && id is String && name is String) {
        folders.add((
          id: AliyunDriveFolderRef(
            driveId: parent.driveId,
            fileId: id,
          ).encode(),
          name: name,
        ));
      }
    }
    final next = data['next_marker'];
    return (
      folders: folders,
      nextCursor: next is String && next.isNotEmpty ? next : null,
    );
  }

  Future<Map<String, dynamic>?> _find(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) async {
    final root = await _resolveRoot(cancellation);
    final data = await _call(
      'openFile/get_by_path',
      {
        'drive_id': root.folder.driveId,
        'file_path': '${root.path}/${_name(logicalKey)}',
      },
      acceptNotFound: true,
      cancellation: cancellation,
    );
    if (data['_status'] == 404 || data['type'] != 'file') return null;
    return data;
  }

  Future<({AliyunDriveFolderRef folder, String path})> _resolveRoot(
    RemoteOperationCancellation? cancellation,
  ) {
    final pending = _root ??= _loadRoot(cancellation);
    // A failed lookup must not be cached for the lifetime of the store.
    return pending.catchError((Object error) {
      _root = null;
      throw error;
    });
  }

  Future<({AliyunDriveFolderRef folder, String path})> _loadRoot(
    RemoteOperationCancellation? cancellation,
  ) async {
    if (rootId == 'root') {
      return (
        folder: AliyunDriveFolderRef(
          driveId: await _defaultDriveId(cancellation),
          fileId: 'root',
        ),
        path: '',
      );
    }
    final folder = AliyunDriveFolderRef.tryParse(rootId);
    if (folder == null) {
      throw ArgumentError.value(rootId, 'rootId', 'is not a folder reference');
    }
    // get_by_path needs the folder's path from the drive root, so walk up the
    // parents once and cache the result.
    final names = <String>[];
    var current = folder.fileId;
    for (var depth = 0; current != 'root'; depth++) {
      if (depth > 64) {
        throw const AliyunDriveException('Folder is nested too deeply.');
      }
      final data = await _call('openFile/get', {
        'drive_id': folder.driveId,
        'file_id': current,
      }, cancellation: cancellation);
      final name = data['name'];
      final parent = data['parent_file_id'];
      if (data['type'] != 'folder' || name is! String || parent is! String) {
        throw const AliyunDriveException('Chosen location is not a folder.');
      }
      names.insert(0, name);
      current = parent;
    }
    return (folder: folder, path: names.isEmpty ? '' : '/${names.join('/')}');
  }

  Future<String> _defaultDriveId(
    RemoteOperationCancellation? cancellation,
  ) async {
    final data = await _call(
      'user/getDriveInfo',
      const {},
      cancellation: cancellation,
    );
    final driveId = data['resource_drive_id'] ?? data['default_drive_id'];
    if (driveId is! String || driveId.isEmpty) {
      throw const AliyunDriveException('The account has no drive.');
    }
    return driveId;
  }

  /// POSTs one open-platform call with the bearer token, refreshing it once on
  /// 401. Accepted 404/409 responses come back with a `_status` marker.
  Future<Map<String, dynamic>> _call(
    String endpoint,
    Map<String, Object?> body, {
    bool acceptNotFound = false,
    bool acceptConflict = false,
    bool retryServerErrors = false,
    RemoteOperationCancellation? cancellation,
  }) async {
    final uri = Uri.https(_host, '/adrive/v1.0/$endpoint');
    final response = await _send<Object?>(
      () async {
        Future<Response<Object?>> post({bool forceRefresh = false}) async =>
            _classified(
              await _dio.postUri<Object?>(
                uri,
                data: jsonEncode(body),
                options: Options(
                  headers: await _accessTokenProvider.authorizationHeaders(
                    forceRefresh: forceRefresh,
                  ),
                  contentType: Headers.jsonContentType,
                  responseType: ResponseType.plain,
                  validateStatus: (status) => status != null && status < 600,
                ),
                cancelToken: dioCancelTokenFor(cancellation),
              ),
            );
        var response = await post();
        if (response.statusCode == 401) {
          response = await post(forceRefresh: true);
        }
        if (response.statusCode == 401) {
          throw ProviderRequestException.fromStatus(401);
        }
        return response;
      },
      retryServerErrors: retryServerErrors,
      cancellation: cancellation,
    );
    final status = response.statusCode ?? 500;
    final data = _decode(response.data);
    if (status >= 200 && status < 300) return data;
    if ((status == 404 && acceptNotFound) ||
        (status == 409 && acceptConflict)) {
      return {...data, '_status': status};
    }
    throw ProviderRequestException.fromStatus(
      status,
      retryAfter: _rateLimitRetry.retryAfter(
        response.headers.value('retry-after'),
      ),
    );
  }

  Future<Response<T>> _send<T>(
    Future<Response<T>> Function() request, {
    bool retryServerErrors = false,
    RemoteOperationCancellation? cancellation,
  }) async {
    try {
      return retryServerErrors
          ? await _rateLimitRetry.executeTransient(
              request,
              whenCancelled: cancellation?.whenCancelled,
            )
          : await _rateLimitRetry.execute(
              request,
              whenCancelled: cancellation?.whenCancelled,
            );
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel) {
        throw const RemoteOperationCancelledException();
      }
      final statusCode = error.response?.statusCode;
      if (statusCode != null) {
        throw ProviderRequestException.fromStatus(
          statusCode,
          retryAfter: _rateLimitRetry.retryAfter(
            error.response?.headers.value('retry-after'),
          ),
        );
      }
      rethrow;
    }
  }

  /// Maps error codes that Aliyun reports with a generic status onto the
  /// status the shared retry and error mapping understand.
  static Response<Object?> _classified(Response<Object?> response) {
    final status = response.statusCode ?? 500;
    if (status < 400) return response;
    final code = _decode(response.data)['code'];
    final mapped = switch (code) {
      String value when value.startsWith('QuotaExhausted') => 507,
      'TooManyRequests' => 429,
      'AccessTokenInvalid' || 'AccessTokenExpired' => 401,
      String value when value.startsWith('NotFound') => 404,
      _ => status,
    };
    if (mapped == status) return response;
    return Response<Object?>(
      requestOptions: response.requestOptions,
      statusCode: mapped,
      headers: response.headers,
      data: response.data,
    );
  }

  static Map<String, dynamic> _decode(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return data.cast<String, dynamic>();
    if (data is String && data.isNotEmpty) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map<String, dynamic>) return decoded;
      } on FormatException {
        return const {};
      }
    }
    return const {};
  }

  static Iterable<Map<String, dynamic>> _items(Object? value) =>
      value is List ? value.whereType<Map<String, dynamic>>() : const [];

  static Map<int, String> _uploadUrls(Object? value) => {
    for (final part in _items(value))
      if (part['part_number'] is int && part['upload_url'] is String)
        part['part_number'] as int: part['upload_url'] as String,
  };

  static String _name(String logicalKey) =>
      'velock-${base64UrlEncode(utf8.encode(logicalKey)).replaceAll('=', '')}';

  static String? _keyFromName(String name) {
    if (!name.startsWith('velock-')) return null;
    try {
      return utf8.decode(
        base64Url.decode(base64Url.normalize(name.substring(7))),
      );
    } on FormatException {
      return null;
    }
  }

  static void _validateKey(String key) {
    if (key.isEmpty ||
        key.startsWith('/') ||
        key
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw ArgumentError.value(
        key,
        'logicalKey',
        'must be a normalised relative key',
      );
    }
  }

  static RemoteObjectMetadata _metadata(
    String key,
    Map<String, dynamic> data,
  ) => RemoteObjectMetadata(
    logicalKey: key,
    size: int.tryParse('${data['size'] ?? 0}') ?? 0,
    updatedAt:
        DateTime.tryParse('${data['updated_at'] ?? ''}')?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    etag: data['content_hash'] as String?,
  );

  static Stream<Uint8List> _chunks(Stream<List<int>> input) async* {
    var pending = BytesBuilder(copy: false);
    await for (final part in input) {
      var offset = 0;
      while (offset < part.length) {
        final take = (_partBytes - pending.length).clamp(
          0,
          part.length - offset,
        );
        pending.add(part.sublist(offset, offset + take));
        offset += take;
        if (pending.length == _partBytes) {
          yield pending.takeBytes();
          pending = BytesBuilder(copy: false);
        }
      }
    }
    if (pending.length > 0) yield pending.takeBytes();
  }
}

class AliyunDriveException implements Exception {
  const AliyunDriveException(this.message);
  final String message;
  @override
  String toString() => 'AliyunDriveException: $message';
}
