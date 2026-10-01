import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:velock_sync/providers/oauth/oauth_access_token_provider.dart';
import 'package:velock_sync/providers/provider_cancellation.dart';
import 'package:velock_sync/providers/provider_rate_limit_retry.dart';
import 'package:velock_sync/providers/provider_request_exception.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/infrastructure/network/sync_http.dart';

/// The folder Baidu lets a third-party app write to: `/apps/<app name>`.
/// The name must match the app registered on the Baidu open platform.
/// An empty define (as in `oauth_keys.example.json`) means the default name.
const baiduNetdiskAppFolder =
    '/apps/${_baiduAppFolderDefine == '' ? 'Velock Sync' : _baiduAppFolderDefine}';

const _baiduAppFolderDefine = String.fromEnvironment(
  'BAIDU_NETDISK_APP_FOLDER',
);

/// The app folder for a user's own Baidu registration, named after the app
/// they registered; the build's folder when they did not give one.
String baiduNetdiskAppFolderFor(String? appName) =>
    appName == null || appName.isEmpty
    ? baiduNetdiskAppFolder
    : '/apps/$appName';

/// Baidu Netdisk (xpan open platform) object storage.
///
/// Logical keys map to real paths below [rootPath], so a chosen folder keeps
/// the same layout a WebDAV target would have. The xpan API reports most
/// failures as HTTP 200 with an `errno`; those are translated to the HTTP
/// status the shared retry helper and error mapping already understand.
class BaiduNetdiskObjectStore implements RemoteObjectStore {
  BaiduNetdiskObjectStore({
    required OAuthAccessTokenProvider accessTokenProvider,
    required String rootPath,
    Dio? dio,
    ProviderRateLimitRetry? rateLimitRetry,
    Future<Directory> Function()? spoolDirectory,
  }) : rootPath = normaliseRootPath(rootPath),
       _accessTokenProvider = accessTokenProvider,
       _dio = dio ?? newSyncDio(),
       _rateLimitRetry = rateLimitRetry ?? ProviderRateLimitRetry(),
       _spoolDirectory =
           spoolDirectory ??
           (() => Directory.systemTemp.createTemp('velock-baidu-'));

  static final _fileApi = Uri.https('pan.baidu.com', '/rest/2.0/xpan/file');
  static final _multimediaApi = Uri.https(
    'pan.baidu.com',
    '/rest/2.0/xpan/multimedia',
  );
  static final _uploadApi = Uri.https(
    'd.pcs.baidu.com',
    '/rest/2.0/pcs/superfile2',
  );

  /// Baidu computes block MD5s over fixed 4 MiB blocks for ordinary accounts.
  static const blockBytes = 4 * 1024 * 1024;
  static const _pageSize = 1000;
  static const _userAgent = 'pan.baidu.com';
  static const _forbiddenKeyCharacters = r'\?|"<>:*';

  final OAuthAccessTokenProvider _accessTokenProvider;
  final Dio _dio;
  final ProviderRateLimitRetry _rateLimitRetry;
  final Future<Directory> Function() _spoolDirectory;

