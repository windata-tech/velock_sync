import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/providers/baidu_netdisk/baidu_netdisk_object_store.dart';
import 'package:velock_sync/providers/oauth/oauth_access_token_provider.dart';
import 'package:velock_sync/providers/provider_rate_limit_retry.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';

import 'stateful_object_store_contract.dart';

StatefulObjectStoreContractFixture baiduNetdiskContractFixture([
  BaiduContractCloud? cloud,
]) => StatefulObjectStoreContractFixture(
  providerName: 'baidu_netdisk',
  cloud: cloud ?? BaiduContractCloud(),
);

class _BaiduFile {
  _BaiduFile({required this.fsId, required this.path, required this.bytes});

  final int fsId;
  final String path;
  final List<int> bytes;

  Map<String, Object?> toJson() => {
    'fs_id': fsId,
    'path': path,
    'server_filename': path.substring(path.lastIndexOf('/') + 1),
    'isdir': 0,
    'size': bytes.length,
    'md5': md5.convert(bytes).toString(),
    'server_mtime': 1893499200,
  };
}

class _BaiduUpload {
  _BaiduUpload(this.path);

  final String path;
  final received = <int, List<int>>{};
}

/// Baidu Netdisk xpan: most failures are HTTP 200 with an `errno`, uploads go
/// to `d.pcs.baidu.com` as multipart blocks, and the token is a query param.
class BaiduContractCloud extends ContractCloud {
  static const rootPath = '/apps/Velock Sync/联调';
  static const _pcsHost = 'd.pcs.baidu.com';

  final _files = <String, _BaiduFile>{};
  final _duplicates = <String>{};
  final _directories = <String>{'/'};
  final _uploads = <String, _BaiduUpload>{};
  final spools = <Directory>[];
  int _nextId = 1;

  /// Makes `create` store the upload under a different name, as Baidu does
  /// when it auto-renames instead of honouring the requested path.
  bool renameOnCreate = false;

  @override
  int get partBytes => BaiduNetdiskObjectStore.blockBytes;

  @override
  String get createOperation => 'precreate';

  @override
  void reset() {
    super.reset();
    _files.clear();
    _duplicates.clear();
    _directories
      ..clear()
      ..add('/');
    _uploads.clear();
    spools.clear();
    renameOnCreate = false;
  }

  static String pathFor(String key) => '$rootPath/$key';

  void _store(String path, List<int> bytes) {
    _files[path] = _BaiduFile(fsId: _nextId++, path: path, bytes: bytes);
    for (
      var at = path.lastIndexOf('/');
      at > 0;
      at = path.lastIndexOf('/', at - 1)
    ) {
      _directories.add(path.substring(0, at));
    }
  }

  @override
  void seed(String key, List<int> bytes, {bool duplicateListing = false}) {
    _store(pathFor(key), bytes);
    if (duplicateListing) _duplicates.add(pathFor(key));
  }

  @override
  List<int>? bytesOf(String key) => _files[pathFor(key)]?.bytes;

  List<String> get storedPaths => _files.keys.toList();

  /// Absolute folder paths, including parents created by uploads.
  Set<String> get directories => Set.unmodifiable(_directories);

  /// Creates a folder (and its parents) without any file in it.
  void addDirectory(String path) {
    for (var at = path.length; at > 0; at = path.lastIndexOf('/', at - 1)) {
      _directories.add(path.substring(0, at));
    }
  }

  @override
  Future<RemoteObjectStore> createStore({
    required OAuthAccessTokenProvider tokens,
    required Dio dio,
    required ProviderRateLimitRetry retry,
  }) async => BaiduNetdiskObjectStore(
    accessTokenProvider: tokens,
    rootPath: rootPath,
    dio: dio,
    rateLimitRetry: retry,
    spoolDirectory: () async {
      final directory = await Directory.systemTemp.createTemp(
        'baidu-contract-',
      );
      spools.add(directory);
      return directory;
    },
  );

  /// The block spool may hold user content, so it must never outlive a put.
  @override
  Future<void> verifyClean() async {
    for (final spool in spools) {
      expect(
        spool.existsSync(),
        isFalse,
        reason: 'spool left at ${spool.path}',
      );
    }
  }

  @override
  CloudRequestKind kindOf(RequestOptions options) {
    if (options.uri.host != _pcsHost) return CloudRequestKind.api;
    return options.uri.path.contains('superfile2')
        ? CloudRequestKind.uploadPart
        : CloudRequestKind.download;
  }

