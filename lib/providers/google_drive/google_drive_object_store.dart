import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:velock_sync/providers/oauth/oauth_access_token_provider.dart';
import 'package:velock_sync/providers/provider_cancellation.dart';
import 'package:velock_sync/providers/provider_rate_limit_retry.dart';
import 'package:velock_sync/providers/provider_request_exception.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/infrastructure/network/sync_http.dart';

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
       _dio = dio ?? newSyncDio(),
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
    final file = await _find(logicalKey, cancellation: cancellation);
    return file == null ? null : _metadata(logicalKey, file.data);
  }

  /// The one lookup by name. It must carry the same `spaces` as [list]: Drive
  /// only searches `appDataFolder` when asked to, so a lookup without it finds
  /// nothing there and reads report "not found" while deletes silently skip.
  Future<_DriveFile?> _find(
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
            'spaces': _spaces,
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
    final id = file['id'];
    return id is String && id.isNotEmpty ? _DriveFile(id, file) : null;
  }

  String get _spaces => parentId == 'appDataFolder' ? 'appDataFolder' : 'drive';

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
            'spaces': _spaces,
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
    final metadata = await _find(logicalKey, cancellation: cancellation);
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
    final location = await _startUpload(
      _uploadUri,
      method: 'POST',
      metadata: {
        'name': _name(logicalKey),
        'parents': [parentId],
      },
      contentLength: contentLength,
      cancellation: cancellation,
    );
    final data = await _sendUpload(
      location,
      content,
      contentLength: contentLength,
      cancellation: cancellation,
    );
    return _metadata(logicalKey, data);
  }

  /// Opens a resumable upload: POST to create a file, PATCH on
  /// `/upload/drive/v3/files/{id}` to replace an existing file's content.
  /// Drive keeps the old content until the last byte has arrived.
  Future<Uri> _startUpload(
    Uri uri, {
    required String method,
    required Map<String, Object?> metadata,
    required int contentLength,
    RemoteOperationCancellation? cancellation,
  }) async {
    final session = await _request<void>(
      (headers) => _dio.requestUri(
        uri.replace(
          queryParameters: {
            'uploadType': 'resumable',
            'fields': _uploadedFields,
          },
        ),
        data: jsonEncode(metadata),
        options: _options(
          headers,
          (status) => status == 200 || status == 401 || status == 429,
          extraHeaders: {
            'X-Upload-Content-Type': 'application/octet-stream',
            'X-Upload-Content-Length': '$contentLength',
          },
        ).copyWith(method: method),
        cancelToken: dioCancelTokenFor(cancellation),
      ),
      cancellation: cancellation,
    );
    final location = session.headers.value('location');
    if (location == null) {
      throw const GoogleDriveException('Missing resumable upload URL.');
    }
    return Uri.parse(location);
  }

  static const _uploadedFields =
      'id,name,mimeType,size,modifiedTime,md5Checksum,version';

  Future<Map<String, dynamic>> _sendUpload(
    Uri location,
    Stream<List<int>> content, {
    required int contentLength,
    RemoteOperationCancellation? cancellation,
  }) async {
    Map<String, dynamic>? data;
    var offset = 0;
    if (contentLength == 0) {
      final completed = await _uploadChunk(
        location: location,
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
          location: location,
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
    return data;
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
    final file = await _find(logicalKey, cancellation: cancellation);
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
  const _DriveFile(this.id, this.data);
  final String id;
  final Map<String, dynamic> data;
}

class GoogleDriveException implements Exception {
  const GoogleDriveException(this.message);
  final String message;
  @override
  String toString() => 'GoogleDriveException: $message';
}

extension GoogleDriveMirrorAccess on GoogleDriveObjectStore {
  /// The connection's folder as a plain mirror of real, visible files.
  /// Only a connection signed in with full Drive access can use it, and never
  /// on the hidden app folder that holds Velock backups.
  GoogleDriveMirrorStore asMirror({List<String> scope = const []}) {
    if (parentId == 'appDataFolder') {
      throw StateError('The app folder is not a plain folder.');
    }
    return GoogleDriveMirrorStore._(this, scope);
  }
}

/// Google Drive as a folder tree with the user's own names, for file sync.
///
/// Drive addresses items by ID and lets one folder hold several items with
/// the same name. Paths are resolved one level at a time; a name that is not
/// unique fails the run with [GoogleDriveDuplicateNameException] instead of
/// guessing which item is meant. Google Docs, Sheets, shortcuts and other
/// Drive-native items have no file content and are left alone.
class GoogleDriveMirrorStore
    implements RemoteObjectStore, RemoteCollectionCreator {
  GoogleDriveMirrorStore._(this._store, this._scope);

  final GoogleDriveObjectStore _store;
  final List<String> _scope;

  static const _folderType = 'application/vnd.google-apps.folder';
  static const _fields =
      'id,name,mimeType,size,modifiedTime,md5Checksum,version';

  /// Folder IDs by path below the connection root, filled as folders are
  /// resolved, listed and created during this store's life (one sync run).
  final _folderIds = <String, String>{};

  /// Names seen so far while paging through a folder, and whether each was a
  /// file or folder sync keeps, so duplicates split across pages are found.
  final _listedNames = <String, Map<String, bool>>{};

  @override
  RemoteCapabilities get capabilities => _store.capabilities;

  @override
  Future<RemoteObjectMetadata?> stat(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    GoogleDriveObjectStore._validateKey(logicalKey);
    final item = await _entry(logicalKey, cancellation);
    if (item == null || _isNative(item)) return null;
    return _metadata(logicalKey, item);
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
    if (prefix.isNotEmpty) GoogleDriveObjectStore._validateKey(prefix);
    final segments = _segments(prefix);
    final folderId = await _folderId(segments, cancellation);
    if (folderId == null) throw RemoteObjectNotFoundException(prefix);
    // A picked folder that was deleted still answers a children query, with
    // nothing in it; check it is there before trusting an empty listing.
    if (cursor == null && segments.isEmpty && folderId != 'root') {
      final root = await _byId(folderId, cancellation);
      if (root == null || root['mimeType'] != _folderType) {
        throw RemoteObjectNotFoundException(prefix);
      }
    }
    final response = await _store._request<Map<String, dynamic>>(
      (headers) => _store._dio.getUri(
        GoogleDriveObjectStore._filesUri.replace(
          queryParameters: {
            'q': "'${_escape(folderId)}' in parents and trashed = false",
            'spaces': 'drive',
            'pageSize': '${limit > 1000 ? 1000 : limit}',
            'pageToken': ?cursor,
            'fields': 'nextPageToken,files($_fields)',
            'orderBy': 'name',
          },
        ),
        options: _store._options(
          headers,
          (status) => status == 200 || status == 401 || status == 429,
        ),
        cancelToken: dioCancelTokenFor(cancellation),
      ),
      cancellation: cancellation,
    );
    final seen = cursor == null
        ? (_listedNames[folderId] = {})
        : (_listedNames[folderId] ??= {});
    final parent = prefix.isEmpty ? '' : '$prefix/';
    final items = <RemoteObjectMetadata>[];
    final files = response.data?['files'];
    if (files is List) {
      for (final value in files) {
        if (value is! Map<String, dynamic>) continue;
        final name = value['name'];
        // Drive allows a "/" in a name; such an item has no path here.
        if (name is! String ||
            name.isEmpty ||
            name == '.' ||
            name == '..' ||
            name.contains('/')) {
          continue;
        }
        final kept = !_isNative(value);
        final earlier = seen[name];
        if (earlier != null && (earlier || kept)) {
          throw GoogleDriveDuplicateNameException('$parent$name');
        }
        seen[name] = kept || (earlier ?? false);
        if (!kept) continue;
        final key = '$parent$name';
        if (value['mimeType'] == _folderType && value['id'] is String) {
          _folderIds[[...segments, name].join('/')] = value['id'] as String;
        }
        items.add(_metadata(key, value));
      }
    }
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
    GoogleDriveObjectStore._validateKey(logicalKey);
    final item = await _entry(logicalKey, cancellation);
    final id = item?['id'];
    if (item == null ||
        id is! String ||
        item['mimeType'] == _folderType ||
        _isNative(item)) {
      throw RemoteObjectNotFoundException(logicalKey);
    }
    final response = await _store._request<ResponseBody>(
      (headers) => _store._dio.getUri(
        _store._fileUri(id, {'alt': 'media'}),
        options: _store._options(
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

  /// Writes a file. An existing file gets new content in place (same item,
  /// a new revision), so its sharing and history survive; Drive keeps the
  /// old content until the upload has finished.
  @override
  Future<RemoteObjectMetadata> put(
    String logicalKey,
    Stream<List<int>> content, {
    required int contentLength,
    bool ifAbsent = false,
    RemoteOperationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    GoogleDriveObjectStore._validateKey(logicalKey);
    if (contentLength < 0) {
      throw ArgumentError.value(contentLength, 'contentLength');
    }
    final segments = _segments(logicalKey);
    final name = segments.last;
    final parentId = await _folderId(
      segments.sublist(0, segments.length - 1),
      cancellation,
    );
    // The engine creates folders first; a missing one is a conflict.
    if (parentId == null) throw ProviderRequestException.fromStatus(409);
    final existing = await _named(parentId, name, logicalKey, cancellation);
    final Uri location;
    if (existing == null) {
      location = await _store._startUpload(
        GoogleDriveObjectStore._uploadUri,
        method: 'POST',
        metadata: {
          'name': name,
          'parents': [parentId],
        },
        contentLength: contentLength,
        cancellation: cancellation,
      );
    } else {
      if (existing['mimeType'] == _folderType) {
        throw ProviderRequestException.fromStatus(409);
      }
      // A Google Doc of that name has no content to replace.
      if (_isNative(existing)) {
        throw GoogleDriveDuplicateNameException(logicalKey);
      }
      if (ifAbsent) throw RemoteObjectAlreadyExistsException(logicalKey);
      location = await _store._startUpload(
        GoogleDriveObjectStore._uploadUri.replace(
          path: '${GoogleDriveObjectStore._uploadUri.path}/${existing['id']}',
        ),
        method: 'PATCH',
        metadata: const {},
        contentLength: contentLength,
        cancellation: cancellation,
      );
    }
    final data = await _store._sendUpload(
      location,
      content,
      contentLength: contentLength,
      cancellation: cancellation,
    );
    if (data['name'] is String && data['name'] != name) {
      throw const GoogleDriveException('Upload was stored under a new name.');
    }
    return _metadata(logicalKey, data);
  }

  /// Moves a file or a folder (with its contents) to the trash.
  @override
  Future<void> delete(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    GoogleDriveObjectStore._validateKey(logicalKey);
    final item = await _entry(logicalKey, cancellation);
    final id = item?['id'];
    // Already gone is a successful no-op; a Google Doc was never synced.
    if (item == null || id is! String || _isNative(item)) return;
    await _store._request<void>(
      (headers) => _store._dio.patchUri(
        _store._fileUri(id, {'fields': 'id'}),
        data: jsonEncode({'trashed': true}),
        options: _store._options(
          headers,
          (status) =>
              status == 200 || status == 401 || status == 404 || status == 429,
          extraHeaders: {Headers.contentTypeHeader: Headers.jsonContentType},
        ),
        cancelToken: dioCancelTokenFor(cancellation),
      ),
      cancellation: cancellation,
    );
    final path = _segments(logicalKey).join('/');
    _folderIds.removeWhere((key, _) => key == path || key.startsWith('$path/'));
  }

  /// Creates one folder. An existing folder of that name counts as created;
  /// a file there, or a missing parent, does not.
  @override
  Future<void> createCollection(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    GoogleDriveObjectStore._validateKey(logicalKey);
    final segments = _segments(logicalKey);
    final name = segments.last;
    final parentId = await _folderId(
      segments.sublist(0, segments.length - 1),
      cancellation,
    );
    if (parentId == null) throw ProviderRequestException.fromStatus(409);
    final existing = await _named(parentId, name, logicalKey, cancellation);
    if (existing != null) {
      if (existing['mimeType'] != _folderType) {
        throw ProviderRequestException.fromStatus(409);
      }
      _folderIds[segments.join('/')] = existing['id'] as String;
      return;
    }
    final response = await _store._request<Map<String, dynamic>>(
      (headers) => _store._dio.postUri(
        GoogleDriveObjectStore._filesUri.replace(
          queryParameters: {'fields': _fields},
        ),
        data: jsonEncode({
          'name': name,
          'mimeType': _folderType,
          'parents': [parentId],
        }),
        options: _store._options(
          headers,
          (status) => status == 200 || status == 401 || status == 429,
          extraHeaders: {Headers.contentTypeHeader: Headers.jsonContentType},
        ),
        cancelToken: dioCancelTokenFor(cancellation),
      ),
      cancellation: cancellation,
    );
    final id = response.data?['id'];
    if (id is! String || response.data?['name'] != name) {
      throw const GoogleDriveException('Folder was not created as asked.');
    }
    _folderIds[segments.join('/')] = id;
  }

  List<String> _segments(String logicalKey) => [
    ..._scope,
    if (logicalKey.isNotEmpty) ...logicalKey.split('/'),
  ];

  /// The ID of the folder at [segments], or null when any part is missing or
  /// is not a folder.
  Future<String?> _folderId(
    List<String> segments,
    RemoteOperationCancellation? cancellation,
  ) async {
    var id = _store.parentId;
    for (var i = 0; i < segments.length; i++) {
      final path = segments.sublist(0, i + 1).join('/');
      final cached = _folderIds[path];
      if (cached != null) {
        id = cached;
        continue;
      }
      final item = await _named(
        id,
        segments[i],
        _relative(segments.sublist(0, i + 1)),
        cancellation,
      );
      final found = item?['id'];
      if (item == null || found is! String || item['mimeType'] != _folderType) {
        return null;
      }
      _folderIds[path] = id = found;
    }
    return id;
  }

  Future<Map<String, dynamic>?> _entry(
    String logicalKey,
    RemoteOperationCancellation? cancellation,
  ) async {
    final segments = _segments(logicalKey);
    final parentId = await _folderId(
      segments.sublist(0, segments.length - 1),
      cancellation,
    );
    if (parentId == null) return null;
    return _named(parentId, segments.last, logicalKey, cancellation);
  }

  /// The one item called [name] in [parentId]; more than one is refused
  /// unless all of them are Drive-native items without content.
  Future<Map<String, dynamic>?> _named(
    String parentId,
    String name,
    String shownPath,
    RemoteOperationCancellation? cancellation,
  ) async {
    final response = await _store._request<Map<String, dynamic>>(
      (headers) => _store._dio.getUri(
        GoogleDriveObjectStore._filesUri.replace(
          queryParameters: {
            'q':
                "'${_escape(parentId)}' in parents and name = '${_escape(name)}' and trashed = false",
            'spaces': 'drive',
            'pageSize': '10',
            'fields': 'files($_fields)',
          },
        ),
        options: _store._options(
          headers,
          (status) => status == 200 || status == 401 || status == 429,
        ),
        cancelToken: dioCancelTokenFor(cancellation),
      ),
      cancellation: cancellation,
    );
    final files = [
      for (final value in response.data?['files'] as List? ?? const [])
        // Drive's name match ignores case for some scripts; keep exact ones.
        if (value is Map<String, dynamic> && value['name'] == name) value,
    ];
    // Several Google Docs of one name are fine: none of them is synced.
    if (files.length > 1 && !files.every(_isNative)) {
      throw GoogleDriveDuplicateNameException(shownPath);
    }
    return files.isEmpty ? null : files.first;
  }

  Future<Map<String, dynamic>?> _byId(
    String id,
    RemoteOperationCancellation? cancellation,
  ) async {
    final response = await _store._request<Map<String, dynamic>>(
      (headers) => _store._dio.getUri(
        _store._fileUri(id, {'fields': 'id,mimeType,trashed'}),
        options: _store._options(
          headers,
          (status) =>
              status == 200 || status == 401 || status == 404 || status == 429,
        ),
        cancelToken: dioCancelTokenFor(cancellation),
      ),
      cancellation: cancellation,
    );
    final data = response.data;
    if (response.statusCode == 404 || data == null || data['trashed'] == true) {
      return null;
    }
    return data;
  }

  /// [segments] as shown to the user: relative to the sync location when it
  /// lies inside it, else the whole path below the connection.
  String _relative(List<String> segments) =>
      segments.length > _scope.length &&
          _scope.indexed.every((entry) => segments[entry.$1] == entry.$2)
      ? segments.sublist(_scope.length).join('/')
      : segments.join('/');

  static bool _isNative(Map<String, dynamic> item) {
    final type = item['mimeType'];
    return type is String &&
        type != _folderType &&
        type.startsWith('application/vnd.google-apps.');
  }

  /// Drive query strings escape a backslash and a single quote.
  static String _escape(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll("'", r"\'");

  static RemoteObjectMetadata _metadata(String key, Map<String, dynamic> raw) {
    final folder = raw['mimeType'] == _folderType;
    final md5 = raw['md5Checksum'];
    final version = raw['version'];
    return RemoteObjectMetadata(
      logicalKey: key,
      size: folder ? 0 : int.tryParse('${raw['size'] ?? 0}') ?? 0,
      updatedAt:
          DateTime.tryParse('${raw['modifiedTime'] ?? ''}')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      etag: folder
          ? null
          : md5 is String
          ? md5
          : version == null
          ? null
          : 'v$version',
      isDirectory: folder,
    );
  }
}

/// Several items in one Drive folder share a name, so a path does not say
/// which one is meant. Sync stops rather than pick one.
class GoogleDriveDuplicateNameException implements SyncFailureException {
  const GoogleDriveDuplicateNameException(this.path);

  final String path;

  @override
  String toString() => 'Google Drive has several items with this name.';

  @override
  SyncFailure get syncFailure => SyncFailure(
    errorCode: 'provider.google.duplicate_name',
    category: SyncErrorCategory.datasetRejected,
    retryable: false,
    suggestedAction:
        'Google Drive 的同一个文件夹里有不止一个「$path」（同名文件、文件夹或 Google 文档）。请在 Google Drive 里把多余的改名或删除后再同步。',
  );
}
