import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:velock_sync/providers/provider_cancellation.dart';
import 'package:velock_sync/providers/provider_rate_limit_retry.dart';
import 'package:velock_sync/providers/provider_request_exception.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:xml/xml.dart';

/// WebDAV mapping for provider-neutral protocol logical keys.
///
/// Authentication is supplied only at construction time from secure storage;
/// this object neither persists nor logs credentials.
class WebDavObjectStore implements RemoteObjectStore {
  WebDavObjectStore({
    required Dio dio,
    required Uri baseUri,
    required this.username,
    required this.password,
    ProviderRateLimitRetry? rateLimitRetry,
    this.capabilities = const RemoteCapabilities(
      supportsConditionalCreate: true,
      supportsConditionalUpdate: false,
      supportsRangeDownload: true,
      supportsResumableUpload: false,
      supportsServerHash: false,
      supportsTrash: false,
      supportsHiddenAppFolder: false,
      hasStrongListConsistency: false,
    ),
  }) : _dio = dio,
       _rateLimitRetry = rateLimitRetry ?? ProviderRateLimitRetry(),
       _baseUri = _normaliseBaseUri(baseUri);

  final Dio _dio;
  final Uri _baseUri;
  final ProviderRateLimitRetry _rateLimitRetry;
  final String? username;
  final String? password;

  @override
  final RemoteCapabilities capabilities;

  @override
  Future<RemoteObjectMetadata?> stat(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final response = await _request(
      () => _dio.headUri<void>(
        _objectUri(logicalKey),
        cancelToken: dioCancelTokenFor(cancellation),
        options: _options(
          validateStatus: (status) =>
              status == 200 || status == 404 || status == 429,
        ),
      ),
      cancellation: cancellation,
    );
    if (response.statusCode == 404) return null;
    return _metadata(logicalKey, response.headers);
  }

