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

/// Microsoft Graph / OneDrive adapter rooted at a user-selected Drive item.
class OneDriveObjectStore implements RemoteObjectStore {
  OneDriveObjectStore({
    required OAuthAccessTokenProvider accessTokenProvider,
    required this.rootItemId,
    Dio? dio,
    ProviderRateLimitRetry? rateLimitRetry,
  }) : _accessTokenProvider = accessTokenProvider,
       _dio = dio ?? Dio(),
       _rateLimitRetry = rateLimitRetry ?? ProviderRateLimitRetry();

  static final _graph = Uri.https('graph.microsoft.com', '/v1.0/me/drive');
  static const _chunkBytes = 10 * 1024 * 1024; // multiple of Graph's 320 KiB.

  final OAuthAccessTokenProvider _accessTokenProvider;
  final Dio _dio;
  final ProviderRateLimitRetry _rateLimitRetry;
  final String rootItemId;

  @override
  final RemoteCapabilities capabilities = const RemoteCapabilities(
    supportsConditionalCreate: true,
    supportsConditionalUpdate: true,
    supportsRangeDownload: true,
    supportsResumableUpload: true,
    supportsServerHash: false,
    supportsTrash: true,
    supportsHiddenAppFolder: false,
    hasStrongListConsistency: false,
    recommendedChunkBytes: _chunkBytes,
  );

  @override
  Future<RemoteObjectMetadata?> stat(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    return (await _lookup(logicalKey, cancellation: cancellation))?.metadata;
  }

