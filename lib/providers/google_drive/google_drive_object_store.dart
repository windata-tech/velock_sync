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

/// Google Drive V3 implementation whose Drive IDs never leave this adapter.
///
/// Objects are flat files beneath [parentId]. The reversible file name encoding
/// keeps protocol logical keys opaque to Drive's folder/path interpretation.
class GoogleDriveObjectStore implements RemoteObjectStore {
  GoogleDriveObjectStore({
    required OAuthAccessTokenProvider accessTokenProvider,
    required this.parentId,
    Dio? dio,
    ProviderRateLimitRetry? rateLimitRetry,
  }) : _accessTokenProvider = accessTokenProvider,
       _dio = dio ?? Dio(),
       _rateLimitRetry = rateLimitRetry ?? ProviderRateLimitRetry();

  static final _filesUri = Uri.https('www.googleapis.com', '/drive/v3/files');
  static final _uploadUri = Uri.https(
    'www.googleapis.com',
    '/upload/drive/v3/files',
  );
  static const _chunkBytes = 8 * 256 * 1024;

  final OAuthAccessTokenProvider _accessTokenProvider;
  final Dio _dio;
  final ProviderRateLimitRetry _rateLimitRetry;
  final String parentId;

  @override
  final RemoteCapabilities capabilities = const RemoteCapabilities(
    supportsConditionalCreate: false,
    supportsConditionalUpdate: false,
    supportsRangeDownload: true,
    supportsResumableUpload: true,
    supportsServerHash: true,
    supportsTrash: true,
    supportsHiddenAppFolder: true,
    hasStrongListConsistency: false,
    recommendedChunkBytes: _chunkBytes,
  );