  @override
  Future<RemoteObjectPage> list({
    String prefix = '',
    String? cursor,
    int limit = 100,
    RemoteOperationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    if (limit < 1) throw ArgumentError.value(limit, 'limit');
    final offset = cursor == null ? 0 : int.tryParse(cursor);
    if (offset == null || offset < 0) {
      throw ArgumentError.value(cursor, 'cursor');
    }

    final response = await _request(
      () => _dio.requestUri<String>(
        _objectUri(prefix, allowEmpty: true),
        cancelToken: dioCancelTokenFor(cancellation),
        options: _options(
          method: 'PROPFIND',
          responseType: ResponseType.plain,
          headers: const {'Depth': '1'},
          validateStatus: (status) =>
              status == 207 || status == 404 || status == 429,
        ),
      ),
      cancellation: cancellation,
    );
    if (response.statusCode == 404) return const RemoteObjectPage(items: []);

    final document = XmlDocument.parse(response.data!);
    final itemsByKey = <String, RemoteObjectMetadata>{};
    final queriedKey = prefix.endsWith('/')
        ? prefix.substring(0, prefix.length - 1)
        : prefix;
    for (final responseElement
        in document.descendants.whereType<XmlElement>().where(
          (element) => element.name.local == 'response',
        )) {
      final href = _firstDescendantText(responseElement, 'href');
      if (href == null) continue;
      final logicalKey = _logicalKeyForHref(href);
      if (logicalKey == null || logicalKey == queriedKey) continue;
      final contentLength =
          int.tryParse(
            _firstDescendantText(responseElement, 'getcontentlength') ?? '',
          ) ??
          0;
      final modified = _parseHttpDate(
        _firstDescendantText(responseElement, 'getlastmodified'),
      );
      final etag = _firstDescendantText(responseElement, 'getetag');
      itemsByKey.putIfAbsent(
        logicalKey,
        () => RemoteObjectMetadata(
          logicalKey: logicalKey,
          size: contentLength,
          updatedAt:
              modified ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          etag: etag,
        ),
      );
    }
    final items = itemsByKey.values.toList()
      ..sort((a, b) => a.logicalKey.compareTo(b.logicalKey));
    final page = items.skip(offset).take(limit).toList();
    final nextOffset = offset + page.length;
    return RemoteObjectPage(
      items: page,
      nextCursor: nextOffset < items.length ? '$nextOffset' : null,
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
    final headers = <String, String>{};
    if (start != null || endInclusive != null) {
      headers['Range'] = 'bytes=${start ?? 0}-${endInclusive ?? ''}';
    }
    final response = await _request(
      () => _dio.getUri<ResponseBody>(
        _objectUri(logicalKey),
        cancelToken: dioCancelTokenFor(cancellation),
        options: _options(
          responseType: ResponseType.stream,
          headers: headers,
          validateStatus: (status) =>
              status == 200 || status == 206 || status == 404 || status == 429,
        ),
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
    final objectUri = _objectUri(logicalKey);
    await _ensureParentCollections(logicalKey, cancellation: cancellation);
    final headers = <String, String>{'Content-Length': '$contentLength'};
    if (ifAbsent) {
      headers['If-None-Match'] = '*';
    }
    final response = await _request(
      () => _dio.putUri<void>(
        objectUri,
        data: content,
        cancelToken: dioCancelTokenFor(cancellation),
        options: _options(
          headers: headers,
          validateStatus: (status) =>
              status == 200 ||
              status == 201 ||
              status == 204 ||
              status == 412 ||
              status == 429,
        ),
      ),
      cancellation: cancellation,
    );
    if (response.statusCode == 412) {
      throw RemoteObjectAlreadyExistsException(logicalKey);
    }
    return RemoteObjectMetadata(
      logicalKey: logicalKey,
      size: contentLength,
      updatedAt: DateTime.now().toUtc(),
      etag: response.headers.value('etag'),
    );
  }

  Future<void> _ensureParentCollections(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) async {
    final parts = logicalKey.split('/');
    if (parts.length < 2) return;

    final parentParts = <String>[];
    for (final part in parts.take(parts.length - 1)) {
      cancellation?.throwIfCancelled();
      parentParts.add(part);
      await _request(
        () => _dio.requestUri<void>(
          _objectUri(parentParts.join('/')),
          cancelToken: dioCancelTokenFor(cancellation),
          options: _options(
            method: 'MKCOL',
            validateStatus: (status) =>
                status == 201 || status == 405 || status == 429,
          ),
        ),
        cancellation: cancellation,
      );
    }
  }

  @override
  Future<void> delete(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    await _request(
      () => _dio.deleteUri<void>(
        _objectUri(logicalKey),
        cancelToken: dioCancelTokenFor(cancellation),
        options: _options(
          validateStatus: (status) =>
              status == 204 || status == 404 || status == 429,
        ),
      ),
      cancellation: cancellation,
    );
    // DELETE is idempotent: a concurrently removed immutable object is gone.
  }

  Options _options({
    String? method,
    ResponseType? responseType,
    Map<String, String>? headers,
    ValidateStatus? validateStatus,
  }) {
    final requestHeaders = <String, String>{...headers ?? {}};
    if (username != null &&
        username!.isNotEmpty &&
        password != null &&
        password!.isNotEmpty) {
      requestHeaders['Authorization'] =
          'Basic ${base64Encode(utf8.encode('$username:$password'))}';
    }
    return Options(
      method: method,
      responseType: responseType,
      headers: requestHeaders,
      validateStatus: validateStatus,
    );
  }

  Future<Response<T>> _request<T>(
    Future<Response<T>> Function() send, {
    RemoteOperationCancellation? cancellation,
  }) async {
    try {
      return await _rateLimitRetry.execute(
        send,
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

  Uri _objectUri(String logicalKey, {bool allowEmpty = false}) {
    if (!allowEmpty && logicalKey.isEmpty) {
      throw ArgumentError.value(logicalKey, 'logicalKey');
    }
    final validatedKey = logicalKey.endsWith('/')
        ? logicalKey.substring(0, logicalKey.length - 1)
        : logicalKey;
    if (logicalKey.startsWith('/') ||
        (!allowEmpty && validatedKey.isEmpty) ||
        validatedKey
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw ArgumentError.value(
        logicalKey,
        'logicalKey',
        'must be a normalised relative key',
      );
    }
    return _baseUri.resolve(logicalKey);
  }

  RemoteObjectMetadata _metadata(String key, Headers headers) {
    final size =
        int.tryParse(headers.value(Headers.contentLengthHeader) ?? '') ?? 0;
    return RemoteObjectMetadata(
      logicalKey: key,
      size: size,
      updatedAt:
          _parseHttpDate(headers.value('last-modified')) ??
          DateTime.now().toUtc(),
      etag: headers.value('etag'),
    );
  }

  String? _logicalKeyForHref(String href) {
    final resolved = _baseUri.resolve(href);
    if (resolved.host != _baseUri.host ||
        !resolved.path.startsWith(_baseUri.path)) {
      return null;
    }
    final key = Uri.decodeComponent(
      resolved.path.substring(_baseUri.path.length),
    );
    return key.endsWith('/') ? key.substring(0, key.length - 1) : key;
  }

  static Uri _normaliseBaseUri(Uri value) {
    if (!value.hasScheme || !value.hasAuthority) {
      throw ArgumentError.value(value, 'baseUri');
    }
    return value.path.endsWith('/')
        ? value
        : value.replace(path: '${value.path}/');
  }

  static String? _firstDescendantText(XmlElement parent, String localName) {
    final element = parent.descendants
        .whereType<XmlElement>()
        .cast<XmlElement?>()
        .firstWhere(
          (element) => element?.name.local == localName,
          orElse: () => null,
        );
    return element?.innerText.trim();
  }

  static DateTime? _parseHttpDate(String? value) {
    if (value == null || value.isEmpty) return null;
    try {
      return HttpDate.parse(value).toUtc();
    } on FormatException {
      return null;
    }
  }
}