  @override
  Future<RemoteObjectPage> list({
    String prefix = '',
    String? cursor,
    int limit = 100,
    RemoteOperationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    if (limit < 1 || limit > 999) throw ArgumentError.value(limit, 'limit');
    final response = await _request<Map<String, dynamic>>(
      (headers) => _dio.getUri(
        cursor == null
            ? _childrenUri().replace(
                queryParameters: {
                  r'$top': '$limit',
                  r'$select': 'id,name,size,lastModifiedDateTime,eTag,file',
                },
              )
            : Uri.parse(cursor),
        options: _options(
          headers,
          (status) => status == 200 || status == 401 || status == 429,
        ),
        cancelToken: dioCancelTokenFor(cancellation),
      ),
      cancellation: cancellation,
    );
    final itemsByKey = <String, RemoteObjectMetadata>{};
    final values = response.data?['value'];
    if (values is List) {
      for (final value in values) {
        if (value is! Map<String, dynamic> || value['file'] is! Map) continue;
        final name = value['name'];
        if (name is! String) continue;
        final key = _keyFromName(name);
        if (key != null && key.startsWith(prefix)) {
          itemsByKey.putIfAbsent(key, () => _metadata(key, value));
        }
      }
    }
    final items = itemsByKey.values.toList()
      ..sort((a, b) => a.logicalKey.compareTo(b.logicalKey));
    return RemoteObjectPage(
      items: items,
      nextCursor: response.data?['@odata.nextLink'] as String?,
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
    final item = await _lookup(
      logicalKey,
      includeDownloadUrl: true,
      cancellation: cancellation,
    );
    if (item == null) {
      throw RemoteObjectNotFoundException(logicalKey);
    }
    final url = item.downloadUrl;
    if (url == null) {
      throw const OneDriveException('Missing preauthenticated download URL.');
    }
    final response = await _dio.getUri<ResponseBody>(
      Uri.parse(url),
      options: Options(
        responseType: ResponseType.stream,
        headers: {
          if (start != null || endInclusive != null)
            'Range': 'bytes=${start ?? 0}-${endInclusive ?? ''}',
        },
        validateStatus: (status) =>
            status == 200 || status == 206 || status == 404,
      ),
      cancelToken: dioCancelTokenFor(cancellation),
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
    final existing = await _lookup(logicalKey, cancellation: cancellation);
    if (ifAbsent && existing != null) {
      throw RemoteObjectAlreadyExistsException(logicalKey);
    }
    if (contentLength == 0) {
      await for (final bytes in content) {
        cancellation?.throwIfCancelled();
        if (bytes.isNotEmpty) {
          throw ArgumentError.value(
            content,
            'content',
            'does not match length',
          );
        }
      }
      final response = await _request<Map<String, dynamic>>(
        (headers) => _dio.putUri(
          existing == null
              ? _itemUri(rootItemId).replace(
                  path:
                      '${_itemUri(rootItemId).path}:/${_name(logicalKey)}:/content',
                )
              : _itemUri(
                  existing.id,
                ).replace(path: '${_itemUri(existing.id).path}/content'),
          data: Uint8List(0),
          options: Options(
            headers: {...headers, 'Content-Length': '0'},
            validateStatus: (status) =>
                status == 200 ||
                status == 201 ||
                status == 401 ||
                status == 429,
          ),
          cancelToken: dioCancelTokenFor(cancellation),
        ),
        cancellation: cancellation,
      );
      final result = response.data;
      if (result == null) {
        throw const OneDriveException('Missing uploaded file metadata.');
      }
      return _metadata(logicalKey, result);
    }
    final sessionUri = existing == null
        ? _childrenUri().replace(
            path:
                '${_childrenUri().path}:/${_name(logicalKey)}:/createUploadSession',
          )
        : _itemUri(
            existing.id,
          ).replace(path: '${_itemUri(existing.id).path}/createUploadSession');
    final session = await _request<Map<String, dynamic>>(
      (headers) => _dio.postUri(
        sessionUri,
        data: {
          'item': {
            '@microsoft.graph.conflictBehavior': ifAbsent ? 'fail' : 'replace',
          },
        },
        options: _options(
          headers,
          (status) =>
              status == 200 || status == 201 || status == 401 || status == 429,
        ),
        cancelToken: dioCancelTokenFor(cancellation),
      ),
      cancellation: cancellation,
    );
    final uploadUrl = session.data?['uploadUrl'];
    if (uploadUrl is! String) {
      throw const OneDriveException('Missing upload session URL.');
    }
    Map<String, dynamic>? completed;
    var offset = 0;
    await for (final chunk in _chunks(content)) {
      cancellation?.throwIfCancelled();
      final end = offset + chunk.length - 1;
      final response = await _uploadChunk(
        uploadUrl: Uri.parse(uploadUrl),
        chunk: chunk,
        start: offset,
        end: end,
        contentLength: contentLength,
        cancellation: cancellation,
      );
      if (response.statusCode == 404) {
        throw const OneDriveException('Upload session expired.');
      }
      if (response.statusCode == 409) {
        if (ifAbsent) throw RemoteObjectAlreadyExistsException(logicalKey);
        throw const OneDriveException('Upload conflict.');
      }
      offset += chunk.length;
      if (response.statusCode != 202) completed = response.data;
    }
    if (offset != contentLength || completed == null) {
      throw const OneDriveException('Upload ended before Graph completed it.');
    }
    return _metadata(logicalKey, completed);
  }

  Future<Response<Map<String, dynamic>>> _uploadChunk({
    required Uri uploadUrl,
    required Uint8List chunk,
    required int start,
    required int end,
    required int contentLength,
    RemoteOperationCancellation? cancellation,
  }) async {
    try {
      return await _rateLimitRetry.executeTransient(
        () => _dio.putUri<Map<String, dynamic>>(
          uploadUrl,
          data: chunk,
          options: Options(
            headers: {
              'Content-Length': '${chunk.length}',
              'Content-Range': 'bytes $start-$end/$contentLength',
            },
            validateStatus: (status) =>
                status == 200 ||
                status == 201 ||
                status == 202 ||
                status == 404 ||
                status == 409 ||
                status == 429 ||
                (status != null && status >= 500 && status <= 599),
          ),
          cancelToken: dioCancelTokenFor(cancellation),
        ),
        whenCancelled: cancellation?.whenCancelled,
      );
    } on DioException catch (error) {
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

  @override
  Future<void> delete(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final item = await _lookup(logicalKey, cancellation: cancellation);
    if (item == null) return;
    await _request<void>(
      (headers) => _dio.deleteUri(
        _itemUri(item.id),
        options: _options(
          headers,
          (status) =>
              status == 204 || status == 401 || status == 404 || status == 429,
        ),
        cancelToken: dioCancelTokenFor(cancellation),
      ),
      cancellation: cancellation,
    );
    // DELETE is idempotent: a concurrently removed immutable object is gone.
  }

  Future<_OneDriveItem?> _lookup(
    String key, {
    bool includeDownloadUrl = false,
    RemoteOperationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    _validateKey(key);
    String? cursor;
    do {
      final page = await _listItems(
        cursor,
        includeDownloadUrl: includeDownloadUrl,
        cancellation: cancellation,
      );
      cancellation?.throwIfCancelled();
      for (final item in page.items) {
        if (item.metadata.logicalKey == key) return item;
      }
      cursor = page.cursor;
    } while (cursor != null);
    return null;
  }

  Future<_ItemPage> _listItems(
    String? cursor, {
    required bool includeDownloadUrl,
    RemoteOperationCancellation? cancellation,
  }) async {
    final response = await _request<Map<String, dynamic>>(
      (headers) => _dio.getUri(
        cursor == null
            ? _childrenUri().replace(
                queryParameters: {
                  r'$top': '999',
                  r'$select':
                      'id,name,size,lastModifiedDateTime,eTag,file${includeDownloadUrl ? ',@microsoft.graph.downloadUrl' : ''}',
                },
              )
            : Uri.parse(cursor),
        options: _options(
          headers,
          (status) => status == 200 || status == 401 || status == 429,
        ),
        cancelToken: dioCancelTokenFor(cancellation),
      ),
      cancellation: cancellation,
    );
    final values = response.data?['value'];
    final items = <_OneDriveItem>[];
    if (values is List) {
      for (final raw in values) {
        if (raw is! Map<String, dynamic> ||
            raw['file'] is! Map ||
            raw['name'] is! String ||
            raw['id'] is! String) {
          continue;
        }
        final key = _keyFromName(raw['name'] as String);
        if (key != null) {
          items.add(
            _OneDriveItem(
              raw['id'] as String,
              _metadata(key, raw),
              raw['@microsoft.graph.downloadUrl'] as String?,
            ),
          );
        }
      }
    }
    return _ItemPage(items, response.data?['@odata.nextLink'] as String?);
  }

  Future<Response<T>> _request<T>(
    Future<Response<T>> Function(Map<String, String>) send, {
    RemoteOperationCancellation? cancellation,
  }) async {
    try {
      return await _rateLimitRetry.execute(() async {
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
      }, whenCancelled: cancellation?.whenCancelled);
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

  Options _options(Map<String, String> headers, ValidateStatus status) =>
      Options(headers: headers, validateStatus: status);
  Uri _childrenUri() =>
      _graph.replace(path: '${_graph.path}/items/$rootItemId/children');
  Uri _itemUri(String id) => _graph.replace(path: '${_graph.path}/items/$id');
  static String _name(String key) =>
      'velock-${base64UrlEncode(utf8.encode(key)).replaceAll('=', '')}';
  static String? _keyFromName(String name) {
    if (!name.startsWith('velock-')) {
      return null;
    }
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
      throw ArgumentError.value(key, 'logicalKey');
    }
  }

  static RemoteObjectMetadata _metadata(String key, Map<String, dynamic> raw) =>
      RemoteObjectMetadata(
        logicalKey: key,
        size: int.tryParse('${raw['size'] ?? 0}') ?? 0,
        updatedAt:
            DateTime.tryParse(
              '${raw['lastModifiedDateTime'] ?? ''}',
            )?.toUtc() ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        etag: raw['eTag'] as String?,
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

class _OneDriveItem {
  const _OneDriveItem(this.id, this.metadata, this.downloadUrl);
  final String id;
  final RemoteObjectMetadata metadata;
  final String? downloadUrl;
}

class _ItemPage {
  const _ItemPage(this.items, this.cursor);
  final List<_OneDriveItem> items;
  final String? cursor;
}

class OneDriveException implements Exception {
  const OneDriveException(this.message);
  final String message;
  @override
  String toString() => 'OneDriveException: $message';
}