  @override
  Future<RemoteObjectMetadata?> stat(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    _validateKey(logicalKey);
    final response = await _request<Map<String, dynamic>>(
      (headers) => _dio.getUri(
        _filesUri.replace(
          queryParameters: {
            'q':
                "'${_escapeQuery(parentId)}' in parents and name = '${_escapeQuery(_name(logicalKey))}' and trashed = false",
            'spaces': parentId == 'appDataFolder' ? 'appDataFolder' : 'drive',
            'pageSize': '2',
            'fields': 'files(id,name,size,modifiedTime,md5Checksum)',
          },
        ),
        options: _options(
          headers,
          (status) => status == 200 || status == 401 || status == 429,
        ),
        cancelToken: dioCancelTokenFor(cancellation),
      ),
      cancellation: cancellation,
    );
    final files = response.data?['files'];
    if (files is! List || files.isEmpty) return null;
    final file = files.first;
    if (file is! Map<String, dynamic>) return null;
    return _metadata(logicalKey, file);
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
    final response = await _request<Map<String, dynamic>>(
      (headers) => _dio.getUri(
        _filesUri.replace(
          queryParameters: {
            'q': "'${_escapeQuery(parentId)}' in parents and trashed = false",
            'spaces': parentId == 'appDataFolder' ? 'appDataFolder' : 'drive',
            'pageSize': '$limit',
            'pageToken': ?cursor,
            'fields':
                'nextPageToken,files(id,name,size,modifiedTime,md5Checksum)',
            'orderBy': 'name',
          },
        ),
        options: _options(
          headers,
          (status) => status == 200 || status == 401 || status == 429,
        ),
        cancelToken: dioCancelTokenFor(cancellation),
      ),
      cancellation: cancellation,
    );
    final files = response.data?['files'];
    final itemsByKey = <String, RemoteObjectMetadata>{};
    if (files is List) {
      for (final value in files) {
        if (value is! Map<String, dynamic>) continue;
        final name = value['name'];
        if (name is! String) continue;
        final logicalKey = _keyFromName(name);
        if (logicalKey == null || !logicalKey.startsWith(prefix)) continue;
        itemsByKey.putIfAbsent(logicalKey, () => _metadata(logicalKey, value));
      }
    }
    final items = itemsByKey.values.toList()
      ..sort((a, b) => a.logicalKey.compareTo(b.logicalKey));
    return RemoteObjectPage(
      items: items,
      nextCursor: response.data?['nextPageToken'] as String?,
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
    final metadata = await _lookup(logicalKey, cancellation: cancellation);
    if (metadata == null) throw RemoteObjectNotFoundException(logicalKey);
    final response = await _request<ResponseBody>(
      (headers) => _dio.getUri(
        _fileUri(metadata.id, {'alt': 'media'}),
        options: _options(
          headers,
          (status) =>
              status == 200 ||
              status == 206 ||
              status == 401 ||
              status == 404 ||
              status == 429,
          responseType: ResponseType.stream,
          extraHeaders: {
            if (start != null || endInclusive != null)
              'Range': 'bytes=${start ?? 0}-${endInclusive ?? ''}',
          },
        ),
        cancelToken: dioCancelTokenFor(cancellation),
      ),
      cancellation: cancellation,
    );
    if (response.statusCode == 404) {
      throw RemoteObjectNotFoundException(logicalKey);
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
    if (ifAbsent &&
        await stat(logicalKey, cancellation: cancellation) != null) {
      throw RemoteObjectAlreadyExistsException(logicalKey);
    }
    final session = await _request<void>(
      (headers) => _dio.postUri(
        _uploadUri.replace(
          queryParameters: {
            'uploadType': 'resumable',
            'fields': 'id,name,size,modifiedTime,md5Checksum',
          },
        ),
        data: jsonEncode({
          'name': _name(logicalKey),
          'parents': [parentId],
        }),
        options: _options(
          headers,
          (status) => status == 200 || status == 401 || status == 429,
          extraHeaders: {
            'X-Upload-Content-Type': 'application/octet-stream',
            'X-Upload-Content-Length': '$contentLength',
          },
        ),
        cancelToken: dioCancelTokenFor(cancellation),
      ),
      cancellation: cancellation,
    );
    final location = session.headers.value('location');
    if (location == null) {
      throw const GoogleDriveException('Missing resumable upload URL.');
    }
    Map<String, dynamic>? data;
    var offset = 0;
    if (contentLength == 0) {
      final completed = await _uploadChunk(
        location: Uri.parse(location),
        chunk: Uint8List(0),
        start: 0,
        end: -1,
        contentLength: 0,
        cancellation: cancellation,
      );
      data = completed.data;
    } else {
      await for (final chunk in _chunks(content)) {
        cancellation?.throwIfCancelled();
        final end = offset + chunk.length - 1;
        if (end >= contentLength) {
          throw ArgumentError.value(
            content,
            'content',
            'exceeds declared length',
          );
        }
        final completed = await _uploadChunk(
          location: Uri.parse(location),
          chunk: chunk,
          start: offset,
          end: end,
          contentLength: contentLength,
          cancellation: cancellation,
        );
        offset += chunk.length;
        if (completed.statusCode != 308) {
          if (offset != contentLength) {
            throw const GoogleDriveException(
              'Upload completed before all bytes were sent.',
            );
          }
          data = completed.data;
        }
      }
    }
    if (offset != contentLength) {
      throw const GoogleDriveException(
        'Upload ended before all bytes were sent.',
      );
    }
    if (data == null) {
      throw const GoogleDriveException('Missing uploaded file metadata.');
    }
    return _metadata(logicalKey, data);
  }

  Future<Response<Map<String, dynamic>>> _uploadChunk({
    required Uri location,
    required Uint8List chunk,
    required int start,
    required int end,
    required int contentLength,
    RemoteOperationCancellation? cancellation,
  }) => _request(
    (headers) => _dio.putUri(
      location,
      data: chunk,
      options: _options(
        headers,
        (status) =>
            status == 200 ||
            status == 201 ||
            status == 308 ||
            status == 401 ||
            status == 429 ||
            (status != null && status >= 500 && status <= 599),
        extraHeaders: {
          'Content-Length': '${chunk.length}',
          if (contentLength > 0)
            'Content-Range': 'bytes $start-$end/$contentLength',
        },
      ),
      cancelToken: dioCancelTokenFor(cancellation),
    ),
    retryServerErrors: true,
    cancellation: cancellation,
  );

  @override
  Future<void> delete(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final file = await _lookup(logicalKey, cancellation: cancellation);
    if (file == null) return;
    await _request<void>(
      (headers) => _dio.deleteUri(
        _fileUri(file.id),
        options: _options(
          headers,
          (status) =>
              status == 204 || status == 401 || status == 404 || status == 429,
        ),
        cancelToken: dioCancelTokenFor(cancellation),
      ),
      cancellation: cancellation,
    );
    // Deleting a previously removed immutable object is a successful no-op.
  }

  Future<_DriveFile?> _lookup(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) async {
    final metadata = await stat(logicalKey, cancellation: cancellation);
    if (metadata == null) return null;
    final response = await _request<Map<String, dynamic>>(
      (headers) => _dio.getUri(
        _filesUri.replace(
          queryParameters: {
            'q':
                "'${_escapeQuery(parentId)}' in parents and name = '${_escapeQuery(_name(logicalKey))}' and trashed = false",
            'pageSize': '1',
            'fields': 'files(id)',
          },
        ),
        options: _options(
          headers,
          (status) => status == 200 || status == 401 || status == 429,
        ),
        cancelToken: dioCancelTokenFor(cancellation),
      ),
    );
    final files = response.data?['files'];
    final id = files is List && files.isNotEmpty && files.first is Map
        ? (files.first as Map)['id']
        : null;
    return id is String ? _DriveFile(id) : null;
  }

  Future<Response<T>> _request<T>(
    Future<Response<T>> Function(Map<String, String>) send, {
    bool retryServerErrors = false,
    RemoteOperationCancellation? cancellation,
  }) async {
    try {
      Future<Response<T>> request() async {
        var response = await send(
          await _accessTokenProvider.authorizationHeaders(),
        );
        if (response.statusCode == 401) {
          response = await send(
            await _accessTokenProvider.authorizationHeaders(forceRefresh: true),
          );
        }
        if (response.statusCode == 401) {
          throw ProviderRequestException.fromStatus(401);
        }
        return response;
      }

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
      final response = error.response;
      final statusCode = response?.statusCode;
      if (statusCode != null) {
        throw ProviderRequestException.fromStatus(
          statusCode,
          retryAfter: _rateLimitRetry.retryAfter(
            response?.headers.value('retry-after'),
          ),
        );
      }
      rethrow;
    }
  }

  Options _options(
    Map<String, String> headers,
    ValidateStatus status, {
    ResponseType? responseType,
    Map<String, String> extraHeaders = const {},
  }) => Options(
    headers: {...headers, ...extraHeaders},
    responseType: responseType,
    contentType: extraHeaders.containsKey('X-Upload-Content-Type')
        ? Headers.jsonContentType
        : null,
    validateStatus: status,
  );

  Uri _fileUri(String id, [Map<String, String> query = const {}]) =>
      _filesUri.replace(path: '${_filesUri.path}/$id', queryParameters: query);

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

  static String _escapeQuery(String value) => value.replaceAll("'", r"\'");

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
        DateTime.tryParse('${data['modifiedTime'] ?? ''}')?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    etag: data['md5Checksum'] as String?,
  );

  static Stream<Uint8List> _chunks(Stream<List<int>> input) async* {
    var pending = Uint8List(0);
    await for (final part in input) {
      final joined = Uint8List(pending.length + part.length)
        ..setAll(0, pending)
        ..setAll(pending.length, part);
      var at = 0;
      while (joined.length - at >= _chunkBytes) {
        yield Uint8List.fromList(joined.sublist(at, at + _chunkBytes));
        at += _chunkBytes;
      }
      pending = Uint8List.fromList(joined.sublist(at));
    }
    if (pending.isNotEmpty) yield pending;
  }
}

class _DriveFile {
  const _DriveFile(this.id);
  final String id;
}

class GoogleDriveException implements Exception {
  const GoogleDriveException(this.message);
  final String message;
  @override
  String toString() => 'GoogleDriveException: $message';
}
