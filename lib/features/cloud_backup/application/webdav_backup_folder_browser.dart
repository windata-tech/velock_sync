import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/remote_object_store_factory.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/providers/provider_request_exception.dart';
import 'package:xml/xml.dart';

class WebDavBackupFolder {
  const WebDavBackupFolder({required this.name});

  final String name;
}

/// Raised for sanitized WebDAV folder browser failures that are not HTTP
/// failures.
class WebDavBackupFolderException implements Exception {
  const WebDavBackupFolderException(this.code);

  final String code;

  @override
  String toString() => 'WebDAV backup folder browsing failed: $code';
}

/// Browses immediate child collections without modifying them. Folder creation
/// is only performed by [createFolder].
class WebDavBackupFolderBrowser {
  WebDavBackupFolderBrowser({
    required ConnectionRepository connections,
    Dio? dio,
    Duration timeout = const Duration(seconds: 20),
  }) : _connections = connections,
       _dio = dio ?? Dio(),
       _timeout = timeout {
    if (timeout <= Duration.zero) {
      throw ArgumentError('timeout must be positive');
    }
  }

  static const _davNamespace = 'DAV:';
  static const _propfindBody =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:">'
      '<d:prop><d:resourcetype/></d:prop>'
      '</d:propfind>';

  final ConnectionRepository _connections;
  final Dio _dio;
  final Duration _timeout;