  @override
  String operationOf(RequestOptions options, CloudRequestKind kind) =>
      kind == CloudRequestKind.download
      ? kind.name
      : options.uri.queryParameters['method'] ?? '';

  @override
  String? tokenOf(CloudRequest request) =>
      request.options.uri.queryParameters['access_token'];

  @override
  bool requiresToken(CloudRequestKind kind) => true;

  @override
  ResponseBody unauthorised(CloudRequest request) =>
      request.kind == CloudRequestKind.download
      ? ResponseBody.fromString('', 401)
      : jsonBody({'errno': 111, 'errmsg': 'access token invalid'});

  @override
  ResponseBody rateLimited() => jsonBody({'errno': 31034});

  @override
  ResponseBody quotaExceeded() => jsonBody({'errno': -10});

  ResponseBody _ok(Map<String, Object?> body) =>
      jsonBody({'errno': 0, ...body});
  ResponseBody _errno(int errno) => jsonBody({'errno': errno});

  @override
  Future<ResponseBody> handle(CloudRequest request) async {
    final options = request.options;
    expect(
      options.headers['User-Agent'],
      'pan.baidu.com',
      reason: 'Baidu rejects requests without its User-Agent',
    );
    final query = options.uri.queryParameters;
    if (request.kind == CloudRequestKind.download) {
      final file = _byId(int.tryParse(options.uri.pathSegments.last));
      if (file == null) return ResponseBody.fromString('', 404);
      return rangedBody(options, file.bytes);
    }
    if (request.kind == CloudRequestKind.uploadPart) {
      final upload = _uploads[query['uploadid']];
      if (upload == null || upload.path != query['path']) return _errno(31299);
      final part = _multipartFile(options, request.body);
      upload.received[int.parse(query['partseq']!)] = part;
      return jsonBody({'md5': md5.convert(part).toString()});
    }
    final form = request.body.isEmpty
        ? const <String, String>{}
        : Uri.splitQueryString(utf8.decode(request.body));
    return switch (request.operation) {
      'list' => _list(query),
      'listall' => _listAll(query),
      'filemetas' => _fileMetas(query),
      'precreate' => _precreate(form),
      'create' => _create(form),
      'filemanager' => _delete(query, form),
      _ => _errno(2),
    };
  }

  _BaiduFile? _byId(int? id) {
    for (final file in _files.values) {
      if (file.fsId == id) return file;
    }
    return null;
  }

  Map<String, Object?> _directoryJson(String path) => {
    'fs_id': path.hashCode,
    'path': path,
    'server_filename': path.substring(path.lastIndexOf('/') + 1),
    'isdir': 1,
    'size': 0,
  };

  List<Map<String, Object?>> _entriesUnder(
    String dir, {
    required bool recursive,
  }) {
    final base = dir == '/' ? '/' : '$dir/';
    bool inScope(String path) =>
        path.startsWith(base) &&
        (recursive || !path.substring(base.length).contains('/'));
    return [
      for (final path in [..._directories, ..._files.keys]..sort())
        if (path != dir && inScope(path)) ...[
          if (_files[path] case final file?) ...[
            file.toJson(),
            if (_duplicates.contains(path)) file.toJson(),
          ] else
            _directoryJson(path),
        ],
    ];
  }

  ResponseBody _list(Map<String, String> query) {
    final dir = query['dir']!;
    if (!_directories.contains(dir)) return _errno(-9);
    var entries = _entriesUnder(dir, recursive: false);
    if (query['folder'] == '1') {
      entries = entries.where((e) => e['isdir'] == 1).toList();
    }
    final start = int.parse(query['start'] ?? '0');
    final limit = int.parse(query['limit'] ?? '1000');
    return _ok({'list': entries.skip(start).take(limit).toList()});
  }

  ResponseBody _listAll(Map<String, String> query) {
    final dir = query['path']!;
    if (!_directories.contains(dir)) return _errno(-9);
    expect(query['recursion'], '1');
    final entries = _entriesUnder(dir, recursive: true);
    final start = int.parse(query['start']!);
    final end = (start + int.parse(query['limit']!)).clamp(0, entries.length);
    return _ok({
      'list': entries.sublist(start.clamp(0, entries.length), end),
      'has_more': end < entries.length ? 1 : 0,
      'cursor': end,
    });
  }