  /// Absolute folder path without a trailing slash; empty is the drive root.
  final String rootPath;

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
    recommendedChunkBytes: blockBytes,
  );

  static String normaliseRootPath(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed == 'root' || trimmed == '/') return '';
    if (!trimmed.startsWith('/')) {
      throw ArgumentError.value(value, 'rootPath', 'must be absolute');
    }
    final parts = trimmed.split('/').skip(1).toList();
    while (parts.isNotEmpty && parts.last.isEmpty) {
      parts.removeLast();
    }
    if (parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw ArgumentError.value(value, 'rootPath', 'must be normalised');
    }
    return '/${parts.join('/')}';
  }

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
    if (prefix.startsWith('/')) throw ArgumentError.value(prefix, 'prefix');
    final slash = prefix.lastIndexOf('/');
    final directoryKey = slash < 0 ? '' : prefix.substring(0, slash);
    if (directoryKey.isNotEmpty) _validateKey(directoryKey);
    final directory = directoryKey.isEmpty
        ? (rootPath.isEmpty ? '/' : rootPath)
        : _pathFor(directoryKey);
    final start = cursor == null ? 0 : int.tryParse(cursor);
    if (start == null || start < 0) {
      throw ArgumentError.value(cursor, 'cursor');
    }
    final data = await _api(
      (token) => _dio.getUri(
        _multimediaApi.replace(
          queryParameters: {
            'method': 'listall',
            'access_token': token,
            'path': directory,
            'recursion': '1',
            'start': '$start',
            'limit': '$limit',
          },
        ),
        options: _options(),
        cancelToken: dioCancelTokenFor(cancellation),
      ),
      acceptedErrnos: const {_errnoNotFound},
      cancellation: cancellation,
    );
    // A folder that has never been written to simply has no objects yet; the
    // app-scoped folder, for example, only appears after the first upload.
    if (data['errno'] == _errnoNotFound) {
      return const RemoteObjectPage(items: []);
    }
    final itemsByKey = <String, RemoteObjectMetadata>{};
    for (final entry in _entries(data['list'])) {
      if (_isDirectory(entry)) continue;
      final key = _keyFromPath(entry['path']);
      if (key == null || !key.startsWith(prefix)) continue;
      itemsByKey.putIfAbsent(key, () => _metadata(key, entry));
    }
    final items = itemsByKey.values.toList()
      ..sort((a, b) => a.logicalKey.compareTo(b.logicalKey));
    final hasMore = data['has_more'] == 1 || data['has_more'] == true;
    final next = data['cursor'];
    return RemoteObjectPage(
      items: items,
      nextCursor: hasMore && next != null && '$next' != '$start'
          ? '$next'
          : null,
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
    final metas = await _api(
      (token) => _dio.getUri(
        _multimediaApi.replace(
          queryParameters: {
            'method': 'filemetas',
            'access_token': token,
            'fsids': jsonEncode([file['fs_id']]),
            'dlink': '1',
          },
        ),
        options: _options(),
        cancelToken: dioCancelTokenFor(cancellation),
      ),
      cancellation: cancellation,
    );
    final entries = _entries(metas['list']);
    final dlink = entries.isEmpty ? null : entries.first['dlink'];
    if (dlink is! String || dlink.isEmpty) {
      throw RemoteObjectNotFoundException(logicalKey);
    }
    final response = await _raw<ResponseBody>((token) {
      final link = Uri.parse(dlink);
      return _dio.getUri(
        link.replace(
          queryParameters: {...link.queryParameters, 'access_token': token},
        ),
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: true,
          validateStatus: (status) => status != null && status < 600,
          headers: {
            'User-Agent': _userAgent,
            if (start != null || endInclusive != null)
              'Range': 'bytes=${start ?? 0}-${endInclusive ?? ''}',
          },
        ),
        cancelToken: dioCancelTokenFor(cancellation),
      );
    }, cancellation: cancellation);
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
    if (ifAbsent &&
        await stat(logicalKey, cancellation: cancellation) != null) {
      throw RemoteObjectAlreadyExistsException(logicalKey);
    }
    final path = _pathFor(logicalKey);
    // Baidu needs every block MD5 before the upload starts, so the stream is
    // spooled once to a private temporary file while hashing each block.
    final directory = await _spoolDirectory();
    try {
      final spool = File('${directory.path}/object');
      final blocks = await _spool(content, spool, contentLength, cancellation);
      final blockList = jsonEncode(blocks);
      // rtype 0 refuses to replace an existing path; 3 overwrites it.
      final rtype = ifAbsent ? '0' : '3';
      final precreate = await _api(
        (token) => _dio.postUri(
          _fileApi.replace(
            queryParameters: {'method': 'precreate', 'access_token': token},
          ),
          data: {
            'path': path,
            'size': '$contentLength',
            'isdir': '0',
            'autoinit': '1',
            'rtype': rtype,
            'block_list': blockList,
          },
          options: _options(form: true),
          cancelToken: dioCancelTokenFor(cancellation),
        ),
        cancellation: cancellation,
      );
      if (precreate['return_type'] == 2) {
        final existing = precreate['info'];
        if (existing is Map<String, dynamic>) {
          return _metadata(logicalKey, existing);
        }
        final found = await _find(logicalKey, cancellation: cancellation);
        if (found == null) {
          throw const BaiduNetdiskException('Rapid upload left no file.');
        }
        return _metadata(logicalKey, found);
      }
      final uploadId = precreate['uploadid'];
      if (uploadId is! String || uploadId.isEmpty) {
        throw const BaiduNetdiskException('Missing upload session.');
      }
      final pending = precreate['block_list'];
      final parts = pending is List && pending.isNotEmpty
          ? pending.whereType<int>().toList()
          : List<int>.generate(blocks.length, (index) => index);
      for (final part in parts) {
        cancellation?.throwIfCancelled();
        if (part < 0 || part >= blocks.length) {
          throw const BaiduNetdiskException('Unexpected upload block.');
        }
        await _uploadBlock(
          spool: spool,
          path: path,
          uploadId: uploadId,
          part: part,
          contentLength: contentLength,
          cancellation: cancellation,
        );
      }
      final created = await _api(
        (token) => _dio.postUri(
          _fileApi.replace(
            queryParameters: {'method': 'create', 'access_token': token},
          ),
          data: {
            'path': path,
            'size': '$contentLength',
            'isdir': '0',
            'rtype': rtype,
            'uploadid': uploadId,
            'block_list': blockList,
          },
          options: _options(form: true),
          cancelToken: dioCancelTokenFor(cancellation),
        ),
        acceptedErrnos: const {_errnoExists},
        cancellation: cancellation,
      );
      if (created['errno'] == _errnoExists) {
        throw RemoteObjectAlreadyExistsException(logicalKey);
      }
      if (created['path'] is String && created['path'] != path) {
        // Baidu renamed the upload instead of writing the requested path.
        throw const BaiduNetdiskException(
          'Upload was stored under a new name.',
        );
      }
      return _metadata(logicalKey, created);
    } finally {
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        // The OS reclaims temporary directories; a leftover spool is harmless.
      }
    }
  }

  Future<List<String>> _spool(
    Stream<List<int>> content,
    File spool,
    int contentLength,
    RemoteOperationCancellation? cancellation,
  ) async {
    final sink = spool.openWrite();
    final blocks = <String>[];
    var block = BytesBuilder(copy: false);
    var written = 0;
    try {
      await for (final part in content) {
        cancellation?.throwIfCancelled();
        written += part.length;
        if (written > contentLength) {
          throw ArgumentError.value(
            content,
            'content',
            'exceeds declared length',
          );
        }
        sink.add(part);
        var offset = 0;
        while (offset < part.length) {
          final take = (blockBytes - block.length).clamp(
            0,
            part.length - offset,
          );
          block.add(part.sublist(offset, offset + take));
          offset += take;
          if (block.length == blockBytes) {
            blocks.add(md5.convert(block.takeBytes()).toString());
            block = BytesBuilder(copy: false);
          }
        }
      }
    } finally {
      await sink.close();
    }
    if (written != contentLength) {
      throw ArgumentError.value(
        content,
        'content',
        'ended before the declared length',
      );
    }
    // An empty object is still uploaded as a single (empty) block.
    if (block.length > 0 || blocks.isEmpty) {
      blocks.add(md5.convert(block.takeBytes()).toString());
    }
    return blocks;
  }

  Future<void> _uploadBlock({
    required File spool,
    required String path,
    required String uploadId,
    required int part,
    required int contentLength,
    RemoteOperationCancellation? cancellation,
  }) async {
    final start = part * blockBytes;
    final end = (start + blockBytes).clamp(0, contentLength);
    await _api(
      (token) async {
        final bytes = contentLength == 0
            ? Uint8List(0)
            : await _readRange(spool, start, end);
        return _dio.postUri(
          _uploadApi.replace(
            queryParameters: {
              'method': 'upload',
              'access_token': token,
              'type': 'tmpfile',
              'path': path,
              'uploadid': uploadId,
              'partseq': '$part',
            },
          ),
          data: FormData.fromMap({
            'file': MultipartFile.fromBytes(bytes, filename: 'blob'),
          }),
          options: _options(),
          cancelToken: dioCancelTokenFor(cancellation),
        );
      },
      retryServerErrors: true,
      cancellation: cancellation,
    );
  }

  static Future<Uint8List> _readRange(File file, int start, int end) async {
    final handle = await file.open();
    try {
      await handle.setPosition(start);
      return await handle.read(end - start);
    } finally {
      await handle.close();
    }
  }

  @override
  Future<void> delete(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) => _delete(
    logicalKey,
    includeDirectories: false,
    cancellation: cancellation,
  );

  /// This store seen as a plain folder tree for the file-sync mirror.
  BaiduNetdiskMirrorStore asMirror() => BaiduNetdiskMirrorStore._(this);

  Future<void> _delete(
    String logicalKey, {
    required bool includeDirectories,
    RemoteOperationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    _validateKey(logicalKey);
    Future<bool> exists() async =>
        await _find(
          logicalKey,
          includeDirectories: includeDirectories,
          cancellation: cancellation,
        ) !=
        null;
    if (!await exists()) return;
    final data = await _api(
      (token) => _dio.postUri(
        _fileApi.replace(
          queryParameters: {
            'method': 'filemanager',
            'opera': 'delete',
            'access_token': token,
          },
        ),
        data: {
          'async': '0',
          'filelist': jsonEncode([_pathFor(logicalKey)]),
        },
        options: _options(form: true),
        cancelToken: dioCancelTokenFor(cancellation),
      ),
      acceptedErrnos: const {_errnoNotFound, _errnoPartialFailure},
      cancellation: cancellation,
    );
    // Deleting an object that is already gone is a successful no-op; any
    // other per-file failure must not be reported as a delete.
    if (data['errno'] != 0 && await exists()) {
      throw ProviderRequestException.fromStatus(409);
    }
  }

  /// Lists the folders directly inside [parentPath] for the location picker.
  Future<({List<({String path, String name})> folders, String? nextCursor})>
  listChildFolders({String? parentPath, String? cursor}) async {
    final directory = normaliseRootPath(parentPath ?? '');
    final start = cursor == null ? 0 : int.tryParse(cursor) ?? 0;
    final data = await _api(
      (token) => _dio.getUri(
        _fileApi.replace(
          queryParameters: {
            'method': 'list',
            'access_token': token,
            'dir': directory.isEmpty ? '/' : directory,
            'folder': '1',
            'start': '$start',
            'limit': '$_pageSize',
            'order': 'name',
          },
        ),
        options: _options(),
      ),
      retryServerErrors: true,
      acceptedErrnos: const {_errnoNotFound},
    );
    final folders = <({String path, String name})>[];
    final entries = _entries(data['list']);
    for (final entry in entries) {
      final path = entry['path'];
      final name = entry['server_filename'];
      if (path is String && name is String) {
        folders.add((path: path, name: name));
      }
    }
    return (
      folders: folders,
      nextCursor: entries.length >= _pageSize
          ? '${start + entries.length}'
          : null,
    );
  }

  Future<Map<String, dynamic>?> _find(
    String logicalKey, {
    bool includeDirectories = false,
    RemoteOperationCancellation? cancellation,
  }) async {
    final path = _pathFor(logicalKey);
    final slash = path.lastIndexOf('/');
    final directory = slash == 0 ? '/' : path.substring(0, slash);
    final name = path.substring(slash + 1);
    for (var start = 0; ; start += _pageSize) {
      final data = await _api(
        (token) => _dio.getUri(
          _fileApi.replace(
            queryParameters: {
              'method': 'list',
              'access_token': token,
              'dir': directory,
              'start': '$start',
              'limit': '$_pageSize',
            },
          ),
          options: _options(),
          cancelToken: dioCancelTokenFor(cancellation),
        ),
        acceptedErrnos: const {_errnoNotFound},
        cancellation: cancellation,
      );
      if (data['errno'] == _errnoNotFound) return null;
      final entries = _entries(data['list']);
      for (final entry in entries) {
        if (entry['server_filename'] == name &&
            (includeDirectories || !_isDirectory(entry))) {
          return entry;
        }
      }
      if (entries.length < _pageSize) return null;
    }
  }

  /// Sends one xpan request, refreshing the token once when Baidu reports it
  /// as invalid, and returns the decoded body. Errnos outside
  /// [acceptedErrnos] become [ProviderRequestException]s.
  Future<Map<String, dynamic>> _api(
    Future<Response<Object?>> Function(String token) send, {
    bool retryServerErrors = false,
    Set<int> acceptedErrnos = const {},
    RemoteOperationCancellation? cancellation,
  }) async {
    final response = await _raw<Object?>(
      send,
      translate: true,
      retryServerErrors: retryServerErrors,
      cancellation: cancellation,
    );
    final data = _decode(response.data);
    final status = response.statusCode ?? 500;
    final errno = data['errno'];
    if (status == 200) return data;
    if (errno is int && acceptedErrnos.contains(errno)) return data;
    throw ProviderRequestException.fromStatus(
      status,
      retryAfter: _rateLimitRetry.retryAfter(
        response.headers.value('retry-after'),
      ),
    );
  }

  Future<Response<T>> _raw<T>(
    Future<Response<Object?>> Function(String token) send, {
    bool translate = false,
    bool retryServerErrors = false,
    RemoteOperationCancellation? cancellation,
  }) async {
    try {
      Future<Response<T>> request() async {
        var response = _translated<T>(
          await send(await _accessTokenProvider.bearerToken()),
          translate,
        );
        if (response.statusCode == 401) {
          response = _translated<T>(
            await send(
              await _accessTokenProvider.bearerToken(forceRefresh: true),
            ),
            translate,
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

  /// Rewrites a 200 response carrying a Baidu errno into the equivalent HTTP
  /// status, so rate limits and auth expiry take the shared code paths.
  static Response<T> _translated<T>(
    Response<Object?> response,
    bool translate,
  ) {
    var status = response.statusCode ?? 500;
    Object? data = response.data;
    if (translate) {
      final decoded = _decode(data);
      data = decoded;
      if (status >= 200 && status < 300) {
        final errno = decoded['errno'];
        status = errno == null || errno == 0 ? 200 : _statusForErrno(errno);
      }
    }
    return Response<T>(
      requestOptions: response.requestOptions,
      statusCode: status,
      headers: response.headers,
      data: data as T?,
    );
  }

  static const _errnoNotFound = -9;
  static const _errnoExists = -8;
  static const _errnoPartialFailure = 12;

  static int _statusForErrno(Object errno) => switch (errno) {
    -6 || 110 || 111 => 401,
    31034 => 429,
    -7 || 6 || 31045 => 403,
    _errnoNotFound || 31066 => 404,
    -10 => 507,
    _errnoExists => 409,
    31023 || 31299 => 500,
    _ => 400,
  };

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

  static bool _isDirectory(Map<String, dynamic> entry) =>
      entry['isdir'] == 1 || entry['isdir'] == true;

  static Iterable<Map<String, dynamic>> _entries(Object? value) =>
      value is List ? value.whereType<Map<String, dynamic>>() : const [];

  Options _options({bool form = false}) => Options(
    responseType: ResponseType.plain,
    contentType: form ? Headers.formUrlEncodedContentType : null,
    headers: const {'User-Agent': _userAgent},
    validateStatus: (status) => status != null && status < 600,
  );

  String _pathFor(String logicalKey) => '$rootPath/$logicalKey';

  String? _keyFromPath(Object? path) {
    if (path is! String) return null;
    final base = '$rootPath/';
    if (!path.startsWith(base)) return null;
    final key = path.substring(base.length);
    return key.isEmpty ? null : key;
  }

  static void _validateKey(String key) {
    if (key.isEmpty ||
        key.startsWith('/') ||
        key
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..') ||
        key.runes.any(
          (rune) =>
              rune < 0x20 ||
              _forbiddenKeyCharacters.contains(String.fromCharCode(rune)),
        )) {
      throw ArgumentError.value(
        key,
        'logicalKey',
        'must be a normalised relative key',
      );
    }
  }

  static RemoteObjectMetadata _metadata(String key, Map<String, dynamic> data) {
    final seconds = int.tryParse(
      '${data['server_mtime'] ?? data['mtime'] ?? ''}',
    );
    return RemoteObjectMetadata(
      logicalKey: key,
      size: int.tryParse('${data['size'] ?? 0}') ?? 0,
      updatedAt: seconds == null
          ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
          : DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true),
      etag: data['md5'] as String?,
      isDirectory: _isDirectory(data),
    );
  }
}

/// Baidu Netdisk as a plain folder tree, for the file-sync mirror.
///
/// Unlike the object view used for Velock backups, [list] returns the direct
/// children of one folder (folders included) and fails when that folder is
/// missing, so an unreadable remote is never mistaken for an empty one.
class BaiduNetdiskMirrorStore
    implements RemoteObjectStore, RemoteCollectionCreator {
  BaiduNetdiskMirrorStore._(this._store);

  final BaiduNetdiskObjectStore _store;

  @override
  RemoteCapabilities get capabilities => _store.capabilities;

  @override
  Future<RemoteObjectMetadata?> stat(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    _validate(logicalKey);
    final entry = await _store._find(
      logicalKey,
      includeDirectories: true,
      cancellation: cancellation,
    );
    return entry == null
        ? null
        : BaiduNetdiskObjectStore._metadata(logicalKey, entry);
  }

  @override
  Future<RemoteObjectPage> list({
    String prefix = '',
    String? cursor,
    int limit = 100,
    RemoteOperationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    if (limit < 1 || limit > BaiduNetdiskObjectStore._pageSize) {
      throw ArgumentError.value(limit, 'limit');
    }
    if (prefix.isNotEmpty) _validate(prefix);
    final start = cursor == null ? 0 : int.tryParse(cursor);
    if (start == null || start < 0) throw ArgumentError.value(cursor, 'cursor');
    final root = _store.rootPath;
    final directory = prefix.isEmpty
        ? (root.isEmpty ? '/' : root)
        : _store._pathFor(prefix);
    final data = await _store._api(
      (token) => _store._dio.getUri(
        BaiduNetdiskObjectStore._fileApi.replace(
          queryParameters: {
            'method': 'list',
            'access_token': token,
            'dir': directory,
            'start': '$start',
            'limit': '$limit',
            'order': 'name',
          },
        ),
        options: _store._options(),
        cancelToken: dioCancelTokenFor(cancellation),
      ),
      retryServerErrors: true,
      acceptedErrnos: const {BaiduNetdiskObjectStore._errnoNotFound},
      cancellation: cancellation,
    );
    if (data['errno'] == BaiduNetdiskObjectStore._errnoNotFound) {
      throw RemoteObjectNotFoundException(prefix);
    }
    final entries = BaiduNetdiskObjectStore._entries(data['list']).toList();
    final parent = prefix.isEmpty ? '' : '$prefix/';
    final items = <String, RemoteObjectMetadata>{};
    for (final entry in entries) {
      final key = _store._keyFromPath(entry['path']);
      // Only direct children of the requested folder belong on this page.
      if (key == null || !key.startsWith(parent)) continue;
      if (key.substring(parent.length).contains('/')) continue;
      items.putIfAbsent(
        key,
        () => BaiduNetdiskObjectStore._metadata(key, entry),
      );
    }
    return RemoteObjectPage(
      items: items.values.toList(),
      nextCursor: entries.length >= limit ? '${start + entries.length}' : null,
    );
  }

  @override
  Stream<List<int>> read(
    String logicalKey, {
    int? start,
    int? endInclusive,
    RemoteOperationCancellation? cancellation,
  }) {
    _validate(logicalKey);
    return _store.read(
      logicalKey,
      start: start,
      endInclusive: endInclusive,
      cancellation: cancellation,
    );
  }

  @override
  Future<RemoteObjectMetadata> put(
    String logicalKey,
    Stream<List<int>> content, {
    required int contentLength,
    bool ifAbsent = false,
    RemoteOperationCancellation? cancellation,
  }) {
    _validate(logicalKey);
    return _store.put(
      logicalKey,
      content,
      contentLength: contentLength,
      ifAbsent: ifAbsent,
      cancellation: cancellation,
    );
  }

  /// Deletes a file or a folder (Baidu removes a folder with its contents).
  @override
  Future<void> delete(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) {
    _validate(logicalKey);
    return _store._delete(
      logicalKey,
      includeDirectories: true,
      cancellation: cancellation,
    );
  }

  /// Creates one folder. An existing folder at that path counts as created;
  /// a file there, or a folder Baidu stored under another name, does not.
  @override
  Future<void> createCollection(
    String logicalKey, {
    RemoteOperationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    _validate(logicalKey);
    final path = _store._pathFor(logicalKey);
    final data = await _store._api(
      (token) => _store._dio.postUri(
        BaiduNetdiskObjectStore._fileApi.replace(
          queryParameters: {'method': 'create', 'access_token': token},
        ),
        // rtype 0: never rename, report the conflict instead.
        data: {'path': path, 'isdir': '1', 'rtype': '0'},
        options: _store._options(form: true),
        cancelToken: dioCancelTokenFor(cancellation),
      ),
      acceptedErrnos: const {BaiduNetdiskObjectStore._errnoExists},
      cancellation: cancellation,
    );
    if (data['errno'] == BaiduNetdiskObjectStore._errnoExists) {
      final existing = await _store._find(
        logicalKey,
        includeDirectories: true,
        cancellation: cancellation,
      );
      if (existing != null && BaiduNetdiskObjectStore._isDirectory(existing)) {
        return;
      }
      throw ProviderRequestException.fromStatus(409);
    }
    if (data['path'] is String && data['path'] != path) {
      throw const BaiduNetdiskException('Folder was created under a new name.');
    }
  }

  /// Baidu refuses some characters that local file systems allow; such a
  /// file is named in the failure instead of failing as an unknown error.
  static void _validate(String logicalKey) {
    try {
      BaiduNetdiskObjectStore._validateKey(logicalKey);
    } on ArgumentError {
      throw BaiduNetdiskUnsupportedNameException(logicalKey);
    }
  }
}

class BaiduNetdiskUnsupportedNameException implements SyncFailureException {
  const BaiduNetdiskUnsupportedNameException(this.logicalKey);

  final String logicalKey;

  @override
  String toString() => 'Baidu Netdisk cannot store this name.';

  @override
  SyncFailure get syncFailure => SyncFailure(
    errorCode: 'provider.baidu.unsupported_name',
    category: SyncErrorCategory.datasetRejected,
    retryable: false,
    suggestedAction:
        '百度网盘不支持文件名里的 \\ ? | " < > : * 这些字符，请在本机改名后再同步：$logicalKey',
  );
}

class BaiduNetdiskException implements Exception {
  const BaiduNetdiskException(this.message);
  final String message;
  @override
  String toString() => 'BaiduNetdiskException: $message';
}