  /// Returns a stable validation code for a new collection name.
  static String? folderNameError(String name) {
    if (name.trim().isEmpty) return 'empty_name';
    if (name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains(r'\') ||
        _containsControlCharacter(name) ||
        name != name.trim()) {
      return 'invalid_name';
    }
    if (utf8.encode(name).length > 255) return 'name_too_long';
    return null;
  }

  Future<List<WebDavBackupFolder>> list({
    required WebDavProtocolModel protocol,
    List<String> relativeSegments = const [],
  }) async {
    for (final segment in relativeSegments) {
      _validateRelativeSegment(segment);
    }

    final Uri target;
    try {
      final root = RemoteObjectStoreFactory.webDavUri(protocol);
      target = root.replace(
        pathSegments: [
          ...root.pathSegments.where((segment) => segment.isNotEmpty),
          ...relativeSegments,
          '',
        ],
        query: null,
        fragment: null,
      );
    } on ArgumentError {
      throw const WebDavBackupFolderException(
        'provider.webdav.invalid_configuration',
      );
    }

    final String? password;
    try {
      password = await _connections.readWebDavPassword(protocol.credentialRef);
    } catch (_) {
      throw const WebDavBackupFolderException('provider.webdav.request_failed');
    }
    final headers = <String, String>{
      'Depth': '1',
      'Accept': 'application/xml, text/xml',
      'Content-Type': 'application/xml; charset=utf-8',
    };
    final username = protocol.username;
    if (username != null &&
        username.isNotEmpty &&
        password != null &&
        password.isNotEmpty) {
      headers['Authorization'] =
          'Basic ${base64Encode(utf8.encode('$username:$password'))}';
    }

    final Response<String> response;
    try {
      response = await _dio
          .requestUri<String>(
            target,
            data: _propfindBody,
            options: Options(
              method: 'PROPFIND',
              responseType: ResponseType.plain,
              headers: headers,
              connectTimeout: _timeout,
              sendTimeout: _timeout,
              receiveTimeout: _timeout,
              followRedirects: false,
              maxRedirects: 0,
              validateStatus: (_) => true,
            ),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw const WebDavBackupFolderException('provider.webdav.browse_timeout');
    } on ProviderRequestException {
      rethrow;
    } on DioException catch (error) {
      final statusCode = error.response?.statusCode;
      if (statusCode != null) {
        throw ProviderRequestException.fromStatus(statusCode);
      }
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout) {
        throw const WebDavBackupFolderException(
          'provider.webdav.browse_timeout',
        );
      }
      throw const WebDavBackupFolderException('provider.webdav.request_failed');
    } catch (_) {
      throw const WebDavBackupFolderException('provider.webdav.request_failed');
    }

    final statusCode = response.statusCode;
    if (statusCode == null) {
      throw const FormatException('WebDAV response is invalid.');
    }
    if (statusCode != 207) {
      throw ProviderRequestException.fromStatus(statusCode);
    }

    final data = response.data;
    if (data == null) {
      throw const FormatException('WebDAV response is invalid.');
    }

    final XmlDocument document;
    try {
      document = XmlDocument.parse(data);
    } on XmlException {
      throw const FormatException('WebDAV response is invalid.');
    } on FormatException {
      throw const FormatException('WebDAV response is invalid.');
    }

    try {
      return _parseMultistatus(document, target);
    } on XmlException {
      throw const FormatException('WebDAV response is invalid.');
    } on StateError {
      throw const FormatException('WebDAV response is invalid.');
    }
  }

  /// Creates exactly one child collection after validating the requested path.
  Future<void> createFolder({
    required WebDavProtocolModel protocol,
    List<String> relativeSegments = const [],
    required String name,
  }) async {
    for (final segment in relativeSegments) {
      _validateRelativeSegment(segment);
    }

    final nameError = folderNameError(name);
    if (nameError != null) {
      throw WebDavBackupFolderException('provider.webdav.$nameError');
    }

    final Uri target;
    try {
      final root = RemoteObjectStoreFactory.webDavUri(protocol);
      target = root.replace(
        pathSegments: [
          ...root.pathSegments.where((segment) => segment.isNotEmpty),
          ...relativeSegments,
          name,
          '',
        ],
        query: null,
        fragment: null,
      );
    } on ArgumentError {
      throw const WebDavBackupFolderException(
        'provider.webdav.invalid_configuration',
      );
    }

    final String? password;
    try {
      password = await _connections.readWebDavPassword(protocol.credentialRef);
    } catch (_) {
      throw const WebDavBackupFolderException('provider.webdav.request_failed');
    }
    final headers = <String, String>{'Accept': 'application/xml, text/xml'};
    final username = protocol.username;
    if (username != null &&
        username.isNotEmpty &&
        password != null &&
        password.isNotEmpty) {
      headers['Authorization'] =
          'Basic ${base64Encode(utf8.encode('$username:$password'))}';
    }

    final Response<String> response;
    try {
      response = await _dio
          .requestUri<String>(
            target,
            options: Options(
              method: 'MKCOL',
              responseType: ResponseType.plain,
              headers: headers,
              connectTimeout: _timeout,
              sendTimeout: _timeout,
              receiveTimeout: _timeout,
              followRedirects: false,
              maxRedirects: 0,
              validateStatus: (_) => true,
            ),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw const WebDavBackupFolderException(
        'provider.webdav.create_outcome_unknown',
      );
    } on ProviderRequestException catch (error) {
      if (_isUnknownCreateStatus(error.statusCode)) {
        throw const WebDavBackupFolderException(
          'provider.webdav.create_outcome_unknown',
        );
      }
      rethrow;
    } on DioException catch (error) {
      final statusCode = error.response?.statusCode;
      if (statusCode != null) {
        if (_isUnknownCreateStatus(statusCode)) {
          throw const WebDavBackupFolderException(
            'provider.webdav.create_outcome_unknown',
          );
        }
        throw ProviderRequestException.fromStatus(statusCode);
      }
      throw const WebDavBackupFolderException(
        'provider.webdav.create_outcome_unknown',
      );
    } catch (_) {
      throw const WebDavBackupFolderException(
        'provider.webdav.create_outcome_unknown',
      );
    }

    final statusCode = response.statusCode;
    if (statusCode == 201) return;
    if (statusCode == null || _isUnknownCreateStatus(statusCode)) {
      throw const WebDavBackupFolderException(
        'provider.webdav.create_outcome_unknown',
      );
    }
    if (statusCode == 405) {
      throw ProviderRequestException.fromStatus(statusCode);
    }
    throw ProviderRequestException.fromStatus(statusCode);
  }

  static bool _isUnknownCreateStatus(int statusCode) =>
      (statusCode >= 200 && statusCode < 300) ||
      (statusCode >= 500 && statusCode <= 599);

  static void _validateRelativeSegment(String segment) {
    if (segment.isEmpty ||
        segment == '.' ||
        segment == '..' ||
        segment.contains('/') ||
        segment.contains(r'\') ||
        _containsControlCharacter(segment)) {
      throw ArgumentError(
        'relativeSegments must contain decoded, single path segments',
      );
    }
  }

  static List<WebDavBackupFolder> _parseMultistatus(
    XmlDocument document,
    Uri target,
  ) {
    final root = document.rootElement;
    if (root.name.local != 'multistatus' ||
        root.name.namespaceUri != _davNamespace) {
      throw const FormatException('WebDAV response is invalid.');
    }

    final names = <String>{};
    for (final response in _children(root, 'response')) {
      if (!_hasSuccessfulCollectionResourceType(response)) continue;

      final hrefElement = _firstChild(response, 'href');
      final href = hrefElement?.innerText.trim();
      if (href == null || href.isEmpty) continue;

      final name = _immediateChildName(href, target);
      if (name != null) names.add(name);
    }

    return names.map((name) => WebDavBackupFolder(name: name)).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  static bool _hasSuccessfulCollectionResourceType(XmlElement response) {
    for (final propstat in _children(response, 'propstat')) {
      final statusCode = _parseStatus(
        _firstChild(propstat, 'status')?.innerText,
      );
      if (statusCode != 200) continue;

      final prop = _firstChild(propstat, 'prop');
      if (prop == null) continue;
      final resourceType = _firstChild(prop, 'resourcetype');
      if (resourceType == null) continue;
      if (_children(resourceType, 'collection').isNotEmpty) return true;
    }
    return false;
  }

  static int? _parseStatus(String? value) {
    if (value == null) return null;
    final match = RegExp(
      r'^HTTP/\d+(?:\.\d+)?\s+(\d{3})(?:\s+.*)?$',
      caseSensitive: false,
    ).firstMatch(value.trim());
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  static String? _immediateChildName(String rawHref, Uri target) {
    final rawPath = _rawPath(rawHref);
    final rawSegments = rawPath == null ? null : _rawPathSegments(rawPath);
    if (rawSegments == null) return null;

    final href = Uri.tryParse(rawHref);
    if (href == null || href.hasQuery || href.hasFragment) return null;

    final Uri resolved;
    if (href.hasAuthority) {
      if (!href.hasScheme ||
          href.userInfo.isNotEmpty ||
          !_sameOrigin(href, target) ||
          !href.path.startsWith('/')) {
        return null;
      }
      resolved = href;
    } else if (!href.hasScheme && rawHref.startsWith('/')) {
      resolved = target.replace(path: href.path);
    } else {
      return null;
    }

    final targetSegments = _normalisedPathSegments(target);
    final hrefSegments = _normalisedPathSegments(resolved);
    if (rawSegments.length != targetSegments.length + 1 ||
        hrefSegments.length != targetSegments.length + 1) {
      return null;
    }
    for (var index = 0; index < targetSegments.length; index++) {
      if (hrefSegments[index] != targetSegments[index]) return null;
    }

    for (var index = 0; index < rawSegments.length; index++) {
      final decoded = _decodeRawSegment(rawSegments[index]);
      if (decoded == null ||
          decoded == '.' ||
          decoded == '..' ||
          (index >= targetSegments.length &&
              (decoded.contains('/') || decoded.contains(r'\')))) {
        return null;
      }
    }

    final name = hrefSegments.last;
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains(r'\') ||
        _containsControlCharacter(name)) {
      return null;
    }
    return name;
  }

  static String? _rawPath(String rawHref) {
    final value = rawHref.trim();
    if (value.isEmpty) return null;
    final queryIndex = value.indexOf('?');
    final fragmentIndex = value.indexOf('#');
    final end = switch ((queryIndex, fragmentIndex)) {
      (-1, -1) => value.length,
      (-1, final fragment) => fragment,
      (final query, -1) => query,
      (final query, final fragment) => query < fragment ? query : fragment,
    };
    final pathAndAuthority = value.substring(0, end);
    if (pathAndAuthority.startsWith('/')) return pathAndAuthority;

    final scheme = RegExp(
      r'^[A-Za-z][A-Za-z0-9+.-]*://',
    ).firstMatch(pathAndAuthority);
    if (scheme == null) return null;
    final afterAuthority = pathAndAuthority.substring(scheme.end);
    final pathStart = afterAuthority.indexOf('/');
    return pathStart == -1 ? '' : afterAuthority.substring(pathStart);
  }

  static List<String>? _rawPathSegments(String rawPath) {
    final segments = rawPath.split('/');
    if (segments.isNotEmpty && segments.first.isEmpty) {
      segments.removeAt(0);
    }
    if (segments.isNotEmpty && segments.last.isEmpty) {
      segments.removeLast();
    }
    return segments;
  }

  static String? _decodeRawSegment(String segment) {
    try {
      return Uri.decodeComponent(segment);
    } on FormatException {
      return null;
    }
  }

  static List<String> _normalisedPathSegments(Uri uri) {
    final segments = uri.pathSegments.toList();
    if (segments.isNotEmpty && segments.last.isEmpty) {
      segments.removeLast();
    }
    return segments;
  }

  static bool _containsControlCharacter(String value) {
    for (final codeUnit in value.codeUnits) {
      if (codeUnit < 0x20 || (codeUnit >= 0x7F && codeUnit <= 0x9F)) {
        return true;
      }
    }
    return false;
  }

  static bool _sameOrigin(Uri first, Uri second) =>
      first.scheme.toLowerCase() == second.scheme.toLowerCase() &&
      first.host.toLowerCase() == second.host.toLowerCase() &&
      first.port == second.port;

  static Iterable<XmlElement> _children(XmlElement parent, String localName) =>
      parent.children.whereType<XmlElement>().where(
        (element) =>
            element.name.local == localName &&
            element.name.namespaceUri == _davNamespace,
      );

  static XmlElement? _firstChild(XmlElement parent, String localName) {
    for (final child in parent.children.whereType<XmlElement>()) {
      if (child.name.local == localName &&
          child.name.namespaceUri == _davNamespace) {
        return child;
      }
    }
    return null;
  }
}