  ResponseBody _fileMetas(Map<String, String> query) {
    final ids = (jsonDecode(query['fsids']!) as List).cast<int>();
    return _ok({
      'list': [
        for (final id in ids)
          if (_byId(id) case final file?)
            {
              ...file.toJson(),
              if (query['dlink'] == '1')
                'dlink': 'https://$_pcsHost/file/${file.fsId}?fid=contract',
            },
      ],
    });
  }

  ResponseBody _precreate(Map<String, String> form) {
    final blocks = (jsonDecode(form['block_list']!) as List).cast<String>();
    final uploadId = 'upload-${_nextId++}';
    _uploads[uploadId] = _BaiduUpload(form['path']!);
    return _ok({
      'return_type': 1,
      'uploadid': uploadId,
      'path': form['path'],
      'block_list': [for (var i = 0; i < blocks.length; i++) i],
    });
  }

  ResponseBody _create(Map<String, String> form) {
    final path = form['path']!;
    if (form['isdir'] == '1') {
      expect(form['rtype'], '0', reason: 'folders must never be renamed');
      if (_directories.contains(path) || _files.containsKey(path)) {
        return _errno(-8);
      }
      addDirectory(path);
      return _ok({..._directoryJson(path), 'ctime': 1893499200});
    }
    final upload = _uploads.remove(form['uploadid']);
    if (upload == null || upload.path != path) return _errno(31299);
    final blocks = (jsonDecode(form['block_list']!) as List).cast<String>();
    final parts = [for (var i = 0; i < blocks.length; i++) upload.received[i]];
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part == null || md5.convert(part).toString() != blocks[i]) {
        return _errno(31363);
      }
    }
    final bytes = Uint8List.fromList([for (final part in parts) ...part!]);
    if (bytes.length != int.parse(form['size']!)) return _errno(31363);
    if (_files.containsKey(path) && form['rtype'] == '0') return _errno(-8);
    final stored = renameOnCreate ? '$path(1)' : path;
    committedUploads.add([for (final part in parts) part!.length]);
    _store(stored, bytes);
    return _ok(_files[stored]!.toJson());
  }

  ResponseBody _delete(Map<String, String> query, Map<String, String> form) {
    expect(query['opera'], 'delete');
    final paths = (jsonDecode(form['filelist']!) as List).cast<String>();
    final info = <Map<String, Object?>>[];
    for (final path in paths) {
      var removed = _files.remove(path) != null;
      if (_directories.contains(path) && path != '/') {
        // Deleting a folder removes everything inside it.
        _directories.removeWhere((d) => d == path || d.startsWith('$path/'));
        _files.removeWhere((f, _) => f.startsWith('$path/'));
        removed = true;
      }
      info.add({'path': path, 'errno': removed ? 0 : -9});
    }
    final failed = info.any((entry) => entry['errno'] != 0);
    return jsonBody({'errno': failed ? 12 : 0, 'info': info});
  }

  /// Extracts the single `file` field from a multipart/form-data body.
  static List<int> _multipartFile(RequestOptions options, Uint8List body) {
    final type =
        '${options.headers[Headers.contentTypeHeader] ?? options.contentType}';
    final boundary = RegExp(r'boundary=(.+)$').firstMatch(type)?.group(1);
    expect(boundary, isNotNull, reason: 'upload must be multipart: $type');
    expect(
      latin1.decode(
        body.sublist(0, body.length.clamp(0, 200)),
        allowInvalid: true,
      ),
      contains('name="file"'),
    );
    final headerEnd = _indexOf(body, ascii.encode('\r\n\r\n'), 0) + 4;
    final closing = ascii.encode('\r\n--$boundary--');
    final end = _lastIndexOf(body, closing);
    return body.sublist(headerEnd, end);
  }

  static int _indexOf(List<int> data, List<int> needle, int from) {
    for (var i = from; i <= data.length - needle.length; i++) {
      var match = true;
      for (var j = 0; j < needle.length && match; j++) {
        match = data[i + j] == needle[j];
      }
      if (match) return i;
    }
    fail('multipart delimiter not found');
  }

  static int _lastIndexOf(List<int> data, List<int> needle) {
    for (var i = data.length - needle.length; i >= 0; i--) {
      var match = true;
      for (var j = 0; j < needle.length && match; j++) {
        match = data[i + j] == needle[j];
      }
      if (match) return i;
    }
    fail('multipart closing boundary not found');
  }
}
