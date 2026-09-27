import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:dio/dio.dart';
import 'package:velock_sync/providers/provider_cancellation.dart';
import 'package:velock_sync/providers/provider_rate_limit_retry.dart';
import 'package:velock_sync/providers/provider_request_exception.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'package:xml/xml.dart';

/// WebDAV mapping for provider-neutral protocol logical keys.
///
/// Authentication is supplied only at construction time from secure storage;
/// this object neither persists nor logs credentials.
class WebDavObjectStore implements RemoteObjectStore, RemoteCollectionCreator {
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

  // Shared by concurrent writes, scoped to this endpoint/authentication instance.
  Future<void>? _atomicCreateReady;

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
    if (response.statusCode == 404) {
      // "The folder is gone" and "the folder is empty" must not be the same
      // answer: the mirror plans deletions from this listing, so an unmounted
      // share or a renamed folder would look like "the user deleted everything
      // remotely" and the local copies would be removed.
      throw RemoteObjectNotFoundException(prefix);
    }

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
      final isDirectory = _isCollectionResponse(responseElement);
      itemsByKey.putIfAbsent(
        logicalKey,
        () => RemoteObjectMetadata(
          logicalKey: logicalKey,
          size: contentLength,
          updatedAt:
              modified ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          etag: etag,
          isDirectory: isDirectory,
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
    if (contentLength < 0) {
      throw ArgumentError.value(contentLength, 'contentLength');
    }
    if (ifAbsent) {
      return _putIfAbsent(
        logicalKey,
        content,
        contentLength: contentLength,
        cancellation: cancellation,
      );
    }
    await _ensureParentCollections(logicalKey, cancellation: cancellation);
    final headers = <String, String>{
      'Content-Type': 'application/octet-stream',
      'Content-Length': '$contentLength',
    };
    late final Response<void> response;
    try {
      response = await _request(
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
    } on ProviderRequestException catch (error) {
      if (kDebugMode) {
        debugPrint(
          'WEBDAV_DIAG method=PUT key=$logicalKey status=${error.statusCode}',
        );
      }
      rethrow;
    }
    if (response.statusCode == 412) {
      throw RemoteObjectAlreadyExistsException(logicalKey);
    }
    if (kDebugMode) {
      debugPrint(
        'WEBDAV_DIAG method=PUT key=$logicalKey status=${response.statusCode}',
      );
    }
    return RemoteObjectMetadata(
      logicalKey: logicalKey,
      size: contentLength,
      updatedAt: DateTime.now().toUtc(),
      etag: response.headers.value('etag'),
    );
  }

  /// PUT If-None-Match is ignored by some NAS servers. Never send an immutable
  /// payload to its final URI: publish a private upload with atomic MOVE instead.
  /// A HEAD-then-PUT check is deliberately NOT used (it races other writers).
  Future<RemoteObjectMetadata> _putIfAbsent(
    String key,
    Stream<List<int>> content, {
    required int contentLength,
    RemoteOperationCancellation? cancellation,
  }) async {
    if (!capabilities.supportsConditionalCreate) {
      throw _atomicCreateUnsupported();
    }
    final ready = _atomicCreateReady ??= _probeAtomicMove().catchError((
      Object error,
    ) {
      // A transient outage must not permanently poison this store instance.
      // Unsupported semantics stay fail-closed until a new connection is made.
      if (error is! UnsupportedError) _atomicCreateReady = null;
      Error.throwWithStackTrace(error, StackTrace.current);
    });
    await Future.any<void>([
      ready,
      if (cancellation != null)
        cancellation.whenCancelled.then<void>(
          (_) => throw const RemoteOperationCancelledException(),
        ),
    ]);
    cancellation?.throwIfCancelled();
    await _ensureParentCollections(key, cancellation: cancellation);
    final temporary = await _createPrivateCollection(
      'upload',
      cancellation: cancellation,
    );
    try {
      cancellation?.throwIfCancelled();
      await _request(
        () => _dio.putUri<void>(
          _objectUri('$temporary/payload'),
          data: content,
          cancelToken: dioCancelTokenFor(cancellation),
          options: _options(
            headers: {
              'Content-Type': 'application/octet-stream',
              'Content-Length': '$contentLength',
            },
            // A caller stream is not replayable: do not retry a consumed upload
            // on 429. Retrying the whole operation creates a new private source.
            validateStatus: (status) =>
                status == 201 || status == 200 || status == 204,
          ),
        ),
        cancellation: cancellation,
      );
      cancellation?.throwIfCancelled();
      final response = await _moveAbsent(
        '$temporary/payload',
        key,
        cancellation: cancellation,
      );
      if (response.statusCode == 412) {
        throw RemoteObjectAlreadyExistsException(key);
      }
      // Only 201 means creation. Never interpret an overwrite/unsupported result
      // as successful immutable publication, and never fall back to direct PUT.
      if (response.statusCode != 201) throw _atomicCreateUnsupported();
      return RemoteObjectMetadata(
        logicalKey: key,
        size: contentLength,
        updatedAt: DateTime.now().toUtc(),
        etag: response.headers.value('etag'),
      );
    } finally {
      await _removePrivateCollection(temporary);
    }
  }

  Future<Response<void>> _moveAbsent(
    String source,
    String destination, {
    RemoteOperationCancellation? cancellation,
  }) {
    final destinationUri = _objectUri(destination);
    return _request(
      () => _dio.requestUri<void>(
        _objectUri(source),
        cancelToken: dioCancelTokenFor(cancellation),
        options: _options(
          method: 'MOVE',
          headers: {
            // RFC 4918 allows a path-absolute Destination. Keeping the encoded
            // path avoids reverse proxies comparing an external authority with
            // the origin host, while retaining the configured base path. A
            // logical key is a decoded relative path, so it has no query part:
            // `?` and `#` inside a name are escaped like any other character.
            'Destination': destinationUri.path,
            'Overwrite': 'F',
          },
          validateStatus: (status) =>
              status == 201 ||
              status == 204 ||
              status == 412 ||
              status == 405 ||
              status == 501 ||
              status == 429,
        ),
      ),
      cancellation: cancellation,
    );
  }

  /// Creates exactly one collection with a single MKCOL request.
  ///
  /// No redirect is followed and no parent is created implicitly: the caller
  /// creates parents in order. Only HTTP 201 proves the collection was created;
  /// 405/409 keep the existing collection-not-writable classification rather
  /// than being reported as an already-existing directory.
  @override
  Future<void> createCollection(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final response = await _request(
      () => _dio.requestUri<void>(
        _objectUri(logicalKey),
        cancelToken: dioCancelTokenFor(cancellation),
        options: _options(
          method: 'MKCOL',
          // A redirect must never turn one logical collection into a write at a
          // different location, so it is surfaced as a failure instead.
          followRedirects: false,
          validateStatus: (status) =>
              status == 201 || status == 405 || status == 409 || status == 429,
        ),
      ),
      cancellation: cancellation,
    );
    if (kDebugMode) {
      debugPrint(
        'WEBDAV_DIAG method=MKCOL key=$logicalKey status=${response.statusCode}',
      );
    }
    if (response.statusCode == 405 || response.statusCode == 409) {
      throw _CollectionNotWritable(response.statusCode!);
    }
    // Every other status is rejected by validateStatus, so only 201 can reach
    // this point; keep the guard so an unexpected response is never success.
    if (response.statusCode != 201) {
      throw _CollectionNotWritable(response.statusCode!);
    }
  }

  Future<String> _createPrivateCollection(
    String kind, {
    RemoteOperationCancellation? cancellation,
  }) async {
    final random = Random.secure();
    final token = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final key = '.velock-$kind-$token';
    final response = await _request(
      () => _dio.requestUri<void>(
        _objectUri(key),
        cancelToken: dioCancelTokenFor(cancellation),
        options: _options(
          method: 'MKCOL',
          validateStatus: (status) =>
              status == 201 || status == 405 || status == 409 || status == 429,
        ),
      ),
      cancellation: cancellation,
    );
    // No ownership on conflict: never reuse, write into, or delete that path.
    if (response.statusCode == 405 || response.statusCode == 409) {
      throw _CollectionNotWritable(response.statusCode!);
    }
    if (response.statusCode != 201) throw _atomicCreateUnsupported();
    return key;
  }

  Future<void> _probeAtomicMove() async {
    // Shared across concurrent writers, so caller cancellation must not cancel
    // another writer's probe. The probe still has its own bounded lifetime.
    final cancellation = RemoteOperationCancellation();
    final deadline = Timer(const Duration(seconds: 20), cancellation.cancel);
    String? temporary;
    try {
      temporary = await _createPrivateCollection(
        'probe',
        cancellation: cancellation,
      );
      final source = '$temporary/source';
      final target = '$temporary/target';
      const sourceBytes = [17, 31, 53];
      const targetBytes = [71, 89, 107];
      for (final entry in {source: sourceBytes, target: targetBytes}.entries) {
        await _request(
          () => _dio.putUri<void>(
            _objectUri(entry.key),
            cancelToken: dioCancelTokenFor(cancellation),
            data: Stream.value(entry.value),
            options: _options(
              headers: {
                'Content-Length': '${entry.value.length}',
                'Content-Type': 'application/octet-stream',
              },
              validateStatus: (status) => status == 201,
            ),
          ),
          cancellation: cancellation,
        );
      }
      final collision = await _moveAbsent(
        source,
        target,
        cancellation: cancellation,
      );
      // Verify bytes even on 412: a broken server can report a precondition
      // failure after overwriting. All destructive probing stays in our directory.
      final sourceAfter = await read(
        source,
        cancellation: cancellation,
      ).expand((bytes) => bytes).toList();
      final targetAfter = await read(
        target,
        cancellation: cancellation,
      ).expand((bytes) => bytes).toList();
      if (collision.statusCode != 412 ||
          !listEquals(sourceAfter, sourceBytes) ||
          !listEquals(targetAfter, targetBytes)) {
        throw _atomicCreateUnsupported();
      }
      final created = await _moveAbsent(
        source,
        '$temporary/published',
        cancellation: cancellation,
      );
      if (created.statusCode != 201 ||
          !listEquals(
            await read(
              '$temporary/published',
              cancellation: cancellation,
            ).expand((bytes) => bytes).toList(),
            sourceBytes,
          ) ||
          await stat(source, cancellation: cancellation) != null) {
        throw _atomicCreateUnsupported();
      }
    } on RemoteObjectNotFoundException {
      throw _atomicCreateUnsupported();
    } on RemoteOperationCancelledException {
      throw const _AtomicCreateProbeTimeout();
    } finally {
      deadline.cancel();
      if (temporary != null) await _removePrivateCollection(temporary);
    }
  }

  Future<void> _removePrivateCollection(String key) async {
    final cancellation = RemoteOperationCancellation();
    final deadline = Timer(const Duration(seconds: 5), cancellation.cancel);
    try {
      // Independent of caller cancellation: remove only our successfully MKCOL'd
      // random collection, never the immutable destination or an existing folder.
      await _request(
        () => _dio.deleteUri<void>(
          _objectUri(key),
          cancelToken: dioCancelTokenFor(cancellation),
          options: _options(
            validateStatus: (status) =>
                status == 200 ||
                status == 204 ||
                status == 404 ||
                status == 429,
          ),
        ),
        cancellation: cancellation,
      );
    } on Object {
      // Preserve the original operation outcome. An orphan is safer than deleting
      // anything outside this scope; do not log URLs, credentials or response bodies.
      if (kDebugMode) debugPrint('WEBDAV private upload cleanup incomplete.');
    } finally {
      deadline.cancel();
    }
  }

  static UnsupportedError _atomicCreateUnsupported() =>
      _AtomicCreateUnsupported();

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
      final parentPath = parentParts.join('/');
      try {
        final response = await _request(
          () => _dio.requestUri<void>(
            _objectUri(parentPath),
            cancelToken: dioCancelTokenFor(cancellation),
            options: _options(
              method: 'MKCOL',
              validateStatus: (status) =>
                  status == 201 ||
                  status == 405 ||
                  status == 409 ||
                  status == 429,
            ),
          ),
          cancellation: cancellation,
        );
        if (kDebugMode) {
          debugPrint(
            'WEBDAV_DIAG method=MKCOL key=$parentPath status=${response.statusCode}',
          );
        }
      } on ProviderRequestException catch (error) {
        if (kDebugMode) {
          debugPrint(
            'WEBDAV_DIAG method=MKCOL key=$parentPath status=${error.statusCode}',
          );
        }
        rethrow;
      }
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
          // Widened for collections: servers answer a successful collection
          // DELETE with 200, 202 or 204, and a concurrently removed target with
          // 404. 207 Multi-Status is deliberately NOT accepted: it reports
          // per-member results and may contain failures, so treating it as
          // success could hide a partially deleted collection.
          validateStatus: (status) =>
              status == 200 ||
              status == 202 ||
              status == 204 ||
              status == 404 ||
              status == 429,
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
    bool? followRedirects,
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
      followRedirects: followRedirects,
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
    // An empty key is only legal when the caller explicitly allows it (listing
    // the store root); every other key must still be a normalised relative path.
    final isEmptyRoot = allowEmpty && validatedKey.isEmpty;
    if (logicalKey.startsWith('/') ||
        (!allowEmpty && validatedKey.isEmpty) ||
        (!isEmptyRoot &&
            validatedKey
                .split('/')
                .any((part) => part.isEmpty || part == '.' || part == '..'))) {
      throw ArgumentError.value(
        logicalKey,
        'logicalKey',
        'must be a normalised relative key',
      );
    }
    return _objectUriFor(
      validatedKey,
      // `list('a/b/')` asks for the collection itself; keep that shape.
      trailingSlash: validatedKey.isNotEmpty && logicalKey.endsWith('/'),
    );
  }

  /// Builds the request URI segment by segment.
  ///
  /// `Uri.resolve('a#b.png')` treats `#b.png` as a fragment, so a file whose
  /// name contains `#` or `?` used to be written to, read from and deleted at
  /// the WRONG remote path (and two such names collided). Encoding each segment
  /// keeps the name intact and still leaves `/` as the separator.
  Uri _objectUriFor(String validatedKey, {bool trailingSlash = false}) {
    if (validatedKey.isEmpty) return _baseUri;
    final segments = <String>[
      ..._baseUri.pathSegments.where((segment) => segment.isNotEmpty),
      ...validatedKey.split('/'),
      if (trailingSlash) '',
    ];
    return _baseUri.replace(
      pathSegments: segments,
      query: null,
      fragment: null,
    );
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

  /// True when the PROPFIND response advertises a DAV collection
  /// (`<resourcetype><collection/></resourcetype>`). A missing or empty
  /// `resourcetype` stays a file, matching the historical parser behaviour.
  static bool _isCollectionResponse(XmlElement responseElement) {
    final resourceType = responseElement.descendants
        .whereType<XmlElement>()
        .cast<XmlElement?>()
        .firstWhere(
          (element) => element?.name.local == 'resourcetype',
          orElse: () => null,
        );
    return resourceType?.childElements.any(
          (element) => element.name.local == 'collection',
        ) ??
        false;
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

/// Sanitized and actionable; never contains endpoint or probe content.
class _AtomicCreateUnsupported extends UnsupportedError
    implements SyncFailureException {
  _AtomicCreateUnsupported()
    : super(
        'WebDAV atomic create could not be verified; direct PUT is disabled.',
      );

  @override
  SyncFailure get syncFailure => const SyncFailure(
    errorCode: 'provider.webdav.atomic_create_unsupported',
    category: SyncErrorCategory.unsupportedProtocol,
    retryable: false,
    suggestedAction: '服务器未通过防覆盖校验。请启用 WebDAV MOVE 支持或更换同步目录/服务。',
  );
}

/// The selected WebDAV location could not create a disposable collection.
///
/// MKCOL 405/409 are not proof that atomic MOVE or conditional creation is
/// unsupported. Keep the location diagnostic precise, retryable, and do not
/// claim that the server cannot safely store backups.
class _CollectionNotWritable implements SyncFailureException {
  const _CollectionNotWritable(this.statusCode);

  final int statusCode;

  @override
  SyncFailure get syncFailure => SyncFailure(
    errorCode: 'provider.webdav.collection_not_writable',
    category: SyncErrorCategory.userActionRequired,
    retryable: true,
    providerStatusCode: statusCode,
    suggestedAction: '请选择有写入权限的实际共享文件夹后重试。',
  );

  @override
  String toString() =>
      'WebDAV could not create a private collection at the selected location.';
}

class _AtomicCreateProbeTimeout implements SyncFailureException {
  const _AtomicCreateProbeTimeout();

  @override
  SyncFailure get syncFailure => const SyncFailure(
    errorCode: 'provider.webdav.atomic_probe_timeout',
    category: SyncErrorCategory.transientNetwork,
    retryable: true,
    suggestedAction: '服务器响应超时，请检查网络后重试。',
  );

  @override
  String toString() => 'WebDAV atomic-create probe timed out.';
}
